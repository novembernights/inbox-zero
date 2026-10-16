# inbox.Zer0

A native SwiftUI email-workflow foundation for iPhone, with a macOS Mail companion and an optional push-relay reference implementation.

Created by **Jason Johnson**. Released under the [MIT license](LICENSE).

## What is here

- Action, Waiting, Read Later, and Done queues, plus an All Mail library.
- Gmail OAuth and iCloud Mail connection infrastructure, with no preconfigured accounts.
- Compose, reply, attachment handling, local search, and on-device intelligence integration.
- A Metal-rendered Ask orb and a bottom action rail for message triage.
- Calendar context, local protected message storage, and Keychain credential storage.
- A macOS Mail companion and MailKit extension.
- An optional Python relay reference for Gmail Watch → APNs notifications.

This is a community-development source snapshot, not a production service or an audited security release. It includes no hosted backend, personal accounts, credentials, signing identity, mailbox export, or previous Git history. All bundled email examples are fictional.

## Quick start

1. Open `ActionMailApp.xcodeproj` in an Xcode version supporting the included project format and iOS 26 APIs. The upstream workspace was maintained with a newer Xcode toolchain; older Xcode versions may need project-setting adjustments.
2. Select the shared `inbox.Zer0iOS` scheme and an iOS 26+ simulator.
3. Resolve the public Swift packages listed in `Package.resolved` using your own development environment.
4. Run. The shared Debug scheme enables `-MockUIData`, which loads fictional preview messages. Remove that argument for a clean, empty mailbox before connecting an account.

Apple Intelligence features require compatible hardware, system settings, and model availability. A simulator can demonstrate UI without proving on-device intelligence or mail delivery.

For a physical device, choose your own signing team and unique bundle identifiers. See [SETUP.md](SETUP.md). Do not reuse anyone else's Apple account or OAuth application.

## Repository map

| Path | Purpose |
| --- | --- |
| `inbox.Zer0iOS/` | iPhone app, providers, local search and UI |
| `ActionMailApp/` | macOS companion |
| `ActionMailMailExtension/` | MailKit extension |
| `Config/` | Empty public defaults and ignored local configuration |
| `relay/` | Optional self-hosted push reference; disabled by default |
| `scripts/` | Fictional smoke fixtures and public-source privacy checks |
| `THIRD_PARTY_NOTICES.md` | Dependency and asset provenance notes |

## Before contributing or distributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [PRIVACY.md](PRIVACY.md). Run:

```sh
python3 scripts/check_public_export.py
```

Never attach real email, financial data, credentials, account identifiers, or unredacted screenshots to issues. Do not commit `Config/Local.xcconfig` or any Xcode user state.

See [RELEASE_REVIEW.md](RELEASE_REVIEW.md) for the sanitization scope and verification limits of this snapshot.
