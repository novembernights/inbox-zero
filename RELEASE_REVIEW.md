# Source release review

## Scope

A fresh allowlisted source export for community development. The working application was not modified. No Git history, account databases, Keychain exports, app containers, provisioning profiles, certificates, local logs, screenshots, build products, environment files, or Xcode user settings were copied.

## Sanitization performed

- Removed personalized greetings, private mailbox shortcuts and email-to-account mapping.
- Removed configured OAuth clients, callback identifiers and Apple signing-team values.
- Replaced developer bundle/service identifiers with `org.example` placeholders or current-bundle-derived identifiers.
- Replaced all bundled message and search fixtures with fictional contacts and reserved example domains.
- Excluded the retired private revenue-feed implementation and the retired integration cleanup code.
- Excluded unrelated design skills, private artifacts, reference photos, campaign video, logos from sample campaigns, and unused desktop prototype views.
- Excluded the custom font; the public copy uses system typography.
- Removed PNG metadata and replaced the desktop personal monogram with the app mark.
- Disabled third-party sender-logo requests by default.
- Removed the relay bearer-token Info.plist setting; the unconfigured reference code reads a runtime Keychain value instead.
- Added empty developer configuration, ignore rules, MIT licensing, contributor/security/privacy documentation, upstream dependency notices and a privacy-check script.

Only the creator's name is retained as personal attribution in the project documentation/license. Third-party legal attribution is preserved in upstream notices.

## Verification and limits

Fresh verification completed on 16 October 2026 using Xcode 27.0 beta (27A5228h), cached packages matching `Package.resolved`, fresh build directories, empty build environments, and unsigned targets. Native sandbox execution was unavailable; the maintainer explicitly approved the normal local Xcode environment with these safeguards. This was not an OS-isolated execution audit.

| Check | Result |
| --- | --- |
| iOS Debug, generic iOS Simulator | Build passed after fixing a public-export Keychain visibility error |
| iOS Release, generic iPhone | Unsigned build passed |
| macOS Debug companion and embedded MailKit extension | Unsigned build passed; not launched against the host Mail account |
| Swift search parsing/ranking fixtures | Passed; fixed false-positive sender matching and added an exact full-name regression case |
| MIME attachment policy | All five fixture cases passed |
| Optional Python relay | Seven tests passed, including mock registration and delivery, missing/incorrect authorization, and invalid payload handling |
| Fresh iPhone 17e / iOS 27 simulator | App installed and launched successfully; reviewed screenshots of Ask/Metal orb, composer, attachments menu, All Mail menu, reader action rail, Settings, and normal empty Home |
| Built configuration | No configured OAuth client, push topic, relay URL or relay token; known private deployment-marker checks passed for all three app builds |

The relay's pinned requirements were installed into a disposable environment with explicit maintainer permission. Tests used fictional tokens, reserved example domains, and mocked Firestore/APNs. No cloud credentials or production services were used.

- The source privacy scanner passed, including its initial-history-free check.
- Xcode's project plist structure passed `plutil -lint`.
- JSON, XML/plist, asset metadata, scheme contents and PNG chunk/checksum structure were checked.
- Dependency license sources matched the revisions in the committed Swift package lockfile.
- Original allowlisted source files were hash-checked to confirm they were not changed by export preparation.
- The archive is generated from reviewed files with normalized metadata, not Finder's directory archive or an export of old Git history.
- The shader was traced to the MIT-licensed Liquid Orb Editor upstream and its notice retained; see `THIRD_PARTY_NOTICES.md`. The maintainer confirmed authorship of the retained star artwork. An unused gradient without confirmed provenance was excluded, without changing the rendered UI.

Builds still emit non-fatal Swift actor-isolation and SDK deprecation warnings. Success with this beta toolchain does not establish compatibility with every earlier Xcode version. The simulator screenshots establish rendering only: UI automation could not initialize because of a local workspace-path configuration issue, so drag gestures, press dent, menu transitions, keyboard/accessibility behavior and interactive picker flows were not exercised. No physical-device, live OAuth, iCloud send/receive, APNs, microphone recording, Apple Intelligence generation, or macOS Mail runtime claims are made. Those need contributor-owned configuration and hardware. The optional relay remains a reference, not a hardened public-user service.

This is a targeted privacy/source-release review, not a complete vulnerability audit or a guarantee that all possible secrets can be detected. No production service or personal login was accessed for validation. No credentials were revoked or changed.

## Publication scope and remaining release work

- This snapshot is prepared for publication as a community-development source release under MIT, subject to the retained upstream notices. It is not certification of production readiness, a legal opinion, or a complete security/accessibility audit.
- Run the remaining interactive and physical-device checks above using your own development configuration before distributing an installed app. Build products and local QA logs/screenshots are deliberately not in the source archive.
- Review and harden the optional relay before any public multi-user deployment. No public service is supplied.
- Review Git author email and publishing-account metadata before creating the first commit; see `PUBLISHING.md`.

The public-source checker should be rerun after any edits. Its pass covers the checked files, not future commits, installed apps, new screenshots or externally published metadata.
