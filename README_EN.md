# xiaoai-archive

Turns WeChat group chats into time-ordered text kept on the machine, with images, videos and an offline preview.

Chat content comes only from files WeChat itself exports. This tool does not read WeChat's database, decrypt it, inject code, or modify WeChat.

Source and issue reports: [luoluo-sen/xiaoai-archive](https://github.com/luoluo-sen/xiaoai-archive). Published versions: [GitHub Releases](https://github.com/luoluo-sen/xiaoai-archive/releases).

Repository links, maintainer metadata, and release settings live in `Project.plist` at the repository root. Check for Updates queries this repository's latest stable GitHub Release, compares tags in `v1.2.3` or `1.2.3` format, and links to its release notes and downloads. No stable release or signed update feed is published yet, so automatic downloading and installation remain disabled.

The product and app bundle are named `xiaoai-archive`. Application identifiers and stored preference keys stay unchanged. The app and its share extensions use the same `~/Downloads/xiaoai-archive/Inbox/` directory, with macOS Downloads read/write access instead of the original developer's App Group. Existing archives in the old group container and Application Support are not automatically deleted or merged. Upstream web pages and release notes are archived in `Resources/UpstreamSite/` and `Resources/UpstreamReleaseNotes/` and are not used for this project's updates.

## First installation on a new Mac

Users receive a compiled app and do not create certificates, install developer tools, or run build scripts. The Downloads inbox works with locally signed builds; allow Downloads folder access on first use. macOS may block the first launch of a locally signed app shared with a small group. Public releases can use Developer ID signing and notarization to reduce installation blocks; the inbox path stays the same. No formal installer is published yet.

1. Download the formal installer from this repository's GitHub Releases, copy `xiaoai-archive.app` to Applications, and open that installed copy.
2. Complete the first-run guide and enable at least one sharing entry. Quick WeChat forwarding requires Stash in xiaoai-archive; choose the other entries as needed. Setup cannot complete with all entries disabled.
3. For reading WeChat windows, automated forwarding, or pasting, add `/Applications/xiaoai-archive.app` in the system privacy settings and enable Accessibility. macOS may require Touch ID or an administrator password. Stashing or copying files can skip this permission.
4. Open and sign in to official WeChat, display its regular or folded conversation list, and read the current chat or window list from the app. If the forward layout requires visual button recognition, the app separately requests Screen Recording permission.

A new Mac does not inherit another Mac's system permissions, and the app does not bypass user authorization. Normal updates keep the same signing identity and installation path. An identity change stops installation with an explanation.

Formal installers target macOS 14 or later and include Apple Silicon and Intel architectures through the release script. Window list recognition currently supports the regular and folded lists in Chinese-language WeChat; other WeChat interface languages are not implemented yet.

## Building from source on another development Mac

If the configured certificate is not in the new Mac's Keychain, import the same certificate and private key. For an independent local build on a new development machine, deliberately clear `SigningIdentity` in `Project.plist`, then perform the one-time local setup below. End users installing formal releases do not do this. Do not clear or replace signing settings for regular updates on an authorized machine.

Run `Scripts/make-signing-identity.sh` once to create a local development identity and pin its public certificate identifier in `Project.plist` as `SigningIdentity`. The private key stays in the login Keychain, and macOS may require your confirmation. For an existing signing certificate, set its identifier directly. Builds no longer choose another certificate or use ad-hoc signing.

Run `Scripts/make-app.sh`, followed by `Scripts/install-dev-build.sh`. `InstallPath` in `Project.plist` fixes the installation location. The installer checks the new app against the installed app's signing requirement before quitting or replacing it. Incompatible updates stop and leave the authorized app intact.

For the first migration from an ad-hoc build, run `ALLOW_SIGNING_MIGRATION=1 Scripts/install-dev-build.sh` and grant Accessibility once. Later updates use the same certificate and application identifier. The migration option accepts only an installed ad-hoc signature, not a change between certificates. Certificate expiration, replacement, or an application identifier change can still require authorization again. The formal release script below uses a Developer ID identity.

## Preparing a formal release

Formal releases use settings separate from the local development identity, so the current `SigningIdentity` and the authorized development install are left unchanged. The Apple Developer Account Holder must create a `Developer ID Application` certificate and import its certificate and private key into the release Mac's Keychain. Put its 40-character SHA-1 identifier in `DistributionSigningIdentity` and the team's 10-character Team ID in `DistributionTeamID` in `Project.plist`. No App Group configuration is needed.

Keep notarization credentials in the Keychain: run `xcrun notarytool store-credentials <name>` with the Apple Developer credentials, then put that name in `NotaryProfile`. Do not put certificate private keys, API keys, or passwords in the repository. After configuration, run `DISTRIBUTION=1 Scripts/check-release-config.sh`, then run `Scripts/release.sh` from a clean, tagged commit. It creates the Universal release artifacts in `dist/release/`, signs and notarizes them, and staples the ticket. With automatic updates disabled, it skips the Sparkle appcast while keeping GitHub Releases usable.

## License and attribution

This project is a modified version of [Dukou](https://github.com/qzz0518/Dukou). The imported upstream commit is [`28f38d7`](https://github.com/qzz0518/Dukou/commit/28f38d7ebb0f107d7bc8cc6ef367753c44250bef).

Copyright in Dukou belongs to qzz0518:

```text
Copyright (c) 2026 qzz0518
```

Dukou is licensed under the [MIT License](LICENSE). Copies and substantial portions of this software must keep that copyright notice and the full permission text in `LICENSE`. Modifications in this repository do not remove that requirement.

Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Sparkle is also MIT; its license is `Resources/Licenses/Sparkle-LICENSE.txt`.

WeChat is a trademark of Tencent. This project is not affiliated with or endorsed by Tencent.

简体中文见 [README.md](README.md)。
