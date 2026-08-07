# Секреты и выпуск релиза

Правила работы с кодом — в [CLAUDE.md](CLAUDE.md), процесс сборки — в
[docs/release.md](docs/release.md). Здесь только то, что не лежит в репозитории
и лежать там не должно.

## Приватный ключ Sparkle

Приватный ключ Sparkle переносится между машинами: он привязан к продукту,
а не к учётной записи Apple.

| | |
|---|---|
| Хранилище | 1Password, сейф `Development` |
| Запись | `Wai Dictation Sparkle EdDSA private key` |
| ID записи | `mnt44t2qfcoavybwxokaqxx6se` |
| Ссылка | `op://Development/Wai Dictation Sparkle EdDSA private key` |
| Куда кладётся | `~/.wai-dictation/sparkle-key`, права `0600` |
| Публичная половина | `SUPublicEDKey` в `apps/macos/project.yml` — она публичная, её место в репозитории |

**Почему это критично.** Публичный ключ вшит в каждую разошедшуюся бету.
Приложение поставит только то обновление, которое подписано парной приватной
половиной. Потерять её и сгенерировать новую пару — значит навсегда оставить
всех установленных пользователей на текущей версии: их копия молча откажется
от обновления, и достучаться до них будет нечем.

Отсюда правило: **`generate_keys` на этом проекте больше не запускается
никогда.** Если ключ не находится — это разговор о том, как выпускать
обновление для тех, кто уже установил бету, а не повод сделать новую пару.

Ключ не хранится в связке ключей macOS специально: связка привязана к машине,
а восстановление после потери ноутбука — ровно тот случай, ради которого всё
это записано.

## На новой машине

```bash
./scripts/bootstrap-release-secrets.sh
```

Скрипт проверяет существующий Sparkle key или восстанавливает его из 1Password,
а затем проверяет file-based App Store Connect credentials. Если Sparkle key уже
перенесён, `op` для выпуска не нужен. Значения ключей и ID нигде не печатаются.

Нужны `~/.appstoreconnect/config.json` и выбранный `.p8` в
`~/.appstoreconnect/private_keys/`; оба файла имеют права `0600`.

## App Store Connect и Developer ID

Предпочтительная нотаризация использует App Store Connect Team API key:

- config: `~/.appstoreconnect/config.json` (`key_filepath`, `key_id`, `issuer_id`);
- key: `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`;
- права обоих файлов: `0600`;
- recovery backup: 1Password `Development`, item `Wai Dictation App Store Connect API key`, ID `zavvctbf6g4el7ygzphjb7mvu4`.

Release-скрипты никогда не читают App Store Connect credentials через `op`. Их
переносят между доверенными release-машинами по защищённому каналу и проверяют
`xcrun notarytool history --key ... --key-id ... --issuer ...`.

Отдельно нужен **сертификат Developer ID** с private key — Xcode → Settings →
Accounts либо `.p12` из архива. Проверить:
`security find-identity -v -p codesigning`. Без него `release.sh` останавливается.

## Выпуск

```bash
SPARKLE_KEY_PATH="$HOME/.wai-dictation/sparkle-key" \
DEVELOPER_ID="Developer ID Application: WaiWai, LLC (R4A779QVVY)" \
./scripts/release.sh
```

`release.sh` по умолчанию читает App Store Connect config и передаёт `notarytool`
`--key`, `--key-id` и `--issuer`. Профиль Keychain остаётся только явной
альтернативой; смешивать два способа запрещено.

Скрипт сам проверит: чистое дерево, ветку `main`, совпадение с `origin/main`,
зелёный CI на этом SHA, наличие заметок к релизу и два файла, которых без
человека не бывает, — `quality/live-benchmark.json` (живой смоук на пяти
голосах) и `quality/release-evidence.json` (ручная матрица установки).

Оба блокера намеренные. Они существуют, чтобы отличать измеренное на людях от
измеренного на синтезированной речи, и подставлять туда синтетику нельзя:
`quality/live-benchmark.json` — единственное место, где эта разница видна.

## Идентификатор приложения

`is.waiwai.dictation` неизменен навсегда: к нему привязан выданный
пользователями универсальный доступ. Смена идентификатора означает, что каждый
установивший заново идёт в системные настройки. `scripts/build-dmg.sh` это
проверяет.
