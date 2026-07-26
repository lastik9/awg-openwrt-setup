# awg-openwrt-setup

**Русский** · [English](README.en.md) · [中文](README.zh-CN.md)

Установочный скрипт для **AmneziaWG** на **OpenWrt 25 (apk)** для совместной работы
с [podkop](https://podkop.net/) — выборочной маршрутизации трафика.

Один прогон: ставит пакеты AmneziaWG, создаёт сетевой интерфейс и firewall-зону с
NAT и MSS clamping, поднимает туннель и проверяет handshake. **Podkop не трогается** —
интерфейс подключается к нему вручную через LuCI. Есть отдельный аптинсталлер.

## Зачем

[AmneziaWG](https://docs.amnezia.org/) — это WireGuard с обфускацией, устойчивый к
блокировкам по DPI. Ручная установка на OpenWrt — это несколько шагов: пакеты,
интерфейс через веб-интерфейс, ручной импорт `.conf`, firewall-зона. При работе с
podkop добавляется нюанс: у интерфейса нельзя включать маршрутизацию всех
`AllowedIPs`, иначе весь трафик уйдёт в туннель мимо выборочных правил podkop.

Скрипт снимает эту рутину: собирает интерфейс и peer из простого `awg.env` (или
генерирует его из готового `.conf`), сразу ставит `route_allowed_ips=0` и создаёт
корректную firewall-зону.

## Требования

- OpenWrt 25.x с пакетным менеджером **apk** (проверялось на 25.12.x).
- Уже установленный и работающий **podkop**.
- Доступ по SSH и права **root**.
- Интернет на роутере на момент запуска — качаются пакеты AmneziaWG.

## Что делает скрипт

1. Ставит пакеты AmneziaWG через официальный установщик
   ([Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)),
   неинтерактивно.
2. Читает параметры туннеля из `awg.env`.
3. Создаёт UCI-интерфейс и peer — **только если интерфейса ещё нет** (идемпотентно).
   Ставит `route_allowed_ips=0`, чтобы маршрутами управлял podkop.
4. Создаёт firewall-зону (`input`/`forward` REJECT, `output` ACCEPT, masquerade,
   MSS clamping). Пересылку `lan → awg` **не** добавляет — это делает podkop.
5. Поднимает интерфейс и проверяет наличие handshake.

Podkop скрипт **не настраивает** — после установки подключи интерфейс в
**Services → Podkop** вручную.

## Установка

Команды выполняются **на роутере** по SSH.

```sh
# скопируй файлы на роутер (например в /root) или скачай по одному:
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/awg.env.example

# вариант A: есть готовый .conf от провайдера — сгенерируй env из него
sh setup-awg.sh --from-conf /root/my.conf
# затем открой awg.env, впиши KEEPALIVE='25' и проверь значения

# вариант B: заполни env вручную
cp awg.env.example awg.env
vi awg.env

# запусти установку и настройку
sh setup-awg.sh
```

После установки: **LuCI → Services → Podkop**, тип подключения **VPN**, сетевой
интерфейс `awg0` → Save & Apply.

## Параметры запуска

| Флаг | Действие |
|------|----------|
| (без флагов) | установка пакетов + настройка из `awg.env` |
| `--from-conf FILE` | сгенерировать `awg.env` из `.conf` и выйти |
| `--no-install` | пропустить установку пакетов, только настройка |
| `--env PATH` | использовать env-файл по другому пути |
| `-h`, `--help` | справка |

## Важно про keepalive

В исходных `.conf` от Amnezia строки `PersistentKeepalive` обычно нет. Если роутер
стоит за NAT (в том числе за другим роутером), обязательно впиши `KEEPALIVE='25'` в
`awg.env` — иначе NAT-сессия будет закрываться и handshake отвалится. Интерфейс без
keepalive к тому же не начинает handshake сам, пока в туннель не пойдёт трафик.

## Удаление

```sh
wget https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/uninstall-awg.sh
sh uninstall-awg.sh
```

Скрипт удаляет интерфейс и firewall-зону, а в конце **отдельно спрашивает**, сносить
ли системные пакеты AmneziaWG. Пакеты (`kmod-amneziawg`, `amneziawg-tools`,
`luci-proto-amneziawg`) — **общие**: если на роутере есть другие AWG-туннели, их
лучше оставить. Podkop скрипт не трогает.

## Безопасность

- **Никогда** не коммить реальный `awg.env` — в нём приватный ключ. Его закрывает
  `.gitignore`.
- В репозиторий идёт только `awg.env.example` (шаблон без значений).
- Если ключи где-то засветились — перевыпусти конфиг и отзови старый на сервере.

## Благодарности

Проект — лишь установщик. Основная работа сделана в апстримах:

- [amnezia-vpn/amneziawg](https://docs.amnezia.org/) — протокол AmneziaWG;
- [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) —
  сборки пакетов AmneziaWG под OpenWrt;
- [podkop](https://podkop.net/) — выборочная маршрутизация.

Устанавливаемые компоненты принадлежат их авторам и распространяются под их
собственными лицензиями. Настоящая лицензия (MIT) покрывает только код этого скрипта.

## Отказ от ответственности

Скрипт предоставляется как есть. Перед первым запуском убедись, что у тебя есть
физический доступ к роутеру на случай отката. Проверяй сгенерированный `awg.env`
глазами перед применением.

## Лицензия

[MIT](LICENSE) © 2026 lastik9
