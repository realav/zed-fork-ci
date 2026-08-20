#!/usr/bin/env bash
# Create the self-signed identity that gives the fork build a stable code
# signature. Run once per machine.
#
#   local/make-signing-cert.sh ["Zed Local Signing"]
#
# Why: without a certificate, `script/bundle-mac` signs ad-hoc, and macOS then
# records every permission grant (Accessibility, Screen Recording, Files,
# Automation, mic, camera) against the binary's cdhash. A new build has a new
# cdhash, so it is a brand-new app to TCC and every prompt comes back. Signing
# with a certificate that never changes makes the recorded requirement
#
#     identifier "dev.zed.Zed" and certificate leaf = H"<this cert>"
#
# which every future build satisfies. The certificate is self-signed and never
# leaves this Mac; it is not an Apple Developer ID and cannot notarize.

set -euo pipefail

NAME="${1:-Zed Local Signing}"
DAYS=7300 # 20 years — an expired cert would cost every permission again
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists — nothing to do"
  security find-identity -v -p codesigning | grep "\"$NAME\""
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# codeSigning is the extended key usage `codesign` looks for; without it the
# identity exists but `find-identity -p codesigning` will not list it.
cat > "$TMP/req.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

# macOS's own openssl, not whatever is first in PATH: OpenSSL 3 writes PKCS#12
# with an AES/SHA-256 MAC that `security import` cannot read ("MAC verification
# failed"), while the system LibreSSL writes the old format it expects.
SSL=/usr/bin/openssl

"$SSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" 2>/dev/null

"$SSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:tmp

# -T /usr/bin/codesign pre-authorizes codesign against the private key, so the
# keychain asks at most once instead of on every signature.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -T /usr/bin/security

# codesign refuses a chain it cannot build; trust the cert for code signing
# only. This is the step that may pop a password prompt.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "created:"
security find-identity -v -p codesigning | grep "\"$NAME\""
echo
echo "next: local/install-build.sh ~/Downloads/Zed-<tag>-patched-arm64.zip"
