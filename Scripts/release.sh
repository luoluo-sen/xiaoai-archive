#!/usr/bin/env bash
# Build the canonical project release DMG used by GitHub Releases, Sparkle
# and Homebrew. The source commit and tag must already exist; secrets stay in
# the login keychain and are referenced only by identity hash / profile name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/signing-identity.sh"
PROJECT="$ROOT/Project.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist")"
REPOSITORY_URL="$(/usr/libexec/PlistBuddy -c 'Print :RepositoryURL' "$PROJECT")"
UPDATE_BASE_URL="$(/usr/libexec/PlistBuddy -c 'Print :UpdateBaseURL' "$PROJECT")"
UPDATES_ENABLED="$(/usr/libexec/PlistBuddy -c 'Print :AutomaticUpdatesEnabled' "$PROJECT")"
NOTARY_PROFILE="$(/usr/libexec/PlistBuddy -c 'Print :NotaryProfile' "$PROJECT")"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")}"
TAG="${TAG:-v$VERSION}"
ARCHS="${ARCHS:-arm64 x86_64}"
NOTARIZE="${NOTARIZE:-1}"
REQUIRE_TAG="${REQUIRE_TAG:-1}"
REQUIRE_CLEAN="${REQUIRE_CLEAN:-1}"
RELEASE_DIR="$ROOT/dist/release"
APP="$RELEASE_DIR/$APP_NAME.app"
APP_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION.app.zip"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
UPDATES_DIR="$ROOT/dist/updates"

if [ -z "${GENERATE_APPCAST+x}" ]; then
	if [ "$UPDATES_ENABLED" = "true" ]; then
		GENERATE_APPCAST=1
	else
		GENERATE_APPCAST=0
	fi
fi

if [ "$NOTARIZE" = "1" ] && [ -z "$NOTARY_PROFILE" ]; then
	echo "set NotaryProfile in Project.plist before creating a notarized release" >&2
	exit 1
fi
DISTRIBUTION=1 "$ROOT/Scripts/check-release-config.sh"
if [ "$GENERATE_APPCAST" = "1" ]; then
	if [ "$UPDATES_ENABLED" != "true" ]; then
		echo "automatic updates are disabled in Project.plist; no appcast will be generated" >&2
		exit 1
	fi
fi

