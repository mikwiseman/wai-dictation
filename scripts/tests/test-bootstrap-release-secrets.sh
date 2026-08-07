#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_DIRECTORY="$(mktemp -d)"

cleanup() {
  local exit_code=$?
  find "$TEMP_DIRECTORY" -type f -delete 2>/dev/null || true
  find "$TEMP_DIRECTORY" -depth -type d -delete 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

HOME="$TEMP_DIRECTORY/home"
mkdir -p "$HOME/.wai-dictation" "$HOME/transfer" "$HOME/.appstoreconnect"

SPARKLE_KEY_PATH="$HOME/.wai-dictation/sparkle-key"
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$SPARKLE_KEY_PATH"
chmod 600 "$SPARKLE_KEY_PATH"

SOURCE_KEY="$HOME/transfer/notary-key.p8"
cat >"$SOURCE_KEY" <<'EOF'
-----BEGIN PRIVATE KEY-----
TEST-NON-SECRET-FIXTURE
-----END PRIVATE KEY-----
EOF

APPSTORECONNECT_CONFIG="$HOME/.appstoreconnect/config.json"
cat >"$APPSTORECONNECT_CONFIG" <<EOF
{
  "key_id": "TESTKEY123",
  "issuer_id": "12345678-1234-1234-1234-1234567890ab",
  "key_filepath": "$SOURCE_KEY"
}
EOF
chmod 600 "$APPSTORECONNECT_CONFIG"

HOME="$HOME" \
SPARKLE_KEY_PATH="$SPARKLE_KEY_PATH" \
APPSTORECONNECT_CONFIG="$APPSTORECONNECT_CONFIG" \
  "$REPOSITORY_ROOT/scripts/bootstrap-release-secrets.sh" >/dev/null

CANONICAL_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_TESTKEY123.p8"
[[ -f "$CANONICAL_KEY" ]] || fail_test "canonical API key was not created"
[[ "$(stat -f '%Lp' "$CANONICAL_KEY")" == "600" ]] \
  || fail_test "canonical API key mode is not 0600"
cmp -s "$SOURCE_KEY" "$CANONICAL_KEY" \
  || fail_test "canonical API key content changed"

CONFIGURED_PATH="$(/usr/bin/plutil -extract key_filepath raw -o - "$APPSTORECONNECT_CONFIG")"
[[ "$CONFIGURED_PATH" == "~/.appstoreconnect/private_keys/AuthKey_TESTKEY123.p8" ]] \
  || fail_test "config key_filepath was not normalized"

printf 'PASS: release secret bootstrap\n'
