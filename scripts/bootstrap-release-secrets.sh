#!/bin/bash
# Подготовить локальные release credentials, не печатая секреты.
# Sparkle key восстанавливается из 1Password. App Store Connect остаётся
# file-based: config.json выбирает .p8 и два идентификатора.

set -euo pipefail

SECRET_REFERENCE='op://Development/Wai Dictation Sparkle EdDSA private key/password'
KEY_PATH="${SPARKLE_KEY_PATH:-$HOME/.wai-dictation/sparkle-key}"
KEY_DIRECTORY=$(dirname "$KEY_PATH")
TEMP_KEY="$KEY_PATH.pending.$$"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
TEMP_NOTARY_KEY=""
TEMP_CONFIG=""

cleanup() {
  if [[ -e "$TEMP_KEY" ]]; then
    /bin/rm -f -- "$TEMP_KEY"
  fi
  if [[ -n "$TEMP_NOTARY_KEY" && -e "$TEMP_NOTARY_KEY" ]]; then
    /bin/rm -f -- "$TEMP_NOTARY_KEY"
  fi
  if [[ -n "$TEMP_CONFIG" && -e "$TEMP_CONFIG" ]]; then
    /bin/rm -f -- "$TEMP_CONFIG"
  fi
}
trap cleanup EXIT

fail() {
  printf 'Ошибка: %s\n' "$1" >&2
  exit 1
}

validate_sparkle_key() {
  local key_size file_mode
  key_size=$(wc -c < "$1" | tr -d ' ')
  [[ "$key_size" == "44" ]] \
    || fail "Sparkle key неожиданного размера: $key_size байт."

  file_mode=$(stat -f '%Lp' "$1")
  [[ "$file_mode" == "600" ]] \
    || fail "Неверные права Sparkle key: $file_mode вместо 600."
}

if [[ -e "$KEY_PATH" ]]; then
  validate_sparkle_key "$KEY_PATH"
  echo "Sparkle key уже готов: $KEY_PATH (44 байта, mode 0600)."
else
  command -v op >/dev/null 2>&1 || fail "не найден 1Password CLI (op)."
  mkdir -p "$KEY_DIRECTORY"
  op read \
    --out-file "$TEMP_KEY" \
    --file-mode 0600 \
    "$SECRET_REFERENCE"

  validate_sparkle_key "$TEMP_KEY"
  mv "$TEMP_KEY" "$KEY_PATH"
  echo "Sparkle key восстановлен: $KEY_PATH (44 байта, mode 0600)."
fi

# shellcheck source=lib/notary-credentials.sh
source "$(dirname "$0")/lib/notary-credentials.sh"

normalize_appstoreconnect_key() {
  local config_mode raw_key_path source_key_path key_id canonical_directory
  local canonical_key_path canonical_config_path

  [[ -f "$APPSTORECONNECT_CONFIG" ]] \
    || fail "нет $APPSTORECONNECT_CONFIG с App Store Connect API credentials."

  config_mode=$(stat -f '%Lp' "$APPSTORECONNECT_CONFIG")
  [[ "$config_mode" == "600" ]] \
    || fail "$APPSTORECONNECT_CONFIG должен иметь mode 0600."

  raw_key_path=$(/usr/bin/plutil -extract key_filepath raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null) \
    || fail "в $APPSTORECONNECT_CONFIG нет key_filepath."
  key_id=$(/usr/bin/plutil -extract key_id raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null) \
    || fail "в $APPSTORECONNECT_CONFIG нет key_id."
  [[ "$key_id" =~ ^[A-Za-z0-9]{10,}$ ]] \
    || fail "key_id в $APPSTORECONNECT_CONFIG имеет неверный формат."

  source_key_path=$(expand_notary_path "$raw_key_path") \
    || fail "key_filepath должен быть абсолютным или начинаться с ~/."
  [[ -f "$source_key_path" ]] \
    || fail "файл App Store Connect API key из config.json не найден."

  canonical_directory="$HOME/.appstoreconnect/private_keys"
  canonical_key_path="$canonical_directory/AuthKey_${key_id}.p8"
  canonical_config_path="~/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
  mkdir -p "$canonical_directory"

  if [[ "$source_key_path" != "$canonical_key_path" ]]; then
    if [[ -e "$canonical_key_path" ]]; then
      cmp -s "$source_key_path" "$canonical_key_path" \
        || fail "в стандартном каталоге уже лежит другой API key; не перезаписываю."
    else
      TEMP_NOTARY_KEY="$canonical_key_path.pending.$$"
      cp "$source_key_path" "$TEMP_NOTARY_KEY"
      chmod 600 "$TEMP_NOTARY_KEY"
      mv "$TEMP_NOTARY_KEY" "$canonical_key_path"
      TEMP_NOTARY_KEY=""
    fi

    TEMP_CONFIG="$APPSTORECONNECT_CONFIG.pending.$$"
    cp "$APPSTORECONNECT_CONFIG" "$TEMP_CONFIG"
    /usr/bin/plutil -replace key_filepath -string "$canonical_config_path" "$TEMP_CONFIG"
    chmod 600 "$TEMP_CONFIG"
    mv "$TEMP_CONFIG" "$APPSTORECONNECT_CONFIG"
    TEMP_CONFIG=""
  fi

  chmod 600 "$canonical_key_path"
}

normalize_appstoreconnect_key

NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_ARGS=()
load_notary_credentials || fail "App Store Connect credentials не прошли проверку."

[[ "$NOTARY_AUTH_SOURCE" == "appstoreconnect-config" ]] \
  || fail "ожидались file-based App Store Connect credentials."

trap - EXIT

echo "App Store Connect API key готов в ~/.appstoreconnect/private_keys/; config mode 0600."
