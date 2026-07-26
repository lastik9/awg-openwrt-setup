#!/bin/sh
# setup-awg.sh — установка пакетов AmneziaWG и настройка интерфейса + firewall-зоны
# на OpenWrt (24.10.3+ / 25.12.x). Podkop НЕ трогает.
#
# Использование:
#   sh setup-awg.sh                       # ставит пакеты + поднимает интерфейс из awg.env
#   sh setup-awg.sh --from-conf my.conf   # генерирует awg.env из .conf и выходит (проверь глазами!)
#   sh setup-awg.sh --no-install          # только настройка, без установки пакетов
#   sh setup-awg.sh --env /path/awg.env   # указать другой env-файл
#
# Интерфейс создаётся ТОЛЬКО если его ещё нет (существующий не затирается).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
ENV_FILE="$SCRIPT_DIR/awg.env"
DO_INSTALL=1
INSTALLER_URL='https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh'

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- разбор аргументов ----------
FROM_CONF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --from-conf) FROM_CONF="${2:-}"; shift 2 || die "--from-conf требует путь к .conf" ;;
    --no-install) DO_INSTALL=0; shift ;;
    --env) ENV_FILE="${2:-}"; shift 2 || die "--env требует путь" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ---------- режим генерации env из .conf ----------
if [ -n "$FROM_CONF" ]; then
  [ -r "$FROM_CONF" ] || die "Не читается файл: $FROM_CONF"
  OUT="$SCRIPT_DIR/awg.env"
  [ -e "$OUT" ] && { warn "$OUT уже есть — пишу в $OUT.new"; OUT="$OUT.new"; }

  # достаём значение по ключу из блока [Interface] или [Peer]
  get() { awk -v k="$1" '
    /^\[/{sect=$0}
    { line=$0; sub(/#.*/,"",line) }
    line ~ "^[ \t]*"k"[ \t]*=" {
      sub("^[ \t]*"k"[ \t]*=[ \t]*","",line)
      sub(/[ \t]+$/,"",line)
      print line; exit
    }' "$FROM_CONF"; }

  # I1 может быть очень длинным и содержать пробелы/угловые скобки — берём всё после '='
  geti1() { awk '/^[ \t]*I1[ \t]*=/{sub(/^[ \t]*I1[ \t]*=[ \t]*/,"");print;exit}' "$FROM_CONF"; }

  addr=$(get Address); dns=$(get DNS); mtu=$(get MTU)
  epraw=$(get Endpoint); ehost=${epraw%:*}; eport=${epraw##*:}
  {
    echo "# сгенерировано из $FROM_CONF $(date)"
    echo "IFACE='awg0'"
    echo "PRIVATE_KEY='$(get PrivateKey)'"
    echo "ADDRESSES='$addr'"
    echo "DNS='$dns'"
    echo "MTU='${mtu:-1280}'"
    for k in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4; do
      up=$(echo "$k" | tr '[:lower:]' '[:upper:]')
      echo "$up='$(get "$k")'"
    done
    echo "I1='$(geti1)'"
    echo "PEER_PUBLIC_KEY='$(get PublicKey)'"
    echo "PRESHARED_KEY='$(get PresharedKey)'"
    echo "ENDPOINT_HOST='$ehost'"
    echo "ENDPOINT_PORT='$eport'"
    echo "ALLOWED_IPS='$(get AllowedIPs)'"
    echo "KEEPALIVE='$(get PersistentKeepalive)'"
    echo "MAKE_ZONE='1'"
    echo "ZONE_NAME='awg'"
  } > "$OUT"
  log "Записан $OUT"
  warn "ВАЖНО: открой $OUT и проверь значения (особенно I1, ADDRESSES, KEEPALIVE) перед запуском."
  exit 0
fi

# ---------- загрузка env ----------
[ -r "$ENV_FILE" ] || die "Нет env-файла: $ENV_FILE (создай из шаблона или используй --from-conf)"
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${IFACE:=awg0}"
[ -n "${PRIVATE_KEY:-}" ]     || die "PRIVATE_KEY пуст"
[ -n "${PEER_PUBLIC_KEY:-}" ] || die "PEER_PUBLIC_KEY пуст"
[ -n "${ENDPOINT_HOST:-}" ]   || die "ENDPOINT_HOST пуст"
[ -n "${ENDPOINT_PORT:-}" ]   || die "ENDPOINT_PORT пуст"
[ -n "${ADDRESSES:-}" ]       || die "ADDRESSES пуст"

command -v uci >/dev/null || die "uci не найден — это точно OpenWrt?"

# ---------- установка пакетов ----------
if [ "$DO_INSTALL" = 1 ]; then
  if command -v awg >/dev/null 2>&1 && [ -f /lib/netifd/proto/amneziawg.sh ]; then
    log "Пакеты AmneziaWG уже установлены — пропускаю установку."
  else
    log "Ставлю пакеты AmneziaWG через официальный установщик..."
    command -v wget >/dev/null || die "wget не найден"
    TMP_INST="/tmp/amneziawg-install.$$.sh"
    wget -4 -qO "$TMP_INST" "$INSTALLER_URL" || { rm -f "$TMP_INST"; die "Не удалось скачать установщик"; }
    # neutral-режим: отвечаем n на все интерактивные вопросы (язык, настройка интерфейса)
    printf 'n\nn\nn\n' | sh "$TMP_INST" \
      || warn "Установщик вернул ошибку — проверь вывод выше. Если пакеты всё же встали, продолжаю."
    rm -f "$TMP_INST"
  fi
else
  log "--no-install: установку пакетов пропускаю."
fi

command -v awg >/dev/null || die "awg не найден после установки — настройку прервал."

# ---------- проверка: интерфейс уже есть? ----------
if uci -q get "network.$IFACE" >/dev/null; then
  warn "Секция network.$IFACE уже существует — НЕ трогаю её (режим 'создать только если нет')."
  warn "Если нужно пересоздать: uci delete network.$IFACE и удали её peer-секции, потом запусти снова."
  SKIP_IFACE=1
else
  SKIP_IFACE=0
fi

# ---------- создание интерфейса ----------
if [ "$SKIP_IFACE" = 0 ]; then
  log "Создаю интерфейс $IFACE..."
  uci set "network.$IFACE=interface"
  uci set "network.$IFACE.proto=amneziawg"
  uci set "network.$IFACE.private_key=$PRIVATE_KEY"
  [ -n "${MTU:-}" ] && uci set "network.$IFACE.mtu=$MTU"

  # адреса (может быть несколько через запятую)
  uci -q delete "network.$IFACE.addresses"
  OLDIFS=$IFS; IFS=','
  for a in $ADDRESSES; do
    a=$(echo "$a" | tr -d ' '); [ -n "$a" ] && uci add_list "network.$IFACE.addresses=$a"
  done
  IFS=$OLDIFS

  # DNS (необязательно)
  if [ -n "${DNS:-}" ]; then
    uci -q delete "network.$IFACE.dns"
    OLDIFS=$IFS; IFS=','
    for d in $DNS; do
      d=$(echo "$d" | tr -d ' '); [ -n "$d" ] && uci add_list "network.$IFACE.dns=$d"
    done
    IFS=$OLDIFS
  fi

  # obfuscation-параметры — задаём только непустые
  for pair in "awg_jc:$JC" "awg_jmin:$JMIN" "awg_jmax:$JMAX" \
              "awg_s1:$S1" "awg_s2:$S2" "awg_s3:$S3" "awg_s4:$S4" \
              "awg_h1:$H1" "awg_h2:$H2" "awg_h3:$H3" "awg_h4:$H4" "awg_i1:$I1"; do
    key=${pair%%:*}; val=${pair#*:}
    [ -n "$val" ] && uci set "network.$IFACE.$key=$val"
  done

  # ---- peer ----
  log "Создаю peer..."
  peer=$(uci add network amneziawg_$IFACE)
  uci set "network.$peer.public_key=$PEER_PUBLIC_KEY"
  [ -n "${PRESHARED_KEY:-}" ] && uci set "network.$peer.preshared_key=$PRESHARED_KEY"
  uci set "network.$peer.endpoint_host=$ENDPOINT_HOST"
  uci set "network.$peer.endpoint_port=$ENDPOINT_PORT"
  [ -n "${KEEPALIVE:-}" ] && uci set "network.$peer.persistent_keepalive=$KEEPALIVE"
  uci set "network.$peer.route_allowed_ips=0"   # ВАЖНО для podkop: маршруты не создаём
  OLDIFS=$IFS; IFS=','
  for ip in $ALLOWED_IPS; do
    ip=$(echo "$ip" | tr -d ' '); [ -n "$ip" ] && uci add_list "network.$peer.allowed_ips=$ip"
  done
  IFS=$OLDIFS

  uci commit network
  log "network настроен."
fi

# ---------- firewall зона ----------
if [ "${MAKE_ZONE:-0}" = 1 ]; then
  ZONE_NAME="${ZONE_NAME:-awg}"
  if uci -q get "firewall.$ZONE_NAME" >/dev/null; then
    warn "Зона firewall.$ZONE_NAME уже есть — не трогаю."
  else
    log "Создаю firewall-зону $ZONE_NAME (input/forward REJECT, output ACCEPT, masq+mss)..."
    uci set "firewall.$ZONE_NAME=zone"
    uci set "firewall.$ZONE_NAME.name=$ZONE_NAME"
    uci set "firewall.$ZONE_NAME.input=REJECT"
    uci set "firewall.$ZONE_NAME.output=ACCEPT"
    uci set "firewall.$ZONE_NAME.forward=REJECT"
    uci set "firewall.$ZONE_NAME.masq=1"
    uci set "firewall.$ZONE_NAME.mtu_fix=1"
    uci add_list "firewall.$ZONE_NAME.network=$IFACE"
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "firewall-зона создана. Пересылку lan->$ZONE_NAME НЕ добавляю (podkop сам)."
  fi
fi

# ---------- поднять интерфейс ----------
log "Поднимаю интерфейс $IFACE..."
ifup "$IFACE" 2>/dev/null
sleep 6

# ---------- проверка ----------
echo
log "Статус:"
awg show "$IFACE" 2>/dev/null | grep -iE 'interface|endpoint|handshake|transfer|keepalive' || \
  warn "awg show ничего не вернул — интерфейс мог не подняться."

if awg show "$IFACE" 2>/dev/null | grep -qi 'latest handshake'; then
  log "УСПЕХ: handshake есть, туннель работает."
else
  warn "Handshake пока нет. Проверь: date, ip route get $ENDPOINT_HOST, logread | grep -i amnezia"
  warn "Если keepalive=25, handshake обычно появляется в течение ~25с — подожди и запусти: awg show $IFACE"
fi

echo
log "Готово. Дальше: Services -> Podkop -> тип VPN, интерфейс $IFACE -> Save & Apply."
