#!/bin/bash
#
# release-basic.sh — builds ScreenRelay Basic for distribution: a universal Release
# build signed with Developer ID, notarized by Apple and stapled, packaged as a DMG
# (and a zip) ready to attach to a GitHub release.
#
# Run it from the `basic` branch. It refuses to package any other edition.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode › Settings › Accounts › Manage Certificates… › + › Developer ID Application).
#   2. Notarization credentials saved in the keychain under a profile name:
#        xcrun notarytool store-credentials ScreenRelay-notary \
#            --apple-id you@example.com --team-id TL76QL278K
#      (it asks for an app-specific password from account.apple.com).
#
# Usage:
#   scripts/release-basic.sh
#
# Environment overrides:
#   NOTARY_PROFILE   keychain profile for notarytool    (default: ScreenRelay-notary)
#   TEAM_ID          Developer team                     (default: TL76QL278K)
#   SKIP_NOTARIZE=1  sign and package only, e.g. to test the script
#
# Output (in dist/release/):
#   ScreenRelay-Basic-<version>.dmg        drag-to-Applications disk image (notarized, stapled)
#   ScreenRelay-Basic-<version>.zip        the same app as a zip (stapled)
#   SHA256SUMS.txt                         checksums to paste into the release notes
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-ScreenRelay-notary}"
TEAM_ID="${TEAM_ID:-TL76QL278K}"
WORK="$ROOT/build/release"
OUT="$ROOT/dist/release"
ARCHIVE="$WORK/ScreenRelay.xcarchive"
EXPORT="$WORK/export"

step() { echo; echo "▸ $*"; }
fail() { echo "error: $*" >&2; exit 1; }

# MARK: - Checks

grep -q 'static let edition = "Basic"' "$ROOT/ScreenRelay/App/AppInfo.swift" \
    || fail "this isn't the Basic edition (AppInfo.edition). Check out the basic branch first."
[[ ! -d "$ROOT/ScreenRelayCamera" ]] \
    || fail "the camera extension target is present; the Basic edition shouldn't include it."
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -q "Developer ID Application" <<< "$IDENTITIES" \
    || fail "no Developer ID Application certificate in the keychain (see the setup notes at the top)."
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool profile '$NOTARY_PROFILE' not found or invalid (see the setup notes at the top)."
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

# MARK: - Build and sign

step "Archiving a universal Release build…"
xcodebuild -project "$ROOT/ScreenRelay.xcodeproj" -scheme ScreenRelay -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    archive -quiet

step "Exporting with Developer ID signing…"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates -quiet

APP="$EXPORT/ScreenRelay.app"
[[ -d "$APP" ]] || fail "export didn't produce $APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="ScreenRelay-Basic-$VERSION"
echo "  Version $VERSION ($BUILD)"

step "Verifying the signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured first: piping codesign straight into `grep -q` can fail under pipefail,
# because grep exits at the first match and codesign then dies writing to the pipe.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
grep -q "Authority=Developer ID Application" <<< "$SIGNATURE" \
    || fail "the app isn't signed with Developer ID."
grep -q "flags=.*runtime" <<< "$SIGNATURE" \
    || fail "the hardened runtime is off; notarization requires it."
if grep -q "get-task-allow" <<< "$ENTITLEMENTS"; then
    fail "the app has the get-task-allow entitlement (a debug build); notarization would reject it."
fi
echo "  $(grep -m1 '^Authority=' <<< "$SIGNATURE" | sed 's/^Authority=//')"
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/ScreenRelay")"

# MARK: - Notarize

notarize() {
    local file="$1"
    if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
        echo "  (skipped: SKIP_NOTARIZE is set)"
        return
    fi
    local log="$WORK/notary-$(basename "$file").json"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format json > "$log" || true
    local status id
    status="$(/usr/bin/plutil -extract status raw -o - "$log" 2>/dev/null || echo unknown)"
    id="$(/usr/bin/plutil -extract id raw -o - "$log" 2>/dev/null || echo "")"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization status: $status" >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || cat "$log" >&2
        fail "notarization failed for $(basename "$file")."
    fi
    echo "  Accepted (submission $id)"
}

step "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$WORK/$NAME-submit.zip"
notarize "$WORK/$NAME-submit.zip"
[[ -n "${SKIP_NOTARIZE:-}" ]] || xcrun stapler staple "$APP"

# MARK: - Package

step "Creating the disk image…"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ScreenRelay.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "ScreenRelay Basic $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
IDENTITY="$(sed -n 's/^Authority=//p' <<< "$SIGNATURE" | head -1)"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the disk image…"
notarize "$DMG"
[[ -n "${SKIP_NOTARIZE:-}" ]] || xcrun stapler staple "$DMG"

step "Creating the zip…"
ZIP="$OUT/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Checking Gatekeeper acceptance…"
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    spctl --assess --type execute --verbose=2 "$APP"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
    echo "  (skipped: not notarized)"
fi

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)

step "Done."
echo "  $DMG"
echo "  $ZIP"
echo "  $OUT/SHA256SUMS.txt"
echo
echo "Attach the files to a GitHub release, e.g.:"
echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" \"$OUT/SHA256SUMS.txt\" --title \"ScreenRelay Basic $VERSION\""
