#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODESIGN_IDENTITY:?Set your Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set the name of a saved notarytool keychain profile}"
case "$CODESIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *)
    # A SHA-1 identity avoids ambiguity when two certificates have the same name.
    [[ "$CODESIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] || {
      printf '%s\n' 'Use a Developer ID Application identity or its SHA-1 fingerprint.' >&2
      exit 1
    } ;;
esac
# Check the saved Apple login before spending time building and signing.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null; then
  printf '%s\n' 'Notarization preflight failed. See docs/NOTARIZATION.md#authentication-failures before retrying.' >&2
  exit 1
fi
CONFIGURATION=release bash scripts/build.sh
signing_details="$(codesign -dv --verbose=4 build/MacClaude.app 2>&1)"
[[ "$signing_details" == *"Authority=Developer ID Application:"* ]] || {
  printf '%s\n' 'The app must be signed with Developer ID Application before submission.' >&2
  exit 1
}
if [[ -n "${DEVELOPER_TEAM_ID:-}" && "$signing_details" != *"TeamIdentifier=$DEVELOPER_TEAM_ID"* ]]; then
  printf '%s\n' 'The signing team does not match DEVELOPER_TEAM_ID.' >&2
  exit 1
fi
ditto -c -k --keepParent build/MacClaude.app build/MacClaude-notarization.zip
xcrun notarytool submit build/MacClaude-notarization.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/MacClaude.app
xcrun stapler validate build/MacClaude.app
spctl --assess --type execute --verbose build/MacClaude.app
ditto -c -k --keepParent build/MacClaude.app build/MacClaude.zip
(cd build && shasum -a 256 MacClaude.zip > SHA256SUMS.txt)
printf '%s\n' 'Notarized build/MacClaude.zip is ready.'
