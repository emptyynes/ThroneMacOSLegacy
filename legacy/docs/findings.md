# Разбор: почему Throne 1.4.2 не запускался на macOS 10.13.6

Заметки по факту работ. Всё ниже проверено на живой машине, а не выведено из документации.

## Инвентарь бинарника

```
Throne.app/Contents/MacOS/Throne        LC_BUILD_VERSION platform=macos sdk=15.5 minos=10.15
                                        Info.plist LSMinimumSystemVersion = 10.15
Contents/Frameworks/                    QtCore QtGui QtWidgets QtNetwork QtSvg QtDBus, Qt 6.4.3
Contents/MacOS/ThroneCore               Go + cgo, sdk=26.5
```

Первое, что мешает увидеть остальное: `LSMinimumSystemVersion`. Пока он 10.15,
LaunchServices просто отказывается стартовать, и никакой другой ошибки не видно.

## Слой 1: dyld

```
dyld: Symbol not found: _NSAppearanceNameDarkAqua
  Referenced from: .../QtCore (which was built for Mac OS X 10.14)
  Expected in: /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
```

`QtCore` ссылается на константу тёмной темы, которой в 10.13 нет. Важная деталь —
`Expected in: AppKit`: это two-level namespace, символ привязан к конкретной библиотеке.
Поэтому `DYLD_INSERT_LIBRARIES` сам по себе не помогает: вставленная библиотека не может
удовлетворить такую привязку. Нужен `DYLD_FORCE_FLAT_NAMESPACE=1` — тогда поиск идёт по
порядку загрузки, и наш shim (загруженный раньше AppKit) выигрывает.

## Как искать недостающие символы правильно

`nm` по системным фреймворкам 10.13 бесполезен: экспорты лежат в dyld shared cache, а не
в символьной таблице на диске. Дифф против такого «набора экспортов» даёт сотни ложных
срабатываний (`_strchr`, `_CGMainDisplayID`, весь NSArray). Точно отвечает только сам
рантайм: `dlsym(RTLD_DEFAULT, name)` для функций и констант и `objc_getClass`/`objc_getMetaClass`
для ObjC-классов (`dlsym` классы не находит — иначе «пропадает» даже `NSArray`).

Итог по приложению: **39 символов**, из них GUI касаются **пять**, остальные 34 — ядро.

| Символ | Кто ссылается | Что сделано |
|---|---|---|
| `_NSAppearanceNameDarkAqua` | QtCore | константа в shim |
| `_responsibility_spawnattrs_setdisclaim` | QtCore | no-op в shim |
| `____chkstk_darwin` | Throne | stack-probe на ассемблере в shim |
| `_objc_alloc_init`, `_objc_opt_respondsToSelector` | Throne | реализации через objc runtime |
| `_nw_*` (10 шт.), `_sec_protocol_*` (9 шт.), `UTType`, `NSWorkspaceOpenConfiguration`, `SecTrustCopyCertificateChain` | ThroneCore | ушли вместе с cgo при пересборке ядра |

Про `__chkstk_darwin`: в C-имени два подчёркивания, в Mach-O — три, а ссылка в бинарнике
требует четыре. `__asm__("____chkstk_darwin")` задаёт ассемблерное имя буквально, без
автоподчёркивания, — только так символ совпал.

## Слой 2: проверка версии внутри Qt

Символы разрешились, dyld доволен, и Qt сам пишет:

```
Sorry, "Throne" cannot be run on this version of macOS. Qt requires macOS 10.14.0 or later,
you have macOS 10.13.6.
```

Это код, а не plist: `QVersionNumber::compare` и `js` в блок, который печатает сообщение
и вызывает `exit(1)`. В `QtCore` нашлось ровно одно место:

```
0x1e4dd7  callq   QVersionNumber::compare
0x1e4ddc  testl   %eax, %eax
0x1e4dde  js      0x1e4e59        ; → fprintf + exit(1)
```

Патч — два байта `78 79` → `90 90`.

Грабли: `otool -tv` показывает адрес `0x1e4dde`, а в файле по этому смещению лежит
совсем другая функция — файловый офсет отличался на `0x4000`. Патчить по вычисленному
офсету нельзя. Правильно — искать уникальный байтовый образец `85 c0 78 79`
(вхождение ровно одно) и патчить по нему, иначе можно тихо испортить чужой код.

