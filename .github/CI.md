# Continuous integration

The `CI` workflow runs for every pull request to `main`, pushes to `main`, and manual dispatches. Documentation-only changes also run the checks so the merge gate cannot remain pending because of path filters.

| Check | Coverage |
| --- | --- |
| Source privacy | Public-source privacy guardrail and whitespace |
| Relay tests | Python 3.12 tests with dummy credentials and mocked Firestore/APNs |
| iOS simulator build | Unsigned Debug app build using the committed Swift package versions |
| macOS build and Swift tests | Unsigned companion/MailKit build, search regression tests, MIME attachment tests |
| CI required | Passes only when all four jobs succeed; failure, cancellation, or skipping blocks it |

Apple builds use GitHub's `xcode-27` hosted runner and Xcode 27.0. No self-hosted runner, Apple signing identity, personal account, production secret, or deployment is involved. Actions are pinned to full commit SHAs; workflow tokens have read-only access and checkout does not persist Git credentials. Fork contributions use `pull_request`, never `pull_request_target`. GitHub may require maintainer approval before running a first-time contributor's workflow.

Branch protection is a GitHub repository setting, not enforced by this file. The intended main-branch rule requires `CI required` from GitHub Actions, an up-to-date branch and resolved review conversations; disallows force pushes/deletion; and applies to administrators. Pull requests are required, but an additional approval is not required for a solo maintainer. A workflow change should always receive careful human review.

These checks do not test actual email delivery, account sign-in, recording, Apple Intelligence generation, or UI gestures. The privacy guardrail is not a complete secret scanner or security audit. See `RELEASE_REVIEW.md` for the initial local verification history.

## When a check fails

1. Open the pull request's **Checks** tab and select the failing job.
2. Reproduce with the commands in the README using fictional data.
3. Push the fix to the same branch; the new run replaces the old run for that pull request.
4. If `main` has changed, update your branch and wait for fresh passing checks.

Do not bypass a failing gate or add real credentials to make tests pass. No scheduled runs or publishing workflow are configured.
