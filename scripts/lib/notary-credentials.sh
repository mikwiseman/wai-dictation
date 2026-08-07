#!/bin/bash
# Общий загрузчик credentials для xcrun notarytool.
# Файл предназначен для source из release/build scripts.

expand_notary_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#"~/"}" ;;
    /*) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

notary_credentials_error() {
  printf 'Notary credentials: %s\n' "$1" >&2
  return 1
}

read_appstoreconnect_config_value() {
  local key="$1"
  /usr/bin/plutil -extract "$key" raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null
}

validate_notary_api_key() {
  local key_mode first_line last_line

  [[ "$NOTARY_KEY_ID" =~ ^[A-Za-z0-9]{10,}$ ]] \
    || notary_credentials_error "key_id должен содержать не менее 10 букв или цифр." \
    || return 1

  if [[ -n "$NOTARY_ISSUER" ]]; then
    [[ "$NOTARY_ISSUER" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
      || notary_credentials_error "issuer_id должен быть UUID." \
      || return 1
  fi

  [[ -f "$NOTARY_KEY" ]] \
    || notary_credentials_error "файл App Store Connect API key не найден." \
    || return 1

  key_mode="$(stat -f '%Lp' "$NOTARY_KEY")"
  [[ "$key_mode" == "600" ]] \
    || notary_credentials_error "App Store Connect API key должен иметь mode 0600." \
    || return 1

  IFS= read -r first_line <"$NOTARY_KEY"
  last_line="$(tail -n 1 "$NOTARY_KEY")"
  [[ "$first_line" =~ ^-----BEGIN\ (EC\ )?PRIVATE\ KEY-----$ ]] \
    || notary_credentials_error "неверный PEM header у App Store Connect API key." \
    || return 1
  [[ "$last_line" =~ ^-----END\ (EC\ )?PRIVATE\ KEY-----$ ]] \
    || notary_credentials_error "неверный PEM footer у App Store Connect API key." \
    || return 1
}

load_notary_credentials() {
  local has_direct_credentials=0 config_mode raw_key_path

  APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
  NOTARY_PROFILE="${NOTARY_PROFILE:-}"
  NOTARY_KEY="${NOTARY_KEY:-}"
  NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
  NOTARY_ISSUER="${NOTARY_ISSUER:-}"
  NOTARY_ARGS=()
  NOTARY_AUTH_SOURCE=""

  if [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]; then
    has_direct_credentials=1
  fi

  if [[ -n "$NOTARY_PROFILE" && "$has_direct_credentials" -eq 1 ]]; then
    notary_credentials_error "NOTARY_PROFILE нельзя смешивать с NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER."
    return 1
  fi

  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_SOURCE="keychain-profile"
    return 0
  fi

  if [[ "$has_direct_credentials" -eq 1 ]]; then
    if [[ -z "$NOTARY_KEY" || -z "$NOTARY_KEY_ID" ]]; then
      notary_credentials_error "для API key обязательны одновременно NOTARY_KEY и NOTARY_KEY_ID."
      return 1
    fi
    NOTARY_KEY="$(expand_notary_path "$NOTARY_KEY")" \
      || { notary_credentials_error "NOTARY_KEY должен быть абсолютным путём или начинаться с ~/."; return 1; }
    NOTARY_AUTH_SOURCE="environment"
  else
    [[ -f "$APPSTORECONNECT_CONFIG" ]] \
      || { notary_credentials_error "нет $APPSTORECONNECT_CONFIG."; return 1; }

    config_mode="$(stat -f '%Lp' "$APPSTORECONNECT_CONFIG")"
    [[ "$config_mode" == "600" ]] \
      || { notary_credentials_error "config.json должен иметь mode 0600."; return 1; }

    raw_key_path="$(read_appstoreconnect_config_value key_filepath)" \
      || { notary_credentials_error "в config.json нет key_filepath."; return 1; }
    NOTARY_KEY_ID="$(read_appstoreconnect_config_value key_id)" \
      || { notary_credentials_error "в config.json нет key_id."; return 1; }
    NOTARY_ISSUER="$(read_appstoreconnect_config_value issuer_id 2>/dev/null || true)"
    NOTARY_KEY="$(expand_notary_path "$raw_key_path")" \
      || { notary_credentials_error "key_filepath должен быть абсолютным или начинаться с ~/."; return 1; }
    case "$NOTARY_KEY" in
      "$HOME/.appstoreconnect/private_keys/"*) ;;
      *) notary_credentials_error "key_filepath должен указывать в ~/.appstoreconnect/private_keys/."; return 1 ;;
    esac
    NOTARY_AUTH_SOURCE="appstoreconnect-config"
  fi

  validate_notary_api_key || return 1

  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
  if [[ -n "$NOTARY_ISSUER" ]]; then
    NOTARY_ARGS+=(--issuer "$NOTARY_ISSUER")
  fi
}