## Слой 3: селекторы AppKit 10.14

Дальше падения идут по одному селектору за запуск:

1. `+[NSColor unemphasizedSelectedContentBackgroundColor]` — в `QCocoaTheme`, при создании палитры.
2. `-[NSCompositeAppearance bestMatchFromAppearancesWithNames:]` — после того, как
   `-effectiveAppearance` вернул объект 10.13, у которого этого метода нет.

Закрыто категориями в shim: набор семантических цветов 10.14 отображён на ближайшие
аналоги 10.13, `-effectiveAppearance` отдаёт `[NSAppearance currentAppearance]`,
`-bestMatchFromAppearancesWithNames:` всегда выбирает `Aqua` (тёмной темы в 10.13 нет).

Полезная проверка на будущее: вытащить из бинарников все имена селекторов
(`otool -v -s __TEXT __objc_methname`, на 10.13 печатает текстом, а не hex) и прогнать
через рантайм — какие не реализует ни один класс. Из 1284 селекторов «ничьими» оказались
307, но почти все — собственные делегаты Qt, которых в пробнике не было; реальных дыр
ровно те, что перечислены выше.

## Слой 4: ядро

```
dyld: Library not loaded: /System/Library/Frameworks/Network.framework/Versions/A/Network
  Referenced from: .../ThroneCore
```

CI собирает darwin-ядро с `CGO_ENABLED=1` и `CGO_LDFLAGS="-weak_framework UniformTypeIdentifiers"`.
`Network.framework` появился в 10.14, `nw_*` и `sec_protocol_*` — оттуда же.

Решение: собрать без cgo (`CGO_ENABLED=0`). Тогда исчезают все фреймворковые зависимости
сразу — и Network, и SecureTransport. Цена: тег `with_naive_outbound` приходится убрать
(он тянет `cronet-go`, а тот существует только как cgo-библиотека), протокол naive недоступен.

Ещё один тег: `noparentcheck`. Ядро проверяет, что запустившим процессом был бинарь
`Throne` из той же папки; наша обёртка запускает `Throne.bin`, поэтому проверка отключается.

## Слой 5: стандартная библиотека Go

После сборки без cgo остался один символ:

```
dyld: Symbol not found: _SecTrustCopyCertificateChain
```

Он не из Throne и не из sing-box — его тянет **stdlib**: `crypto/x509/internal/macos`
делает `//go:cgo_import_dynamic ... SecTrustCopyCertificateChain "/System/Library/Frameworks/Security.framework/..."`,
а это API 10.15. Ссылка попадает в любой Go-бинарник под darwin.

Лечится на своей стороне, в GOROOT: динамический импорт 10.15-функции заменён реализацией
через `SecTrustGetCertificateCount` + `SecTrustGetCertificateAtIndex` + `CFArrayCreateMutable`/
`CFArrayAppendValue` — те же данные, только старыми вызовами. См.
`patches/go-x509-darwin-security.patch`; применяется на копию GOROOT, потому что стоковый
GOROOT часто read-only (Nix) и патчить чужую установку не стоит.

## Слой 6: setuid вырезает DYLD_*

TUN требует, чтобы ядро было `setuid root` — приложение само делает `chown root` + `chmod u+s`
через Terminal. Сразу после этого ядро падает снова, с тем же
`_SecTrustCopyCertificateChain`, только теперь `Expected in: Security.framework` вместо
`flat namespace`: macOS для setuid-бинарников вычищает все `DYLD_*` переменные.

Вывод, который стоил одного круга: инъекция — это всегда костыль для GUI-процесса. Всё, что
должно работать под root, обязано быть починено в сборке, а не в окружении.

## Итоговая схема

```
Throne.app/Contents/MacOS/Throne        обёртка: DYLD_INSERT_LIBRARIES + DYLD_FORCE_FLAT_NAMESPACE
Throne.app/Contents/MacOS/Throne.bin    настоящий GUI, пропатченный QtCore рядом
Throne.app/Contents/MacOS/ThroneCore    пересобранный Go-бинарь, cgo off, setuid root
Throne.app/Contents/Frameworks/libthronecompat.dylib
                                        пять символов + категории AppKit + SecTrust
```
