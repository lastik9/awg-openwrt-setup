#!/bin/sh
# setup-awg.sh — установка пакетов AmneziaWG и настройка интерфейса + firewall-зоны
# на OpenWrt (24.10.3+ / 25.12.x). Podkop НЕ трогает.
#
# Использование:
#   sh setup-awg.sh                       # интерактивный мастер (если нет awg.env)
#   sh setup-awg.sh -i                    # интерактивный мастер (явно)
#   sh setup-awg.sh --from-conf my.conf   # генерирует awg.env из .conf и выходит (проверь глазами!)
#   sh setup-awg.sh --no-install          # только настройка, без установки пакетов
#   sh setup-awg.sh --env /path/awg.env   # указать другой env-файл
#
# Интерактивный мастер спросит имя интерфейса (напр. awg_nl), откроет редактор для
# вставки .conf и создаст всё сам. Несколько серверов = несколько интерфейсов с
# разными именами в ОДНОЙ общей firewall-зоне.
#
# Интерфейс создаётся ТОЛЬКО если его ещё нет (существующий не затирается).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
ENV_FILE="$SCRIPT_DIR/awg.env"
DO_INSTALL=1
AUTO_REBOOT=0
WIZARD=0
SHARED_ZONE='awg'   # общая зона для всех awg-интерфейсов
INSTALLER_URL='https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh'

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '%s' "$1" >&2; read -r REPLY; }

# ---------- разбор аргументов ----------
FROM_CONF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --from-conf) FROM_CONF="${2:-}"; shift 2 || die "--from-conf требует путь к .conf" ;;
    -i|--wizard) WIZARD=1; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --reboot) AUTO_REBOOT=1; shift ;;
    --env) ENV_FILE="${2:-}"; shift 2 || die "--env требует путь" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ---------- парсер .conf -> env (общий для --from-conf и мастера) ----------
