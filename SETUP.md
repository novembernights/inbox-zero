# Developer setup

## Configuration

`Config/Public.xcconfig` is the project's base configuration. It contains empty values and optionally includes `Config/Local.xcconfig`, which Git ignores. Copy `Config/Local.xcconfig.example` to that local filename and fill in only your own non-secret identifiers.

The `org.example` bundle IDs are placeholders. Choose unique IDs for all targets before device installation or distribution. The Mail extension must remain nested beneath the desktop app's bundle ID. No provisioning profiles, signing certificates, Apple team IDs, or private keys are included.

The shared iOS scheme starts with `-MockUIData` in Debug. Remove it before connecting a real account. Optional UI-only arguments include `-OpenAsk`, `-OpenAllMail`, `-OpenSettings`, and `-OpenSwipePreview`. Preview fixtures are not live mail and should not be used to verify sending or deletion.

## Gmail

Use your own Google Cloud project, enable the Gmail API, and configure an iOS OAuth client for your chosen bundle ID. Set:

```text
GMAIL_CLIENT_ID = your own OAuth client ID
GMAIL_REDIRECT_SCHEME = the corresponding reversed client ID
```

These identifiers are not passwords, but remain local to your build. The redirect scheme must be registered in the built app before sign-in; typing a client ID into Settings alone cannot register a new URL scheme. The source uses Google OAuth with PKCE and requests OpenID/email plus Gmail modify/compose scopes. Review Google's current verification and distribution requirements for your use case.

OAuth access and refresh tokens are written to the app's Keychain at runtime. No client secret is supplied or needed by this native-client flow. Sign in with your own account only after reviewing the permissions and code.

## iCloud Mail

The integration supports entering your own iCloud email and app-specific password through Settings. Credentials are stored in the app's device-only Keychain namespace. No saved account, password, or mailbox data is supplied. Use the account-management link in the app to manage your own credentials.

## Calendar and dictation

Calendar access is requested separately. Microphone and Speech permissions are required for dictation. Intelligence availability depends on Apple's supported hardware, models, language, and settings; do not assume simulator UI previews validate those capabilities.

## Optional notifications relay

The app works without a configured hosted relay. `GMAIL_PUSH_TOPIC` and `PUSH_RELAY_BASE_URL` are empty. See `relay/README.md` before considering deployment.

The legacy static registration-token transport is a reference integration, not a secure public-user enrollment design. The app reads a development-only relay credential from its own Keychain key `push-relay-registration-token`; there is deliberately no bundled token or public credential-provisioning UI. Public distribution needs an authenticated device-registration design, revocation, abuse controls, and a security review. Do not ship a shared secret in Info.plist or an xcconfig file.

## Checks

The standard-library privacy check needs Python 3 and no network:

```sh
python3 scripts/check_public_export.py
```

Build on your own Mac after reviewing dependencies:

```sh
xcodebuild -project ActionMailApp.xcodeproj -scheme inbox.Zer0iOS \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Run the fictional search-ranking and attachment-policy checks from the repository root:

```sh
sh scripts/run_smoke_tests.sh
```

For the optional relay, create a disposable Python environment, install `relay/requirements.txt`, then run `python -m unittest -v test_app` from `relay/`. The tests use dummy tokens and mock Firestore/APNs; no cloud account is needed.

These checks are not a complete test suite. Run them in an isolated development environment with only fictional data. Physical-device testing is still required for OAuth callbacks, iCloud transport, sending, background notifications, recording, and intelligence. See `RELEASE_REVIEW.md` for the exact configurations tested in this snapshot.
