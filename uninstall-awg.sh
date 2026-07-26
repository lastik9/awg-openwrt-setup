#!/bin/sh
# uninstall-awg.sh — удаляет то, что настроил setup-awg.sh на OpenWrt:
# сетевые интерфейсы AmneziaWG, их peer-секции и firewall-зону.
# Podkop НЕ трогается. Пакеты AWG удаляются отдельно, по подтверждению.
#
# Использование:
#   sh uninstall-awg.sh                 # найти ВСЕ интерфейсы proto=amneziawg + зона awg
#   sh uninstall-awg.sh --iface awgX    # удалить только один интерфейс по имени
#   sh uninstall-awg.sh --zone myzone   # другое имя зоны
#   sh uninstall-awg.sh --yes           # не задавать вопросов (кроме удаления пакетов)
#
# По умолчанию удаляются ВСЕ amneziawg-интерфейсы (мастер создаёт произвольные
# имена в общей зоне). Указав --iface, удалишь только его.
# Удаление системных пакетов AWG предлагается отдельно в конце.

set -u

IFACE=''          # пусто = автообнаружение всех proto=amneziawg
ZONE='awg'
ASSUME_YES=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- аргументы ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --iface) IFACE="${2:-}"; shift 2 || die "--iface требует имя" ;;
    --zone)  ZONE="${2:-}";  shift 2 || die "--zone требует имя" ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

command -v uci >/dev/null || die "uci не найден — это точно OpenWrt?"

ask() {
  # ask "вопрос" -> 0 если да
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s [y/N]: ' "$1"
  read -r a 2>/dev/null || return 1
  case "$a" in y|Y|yes|YES|да) return 0 ;; *) return 1 ;; esac
}

# remove_iface NAME — опустить интерфейс, снести его peer-секции и саму секцию
remove_iface() {
  _if="$1"
  log "Опускаю интерфейс $_if..."
  ifdown "$_if" 2>/dev/null || true

  # удаляем все peer-секции типа amneziawg_<iface> (с конца, чтобы индексы не съезжали)
  _stype="amneziawg_$_if"
  _i=0
  while uci -q get "network.@$_stype[0]" >/dev/null; do
    uci delete "network.@$_stype[0]" || break
    _i=$((_i+1))
    [ "$_i" -gt 50 ] && break   # предохранитель
  done
  [ "$_i" -gt 0 ] && log "  peer-секций удалено: $_i"

  uci -q delete "network.$_if"
  log "Интерфейс $_if удалён."
}

# ---------- 1. интерфейс(ы) ----------
if [ -n "$IFACE" ]; then
  # явно указан один интерфейс
  if uci -q get "network.$IFACE" >/dev/null; then
    if ask "Удалить сетевой интерфейс '$IFACE' и его peer-секции?"; then
      remove_iface "$IFACE"
      uci commit network
    else
      warn "Интерфейс $IFACE оставлен."
    fi
  else
    warn "Интерфейс network.$IFACE не найден — пропускаю."
  fi
else
  # автообнаружение: все секции interface с proto=amneziawg
  ifaces=$(uci show network 2>/dev/null \
           | sed -n "s/^network\.\([^.]*\)\.proto='amneziawg'\$/\1/p")
  if [ -z "$ifaces" ]; then
    warn "Интерфейсы proto=amneziawg не найдены — пропускаю."
  else
    n=$(printf '%s\n' "$ifaces" | grep -c .)
    warn "Найдено amneziawg-интерфейсов: $n"
    printf '%s\n' "$ifaces" | sed 's/^/    - /'
    if ask "Удалить ВСЕ перечисленные интерфейсы и их peer-секции?"; then
      for _if in $ifaces; do
        remove_iface "$_if"
      done
      uci commit network
    else
      warn "Интерфейсы оставлены."
    fi
  fi
fi

# ---------- 2. firewall-зона ----------
if uci -q get "firewall.$ZONE" >/dev/null 2>&1 || \
   uci show firewall 2>/dev/null | grep -q "\.name='$ZONE'\$"; then
  if ask "Удалить firewall-зону '$ZONE'?"; then
    # зона может быть именованной секцией или анонимной @zone[N] с name='awg'
    uci -q delete "firewall.$ZONE" 2>/dev/null
    while :; do
      z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='$ZONE'\$/\1/p" | head -n1)
      [ -z "$z" ] && break
      uci -q delete "firewall.$z" || break
    done
    # подчистим forwarding-секции, ссылающиеся на зону
    while :; do
      sec=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@forwarding\[[0-9]*\]\)\.\(src\|dest\)='$ZONE'\$/\1/p" | head -n1)
      [ -z "$sec" ] && break
      uci -q delete "firewall.$sec" || break
    done
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    log "Зона $ZONE удалена."
  else
    warn "Зона $ZONE оставлена."
  fi
else
  warn "Зона firewall.$ZONE не найдена — пропускаю."
fi

# ---------- 3. пакеты AWG (отдельно, осторожно) ----------
echo
warn "Пакеты AmneziaWG (kmod-amneziawg, amneziawg-tools, luci-proto-amneziawg)"
warn "являются ОБЩИМИ: их могут использовать другие AWG-туннели на роутере."
if ask "Удалить пакеты AmneziaWG из системы?"; then
  if command -v apk >/dev/null 2>&1; then
    apk del luci-proto-amneziawg amneziawg-tools kmod-amneziawg 2>/dev/null \
      && log "Пакеты удалены." \
      || warn "Не все пакеты удалились — возможно, их уже нет или держатся зависимостями."
  elif command -v opkg >/dev/null 2>&1; then
    opkg remove luci-proto-amneziawg amneziawg-tools kmod-amneziawg 2>/dev/null \
      && log "Пакеты удалены." \
      || warn "Не все пакеты удалились."
  else
    warn "Ни apk, ни opkg не найдены — пропускаю удаление пакетов."
  fi
else
  log "Пакеты оставлены (рекомендуется, если есть другие AWG-туннели)."
fi

echo
log "Готово. Podkop не трогался — при необходимости убери интерфейс из его настроек вручную."
