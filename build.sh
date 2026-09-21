#!/bin/bash
# Builds build/Z407Volume.app.
#   ./build.sh install   also copies it to ~/Applications
#   ./build.sh run       install, then (re)launch it
# Signs with SIGN_IDENTITY, else the self-signed "Z407Volume Local Signing" identity from its own
# keychain (created by setup-signing.sh), else ad-hoc. Ad-hoc makes macOS forget the
# Accessibility grant after every rebuild.
# SWIFT_BUILD_FLAGS is passed to `swift build` (CI: "--arch arm64 --arch x86_64" for a universal
# binary); VERSION, if set, becomes CFBundleShortVersionString.
set -euo pipefail
cd "$(dirname "$0")"

LOCAL_IDENTITY="Z407Volume Local Signing"
SIGNING_KEYCHAIN=~/Library/Keychains/z407-signing.keychain-db
SIGN_ARGS=()
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if [[ -f "$SIGNING_KEYCHAIN" ]]; then
        # The login keychain can't hand its keys to codesign without a GUI prompt, so the
        # identity lives in a dedicated keychain whose password is this throwaway constant.
        security unlock-keychain -p z407-local-signing "$SIGNING_KEYCHAIN"
        SIGN_IDENTITY="$LOCAL_IDENTITY"
        SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
    else
        SIGN_IDENTITY="-"
    fi
fi

read -ra FLAGS <<< "${SWIFT_BUILD_FLAGS:-}"
swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/Z407Volume"

APP=build/Z407Volume.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Z407Volume"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP"
echo "Built $APP (signed: $SIGN_IDENTITY)"

if [[ "${1:-}" == "install" || "${1:-}" == "run" ]]; then
    pkill -x Z407Volume || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Z407Volume.app
    ditto "$APP" ~/Applications/Z407Volume.app
    echo "Installed ~/Applications/Z407Volume.app"
fi
if [[ "${1:-}" == "run" ]]; then
    open ~/Applications/Z407Volume.app
fi
