#!/bin/bash
# Разложить секреты релиза по местам на этой машине.
#
# Приватный ключ Sparkle — единственный секрет проекта, который переносим:
# он не привязан ни к машине, ни к Apple ID. Хранится в 1Password, сюда
# приезжает файлом с правами 0600.
#
# Почему это важнее, чем кажется: публичный ключ вшит в каждую разошедшуюся
# бету (`SUPublicEDKey` в apps/macos/project.yml). Потерять приватную половину
# и сгенерировать новую пару — значит навсегда оставить всех установленных
# пользователей на текущей версии: их приложение просто откажется от
# обновления, подписанного чужим ключом, и сказать им об этом будет нечем.
#
# Запуск:
#   ./scripts/bootstrap-release-secrets.sh
#
# Перезаписать существующий ключ (по умолчанию запрещено):
#   FORCE=1 ./scripts/bootstrap-release-secrets.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ITEM_ID="${OP_SPARKLE_ITEM:-mnt44t2qfcoavybwxokaqxx6se}"
KEY_PATH="${SPARKLE_KEY_PATH:-$HOME/.wai-dictation/sparkle-key}"
FORCE="${FORCE:-0}"

fail() {
  echo "" >&2
  echo "$1" >&2
  exit 1
}

# --- Проверки окружения ------------------------------------------------------

command -v op >/dev/null || fail "Не найден 1Password CLI (op).

Установить:
  brew install 1password-cli
или скачать и положить в ~/.local/bin:
  https://developer.1password.com/docs/cli/get-started/"

# Ошибку авторизации отделяем от всего остального: она самая частая и
# чинится не тем, чем остальные.
if ! op account list >/dev/null 2>&1; then
  fail "1Password CLI не подключён к аккаунту.
  op account add   — и следуйте подсказкам."
fi

# --- Куда пишем --------------------------------------------------------------

# Ключ рядом с исходниками — это ключ, который однажды уедет в git. Проверяем
# до записи, а не после.
REPO_ROOT="$(pwd -P)"
KEY_DIR="$(dirname "$KEY_PATH")"

