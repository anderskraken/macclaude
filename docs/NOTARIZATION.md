# Developer ID signing and notarization

## Verify a download

Download `MacClaude.zip` and `SHA256SUMS.txt` from the [same release](https://github.com/anderskraken/macclaude/releases/tag/v0.2.6). In their download directory, check the archive before extracting it:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

After extracting, run these commands from the directory containing `MacClaude.app` (Apple command line tools are required for `stapler`):

```sh
codesign --verify --strict --verbose=2 MacClaude.app
codesign -dv --verbose=4 MacClaude.app
xcrun stapler validate MacClaude.app
spctl --assess --type execute --verbose=2 MacClaude.app
```

Expect `Developer ID Application: Snega AS (P5VRX5EBV4)`, `TeamIdentifier=P5VRX5EBV4`, a valid stapled ticket, and Gatekeeper acceptance with `source=Notarized Developer ID`. A checksum detects an altered or incomplete download; the signature identifies the signer. Notarization does not guarantee the absence of bugs.

## Publish a release

Official previews from 0.2.2 onward use Developer ID signing and notarization. To distribute your own build, use your own signing identity and credentials. A notarized release requires:

1. An installed **Developer ID Application** certificate and its private key for the intended Apple Developer team. Apple Development certificates cannot substitute for this distribution identity.
2. A validated `notarytool` Keychain profile for that team.

Create or import the certificate through Xcode’s account certificate management or the [Apple Developer account](https://developer.apple.com/help/account/certificates/create-developer-id-certificates). Store notarization credentials locally using the interactive command:

```sh
xcrun notarytool store-credentials macclaude-notary
```

The command prompts for credentials; enter them locally, never in source files or chat. Apple documents the credential options in its [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Then run:

```sh
CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE='macclaude-notary' make notarize
```

The script builds a release app with its MIT license, signs with hardened runtime and a secure timestamp, submits to Apple, staples and validates the ticket, checks Gatekeeper, and creates `build/MacClaude.zip` and `build/SHA256SUMS.txt`. Any failed step stops publication. Only upload these resulting artifacts after successful validation. Use a new release version for the signed distribution.

No credentials or private signing keys belong in Git. The ordinary CI workflow builds and tests without distribution credentials.

If two installed certificates have the same name, set `CODESIGN_IDENTITY` to the desired certificate’s SHA-1 fingerprint from `security find-identity -v -p codesigning`. The script verifies Developer ID signing before submission. Set `DEVELOPER_TEAM_ID=YOUR_TEAM_ID` to require your signing team.
