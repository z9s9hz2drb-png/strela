#!/usr/bin/env bash
# Packs a built .app into:
#   <Name>-unsigned.ipa   — for signing in GBox / ESign / Sideloadly / Feather with your certificate
#   <Name>-trollstore.tipa — fake-signed with VPN entitlements via ldid (TrollStore only)
# Usage: Scripts/package-ipa.sh path/to/Strela.app [out-dir]
set -euo pipefail

APP="${1:?path to .app}"
OUT="${2:-dist}"
NAME="$(basename "$APP" .app)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
find "$WORK/Payload" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
find "$WORK/Payload" -name "embedded.mobileprovision" -delete

(cd "$WORK" && zip -qry "$OUT/$NAME-unsigned.ipa" Payload)
echo "==> $OUT/$NAME-unsigned.ipa"

if command -v ldid >/dev/null 2>&1; then
  BUNDLE="$WORK/Payload/$NAME.app"
  GROUP="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupID' "$BUNDLE/Info.plist" 2>/dev/null || echo 'group.com.example.strela')"
  ENT="$WORK/entitlements.plist"
  cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.networking.networkextension</key>
  <array><string>packet-tunnel-provider</string></array>
  <key>com.apple.security.application-groups</key>
  <array><string>${GROUP}</string></array>
</dict>
</plist>
EOF
  for APPEX in "$BUNDLE"/PlugIns/*.appex; do
    [ -d "$APPEX" ] || continue
    EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPEX/Info.plist")"
    ldid -S"$ENT" "$APPEX/$EXE"
  done
  ldid -S"$ENT" "$BUNDLE/$NAME"
  (cd "$WORK" && zip -qry "$OUT/$NAME-trollstore.tipa" Payload)
  echo "==> $OUT/$NAME-trollstore.tipa"
else
  echo "ldid not found — TrollStore build skipped (brew install ldid)"
fi