# get KEY FILE — значение по ключу из .conf
conf_get() { awk -v k="$1" '
    { line=$0; sub(/#.*/,"",line) }
    line ~ "^[ \t]*"k"[ \t]*=" {
      sub("^[ \t]*"k"[ \t]*=[ \t]*","",line); sub(/[ \t]+$/,"",line)
      print line; exit
    }' "$2"; }
conf_geti1() { awk '/^[ \t]*I1[ \t]*=/{sub(/^[ \t]*I1[ \t]*=[ \t]*/,"");print;exit}' "$1"; }

# write_env CONF IFACE ZONE OUT — собрать env из CONF
write_env() {
  _conf="$1"; _iface="$2"; _zone="$3"; _out="$4"
  _ep=$(conf_get Endpoint "$_conf"); _eh=${_ep%:*}; _epp=${_ep##*:}
  {
    echo "# сгенерировано из $_conf $(date)"
    echo "IFACE='$_iface'"
    echo "PRIVATE_KEY='$(conf_get PrivateKey "$_conf")'"
    echo "ADDRESSES='$(conf_get Address "$_conf")'"
    echo "DNS='$(conf_get DNS "$_conf")'"
    echo "MTU='$(conf_get MTU "$_conf")'"
    for pair in Jc:JC Jmin:JMIN Jmax:JMAX S1:S1 S2:S2 S3:S3 S4:S4 H1:H1 H2:H2 H3:H3 H4:H4; do
      ck=${pair%:*}; ek=${pair#*:}; echo "$ek='$(conf_get "$ck" "$_conf")'"
    done
    echo "I1='$(conf_geti1 "$_conf")'"
    echo "PEER_PUBLIC_KEY='$(conf_get PublicKey "$_conf")'"
    echo "PRESHARED_KEY='$(conf_get PresharedKey "$_conf")'"
    echo "ENDPOINT_HOST='$_eh'"
    echo "ENDPOINT_PORT='$_epp'"
    echo "ALLOWED_IPS='$(conf_get AllowedIPs "$_conf")'"
    echo "KEEPALIVE='$(conf_get PersistentKeepalive "$_conf")'"
    echo "MAKE_ZONE='1'"
    echo "ZONE_NAME='$_zone'"
  } > "$_out"
}

# normalize_iface NAME — привести имя интерфейса к валидному UCI-виду
normalize_iface() {
  _n="$1"
  _clean=$(printf '%s' "$_n" | tr '-' '_' | tr -cd 'A-Za-z0-9_')
  printf '%s' "$_clean" | cut -c1-15
}

# ---------- режим генерации env из .conf ----------
if [ -n "$FROM_CONF" ]; then
  [ -r "$FROM_CONF" ] || die "Не читается файл: $FROM_CONF"
  OUT="$ENV_FILE"
  [ -e "$OUT" ] && { warn "$OUT уже есть — пишу в $OUT.new"; OUT="$OUT.new"; }
  write_env "$FROM_CONF" "awg0" "$SHARED_ZONE" "$OUT"
  log "Записан $OUT"
  warn "ВАЖНО: открой $OUT и проверь значения (особенно I1 и ADDRESSES) перед запуском."
  if ! grep -qE "^KEEPALIVE='[0-9]+'" "$OUT"; then
    warn "KEEPALIVE пуст (в .conf нет PersistentKeepalive). За NAT впиши KEEPALIVE='25':"
    warn "  sed -i \"s/^KEEPALIVE=.*/KEEPALIVE='25'/\" $OUT"
  fi
  exit 0
fi

# ---------- интерактивный мастер ----------
# запускается по -i ЛИБО когда нет awg.env и не заданы флаги настройки
if [ "$WIZARD" = 1 ] || { [ ! -r "$ENV_FILE" ] && [ -t 0 ]; }; then
  command -v uci >/dev/null || die "uci не найден — это точно OpenWrt? Мастер запускается на роутере."
  echo "=== Мастер настройки AmneziaWG ==="

  # 1) имя интерфейса
  while :; do
    ask "Имя интерфейса (напр. awg_nl, awg_de): "
    raw="$REPLY"
    [ -z "$raw" ] && { warn "Пусто, попробуй ещё раз."; continue; }
    iface=$(normalize_iface "$raw")
    [ -z "$iface" ] && { warn "Недопустимое имя, попробуй ещё раз."; continue; }
    if [ "$iface" != "$raw" ]; then
      warn "Имя приведено к '$iface' (UCI допускает только буквы/цифры/подчёркивание, максимум 15)."
    fi
    if uci -q get "network.$iface" >/dev/null; then
      warn "Интерфейс '$iface' уже существует. Выбери другое имя."
      continue
    fi
    break
  done

  # 2) редактор для вставки .conf
  tmpconf="/tmp/awg-wizard.$$.conf"
  {
    echo "# Paste your full .conf below (from [Interface] to the end of [Peer]),"
    echo "# then save and quit. Lines starting with # are ignored."
  } > "$tmpconf"
  ed="${EDITOR:-vi}"
  command -v "$ed" >/dev/null 2>&1 || ed=vi
  log "Открываю $ed — вставь конфиг, затем сохрани и выйди (в vi: Esc, :wq)."
  sleep 1
  "$ed" "$tmpconf"

  # проверим, что что-то ввели
  grep -q '^[ \t]*PrivateKey[ \t]*=' "$tmpconf" || { rm -f "$tmpconf"; die "В конфиге нет PrivateKey — отмена."; }
  grep -q '^[ \t]*PublicKey[ \t]*='  "$tmpconf" || { rm -f "$tmpconf"; die "В конфиге нет PublicKey — отмена."; }

  # 3) собираем env под именем интерфейса, зона общая
  ENV_FILE="/tmp/awg-$iface.env"
  write_env "$tmpconf" "$iface" "$SHARED_ZONE" "$ENV_FILE"
  rm -f "$tmpconf"

  # 4) keepalive
  if ! grep -qE "^KEEPALIVE='[0-9]+'" "$ENV_FILE"; then
    ask "Persistent keepalive в секундах (Enter = 25, за NAT рекомендуется): "
    ka="${REPLY:-25}"
    case "$ka" in ''|*[!0-9]*) ka=25 ;; esac
    sed -i "s/^KEEPALIVE=.*/KEEPALIVE='$ka'/" "$ENV_FILE"
  fi

  log "env собран: $ENV_FILE (интерфейс '$iface', зона '$SHARED_ZONE'). Продолжаю установку..."
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
  # ВАЖНО для podkop: не создаём default route, иначе весь трафик уйдёт в туннель
  uci set "network.$IFACE.defaultroute=0"
  # снимаем делегирование IPv6-префиксов — для VPN-интерфейса не нужно
  uci set "network.$IFACE.delegate=0"

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

  # obfuscation-параметры — задаём только непустые.
  # ${VAR:-} чтобы set -u не ронял скрипт на отсутствующей переменной.
  for pair in "awg_jc:${JC:-}" "awg_jmin:${JMIN:-}" "awg_jmax:${JMAX:-}" \
              "awg_s1:${S1:-}" "awg_s2:${S2:-}" "awg_s3:${S3:-}" "awg_s4:${S4:-}" \
              "awg_h1:${H1:-}" "awg_h2:${H2:-}" "awg_h3:${H3:-}" "awg_h4:${H4:-}" \
              "awg_i1:${I1:-}"; do
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

# ---------- firewall зона (общая для всех awg-интерфейсов) ----------
if [ "${MAKE_ZONE:-0}" = 1 ]; then
  ZONE_NAME="${ZONE_NAME:-awg}"
  # ищем секцию зоны по имени: сначала именованная, потом анонимная
  zsec=""
  if uci -q get "firewall.$ZONE_NAME" >/dev/null; then
    zsec="$ZONE_NAME"
  else
    for s in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='$ZONE_NAME'/\1/p"); do
      zsec="$s"; break
    done
  fi

  if [ -n "$zsec" ]; then
    # зона есть — добавляем интерфейс в её network, если его там ещё нет
    if uci -q get "firewall.$zsec.network" | grep -qw "$IFACE"; then
      log "Интерфейс $IFACE уже в зоне $ZONE_NAME."
    else
      uci add_list "firewall.$zsec.network=$IFACE"
      uci commit firewall
      /etc/init.d/firewall reload >/dev/null 2>&1
      log "Интерфейс $IFACE добавлен в существующую зону $ZONE_NAME."
    fi
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
# netifd регистрирует proto-хендлеры только при старте своего процесса.
# При свежей установке пакетов /lib/netifd/proto/amneziawg.sh появляется уже
# ПОСЛЕ старта netifd, поэтому proto ещё не зарегистрирован — и ни reload_config,
# ни "/etc/init.d/network restart" его не подхватывают. Помогает только reboot,
# при котором netifd сканирует /lib/netifd/proto заново. На уже "прогретом"
# роутере (proto зарегистрирован) reboot не нужен — интерфейс встаёт сразу.
reload_config 2>/dev/null
sleep 1
ifup "$IFACE" 2>/dev/null
sleep 3

# Проверяем, что РЕАЛЬНО произошло: если netifd не знает proto amneziawg,
# он подставляет заглушку "none". Это честнее, чем гадать "ставились ли пакеты".
proto_now=$(ubus call network.interface."$IFACE" status 2>/dev/null \
            | sed -n 's/.*"proto": *"\([^"]*\)".*/\1/p')

if [ "$proto_now" != "amneziawg" ]; then
  echo
  warn "netifd пока не знает proto 'amneziawg' (свежая установка пакетов)."
  warn "Конфигурация записана корректно, но для её применения нужен ОДИН reboot."
  if [ "${AUTO_REBOOT:-0}" = 1 ]; then
    warn "AUTO_REBOOT=1 — перезагружаю роутер через 3 секунды..."
    sleep 3
    reboot
    exit 0
  fi
  warn "Выполни вручную:  reboot"
  warn "После загрузки интерфейс $IFACE поднимется сам. Проверка:  awg show $IFACE"
  echo
  log "Дальше (после reboot): Services -> Podkop -> тип VPN, интерфейс $IFACE -> Save & Apply."
  exit 0
fi

log "netifd знает proto — интерфейс поднят без перезагрузки."

# ---------- проверка ----------
echo
log "Статус:"
awg show "$IFACE" 2>/dev/null | grep -iE 'interface|endpoint|handshake|transfer|keepalive' || \
  warn "awg show ничего не вернул — интерфейс мог не подняться."

if awg show "$IFACE" 2>/dev/null | grep -qi 'latest handshake'; then
  log "УСПЕХ: handshake есть, туннель работает."
elif [ -n "${KEEPALIVE:-}" ] && [ "${KEEPALIVE:-0}" != 0 ]; then
  warn "Handshake пока нет — при keepalive=$KEEPALIVE появится в течение ~${KEEPALIVE}с."
  warn "Подожди и повтори:  awg show $IFACE"
else
  # keepalive=0 и маршрутов в туннель нет (route_allowed_ips=0 для podkop):
  # это НОРМА. Handshake появится, когда podkop направит трафик в туннель.
  log "Интерфейс поднят. Handshake появится, когда в туннель пойдёт трафик"
  log "(через podkop, либо задай PersistentKeepalive>0 в конфиге)."
fi

echo
log "Готово. Дальше: Services -> Podkop -> тип VPN, интерфейс $IFACE -> Save & Apply."
