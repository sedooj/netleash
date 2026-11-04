// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package i18n

// ru maps English messages to Russian. Format verbs must match (checked by a test).
var ru = map[string]string{
	"✗ could not run the protection helper: %s":                             "✗ не удалось запустить помощник защиты: %s",
	"✗ could not list network interfaces: %v":                               "✗ не удалось получить сетевые интерфейсы: %v",
	"✗ protection changed during the test; try again":                       "✗ во время проверки изменилось состояние защиты; повторите попытку",
	"○ test incomplete: no usable physical interface or no VPN response":    "○ проверка неполная: нет доступного физического интерфейса или ответа через VPN",
	"✓ no direct test connections succeeded (not a complete privacy audit)": "✓ прямые тестовые соединения не прошли (это не полный аудит приватности)",
	"protection on":  "защита включена",
	"protection off": "защита выключена",
	"Administrator access is required to change protected applications.": "Для изменения защищаемых приложений нужны права администратора.",
	"Quit the application before enabling protection: %s":                "Перед включением защиты закройте приложение: %s",
	"✗ daemon is not running (no %s)":                                    "✗ демон не запущен (нет %s)",
	"✗ unreadable status file":                                           "✗ файл статуса не читается",
	"✗ daemon has not updated its status for %ds":                        "✗ демон не обновлял статус %d с",
	"✗ protection is NOT armed: %s":                                      "✗ защита НЕ взведена: %s",
	"● VPN connected (%s) — network allowed":                             "● VPN подключён (%s) — сеть разрешена",
	"○ VPN disconnected — network of the protected app is blocked":       "○ VPN отключён — сеть защищаемого приложения заблокирована",
	"  protection armed, daemon pid %d":                                  "  защита взведена, pid демона %d",
	"→ through the VPN (must work if the VPN is up):":                    "→ через VPN (должно работать, если VPN включён):",
	"   no answer": "   нет ответа",
	"→ forced through a physical interface (MUST be blocked):": "→ принудительно через физический интерфейс (ДОЛЖНО быть заблокировано):",
	"   ✗ LEAK through %s!":                                    "   ✗ УТЕЧКА через %s!",
	"   ✓ %s is blocked":                                       "   ✓ %s заблокирован",
	"✗ LEAKS FOUND":                                            "✗ НАЙДЕНЫ УТЕЧКИ",
	"✓ no leaks found":                                         "✓ утечек не найдено",
	"netleash: cannot run %s: %v":                              "netleash: не удалось запустить %s: %v",

	"GitHub answered %s for %s":    "GitHub ответил %s для %s",
	"protection is not active: %s": "защита не активна: %s",
	"could not reach GitHub through the VPN (is it connected?); use --direct to connect outside the VPN": "не удалось связаться с GitHub через VPN (он подключён?); используйте --direct, чтобы подключиться в обход VPN",
	"release archives are published only for darwin/arm64 (this is %s/%s)":                               "архивы релизов публикуются только для darwin/arm64 (у вас %s/%s)",
	"Netleash %s is up to date.":                  "Netleash %s — актуальная версия.",
	"Update available: %s → %s":                   "Доступно обновление: %s → %s",
	"Release notes: %s":                           "Описание релиза: %s",
	"Aborted.":                                    "Отменено.",
	"Download, verify and install it now? [y/N] ": "Скачать, проверить и установить сейчас? [y/N] ",
	"Downloading %s ...":                          "Скачиваю %s ...",
	"Checksum verified.":                          "Контрольная сумма проверена.",
	"Installer: %s":                               "Установщик: %s",
	"unexpected archive layout":                   "неожиданная структура архива",
	"installer failed":                            "установщик завершился с ошибкой",

	usageMain:   usageMainRu,
	usageUpdate: usageUpdateRu,
}

// The usage texts are long, so they live in constants shared with the commands.
const (
	usageMain = `netleash — confine an application's network access to a VPN tunnel

usage: netleash <command>

  status              is protection armed, is the VPN alive
  test                leak test: a forced connection through a physical interface MUST be blocked
  panic               emergency rollback: remove all protection (asks for sudo)
  resume              restore protection after panic (asks for sudo)
  update [flags]      check for a newer release and install it (see: netleash update --help)
  log                 follow the daemon log
  run <command...>    run a command under the same network confinement
  apps                list configured applications as JSON
  apps launch <path>  launch an enabled original .app under protection
  apps add <path>     add an application (sudo; quit it first)
  apps enable|disable|remove <path>  change protection (sudo)
  version             print the version
  daemon              run the root daemon (started by launchd; not for manual use)
`
	usageMainRu = `netleash — привязывает сеть приложения к VPN-туннелю

использование: netleash <команда>

  status              взведена ли защита, жив ли VPN
  test                проверка утечек: принудительное соединение через физический интерфейс ДОЛЖНО быть заблокировано
  panic               аварийный откат: снять всю защиту (спросит sudo)
  resume              вернуть защиту после panic (спросит sudo)
  update [флаги]      проверить новый релиз и установить его (см.: netleash update --help)
  log                 следить за журналом демона
  run <команда...>    запустить команду под той же сетевой изоляцией
  apps                список настроенных приложений в JSON
  apps launch <путь>  запустить оригинальное .app под защитой
  apps add <путь>     добавить приложение (sudo; сначала закройте его)
  apps enable|disable|remove <путь>  изменить защиту (sudo)
  version             показать версию
  daemon              запустить демон root (запускается launchd; вручную не нужен)
`
	usageUpdate = `usage: netleash update [flags]

Checks GitHub for a newer release and, after you confirm, downloads it, verifies its SHA-256 checksum and runs its
installer with sudo. By default all network traffic goes THROUGH THE VPN (it is run inside the same network
confinement as the protected app), so GitHub and your ISP do not see this Mac's real address.

  --check            only report whether an update is available
  --json             machine-readable output (used by the menu bar app)
  --yes, -y          do not ask for confirmation
  --direct           connect outside the VPN (works without VPN, but the connection is not protected)
  --download-only    download and verify, print where the installer is, do not install
  --version vX.Y.Z   take this release instead of the latest one
`
	usageUpdateRu = `использование: netleash update [флаги]

Проверяет на GitHub новый релиз и после вашего подтверждения скачивает его, сверяет SHA-256 и запускает его установщик
через sudo. По умолчанию весь сетевой трафик идёт ЧЕРЕЗ VPN (запрос выполняется внутри той же сетевой изоляции, что и
защищаемое приложение), поэтому GitHub и провайдер не видят настоящий адрес этого Mac.

  --check            только сообщить, есть ли обновление
  --json             машиночитаемый вывод (его использует приложение в строке меню)
  --yes, -y          не спрашивать подтверждение
  --direct           подключаться в обход VPN (работает без VPN, но соединение не защищено)
  --download-only    скачать и проверить, показать путь к установщику, не устанавливать
  --version vX.Y.Z   взять этот релиз вместо последнего
`
)

// Usage texts for the commands.
func UsageMain() string   { return T(usageMain) }
func UsageUpdate() string { return T(usageUpdate) }
