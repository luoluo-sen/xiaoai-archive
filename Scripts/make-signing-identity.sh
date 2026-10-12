#!/usr/bin/env bash
# Create one local code-signing identity and pin its public identifier.
# Keys live in the login Keychain. Trust applies only to code signing.
set -euo pipefail
umask 077
OPENSSL=/usr/bin/openssl
CERTIFICATE_VALIDITY_DAYS=3650
KEY_BITS=2048

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Project.plist"
source "$ROOT/Scripts/signing-identity.sh"
PINNED="$(/usr/libexec/PlistBuddy -c 'Print :SigningIdentity' "$PROJECT")"
if [ -n "$PINNED" ]; then
	IDENTITY="$(project_signing_identity "$PROJECT" 0)"
	echo "The fixed project identity is available: $IDENTITY"
	exit 0
fi

APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist")"
NAME="$APP_NAME Dev"
EXISTING="$(security find-identity -v -p codesigning | awk -v name="$NAME" 'index($0, "\"" name "\"") { print $2 }')"
if [ -n "$EXISTING" ]; then
	if [ "$(printf '%s\n' "$EXISTING" | wc -l | tr -d ' ')" != "1" ]; then
		echo "Multiple identities are named $NAME; set SigningIdentity explicitly in Project.plist." >&2
		exit 1
	fi
	/usr/libexec/PlistBuddy -c "Set :SigningIdentity $EXISTING" "$PROJECT"
	echo "Pinned the existing local identity: $EXISTING"
	exit 0
fi
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
	echo "A certificate named $NAME exists but is not a valid code-signing identity. Complete its Keychain setup instead of creating another certificate." >&2
	exit 1
fi

KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/')"
if [[ "$KEYCHAIN" != /* ]]; then
	echo "The user default Keychain path could not be read." >&2
	exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/identity.cnf" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = $NAME
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

"$OPENSSL" req -new -x509 -newkey "rsa:$KEY_BITS" -sha256 -nodes -days "$CERTIFICATE_VALIDITY_DAYS" \
	-config "$WORK/identity.cnf" -keyout "$WORK/private.key" -out "$WORK/certificate.pem" \
	> "$WORK/generation.log" 2>&1
export SIGNING_IMPORT_PASSWORD="$("$OPENSSL" rand -hex 32)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/private.key" -in "$WORK/certificate.pem" \
	-name "$NAME" -out "$WORK/identity.p12" -passout env:SIGNING_IMPORT_PASSWORD
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$SIGNING_IMPORT_PASSWORD" -T /usr/bin/codesign
unset SIGNING_IMPORT_PASSWORD
echo "macOS may ask you to approve trust for the local code-signing certificate."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/certificate.pem"
IDENTITY="$(security find-identity -v -p codesigning | awk -v name="$NAME" 'index($0, "\"" name "\"") { print $2 }')"
if [[ ! "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
	echo "The created certificate is not available as a valid code-signing identity. Complete its Keychain trust before building." >&2
	exit 1
fi
/usr/libexec/PlistBuddy -c "Set :SigningIdentity $IDENTITY" "$PROJECT"
echo "Created and pinned the local code-signing identity: $IDENTITY"
echo "The first migration from the old ad-hoc app needs Accessibility authorization once."