if [ "$REQUIRE_CLEAN" = "1" ] && [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
	echo "release requires a clean Git working tree" >&2
	exit 1
fi
if [ "$REQUIRE_TAG" = "1" ]; then
	HEAD_TAG="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
	if [ "$HEAD_TAG" != "$TAG" ]; then
		echo "HEAD must be tagged $TAG before creating a release" >&2
		exit 1
	fi
fi
# The feed step needs both notes; fail now rather than after notarization.
if [ "$GENERATE_APPCAST" = "1" ]; then
	for NOTES in "$ROOT/Resources/ReleaseNotes/$VERSION.md" "$ROOT/Resources/ReleaseNotes/$VERSION.zh.md"; do
		if [ ! -f "$NOTES" ]; then
			echo "missing ${NOTES#$ROOT/}" >&2
			exit 1
		fi
	done
fi

IDENTITY="$(project_signing_identity "$PROJECT" 1)"

notarize_artifact() {
	local artifact="$1"
	local label="$2"
	local result="$ROOT/dist/notary-$label-result.json"
	local log="$ROOT/dist/notary-$label-log.json"
	local submission_id status

	xcrun notarytool submit "$artifact" \
		--keychain-profile "$NOTARY_PROFILE" \
		--wait --output-format json > "$result"
	submission_id="$(plutil -extract id raw -o - "$result")"
	status="$(plutil -extract status raw -o - "$result")"
	xcrun notarytool log "$submission_id" \
		--keychain-profile "$NOTARY_PROFILE" > "$log"
	if [ "$status" != "Accepted" ]; then
		echo "Apple notarization status for $label: $status" >&2
		echo "see $log" >&2
		exit 1
	fi
}

if [ "$NOTARIZE" = "1" ]; then
	# Fail before the expensive Universal 2 build if the Keychain profile is
	# missing, expired or tied to the wrong Developer team.
	xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
fi

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" ARCHS="$ARCHS" \
	DISTRIBUTION=1 CONFIG=release \
	"$ROOT/Scripts/make-app.sh"

# The app needs its own stapled ticket before it is sealed inside the DMG.
# That preserves offline Gatekeeper validation after Finder, Homebrew or
# Sparkle copies the bundle out of the mounted image.
if [ "$NOTARIZE" = "1" ]; then
	rm -f "$APP_ZIP"
	ditto -c -k --keepParent "$APP" "$APP_ZIP"
	notarize_artifact "$APP_ZIP" app
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"
fi

"$ROOT/Scripts/make-dmg.sh" \
	"$APP" "$DMG" "$VERSION" "$ROOT/Resources/DMG/background.png"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
hdiutil verify "$DMG"

if [ "$NOTARIZE" = "1" ]; then
	notarize_artifact "$DMG" dmg
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
else
	echo "warning: NOTARIZE=0; this DMG is not publishable" >&2
fi

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

if [ "$GENERATE_APPCAST" = "1" ]; then
	if [ "$NOTARIZE" != "1" ]; then
		echo "refusing to generate a production appcast from an unstapled DMG" >&2
		exit 1
	fi
	SPARKLE_TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
	if [ ! -x "$SPARKLE_TOOLS/generate_appcast" ]; then
		echo "missing Sparkle generate_appcast tool; run swift package resolve" >&2
		exit 1
	fi
	rm -rf "$UPDATES_DIR"
	mkdir -p "$UPDATES_DIR"
	# Only this project's feed is input. The imported upstream feed lives in
	# Resources/UpstreamSite and must never enter this project's update channel.
	if [ -f "$ROOT/site/appcast.xml" ]; then
		cp "$ROOT/site/appcast.xml" "$UPDATES_DIR/appcast.xml"
	fi
	cp "$DMG" "$UPDATES_DIR/"
	# Styled HTML from Resources/ReleaseNotes/<version>.md and <version>.zh.md:
	# `<app>-<version>.html` is the English default, `.zh.html` becomes the
	# `xml:lang="zh"` link (generate_appcast only recognises two-letter codes).
	# Full documents, so they are linked and signed rather than embedded.
	swift "$ROOT/Scripts/release-notes.swift" sparkle \
		"$VERSION" "$BUILD_NUMBER" "$(date +%Y-%m-%d)" "$UPDATES_DIR"
	# Notes are served from GitHub Pages next to the appcast, not from the
	# release assets. Deltas are disabled so every enclosure is the full DMG,
	# and every version is kept: the history page is built from this feed.
	# "Version History" in Sparkle's up-to-date alert opens the history page.
	"$SPARKLE_TOOLS/generate_appcast" \
		--download-url-prefix "$REPOSITORY_URL/releases/download/$TAG/" \
		--release-notes-url-prefix "$UPDATE_BASE_URL" \
		--full-release-notes-url "${UPDATE_BASE_URL}updates.html" \
		--link "$REPOSITORY_URL" \
		--maximum-deltas 0 \
		--maximum-versions 0 \
		"$UPDATES_DIR"
	swift "$ROOT/Scripts/release-notes.swift" history \
		"$UPDATES_DIR/appcast.xml" "$UPDATES_DIR/updates.html"
fi

echo "release artifact: $DMG"
echo "checksum: $DMG.sha256"
if [ -f "$UPDATES_DIR/appcast.xml" ]; then
	echo "signed appcast: $UPDATES_DIR/appcast.xml"
	echo "publish: copy appcast.xml, $APP_NAME-$VERSION*.html and updates.html from $UPDATES_DIR to site/, then commit"
fi
echo "homebrew cask: run Scripts/update-tap.sh once the GitHub Release exists"