# Проверяем ДО mkdir. Иначе отказ всё равно оставлял бы за собой пустой
# каталог внутри репозитория — тихий мусор ровно там, где мы только что
# объяснили, что ничего быть не должно.
case "$KEY_DIR/" in
  /*) ABS_KEY_DIR="$KEY_DIR" ;;
  *)  ABS_KEY_DIR="$REPO_ROOT/$KEY_DIR" ;;
esac
case "$(cd "$(dirname "$ABS_KEY_DIR")" 2>/dev/null && pwd -P || echo "$ABS_KEY_DIR")/$(basename "$ABS_KEY_DIR")/" in
  "$REPO_ROOT"/*)
    fail "Отказываюсь писать ключ внутрь репозитория: $KEY_PATH
Приватный ключ рядом с исходниками рано или поздно окажется в коммите."
    ;;
esac

mkdir -p "$KEY_DIR"
KEY_DIR_REAL="$(cd "$KEY_DIR" && pwd -P)"

if [[ -e "$KEY_PATH" && "$FORCE" != "1" ]]; then
  echo "Ключ уже на месте: $KEY_PATH"
  echo "Ничего не трогаю. Перезаписать: FORCE=1 $0"
  exit 0
fi

# --- Достаём ключ ------------------------------------------------------------

echo "→ Читаю ключ из 1Password (запись $ITEM_ID)"

ITEM_JSON="$(op item get "$ITEM_ID" --format json 2>/dev/null)" || fail "Не удалось прочитать запись $ITEM_ID.

Частые причины:
  • в приложении 1Password не включена интеграция с CLI
    (Settings → Developer → Integrate with 1Password CLI);
  • запрос на разблокировку остался без ответа — повторите и подтвердите;
  • нет доступа к сейфу Development."

# Поле выбирает скрипт, а не человек: у записи может быть и password, и
# notes, и вложение. Значение при этом нигде не печатается — оно уходит
# прямо в файл.
KEY_VALUE="$(
  ITEM_JSON="$ITEM_JSON" python3 - <<'PY'
import json, os, re, sys

item = json.loads(os.environ["ITEM_JSON"])
# Приватный ключ Sparkle — одна строка base64 (ed25519, 32 байта seed).
pattern = re.compile(r"^[A-Za-z0-9+/]{40,120}={0,2}$")

candidates = []
for field in item.get("fields", []):
    value = (field.get("value") or "").strip()
    if not value:
        continue
    # Предпочитаем поля с говорящей меткой, но не полагаемся на неё.
    weight = 0 if (field.get("id") == "password" or "key" in str(field.get("label", "")).lower()) else 1
    candidates.append((weight, value))

for weight, value in sorted(candidates, key=lambda pair: pair[0]):
    if pattern.match(value):
        sys.stdout.write(value)
        sys.exit(0)

sys.exit(3)
PY
)" || fail "В записи $ITEM_ID не нашлось поля, похожего на приватный ключ Sparkle.

Ожидается одна строка base64 (то, что печатает generate_keys -x).
Если ключ лежит вложенным файлом, выгрузите его руками:
  op read 'op://Development/Wai Dictation Sparkle EdDSA private key/<поле>' > \"$KEY_PATH\"
  chmod 600 \"$KEY_PATH\""

# --- Пишем -------------------------------------------------------------------

# umask до создания файла, а не chmod после: между созданием и chmod файл
# успевает пожить с правами по умолчанию, и этого достаточно.
OLD_UMASK="$(umask)"
umask 077
TMP_PATH="$KEY_DIR_REAL/.sparkle-key.$$"
printf '%s\n' "$KEY_VALUE" > "$TMP_PATH"
umask "$OLD_UMASK"
chmod 600 "$TMP_PATH"
mv -f "$TMP_PATH" "$KEY_PATH"
unset KEY_VALUE

echo "→ Ключ записан: $KEY_PATH"

# --- Проверяем, что ключ рабочий --------------------------------------------

# Единственная честная проверка — подписать им что-нибудь. Сверять сам ключ
# глазами нельзя (и не нужно): важно не как он выглядит, а принимает ли его
# инструмент, которым подписывается релиз.
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -maxdepth 8 -name sign_update -type f 2>/dev/null | head -1 || true)"

if [[ -z "$SIGN_UPDATE" ]]; then
  echo "  sign_update не найден — проверить подпись сейчас нечем."
  echo "  Соберите приложение один раз, и запустите скрипт снова."
else
  PROBE="$(mktemp)"
  echo "проверка" > "$PROBE"
  if "$SIGN_UPDATE" "$PROBE" -f "$KEY_PATH" >/dev/null 2>&1; then
    echo "→ Подпись работает: sign_update принял ключ."
  else
    rm -f "$PROBE"
    fail "sign_update не принял ключ из $KEY_PATH.
Скорее всего, в 1Password лежит не та строка. НЕ генерируйте новую пару:
публичный ключ уже вшит в разошедшиеся беты, и новая пара сломает
обновление у всех установленных копий."
  fi
  rm -f "$PROBE"
fi

# --- Чего здесь нет ----------------------------------------------------------

cat <<'TEXT'

Готово. Осталось то, что перенести нельзя — это Apple-секреты, привязанные
к учётной записи разработчика, а не к проекту:

  • сертификат Developer ID  — Xcode → Settings → Accounts, либо .p12 из архива;
    проверить:  security find-identity -v -p codesigning
  • профиль нотаризации      — xcrun notarytool store-credentials
    (спросит Apple ID и app-specific password)

Дальше:
  SPARKLE_KEY_PATH="$HOME/.wai-dictation/sparkle-key" \
  DEVELOPER_ID="Developer ID Application: …" \
  NOTARY_PROFILE="…" \
  ./scripts/release.sh
TEXT
