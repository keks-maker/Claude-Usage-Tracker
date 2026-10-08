#!/usr/bin/env bash
# Builds the personal fork variant "Claude Usage Fork" (Release, own bundle ID,
# Sparkle auto-update disabled, signed with the local Apple Development identity),
# then replaces /Applications/Claude Usage Fork.app and relaunches it.
# Never touches /Applications/Claude Usage.app. No credentials or team IDs are
# stored here; the signing identity and team are detected from the keychain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME_FORK="Claude Usage Fork"
BUNDLE_ID_FORK="HamedElfayome.Claude-Usage.fork"
DEST="/Applications/${PRODUCT_NAME_FORK}.app"

if [[ "$DEST" == "/Applications/Claude Usage.app" ]]; then
  echo "Refusing to overwrite the original app." >&2
  exit 1
fi

# First Apple Development identity: SHA-1 hash and certificate name.
IDENTITY_LINE="$(security find-identity -v -p codesigning | grep '"Apple Development:' | head -n 1 || true)"
if [[ -z "$IDENTITY_LINE" ]]; then
  echo "No 'Apple Development' signing identity found." >&2
  exit 1
fi
IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"

# Team ID = OU of the certificate subject.
TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F'= *' '/organizationalUnitName/ {print $2; exit}' || true)"
if [[ -z "$TEAM_ID" ]]; then
  echo "Could not determine the team ID from the certificate." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-fork.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Info.plist copy without Sparkle feed/key and with automatic updates off.
FORK_PLIST="$WORK_DIR/Info.plist"
cp "$REPO_ROOT/Claude Usage/Resources/Info.plist" "$FORK_PLIST"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Delete :SUFeedURL" "$FORK_PLIST" 2>/dev/null || true
"$PB" -c "Delete :SUPublicEDKey" "$FORK_PLIST" 2>/dev/null || true
"$PB" -c "Set :SUEnableAutomaticChecks false" "$FORK_PLIST"
"$PB" -c "Set :SUAllowsAutomaticUpdates false" "$FORK_PLIST"

DERIVED="$WORK_DIR/DerivedData"
xcodebuild \
  -project "$REPO_ROOT/Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  PRODUCT_NAME="$PRODUCT_NAME_FORK" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID_FORK" \
  INFOPLIST_FILE="$FORK_PLIST" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY_HASH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build

BUILT="$DERIVED/Build/Products/Release/${PRODUCT_NAME_FORK}.app"
if [[ ! -d "$BUILT" ]]; then
  echo "Build product not found: $BUILT" >&2
  exit 1
fi

# Quit only the running fork (matched by bundle ID), not the original app.
osascript -e "tell application id \"$BUNDLE_ID_FORK\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f "${DEST}/Contents/MacOS/" >/dev/null || break
  sleep 0.5
done
pkill -f "${DEST}/Contents/MacOS/" 2>/dev/null || true

rm -rf "$DEST"
ditto "$BUILT" "$DEST"
open "$DEST"
echo "Installed and started $DEST"
