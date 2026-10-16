import base64
import hashlib
import json
import os
import time
from dataclasses import dataclass
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from flask import Flask, Response, jsonify, request
from google.cloud import firestore
import httpx


app = Flask(__name__)


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _constant_time_equal(left: str, right: str) -> bool:
    return bool(left and right) and hashlib.sha256(left.encode()).digest() == hashlib.sha256(right.encode()).digest()


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


@dataclass(frozen=True)
class APNSConfig:
    key_id: str
    team_id: str
    private_key: str


class APNSClient:
    def __init__(self, config: APNSConfig):
        self.config = config
        self._key = serialization.load_pem_private_key(config.private_key.encode(), password=None)
        if not isinstance(self._key, ec.EllipticCurvePrivateKey):
            raise ValueError("APNs key must be an elliptic-curve private key")

    def _jwt(self) -> str:
        header = _b64url(json.dumps({"alg": "ES256", "kid": self.config.key_id}, separators=(",", ":")).encode())
        claims = _b64url(json.dumps({"iss": self.config.team_id, "iat": int(time.time())}, separators=(",", ":")).encode())
        signing_input = f"{header}.{claims}".encode()
        der = self._key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return f"{header}.{claims}.{_b64url(signature)}"

    def send(self, *, device_token: str, bundle_id: str, environment: str, account_email: str, history_id: str) -> tuple[int, str]:
        host = "api.sandbox.push.apple.com" if environment == "sandbox" else "api.push.apple.com"
        body = json.dumps({
            "aps": {"content-available": 1},
            "inboxZero": {"accountEmail": account_email, "historyId": history_id},
        }, separators=(",", ":"))
        with httpx.Client(http2=True, timeout=15) as client:
            response = client.post(
                f"https://{host}/3/device/{device_token}",
                content=body,
                headers={
                    "authorization": f"bearer {self._jwt()}",
                    "apns-topic": bundle_id,
                    "apns-push-type": "background",
                    "apns-priority": "5",
                    "content-type": "application/json",
                },
            )
        return response.status_code, response.text


# Imported separately to keep the cryptographic conversion explicit and testable.
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


def _db():
    return firestore.Client()


def _apns():
    return APNSClient(APNSConfig(
        key_id=_required_env("APNS_KEY_ID"),
        team_id=_required_env("APNS_TEAM_ID"),
        private_key=_required_env("APNS_PRIVATE_KEY"),
    ))


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "service": "inbox-zero-push-relay"})


@app.post("/v1/devices/register")
def register_device():
    expected = _required_env("REGISTRATION_TOKEN")
    supplied = request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not _constant_time_equal(supplied, expected):
        return jsonify({"error": "unauthorized"}), 401

    payload = request.get_json(silent=True) or {}
    token = str(payload.get("deviceToken", "")).lower()
    bundle_id = str(payload.get("bundleID", ""))
    environment = str(payload.get("environment", ""))
    accounts = sorted({str(item).strip().lower() for item in payload.get("accounts", []) if str(item).strip()})
    if len(token) != 64 or any(char not in "0123456789abcdef" for char in token):
        return jsonify({"error": "invalid device token"}), 400
    if bundle_id != _required_env("IOS_BUNDLE_ID") or environment not in {"sandbox", "production"} or not accounts:
        return jsonify({"error": "invalid registration"}), 400

    document_id = hashlib.sha256(f"{bundle_id}:{environment}:{token}".encode()).hexdigest()
    _db().collection("pushDevices").document(document_id).set({
        "deviceToken": token,
        "bundleID": bundle_id,
        "environment": environment,
        "accounts": accounts,
        "watchExpirations": payload.get("watchExpirations", {}),
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }, merge=True)
    return jsonify({"registered": True, "accounts": len(accounts)})


@app.post("/v1/gmail/events")
def gmail_event():
    expected = _required_env("PUBSUB_WEBHOOK_TOKEN")
    supplied = request.args.get("token", "")
    if not _constant_time_equal(supplied, expected):
        return jsonify({"error": "unauthorized"}), 401

    envelope: dict[str, Any] = request.get_json(silent=True) or {}
    encoded = ((envelope.get("message") or {}).get("data") or "")
    try:
        decoded = json.loads(base64.b64decode(encoded).decode("utf-8"))
        account_email = str(decoded["emailAddress"]).strip().lower()
        history_id = str(decoded["historyId"])
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        return jsonify({"error": "invalid Pub/Sub envelope"}), 400

    successes = 0
    failures: list[dict[str, Any]] = []
    client = _apns()
    for snapshot in _db().collection("pushDevices").where("accounts", "array_contains", account_email).stream():
        device = snapshot.to_dict()
        status, response_body = client.send(
            device_token=device["deviceToken"],
            bundle_id=device["bundleID"],
            environment=device["environment"],
            account_email=account_email,
            history_id=history_id,
        )
        if status == 200:
            successes += 1
        else:
            failures.append({"device": snapshot.id, "status": status, "reason": response_body[:200]})

    # Acknowledge valid Gmail events even when there is no currently registered
    # device. Retrying cannot repair an absent/expired APNs registration.
    app.logger.info("gmail event account=%s history=%s successes=%d failures=%s", account_email, history_id, successes, failures)
    return jsonify({"delivered": successes, "failed": len(failures)}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
