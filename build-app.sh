#!/bin/bash
# Builds SysRec.app (SwiftPM release build + hand-assembled bundle, ad-hoc signed).
# Usage: ./build-app.sh            build ./SysRec.app
#        ./build-app.sh --install  also copy it to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product SysRec
BIN="$(swift build -c release --show-bin-path)/SysRec"

APP=SysRec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SysRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# macOS ties permissions (System Audio Recording, Automation) to the signing
# identity. With the self-signed "SysRec Local Signing" certificate in the
# login keychain, the identity stays the same across rebuilds and permissions
# stick. Without it we fall back to an ad-hoc signature, and macOS asks again
# after every rebuild.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"SysRec Local Signing"/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.akkaouim.sysrec "$APP"
else
  echo "note: 'SysRec Local Signing' certificate not found; signing ad hoc"
  codesign --force --sign - --identifier com.akkaouim.sysrec "$APP"
fi
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/SysRec.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/SysRec.app"
fi
