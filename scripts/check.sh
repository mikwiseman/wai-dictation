#!/bin/bash
# Прогнать всё, что должно быть зелёным перед коммитом.
#
#   ./scripts/check.sh          оба пакета + приложение + сетевой гейт
#   ./scripts/check.sh --fast   только пакеты и гейт (секунды, без Xcode)
#   ./scripts/check.sh --app    только приложение
#
# Скрипт сам чинит зависание сборки, о котором иначе спотыкаются все: SwiftPM
# спрашивает у Keychain учётные данные для хоста загрузки бинарного артефакта
# Sparkle, а показать диалог из терминала некому — и запрос ждёт вечно, на 0%
# CPU, без единой строки в логе. Лечится тем, что артефакт один раз кладётся
# в общий кэш прогоном с --disable-keychain; дальше xcodebuild берёт его
# оттуда и в Keychain не ходит вовсе.
#
# Кэш общий и переживает удаление DerivedData, но не переживает чистку
# ~/Library/Caches. Поэтому проверка дешёвая и делается каждый раз.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
ARTIFACT_CACHE="$HOME/Library/Caches/org.swift.swiftpm/artifacts"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

fail() { red "$1"; exit 1; }

# --- Прогрев кэша бинарных артефактов ---------------------------------------

warm_artifact_cache() {
  # Ревизию берём из project.yml, а не хардкодим: при обновлении Sparkle
  # кэш прогреется для новой версии сам, без правки этого скрипта.
  local revision
  revision=$(sed -n 's/^ *revision: *\([0-9a-f]\{40\}\).*/\1/p' apps/macos/project.yml | head -1)
  [[ -n "$revision" ]] || fail "Не нашёл ревизию Sparkle в apps/macos/project.yml"

  if compgen -G "$ARTIFACT_CACHE/*Sparkle*" > /dev/null 2>&1; then
    return 0
  fi

  echo "→ Кэш артефактов пуст — грею (иначе xcodebuild зависнет на Keychain)"
  local work
  work=$(mktemp -d)
  mkdir -p "$work/Sources/Warm"
  cat > "$work/Package.swift" <<SWIFT
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Warm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", revision: "$revision")
    ],
    targets: [
        .target(name: "Warm", dependencies: [.product(name: "Sparkle", package: "Sparkle")])
    ]
)
SWIFT
  echo "public let warm = 1" > "$work/Sources/Warm/Warm.swift"

  if (cd "$work" && swift build --disable-keychain > /dev/null 2>&1); then
    green "  кэш прогрет"
  else
    rm -rf "$work"
    fail "Не удалось прогреть кэш артефактов.
Проверьте сеть: curl -sSI https://github.com/sparkle-project/Sparkle/releases/latest | head -1"
  fi
  rm -rf "$work"
}

# --- Шаги --------------------------------------------------------------------

run_packages() {
  for package in DictationCore LocalASR; do
    echo "→ $package"
    local log
    log=$(mktemp)
    if swift test --package-path "Packages/$package" > "$log" 2>&1; then
      # Строку со счётчиком ищем во всём выводе, а не в хвосте: после неё
      # swift-testing печатает свои строки, и tail её не застаёт.
      grep -E "Executed [0-9]+ tests, with" "$log" | tail -1
    else
      grep -E "error:|failed" "$log" | head -20
      rm -f "$log"
      fail "Тесты $package не прошли."
    fi
    rm -f "$log"
  done
}

run_app() {
  warm_artifact_cache
  echo "→ Генерирую проект"
  local xcodegen
  xcodegen=$(scripts/pinned-xcodegen.sh)
  (cd apps/macos && "$xcodegen" generate > /dev/null)

  echo "→ Тесты приложения"
  local log
  log=$(mktemp)
  if (cd apps/macos && xcodebuild -project WaiDictation.xcodeproj -scheme WaiDictation \
        -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test) > "$log" 2>&1; then
    grep -E "Executed [0-9]+ tests, with" "$log" | tail -1
  else
    grep -E "error:" "$log" | head -20
    rm -f "$log"
    fail "Тесты приложения не прошли."
  fi
  rm -f "$log"
}

run_network_gate() {
  echo "→ Сетевая поверхность"
  ./scripts/check-network-surface.sh > /dev/null || fail "Сетевой гейт не прошёл."
  green "  обещание про сеть в силе"
}

case "$MODE" in
  --fast) run_packages; run_network_gate ;;
  --app)  run_app ;;
  all|*)  run_packages; run_app; run_network_gate ;;
esac

green "
Всё зелёное."
