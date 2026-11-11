#!/bin/sh
# One-time setup: creates a self-signed code-signing identity "MailReplica Dev" in your login keychain.
# run.sh signs every build with it, so the Keychain recognises the app across rebuilds and stops asking
# for the password of the "MailReplica-EWS" item. Without it, each build is signed ad hoc and looks new.
# Remove it again with: security delete-identity -c "MailReplica Dev"
set -e
NAME="MailReplica Dev"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cat > "$d/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# LibreSSL from the system: its PKCS#12 files are ones `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$d/req.cnf" \
  -keyout "$d/key.pem" -out "$d/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$d/key.pem" -in "$d/cert.pem" -out "$d/id.p12" -passout pass:temp
# -T: codesign may use the key without asking.
security import "$d/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Next ./run.sh signs with it; allow the Keychain prompt once with \"Always Allow\"."
