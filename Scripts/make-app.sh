#!/usr/bin/env bash
# Assemble and sign the app, with five share extensions nested inside it.
#
# Local and distribution builds use separate fixed identities in Project.plist.
# Extensions are signed before the app so its signature covers final nested code.
set -euo pipefail

CONFIG="${CONFIG:-release}"

DISTRIBUTION="${DISTRIBUTION:-0}"
ARCHS="${ARCHS:-$(uname -m)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/share-slots.sh"
source "$ROOT/Scripts/signing-identity.sh"
APP_INFO="$ROOT/Resources/Info.plist"
SHARE_INFO="$ROOT/Resources/Share-Info.plist"
PROJECT_INFO="$ROOT/Project.plist"
IDENTITY="$(project_signing_identity "$PROJECT_INFO" "$DISTRIBUTION")"
if [ "$DISTRIBUTION" = "1" ]; then
	TEAM_ID="$(project_distribution_team_id "$PROJECT_INFO")"
	BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/dukou-release-bundle}"
	OUTPUT_ROOT="$ROOT/dist/release"
else
	BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/dukou-bundle}"
	OUTPUT_ROOT="$ROOT/dist"
fi
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_INFO")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_INFO")"
APP="${APP_PATH:-$OUTPUT_ROOT/$APP_NAME.app}"
APP_ENTITLEMENTS="$ROOT/Resources/Dukou.entitlements"
SHARE_ENTITLEMENTS="$ROOT/Resources/DukouShare.entitlements"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")}"

read -r -a ARCH_LIST <<< "$ARCHS"
if [ "${#ARCH_LIST[@]}" -eq 0 ]; then
	echo "ARCHS must contain at least one architecture" >&2
	exit 1
fi

APP_BINARIES=()
SHARE_BINARIES=()
BIN_DIRS=()
for ARCH in "${ARCH_LIST[@]}"; do
	case "$ARCH" in
		arm64|x86_64) ;;
		*) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
	esac
	SCRATCH="$BUILD_ROOT/$ARCH"
	swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --product "$APP_EXECUTABLE"
	swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --product DukouShare
	BIN_DIR="$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --show-bin-path)"
	for PRODUCT in "$APP_EXECUTABLE" DukouShare; do
		if [ ! -x "$BIN_DIR/$PRODUCT" ]; then
			echo "missing $PRODUCT executable for $ARCH: $BIN_DIR/$PRODUCT" >&2
			exit 1
		fi
		if ! lipo -archs "$BIN_DIR/$PRODUCT" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
			echo "$PRODUCT does not contain requested architecture $ARCH" >&2
			exit 1
		fi
	done
	APP_BINARIES+=("$BIN_DIR/$APP_EXECUTABLE")
	SHARE_BINARIES+=("$BIN_DIR/DukouShare")
	BIN_DIRS+=("$BIN_DIR")
done

# Sparkle ships as a universal binary framework, so the copy SwiftPM placed
# beside the first architecture's build serves every architecture requested.
SPARKLE_FRAMEWORK="${BIN_DIRS[0]}/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
	echo "missing embedded framework: $SPARKLE_FRAMEWORK" >&2
	exit 1
fi

# An app extension is entered at NSExtensionMain, not main. If the linker flag
# in Package.swift is ever dropped the appex still builds, still installs, and
# silently never activates — so the entry symbol is a build invariant.
if ! nm -u "${SHARE_BINARIES[0]}" | grep -Fq '_NSExtensionMain'; then
	echo "DukouShare is not linked against _NSExtensionMain; check the -e linker flag" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

lipo -create "${APP_BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_EXECUTABLE"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
for ARCH in "${ARCH_LIST[@]}"; do
	if ! lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
		echo "Sparkle.framework is missing requested architecture $ARCH" >&2
		exit 1
	fi
done
# SwiftPM links the framework through @rpath. A shell-assembled app does not
# inherit Xcode's LD_RUNPATH_SEARCH_PATHS, so the conventional location is
# added before any signature is created. Only the app: the extensions never
# link Sparkle.
if ! otool -l "$APP/Contents/MacOS/$APP_EXECUTABLE" | grep -Fq '@executable_path/../Frameworks'; then
	install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/$APP_EXECUTABLE"
fi
SHARE_BINARY="$BUILD_ROOT/DukouShare"
lipo -create "${SHARE_BINARIES[@]}" -output "$SHARE_BINARY"

cp "$APP_INFO" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

for KEY in RepositoryURL MaintainerName MaintainerURL; do
	VALUE="$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$PROJECT_INFO")"
	/usr/libexec/PlistBuddy -c "Add :XA$KEY string $VALUE" "$APP/Contents/Info.plist"
done
AUTOMATIC_UPDATES="$(/usr/libexec/PlistBuddy -c 'Print :AutomaticUpdatesEnabled' "$PROJECT_INFO")"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks $AUTOMATIC_UPDATES" "$APP/Contents/Info.plist"
if [ "$AUTOMATIC_UPDATES" = "true" ]; then
	UPDATE_BASE="$(/usr/libexec/PlistBuddy -c 'Print :UpdateBaseURL' "$PROJECT_INFO")"
	UPDATE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :UpdatePublicEDKey' "$PROJECT_INFO")"
	/usr/libexec/PlistBuddy -c "Add :SUFeedURL string ${UPDATE_BASE}appcast.xml" "$APP/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $UPDATE_KEY" "$APP/Contents/Info.plist"
fi

APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")"
APPEX_PATHS=()

