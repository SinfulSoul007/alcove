#!/bin/bash
set -euo pipefail
directory="$1"
cat > "$directory/loopback.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = certificate
prompt = no
[subject]
CN = 127.0.0.1
[certificate]
subjectAltName = IP:127.0.0.1
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
CONFIG
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$directory/loopback.cnf" \
    -keyout "$directory/loopback.key" -out "$directory/loopback.pem"
openssl x509 -in "$directory/loopback.pem" -outform DER -out "$directory/loopback.der"
