#!/usr/bin/env bash
# Install to the fixed project path after verifying the signing identity.
# Every identity check precedes quitting or replacing the installed app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist")"
SOURCE="${SOURCE:-$ROOT/dist/$APP_NAME.app}"
DESTINATION="$(/usr/libexec/PlistBuddy -c 'Print :InstallPath' "$ROOT/Project.plist")"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"
ALLOW_SIGNING_MIGRATION="${ALLOW_SIGNING_MIGRATION:-0}"
# shellcheck source=share-slots.sh
source "$ROOT/Scripts/share-slots.sh"
source "$ROOT/Scripts/signing-identity.sh"
IDENTITY="$(project_signing_identity "$ROOT/Project.plist" 0)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -d "$SOURCE" ]; then
	echo "no build at $SOURCE — run Scripts/make-app.sh first" >&2
	exit 1
fi

case "$DESTINATION" in
	/*.app) ;;
	*) echo "InstallPath must be an absolute .app path in Project.plist." >&2; exit 1 ;;
esac
case "$ALLOW_SIGNING_MIGRATION" in
	0|1) ;;
	*) echo "ALLOW_SIGNING_MIGRATION must be 0 or 1." >&2; exit 1 ;;
esac
if [ -d "$DESTINATION" ] && [[ "$SOURCE" -ef "$DESTINATION" ]]; then
	echo "The build source and installation destination must be different bundles." >&2
	exit 1
fi
SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
if [ "$SOURCE_ID" != "$APP_ID" ]; then
	echo "The build does not have the project application identifier $APP_ID." >&2
	exit 1
fi
codesign --verify --deep --strict -R="certificate leaf = H\"$IDENTITY\"" "$SOURCE"

if [ -d "$DESTINATION" ]; then
	INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")"
	if [ "$INSTALLED_ID" != "$APP_ID" ]; then
		echo "InstallPath belongs to another application; installation stopped." >&2
		exit 1
	fi
	codesign --verify --deep --strict "$DESTINATION"
	INSTALLED_REQUIREMENT="$(codesign -d -r- "$DESTINATION" 2>&1 | sed -nE 's/^(# )?designated => //p')"
	if [ -z "$INSTALLED_REQUIREMENT" ]; then
		echo "The installed application has no readable designated requirement." >&2
		exit 1
	fi
	if ! codesign --verify --strict -R="$INSTALLED_REQUIREMENT" "$SOURCE"; then
		if [ "$ALLOW_SIGNING_MIGRATION" != "1" ] || ! codesign -dv "$DESTINATION" 2>&1 | grep -Fx 'Signature=adhoc' >/dev/null; then
			echo "The new signing identity differs from the installed app. Installation stopped before quitting or replacing it. For the one-time migration to the pinned certificate, use ALLOW_SIGNING_MIGRATION=1 and re-grant Accessibility once." >&2
			exit 1
		fi
		echo "Migrating to the fixed project certificate; macOS requires Accessibility authorization once."
	fi
fi

# A running copy holds its own bundle open, and replacing it underneath would
# leave a half-updated app registered.
xcrun swift "$ROOT/Scripts/stop-dev-app.swift" "$APP_ID"

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
ditto "$SOURCE" "$DESTINATION"
"$LSREGISTER" -f "$DESTINATION"

echo "installed $DESTINATION"
echo
echo "share extension registration:"
pluginkit -m -p com.apple.share-services -vvv 2>/dev/null | grep -i dukou || {
	echo "  not registered yet — open the app once, then re-run this script"
	exit 0
}
echo
# The switches live in Dukou now — the app gave up its sandbox for them — so
# that is the path this prints first. Every entry is listed by its real
# identifier: the template plist holds only the first slot's, and make-app.sh
# rewrites it per slot, so printing that one alone left four entries for the
# reader to guess the suffix of.
echo "If an entry is registered but disabled, open $APP_NAME → 设置 → 入口 and flip it,"
echo "or manage the same setting in System Settings → Login Items & Extensions → Sharing."
echo "Per entry, from a terminal:"
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r _ _ ID_SUFFIX _ DISPLAY_NAME <<< "$SLOT_ROW"
	echo "  pluginkit -e use -i $APP_ID.$ID_SUFFIX   # $DISPLAY_NAME"
done