# One executable, five bundles. The extensions differ only in identity, so
# copying the same binary keeps them honestly identical and keeps the build to a
# single compile.
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r SLOT APPEX_NAME ID_SUFFIX SLOT_ACTION DISPLAY_NAME <<< "$SLOT_ROW"
	SLOT_APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
	mkdir -p "$SLOT_APPEX/Contents/MacOS" "$SLOT_APPEX/Contents/Resources"
	cp "$SHARE_BINARY" "$SLOT_APPEX/Contents/MacOS/$APPEX_NAME"
	cp "$SHARE_INFO" "$SLOT_APPEX/Contents/Info.plist"

	PLIST="$SLOT_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APPEX_NAME" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID.$ID_SUFFIX" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :DKShareAction $SLOT_ACTION" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

	SLOT_LOCALIZATIONS="$ROOT/Resources/ShareLocalizations/$SLOT"
	if [ ! -d "$SLOT_LOCALIZATIONS" ]; then
		echo "missing localizations for share slot $SLOT: $SLOT_LOCALIZATIONS" >&2
		exit 1
	fi
	APPEX_PATHS+=("$SLOT_APPEX")
done

# Bundle.main must own localisations. SwiftPM's Bundle.module points back into
# the build directory and does not survive a standalone .app distribution. The
# extension needs its own copy: it is a separate bundle with a separate
# Bundle.main.
shopt -s nullglob
for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
	ditto "$LPROJ" "$APP/Contents/Resources/$(basename "$LPROJ")"
done
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r SLOT APPEX_NAME _ _ _ <<< "$SLOT_ROW"
	SLOT_APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
	for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
		ditto "$LPROJ" "$SLOT_APPEX/Contents/Resources/$(basename "$LPROJ")"
	done
	# The entry's name in the Share menu comes from the appex's own
	# InfoPlist.strings, so this deliberately overwrites the app's copy of that
	# one table inside each extension bundle.
	for LPROJ in "$ROOT/Resources/ShareLocalizations/$SLOT"/*.lproj; do
		ditto "$LPROJ" "$SLOT_APPEX/Contents/Resources/$(basename "$LPROJ")"
	done
done
shopt -u nullglob

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
ditto "$ROOT/Resources/Licenses" "$APP/Contents/Resources/Licenses"

# Repository fallbacks are useful for `swift run`, but a distributable binary
# must never reveal the builder's absolute checkout path.
if [ "$CONFIG" = "release" ]; then
	RELEASE_BINARIES=("$APP/Contents/MacOS/$APP_EXECUTABLE")
	for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
		IFS='|' read -r _ APPEX_NAME _ _ _ <<< "$SLOT_ROW"
		RELEASE_BINARIES+=("$APP/Contents/PlugIns/$APPEX_NAME.appex/Contents/MacOS/$APPEX_NAME")
	done
	for BINARY in "${RELEASE_BINARIES[@]}"; do
		if strings "$BINARY" | grep -Fq "$ROOT"; then
			echo "release binary contains the absolute repository path: $BINARY" >&2
			exit 1
		fi
	done
fi

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$DISTRIBUTION" = "1" ]; then
	SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Inside out. Signing the app first would seal a hash of unsigned nested code,
# and codesign --deep is not a substitute for signing it explicitly. Sparkle
# carries executable code several levels below the framework; Downloader.xpc
# keeps its upstream entitlement metadata, everything else gets a fresh
# signature.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/Current"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
for SLOT_APPEX in "${APPEX_PATHS[@]}"; do
	codesign "${SIGN_FLAGS[@]}" --entitlements "$SHARE_ENTITLEMENTS" "$SLOT_APPEX"
done
codesign "${SIGN_FLAGS[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$DISTRIBUTION" = "1" ]; then
	for BUNDLE in "$APP" "${APPEX_PATHS[@]}"; do
		SIGNED_TEAM="$(codesign -d --verbose=4 "$BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
		if [ "$SIGNED_TEAM" != "$TEAM_ID" ]; then
			echo "signed team for $BUNDLE is $SIGNED_TEAM, expected $TEAM_ID" >&2
			exit 1
		fi
	done
fi

# Verify the extension's actual signature grants access to the shared Downloads
# inbox. No bundle may claim the retired App Group.
verify_inbox_entitlements() {
	local dump
	dump="$(mktemp "$BUILD_ROOT/entitlements.XXXXXX.plist")"
	codesign -d --entitlements - --xml "$1" 2>/dev/null > "$dump"
	if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$dump" >/dev/null 2>&1; then
		echo "$1 still declares the retired App Group" >&2
		exit 1
	fi
	if [ "$2" = "extension" ]; then
		if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.downloads.read-write' "$dump")" != "true" ]; then
			echo "$1 cannot write the Downloads inbox" >&2
			exit 1
		fi
	fi
	rm -f "$dump"
}
verify_inbox_entitlements "$APP" app
for SLOT_APPEX in "${APPEX_PATHS[@]}"; do
	verify_inbox_entitlements "$SLOT_APPEX" extension
done

echo "built $APP"
echo "version $VERSION ($BUILD_NUMBER)"
echo "inbox ~/Downloads/xiaoai-archive/Inbox"
echo "share entries ${#APPEX_PATHS[@]}"
echo "architectures $(lipo -archs "$APP/Contents/MacOS/$APP_EXECUTABLE")"
if [ "$DISTRIBUTION" = "1" ]; then
	echo "signed for Developer ID distribution"
else
	echo "signed with the fixed project identity $IDENTITY"
fi
