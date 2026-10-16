import base64
import json
import os
import unittest
from unittest.mock import MagicMock, patch

os.environ.update({
    "REGISTRATION_TOKEN": "registration-test-token",
    "PUBSUB_WEBHOOK_TOKEN": "webhook-test-token",
    "IOS_BUNDLE_ID": "org.example.inboxzero.ios",
})

from app import app


class RelayHTTPTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_health(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["status"], "ok")

    def test_registration_requires_bearer_token(self):
        response = self.client.post("/v1/devices/register", json={})
        self.assertEqual(response.status_code, 401)

    def test_pubsub_requires_webhook_token(self):
        response = self.client.post("/v1/gmail/events", json={})
        self.assertEqual(response.status_code, 401)

    def test_invalid_pubsub_payload_is_rejected(self):
        response = self.client.post("/v1/gmail/events?token=webhook-test-token", json={"message": {"data": "bad"}})
        self.assertEqual(response.status_code, 400)

    def test_incorrect_registration_token_is_rejected(self):
        response = self.client.post("/v1/devices/register", json={},
                                    headers={"Authorization": "Bearer incorrect-test-token"})
        self.assertEqual(response.status_code, 401)

    @patch("app._db")
    def test_registration_normalizes_accounts(self, database):
        response = self.client.post("/v1/devices/register", json={
            "deviceToken": "a" * 64, "bundleID": "org.example.inboxzero.ios",
            "environment": "sandbox", "accounts": [" Alex@example.com ", "alex@example.com"],
        }, headers={"Authorization": "Bearer registration-test-token"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"registered": True, "accounts": 1})
        write = database.return_value.collection.return_value.document.return_value.set
        self.assertEqual(write.call_args.args[0]["accounts"], ["alex@example.com"])

    @patch("app._db")
    @patch("app._apns")
    def test_valid_event_delivers_using_mock_services(self, apns, database):
        snapshot = MagicMock()
        snapshot.to_dict.return_value = {
            "deviceToken": "a" * 64, "bundleID": "org.example.inboxzero.ios",
            "environment": "sandbox",
        }
        database.return_value.collection.return_value.where.return_value.stream.return_value = [snapshot]
        apns.return_value.send.return_value = (200, "")
        data = base64.b64encode(json.dumps({
            "emailAddress": "alex@example.com", "historyId": "123",
        }).encode()).decode()
        response = self.client.post("/v1/gmail/events?token=webhook-test-token",
                                    json={"message": {"data": data}})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"delivered": 1, "failed": 0})
        self.assertEqual(apns.return_value.send.call_args.kwargs["account_email"], "alex@example.com")


if __name__ == "__main__":
    unittest.main()

