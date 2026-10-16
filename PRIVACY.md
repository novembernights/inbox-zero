# Privacy and data flow

The source archive contains no saved user account, real mailbox cache, login session, private backend URL, or production credential. A fresh build is unconfigured. The example domains in preview data are reserved fictional examples.

When a developer deliberately connects their own account:

- Gmail authentication and mail operations contact Google's services.
- iCloud Mail operations connect to Apple's mail servers.
- OAuth and iCloud credentials are stored in Keychain; local message files use iOS file protection. Local search and personalization also persist app data on the device.
- Calendar context reads events only with the relevant permission.
- The intelligence implementation uses Apple's on-device FoundationModels framework. Speech availability and on-device requirements are controlled by the implementation and platform.
- Opening a full HTML email or external link can load sender-controlled remote content. This release is not a claim that all message rendering is network-isolated.
- Third-party logo lookup and sender-image fetching are disabled in the sanitized copy.
- An optional self-hosted relay would receive device tokens, account email addresses and Gmail history metadata, and use APNs. It is not configured in this release.

Do not describe this app as independently security-audited, universally local-only, or production-hardened. Review provider permissions, remote-content handling, retention, notifications, and relay authentication before public binary distribution.
