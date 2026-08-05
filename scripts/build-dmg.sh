#!/bin/bash
# Собрать образ для распространения.
#
# Без Developer ID получается только Debug-probe с отдельными именем и bundle
# id. Production identity никогда не подписывается ad-hoc: иначе каждый rebuild
# создаёт новую запись Accessibility, а в системных настройках копятся
# неразличимые «Wai Dictation».
#
#   DEVELOPER_ID   — «Developer ID Application: …»
#   NOTARY_PROFILE — профиль notarytool, заведённый через `xcrun notarytool store-credentials`
# Если профиль не задан, используются ключ и идентификаторы из
# ~/.appstoreconnect/config.json — без вывода секретов в лог.
#
# Запуск:
#   ./scripts/build-dmg.sh            Debug-probe: Wai Dictation Dev
#   DEVELOPER_ID="…" NOTARY_PROFILE="…" ./scripts/build-dmg.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="WaiDictation"
PROJECT="apps/macos/WaiDictation.xcodeproj"
BUILD_DIR="artifacts/build"
DMG_DIR="artifacts/dmg"
APP_ENTITLEMENTS="apps/macos/WaiDictation/WaiDictation.entitlements"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
BUILD_NUMBER_OVERRIDE="${BUILD_NUMBER_OVERRIDE:-}"
NOTARY_ARGS=()
BUILD_OVERRIDES=()

if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  [[ "$BUILD_NUMBER_OVERRIDE" =~ ^[0-9]+$ ]] || {
    echo "BUILD_NUMBER_OVERRIDE должен состоять только из цифр." >&2
    exit 1
  }
  BUILD_OVERRIDES=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER_OVERRIDE")
  echo "→ Build number override: $BUILD_NUMBER_OVERRIDE"
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  APP_NAME="Wai Dictation"
  BUNDLE_ID="is.waiwai.dictation"
  BUILD_CONFIGURATION="Release"
  DMG_BASENAME="WaiDictation"
else
  APP_NAME="Wai Dictation Dev"
  BUNDLE_ID="is.waiwai.dictation.dev"
  BUILD_CONFIGURATION="Debug"
  DMG_BASENAME="WaiDictationDev"
fi

expand_user_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#"~/"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

read_appstoreconnect_config_value() {
  [[ -f "$APPSTORECONNECT_CONFIG" ]] || return 0
  /usr/bin/plutil -extract "$1" raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null || true
}

