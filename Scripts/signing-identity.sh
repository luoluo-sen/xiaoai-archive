# Resolve the certificates pinned in the root project configuration.
# The private key stays in Keychain; the identifier here is public.
project_distribution_team_id() {
	local project="$1" team
	team="$(/usr/libexec/PlistBuddy -c 'Print :DistributionTeamID' "$project")" || return 1
	if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
		echo "Set DistributionTeamID in Project.plist to your Apple Developer team's 10-character identifier." >&2
		return 1
	fi
	printf '%s' "$team"
}

project_signing_identity() {
	local project="$1" distribution="$2" key identity matches team
	case "$distribution" in
		0) key=SigningIdentity ;;
		1) key=DistributionSigningIdentity ;;
		*) echo "DISTRIBUTION must be 0 or 1." >&2; return 1 ;;
	esac
	identity="$(/usr/libexec/PlistBuddy -c "Print :$key" "$project")" || return 1
	if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
		if [ "$distribution" = "1" ]; then
			echo "Set DistributionSigningIdentity in Project.plist to the 40-character identifier of your Developer ID Application certificate. Keep the local SigningIdentity unchanged." >&2
		else
			echo "Set SigningIdentity in Project.plist to a fixed code-signing certificate identifier. Run Scripts/make-signing-identity.sh for local setup. Ad-hoc signing is not supported." >&2
		fi
		return 1
	fi
	matches="$(security find-identity -v -p codesigning | awk -v identity="$identity" 'tolower($2) == tolower(identity) { print }')" || return 1
	if [ -z "$matches" ]; then
		echo "The configured $key is not available in this Mac's Keychain. Import that certificate with its private key; do not change the local signing identity for normal updates." >&2
		return 1
	fi
	if [ "$distribution" = "1" ]; then
		team="$(project_distribution_team_id "$project")" || return 1
		if ! printf '%s\n' "$matches" | grep -Fq 'Developer ID Application:' || \
			! printf '%s\n' "$matches" | grep -Fq "($team)"; then
			echo "DistributionSigningIdentity must be a Developer ID Application certificate for team $team." >&2
			return 1
		fi
	fi
	printf '%s' "$identity"
}
