#!/usr/bin/env bash
# One-time setup for free releases (no Apple Developer account):
#   1. a self-signed code-signing certificate "SpaceSweeper Release". Every release is signed with it, so
#      macOS keeps Full Disk Access across updates (the permission is tied to this certificate);
#   2. a Sparkle EdDSA key that signs update packages (stored in your login keychain, exported to a file).
# Prints the values to add as GitHub secrets. Keys are written OUTSIDE the repository and must never be committed.
#   scripts/setup-release-keys.sh [output-folder]   (default: ~/SpaceSweeper-release-keys)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-$HOME/SpaceSweeper-release-keys}"
SPARKLE_BIN="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ ! -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "Sparkle tools not found. Run scripts/ci.sh build first." >&2
  exit 1
fi
if [[ -e "$OUT/SpaceSweeper-Release.p12" ]]; then
  echo "Keys already exist in $OUT. Reusing them keeps updates working; delete the folder only on purpose." >&2
  exit 1
fi

mkdir -p "$OUT" && chmod 700 "$OUT"

# --- 1. Self-signed code-signing certificate (10 years) -------------------------------------------
cat > "$OUT/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = SpaceSweeper Release
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 3650 \
  -config "$OUT/cert.cnf" 2>/dev/null
P12_PASSWORD="$(openssl rand -base64 24)"
# Legacy algorithms so macOS's `security import` can read the file.
openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -out "$OUT/SpaceSweeper-Release.p12" \
  -passout "pass:$P12_PASSWORD" -name "SpaceSweeper Release" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -legacy
printf '%s' "$P12_PASSWORD" > "$OUT/p12-password.txt"
chmod 600 "$OUT"/*

# --- 2. Sparkle update-signing key ----------------------------------------------------------------
"$SPARKLE_BIN/generate_keys" --account spacesweeper >/dev/null
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account spacesweeper -p)"
"$SPARKLE_BIN/generate_keys" --account spacesweeper -x "$OUT/sparkle-private-key.txt" >/dev/null
chmod 600 "$OUT/sparkle-private-key.txt"

FINGERPRINT="$(openssl x509 -in "$OUT/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"

cat <<EOF

✔ Release keys created in $OUT  (back this folder up somewhere safe; never commit it)

Sparkle public key (goes in the project, it's public):
  SPARKLE_PUBLIC_KEY = $PUBLIC_KEY

Certificate fingerprint (SHA-1): $FINGERPRINT

Add these three repository secrets on GitHub
(Settings › Secrets and variables › Actions › New repository secret):

  SIGNING_CERT_P12       →  output of:  base64 -i "$OUT/SpaceSweeper-Release.p12" | pbcopy
  SIGNING_CERT_PASSWORD  →  output of:  pbcopy < "$OUT/p12-password.txt"
  SPARKLE_PRIVATE_KEY    →  output of:  pbcopy < "$OUT/sparkle-private-key.txt"

(Each command copies the value to the clipboard; paste it as the secret's value.)
EOF
