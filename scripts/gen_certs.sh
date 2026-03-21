#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${1:-./certs}"
DAYS="${2:-365}"

mkdir -p "$CERT_DIR"

echo "Generating self-signed TLS certificate in $CERT_DIR ..."

openssl req -x509 -newkey rsa:4096 \
  -keyout "$CERT_DIR/key.pem" \
  -out    "$CERT_DIR/cert.pem" \
  -days   "$DAYS" \
  -nodes  \
  -subj   "/CN=dropfu/O=dropfu/OU=IR" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo ""
echo "Certificate : $CERT_DIR/cert.pem"
echo "Private key : $CERT_DIR/key.pem"
echo "Valid for   : $DAYS days"
echo ""
echo "To use with nginx reverse proxy, see README.md"
