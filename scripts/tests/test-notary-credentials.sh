#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
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

assert_equal() {
  local expected="$1" actual="$2" message="$3"
  [[ "$expected" == "$actual" ]] \
    || fail_test "$message: expected '$expected', got '$actual'"
}

HOME="$TEMP_DIRECTORY/home"
mkdir -p "$HOME/.appstoreconnect/private_keys"

KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_TESTKEY123.p8"
cat >"$KEY_PATH" <<'EOF'
-----BEGIN PRIVATE KEY-----
TEST-NON-SECRET-FIXTURE
-----END PRIVATE KEY-----
EOF
chmod 600 "$KEY_PATH"

CONFIG_PATH="$HOME/.appstoreconnect/config.json"
cat >"$CONFIG_PATH" <<'EOF'
{
  "key_id": "TESTKEY123",
  "issuer_id": "12345678-1234-1234-1234-1234567890ab",
  "key_filepath": "~/.appstoreconnect/private_keys/AuthKey_TESTKEY123.p8"
}
EOF
chmod 600 "$CONFIG_PATH"

# shellcheck source=../lib/notary-credentials.sh
[[ -f "$REPOSITORY_ROOT/scripts/lib/notary-credentials.sh" ]] \
  || fail_test "notary credential library is missing"
source "$REPOSITORY_ROOT/scripts/lib/notary-credentials.sh"

APPSTORECONNECT_CONFIG="$CONFIG_PATH"
NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_ARGS=()

load_notary_credentials || fail_test "valid config was rejected"
assert_equal "$KEY_PATH" "$NOTARY_KEY" "key path"
assert_equal "TESTKEY123" "$NOTARY_KEY_ID" "key id"
assert_equal "12345678-1234-1234-1234-1234567890ab" "$NOTARY_ISSUER" "issuer"
assert_equal "6" "${#NOTARY_ARGS[@]}" "notary argument count"

NOTARY_PROFILE="saved-profile"
NOTARY_KEY="$KEY_PATH"
NOTARY_KEY_ID="TESTKEY123"
NOTARY_ISSUER="12345678-1234-1234-1234-1234567890ab"
NOTARY_ARGS=()
if load_notary_credentials >/dev/null 2>&1; then
  fail_test "profile and API key were accepted together"
fi

NOTARY_PROFILE=""
NOTARY_KEY="$KEY_PATH"
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_ARGS=()
if load_notary_credentials >/dev/null 2>&1; then
  fail_test "partial direct credentials were accepted"
fi

NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_ARGS=()
chmod 644 "$KEY_PATH"
if load_notary_credentials >/dev/null 2>&1; then
  fail_test "world-readable API key was accepted"
fi

printf 'PASS: notary credential loading\n'
