#!/bin/bash
# One-time: creates a self-signed code-signing identity in its own keychain so build.sh can
# sign with a stable identity (TCC grants survive rebuilds) without keychain prompts.
set -euo pipefail
KC=~/Library/Keychains/z407-signing.keychain-db
PW=z407-local-signing
[[ -f $KC ]] && { echo "$KC already exists"; exit 0; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -nodes \
    -subj "/CN=Z407Volume Local Signing" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -out "$D/id.p12" -inkey "$D/key.pem" -in "$D/cert.pem" -passout pass:tmp
security create-keychain -p $PW $KC
security set-keychain-settings $KC
security unlock-keychain -p $PW $KC
security import "$D/id.p12" -k $KC -P tmp -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW $KC >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') $KC
echo "Created $KC"
