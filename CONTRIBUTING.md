# Contributing

The goal is to evolve a clear, private, native email-workflow foundation.

Use the [issue chooser](https://github.com/novembernights/inbox-zero/issues/new/choose) for a guided **bug report** or **feature request**. Bug reports ask for reproduction steps, versions, and sanitized evidence; feature requests start with the user need and success criteria. For sensitive vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of posting details publicly.

New pull requests include a template for scope, linked issues, verification, UI evidence, and privacy/licensing checks. Mark unperformed checks as **Not run** and explain why. Required CI must pass, the branch must be current with `main`, and review conversations must be resolved before merge.

1. Open an issue describing the problem and proposed scope. Use fictional examples.
2. Make a focused branch and preserve existing mail behavior unless explicitly changing it.
3. Add regression coverage for parsers, search, persistence, and provider changes.
4. For UI changes, include screenshots using the fictional preview mailbox, including light/dark appearance and accessibility sizing where relevant.
5. Run the privacy check and review your staged diff for credentials and identifying data.
6. State separately what was checked in source, in the simulator, and on a real device.

Do not commit signing identities, provisioning profiles, local settings, token dumps, real email fixtures, contact lists, or private screenshots. New service integrations must start unconfigured and document what information leaves the device. Keep required third-party attribution and supply redistribution licenses for new assets.

Contributions are submitted under this repository's MIT license. Only contribute work you have permission to distribute. Retain the creator copyright notice and existing third-party notices.
