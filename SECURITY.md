# Security

This is a development foundation, not a security-certified email client.

Never put credentials, real emails, attachments, personal identifiers, or exploitable secrets into a public issue. Once the repository is published, maintainers should enable GitHub private vulnerability reporting and secret scanning before accepting security reports.

Use private reporting if enabled. If it is not enabled, ask maintainers to establish a private reporting route without posting sensitive details.

The source sanitation check is a guardrail, not a complete secret detector or vulnerability audit. Review every outgoing commit and enable push protection where available. If a real secret is ever published, revoke or rotate it; removing it from the newest source does not erase Git history or copies.
