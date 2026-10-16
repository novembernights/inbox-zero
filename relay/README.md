# Optional push-relay reference

This Python reference receives Gmail Watch notifications through Pub/Sub and forwards silent APNs notifications. It is not deployed, enabled, or associated with any account in this source release.

## Runtime configuration

Supply your own runtime environment through your deployment's secret manager:

- `REGISTRATION_TOKEN`: private development enrollment bearer credential.
- `PUBSUB_WEBHOOK_TOKEN`: development webhook credential.
- `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`: your APNs signing configuration.
- `IOS_BUNDLE_ID`: your iPhone app's bundle identifier.
- Your runtime's Google application credentials and Firestore project configuration.

No values are provided. Never place production credentials in this folder, a container image, a client app, or a tracked environment file.

## Endpoints and limitations

- `GET /healthz`
- `POST /v1/devices/register`
- `POST /v1/gmail/events`

Registrations store device tokens and account email addresses in Firestore. Mail bodies are not part of the intended relay payload, but mailbox metadata is personal data and requires appropriate access and retention controls.

This is a reference implementation. Static enrollment credentials and URL-query webhook tokens need redesign before a public multi-user deployment. Query strings can be logged by infrastructure. Add authenticated per-user/device enrollment, account ownership validation, revocation, replay protection, rate limits, retention policy and transport/deployment review. Do not treat the included HTTP tests as a complete security audit.

Dependencies are listed in `requirements.txt`; `Dockerfile` is provided for community development, not as a deployment instruction to an existing service.
