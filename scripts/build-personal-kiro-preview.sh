#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this packaging script requires macOS." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
IDENTITY="Developer ID Application: Fred Lackey (45X9J287ZA)"
NOTARY_PROFILE="buzz-fredlackey-notary"
APP_NAME="Buzz Kiro Preview"
ARCH=$(uname -m)
VERSION=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$REPO_ROOT/desktop/package.json" | head -1)
if [[ -z "$VERSION" ]]; then
  echo "Error: unable to read the desktop version." >&2
  exit 1
fi
BUNDLE_ROOT="$REPO_ROOT/desktop/src-tauri/target/release/bundle"
APP_PATH="$BUNDLE_ROOT/macos/$APP_NAME.app"
DMG_DIR="$BUNDLE_ROOT/dmg"
DMG_PATH="$DMG_DIR/Buzz_Kiro_Preview_${VERSION}_${ARCH}.dmg"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buzz-kiro-preview.XXXXXX")
MOUNT_PATH="$TEMP_ROOT/mount"
ATTACHED=0

cleanup() {
  if [[ "$ATTACHED" == "1" ]]; then
    hdiutil detach "$MOUNT_PATH" -quiet || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

cd "$REPO_ROOT"
# shellcheck source=bin/activate-hermit
. "$REPO_ROOT/bin/activate-hermit"

if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  echo "Error: signing identity is unavailable: $IDENTITY" >&2
  exit 1
fi

echo "Validating saved Apple notarization credentials..."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null

echo "Installing pinned frontend dependencies..."
pnpm install --frozen-lockfile

echo "Building release sidecars..."
cargo build --release \
  -p buzz-acp \
  -p buzz-agent \
  -p buzz-dev-mcp \
  -p git-credential-nostr \
  -p buzz-cli
./scripts/bundle-sidecars.sh

echo "Building and signing $APP_NAME..."
export BUZZ_BUILD_KEYRING_SERVICE="buzz-desktop-kiro-preview"
export BUZZ_BUILD_NEST_DIR=".buzz-kiro-preview"
unset BUZZ_UPDATER_PUBLIC_KEY BUZZ_UPDATER_ENDPOINT
(
  cd desktop
  pnpm exec tauri build \
    --verbose \
    --bundles app \
    --config src-tauri/tauri.kiro-preview.conf.json
)

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: expected app bundle not found: $APP_PATH" >&2
  exit 1
fi

for sidecar in buzz-acp buzz-agent buzz-dev-mcp git-credential-nostr buzz; do
  if [[ ! -x "$APP_PATH/Contents/MacOS/$sidecar" ]]; then
    echo "Error: bundled sidecar is not executable: $sidecar" >&2
    exit 1
  fi
done

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Submitting the signed app to Apple for notarization..."
APP_ZIP="$TEMP_ROOT/Buzz_Kiro_Preview.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "Creating the private team DMG..."
DMG_STAGE="$TEMP_ROOT/dmg-root"
mkdir -p "$DMG_STAGE" "$DMG_DIR"
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "Submitting the DMG to Apple for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Verifying the final DMG and enclosed application..."
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
mkdir -p "$MOUNT_PATH"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_PATH" "$DMG_PATH" -quiet
ATTACHED=1
codesign --verify --deep --strict --verbose=2 "$MOUNT_PATH/$APP_NAME.app"
for sidecar in buzz-acp buzz-agent buzz-dev-mcp git-credential-nostr buzz; do
  if [[ ! -x "$MOUNT_PATH/$APP_NAME.app/Contents/MacOS/$sidecar" ]]; then
    echo "Error: packaged sidecar is not executable: $sidecar" >&2
    exit 1
  fi
done
spctl --assess --type execute --verbose=4 "$MOUNT_PATH/$APP_NAME.app"
hdiutil detach "$MOUNT_PATH" -quiet
ATTACHED=0

echo
echo "Private preview package:"
echo "  $DMG_PATH"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