load_notary_credentials() {
  if [[ -z "$NOTARY_PROFILE" && -z "$NOTARY_KEY" && -z "$NOTARY_KEY_ID" ]]; then
    local key_path
    key_path=$(read_appstoreconnect_config_value key_filepath)
    NOTARY_KEY_ID=$(read_appstoreconnect_config_value key_id)
    NOTARY_ISSUER=$(read_appstoreconnect_config_value issuer_id)
    if [[ -n "$key_path" ]]; then
      NOTARY_KEY=$(expand_user_path "$key_path")
    fi
  fi

  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" ]]; then
    [[ -f "$NOTARY_KEY" ]] || {
      echo "Notary API key не найден по пути из конфигурации." >&2
      return 1
    }
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
    if [[ -n "$NOTARY_ISSUER" ]]; then
      NOTARY_ARGS+=(--issuer "$NOTARY_ISSUER")
    fi
  fi

  [[ ${#NOTARY_ARGS[@]} -gt 0 ]]
}

if ! load_notary_credentials && [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  echo "Для installable beta обязательны настроенные credentials нотаризации." >&2
  exit 1
fi

echo "→ Генерирую проект"
XCODEGEN=$(./scripts/pinned-xcodegen.sh)
(cd apps/macos && "$XCODEGEN" generate >/dev/null)

echo "→ Собираю конфигурацию $BUILD_CONFIGURATION"
rm -rf "$BUILD_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"

PACKAGE_CACHE="$BUILD_DIR/SourcePackages"
echo "→ Разрешаю immutable package revisions"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" >/dev/null

if [[ -n "$DEVELOPER_ID" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual)
else
  echo "  Developer ID не задан — собираю отдельный Debug-probe Wai Dictation Dev"
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

ARCHIVE_LOG=$(mktemp)
# В ловушке — только временные файлы. Здесь однажды побывала переменная,
# которую ниже переиспользовали под путь В РЕПОЗИТОРИИ, — и каждая репетиция
# сборки молча удаляла licenses/CC-BY-4.0.txt, после чего release.sh падал
# на «грязном дереве» без намёка на причину.
trap 'rm -f "$ARCHIVE_LOG"' EXIT
set +e
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
  "${SIGN_ARGS[@]}" ${BUILD_OVERRIDES[@]+"${BUILD_OVERRIDES[@]}"} 2>&1 \
  | tee "$ARCHIVE_LOG" \
  | grep -E "error:|warning: .*deprecated|ARCHIVE"
ARCHIVE_STATUS=${PIPESTATUS[0]}
set -e
if [[ $ARCHIVE_STATUS -ne 0 ]]; then
  echo "Archive failed with exit code $ARCHIVE_STATUS" >&2
  exit "$ARCHIVE_STATUS"
fi

APP_PATH="$BUILD_DIR/$SCHEME.xcarchive/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Сборка не дала приложения" >&2
  exit 1
fi

# Binary targets зависимостей могут приехать universal, даже когда наша цель
# собирается arm64. Убираем чужой x86_64 до подписи; отсутствие arm64 — hard
# failure, а не повод оставить смешанный artifact.
echo "→ Убираю не-arm64 slices из bundled binary targets"
while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  archs=$(lipo -archs "$binary")
  [[ " $archs " == *" arm64 "* ]] || {
    echo "В Mach-O нет arm64 slice: $binary ($archs)" >&2
    exit 1
  }
  if [[ "$archs" != "arm64" ]]; then
    thinned="$binary.arm64-thinned"
    rm -f "$thinned"
    lipo "$binary" -thin arm64 -output "$thinned"
    mv "$thinned" "$binary"
  fi
done < <(find "$APP_PATH" -type f)

# Полные тексты лицензий должны ехать в самом artifact, а не быть только
# ссылками в README. Исходники берутся из тех же immutable package revisions,
# которыми только что собрано приложение.
echo "→ Добавляю полные third-party licenses"
RESOURCES="$APP_PATH/Contents/Resources"
FLUID_LICENSES="$PACKAGE_CACHE/checkouts/FluidAudio"
SPARKLE_LICENSES="$PACKAGE_CACHE/checkouts/Sparkle"
for source in \
  "$FLUID_LICENSES/LICENSE" \
  "$FLUID_LICENSES/ThirdPartyLicenses/fastcluster-LICENSE.md" \
  "$FLUID_LICENSES/ThirdPartyLicenses/vbx-LICENSE.md" \
  "$SPARKLE_LICENSES/LICENSE"
do
  [[ -s "$source" ]] || { echo "Нет license в resolved dependency: $source" >&2; exit 1; }
done
cp "$FLUID_LICENSES/LICENSE" "$RESOURCES/FluidAudio-Apache-2.0.txt"
cp "$FLUID_LICENSES/ThirdPartyLicenses/fastcluster-LICENSE.md" "$RESOURCES/FluidAudio-fastcluster-BSD.txt"
cp "$FLUID_LICENSES/ThirdPartyLicenses/vbx-LICENSE.md" "$RESOURCES/FluidAudio-vbx-Apache-2.0.txt"
cp "$SPARKLE_LICENSES/LICENSE" "$RESOURCES/Sparkle-LICENSE.txt"

# Текст CC BY 4.0 завендорен в репозиторий: сборка не должна требовать сети.
# Checksum остаётся — файл юридический, молчаливая подмена недопустима.
CC_SOURCE="licenses/CC-BY-4.0.txt"
CC_SHA=$(shasum -a 256 "$CC_SOURCE" | awk '{print $1}')
if [[ "$CC_SHA" != "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411" ]]; then
  echo "CC BY 4.0 legalcode checksum mismatch: $CC_SHA" >&2
  exit 1
fi
cp "$CC_SOURCE" "$RESOURCES/Parakeet-CC-BY-4.0.txt"

# Каждый Mach-O в artifact обязан быть arm64-only: включая Sparkle helpers.
echo "→ Проверяю arm64-only"
while IFS= read -r binary; do
  if ! file "$binary" | grep -q 'Mach-O'; then
    continue
  fi
  ARCHS=$(lipo -archs "$binary")
  echo "  ${binary#$APP_PATH/}: $ARCHS"
  if [[ "$ARCHS" != "arm64" ]]; then
    echo "Недопустимые slices в $binary: $ARCHS" >&2
    exit 1
  fi
done < <(find "$APP_PATH" -type f)

echo "→ Проверяю минимальную версию системы"
MIN_OS=$(vtool -show-build "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -m1 "minos" | awk '{print $2}')
echo "  minos $MIN_OS"
if [[ "$MIN_OS" != "14.0" ]]; then
  echo "Ожидалась minOS 14.0, получилась $MIN_OS" >&2
  exit 1
fi

# Release identifier обязан остаться неизменным навсегда: на нём держится
# выданный пользователем универсальный доступ. Debug-probe намеренно использует
# отдельный .dev identifier. Проверяем до подписи, потому что подпись его и
# закрепляет.
echo "→ Проверяю идентификатор"
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
echo "  $ACTUAL_BUNDLE_ID"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Идентификатор не тот: ожидался $BUNDLE_ID, получился «$ACTUAL_BUNDLE_ID»." >&2
  echo "Ожидалась конфигурация $BUILD_CONFIGURATION." >&2
  exit 1
fi

ACTUAL_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
echo "→ Build number: $ACTUAL_BUILD_NUMBER"
if [[ -n "$BUILD_NUMBER_OVERRIDE" && "$ACTUAL_BUILD_NUMBER" != "$BUILD_NUMBER_OVERRIDE" ]]; then
  echo "Build number override не попал в artifact." >&2
  exit 1
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Подписываю"

  # Подписывать нужно изнутри наружу, каждый вложенный компонент отдельно.
  # Порядок и состав — из документации Sparkle (sparkle-project.org, раздел
  # про песочницу и подпись компонентов).
  #
  # --deep здесь запрещён по двум причинам. Apple объявила его для подписи
  # устаревшим («for emergency use only»): он применяет одни и те же опции ко
  # всему вложенному коду, хотя тот подписывается по-разному. Sparkle просит не
  # применять его прямо: Downloader.xpc подписывается со своими entitlements,
  # которых нет у остальных двоичных файлов, и одинаковыми опциями их не
  # накрыть. Ломается при этом не сборка и не нотаризация, а установка
  # обновления — то есть у первого же пользователя, и чинить будет уже нечем.
  SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE/Versions/B"

  sign() {
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"
  }

  # Если Sparkle переедет на другую букву версии или уберёт компонент, молча
  # пропустить его нельзя: вложенный код останется с ad-hoc подписью сборки.
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    if [[ ! -e "$component" ]]; then
      echo "Не нашёл вложенный компонент Sparkle: $component" >&2
      echo "Разложение фреймворка изменилось — обновите список, иначе часть кода" >&2
      echo "уедет в релиз с ad-hoc подписью." >&2
      exit 1
    fi
  done

  sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  # Единственный компонент, которому Sparkle отдельно велит сохранять
  # entitlements. У нас приложение не в песочнице, и сейчас там пустой список —
  # но это ровно то место, где право на сеть появится, если песочница когда-то
  # включится. Флаг стоит заранее, чтобы подпись не съела его молча.
  sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  sign "$SPARKLE_VERSION/Autoupdate"
  sign "$SPARKLE_VERSION/Updater.app"
  sign "$SPARKLE"

  # Приложение — последним. Идентификатор задаём явно, чтобы он не зависел от
  # имени продукта и настроек сборки.
  sign --identifier "$BUNDLE_ID" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

  # А вот при проверке --deep как раз нужен: он обходит вложенный код.
  echo "→ Проверяю подпись"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # Ради чего проверка: пропущенный компонент останется с ad-hoc подписью
  # сборки. Нотаризация такое отклонит, а если и пропустит — сломается ровно
  # установка обновления. Сверяем удостоверение каждого компонента с
  # удостоверением приложения.
  APP_AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  echo "  удостоверение: ${APP_AUTHORITY:-ad-hoc}"
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    authority=$(codesign -dvv "$component" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    if [[ "$authority" != "$APP_AUTHORITY" ]]; then
      echo "Компонент подписан не тем же удостоверением: $component" >&2
      echo "  приложение: ${APP_AUTHORITY:-ad-hoc}" >&2
      echo "  компонент:  ${authority:-ad-hoc}" >&2
      exit 1
    fi
  done
  echo "  вложенный код подписан тем же удостоверением"
else
  # После thinning и добавления license resources подписи готовых Sparkle
  # компонентов уже недействительны. Debug-probe должен проходить строгую
  # локальную проверку кода, поэтому пересобираем ad-hoc подпись изнутри
  # наружу. Его .dev identity не может загрязнить production TCC grant.
  echo "→ Ставлю проверяемую ad-hoc подпись Debug-probe"
  SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE/Versions/B"
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    [[ -e "$component" ]] || {
      echo "Не нашёл вложенный компонент Sparkle: $component" >&2
      exit 1
    }
  done

  codesign --force --sign - "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  codesign --force --sign - --preserve-metadata=entitlements \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  codesign --force --sign - "$SPARKLE_VERSION/Autoupdate"
  codesign --force --sign - "$SPARKLE_VERSION/Updater.app"
  codesign --force --sign - "$SPARKLE"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "→ Собираю образ"
STAGING="$DMG_DIR/staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# PlistBuddy, а не defaults: defaults молча падал на этом пути, и фолбэк
# подписывал образ чужой версией — релиз v0.1.0 с приложением 0.2.0 внутри.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$DMG_DIR/$DMG_BASENAME-$VERSION.dmg"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Подписываю DMG"
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH" >/dev/null

if [[ -n "$DEVELOPER_ID" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "→ Отправляю на нотаризацию (это занимает несколько минут)"
  NOTARY_RESULT=$(xcrun notarytool submit \
    "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait --output-format json)
  NOTARY_STATUS=$(printf '%s' "$NOTARY_RESULT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
  NOTARY_ID=$(printf '%s' "$NOTARY_RESULT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
  echo "  status: ${NOTARY_STATUS:-unknown}; id: ${NOTARY_ID:-unknown}"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    if [[ -n "$NOTARY_ID" ]]; then
      xcrun notarytool log "$NOTARY_ID" "${NOTARY_ARGS[@]}" || true
    fi
    echo "Нотаризация отклонена." >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  echo "→ Нотаризовано"
else
  if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    echo "Нотаризация обязательна, но Developer ID или credentials не заданы." >&2
    exit 1
  fi
  echo "  Нотаризация пропущена: это не installable beta"
fi

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
echo ""
echo "Готово: $DMG_PATH"
