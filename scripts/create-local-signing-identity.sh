#!/bin/bash

set -euo pipefail

identity_name="CatGuard Local Development"
pkcs12_password="catguard-temporary-import"

if security find-identity -v -p codesigning | grep -F "\"${identity_name}\"" >/dev/null; then
    echo "Signing identity already available: ${identity_name}"
    exit 0
fi

if security find-certificate -c "${identity_name}" >/dev/null 2>&1; then
    echo "A certificate named '${identity_name}' exists but is not a valid code-signing identity." >&2
    echo "Remove or repair that certificate in Keychain Access before retrying." >&2
    exit 1
fi

login_keychain="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
if [[ -z "${login_keychain}" ]]; then
    echo "Could not determine the default user keychain." >&2
    exit 1
fi

signing_temp="$(mktemp -d /private/tmp/catguard-signing.XXXXXX)"
cleanup() {
    rm -rf -- "${signing_temp}"
}
trap cleanup EXIT

/usr/bin/openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -x509 \
    -days 3650 \
    -subj "/C=DK/O=Oana Alina Goge/OU=CatGuard Local/CN=${identity_name}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "${signing_temp}/private-key.pem" \
    -out "${signing_temp}/certificate.pem" \
    >/dev/null 2>&1

/usr/bin/openssl pkcs12 \
    -export \
    -passout "pass:${pkcs12_password}" \
    -inkey "${signing_temp}/private-key.pem" \
    -in "${signing_temp}/certificate.pem" \
    -name "${identity_name}" \
    -out "${signing_temp}/identity.p12"

security import "${signing_temp}/identity.p12" \
    -k "${login_keychain}" \
    -P "${pkcs12_password}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "${login_keychain}" \
    "${signing_temp}/certificate.pem"

if ! security find-identity -v -p codesigning | grep -F "\"${identity_name}\"" >/dev/null; then
    echo "The certificate was imported but is not trusted for code signing." >&2
    exit 1
fi

echo "Created trusted local signing identity: ${identity_name}"
