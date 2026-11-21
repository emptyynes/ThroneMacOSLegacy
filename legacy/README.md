# Throne на macOS 10.13 (High Sierra)

> **Все изменения в этом репозитории сделаны LLM.** Код, скрипты, патчи и документация
> написаны языковой моделью (Hermes Agent) в паре с владельцем форка, который запускал
> команды и проверял результат на живой машине. Человек не писал здесь ни строки руками —
> он ставил задачи и подтверждал, что приложение действительно работает.

Проверено на:

| | |
|---|---|
| Машина | MacBook Pro 13" Late 2011 (i5-2435M, 16 ГБ) |
| ОС | macOS 10.13.6 (17G14042), Darwin 17.7.0, x86_64 |
| Хост-приложение | Throne 1.4.2, официальный `Throne-1.4.2-macoslegacy-amd64.zip` |
| Qt | 6.4.3, `minos 10.15`, SDK 15.5 |
| Ядро | `ThroneCore`, пересобрано Go 1.26.10, `CGO_ENABLED=0` |

## Почему не работает из коробки

Официальный «legacy»-билд собирается с `CMAKE_OSX_DEPLOYMENT_TARGET=10.15`, то есть
рассчитан на Catalina. На High Sierra он падает на пяти независимых слоях, и каждый
следующий виден только после починки предыдущего:

1. `LSMinimumSystemVersion` в `Info.plist` = 10.15 — LaunchServices отказывается запускать.
2. `QtCore` упирается в две вещи: символ `_NSAppearanceNameDarkAqua` (AppKit 10.14)
   и собственную проверку версии ОС в коде (`QVersionNumber::compare` + `exit(1)`
   с текстом «Qt requires macOS 10.14.0»).
3. После старта Qt дёргает API 10.14 через Objective-C: `+[NSColor unemphasizedSelectedContentBackgroundColor]`,
   `-effectiveAppearance`, `-bestMatchFromAppearancesWithNames:` — по одному краху на запуск.
4. `ThroneCore` собран с cgo и грузит `Network.framework` (10.14) — dyld: image not found.
5. Даже пересобранное без cgo ядро падает на `_SecTrustCopyCertificateChain` (10.15):
   эту ссылку даёт **стандартная библиотека Go** (`crypto/x509/internal/macos`), а не Throne.
6. TUN требует setuid root, а для setuid-бинарников macOS **вырезает все `DYLD_*`** —
   любая инъекция shim в такой процесс молча перестаёт работать.

Подробный разбор со списками символов и селекторов — в [docs/findings.md](docs/findings.md).

## Что в каталоге

| Файл | Назначение |
|---|---|
| `patches/qtcore-version-gate.py` | вырезает проверку версии macOS в `QtCore` (патч по уникальному байтовому образцу, с проверкой) |
| `patches/go-x509-darwin-security.patch` | патч stdlib Go: `crypto/x509/internal/macos` не должен звать API 10.15 |
| `compat/throne_shim.m` | dylib-совместимость для GUI: недостающие символы 10.14/10.15 и категории AppKit |
| `compat/build-shim.sh` | сборка shim через clang |
| `build-core-darwin.sh` | кросс-сборка `ThroneCore` под darwin/amd64 без cgo (с патчем stdlib) |
| `install-app.sh` | патч готового `.app`: plist, QtCore, shim, обёртка, подпись |

## Порядок сборки

Нужны две машины или одна: сборка ядра делается на **Linux** (кросс-компиляция Go),
патч `.app` — на **самом маке** (там нужен `clang` и Command Line Tools).

### 1. Ядро (Linux, Go 1.26.x)

```bash
./legacy/build-core-darwin.sh            # → dist/ThroneCore (darwin/amd64, статический)
```

Скрипт копирует `GOROOT` в рабочий каталог, применяет `patches/go-x509-darwin-security.patch`,
генерирует protobuf-биндинги и собирает ядро с `CGO_ENABLED=0`. Результат не зависит ни от
`Network.framework`, ни от `Security.framework`-API новее 10.13.

Теги сборки отличаются от CI одним: добавлен `noparentcheck`. Ядро проверяет, что его
запустил бинарь с именем `Throne` из той же папки; наша обёртка запускает `Throne.bin`,
поэтому проверка отключена. Это осознанная потеря антитампер-защиты, а не недосмотр.

### 2. Патч приложения (на маке)

```bash
xattr -dr com.apple.quarantine ~/Applications/Throne/Throne.app
./legacy/compat/build-shim.sh
./legacy/install-app.sh ~/Applications/Throne/Throne.app dist/ThroneCore
```

`install-app.sh` идемпотентен: сохраняет бэкапы (`QtCore.bak`, `ThroneCore.orig`),
кладёт shim в `Contents/Frameworks`, подменяет исполняемый файл обёрткой и подписывает
бандл ad-hoc.

### 3. Первый запуск

```bash
open ~/Applications/Throne/Throne.app
```

TUN потребует пароль администратора: приложение само откроет `Terminal` и сделает
`chown root` + `chmod u+s` для ядра. После этого ядро работает от root, а shim ему не нужен —
именно поэтому патч stdlib обязателен, а не «одно из решений».

## Ограничения

- **Тёмной темы нет.** High Sierra её не умеет; всё, что Qt спрашивает про appearance,
  отдаётся как `Aqua`, цветовые константы 10.14 отображены на ближайшие аналоги 10.13.
- **Протокол naive недоступен.** Он требует `cronet-go`, а тот собран только с cgo.
  Всё остальное (VLESS, VMess, Trojan, Shadowsocks, Hysteria/2, TUIC, WireGuard, QUIC, uTLS) на месте.
- **Сборка ядра привязана к версии Go.** Патч stdlib — это unified diff по файлам
  `crypto/x509/internal/macos`, он проверен на Go 1.26.10 и на другой версии может не примениться.
- **Qt не пересобирается.** Собрать Qt 6.4 под `minos 10.13` на такой машине нереально,
  поэтому Qt-часть лечится бинарными патчами и shim'ом поверх официального билда.

## Что проверено, а что нет

Проверено на живой машине: приложение запускается, окно рендерится корректно, подписка
скачивается и разбирается (24 профиля), ядро стартует и подключается —
`Core Has Successfully Connected to Throne!`, падений в GUI нет.

Не проверено до конца: реальный трафик через TUN — на момент сборки этого каталога шаг
с вводом пароля администратора ещё не был пройден.
