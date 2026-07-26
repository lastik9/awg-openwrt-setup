#!/bin/sh
# uninstall-awg.sh — удаляет то, что настроил setup-awg.sh на OpenWrt:
# сетевой интерфейс AmneziaWG, его peer-секции и firewall-зону.
# Podkop НЕ трогается. Пакеты AWG удаляются отдельно, по подтверждению.
#
# Использование:
#   sh uninstall-awg.sh                 # интерфейс awg0 и зона awg
#   sh uninstall-awg.sh --iface awgX    # другое имя интерфейса
#   sh uninstall-awg.sh --zone myzone   # другое имя зоны
#   sh uninstall-awg.sh --yes           # не задавать вопросов (кроме удаления пакетов)
#
# Обычный запуск убирает ТОЛЬКО конфигурацию (интерфейс + зона).
# Удаление системных пакетов AWG предлагается отдельно в конце.

set -u

IFACE='awg0'
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

# ---------- 1. интерфейс и peer-секции ----------
if uci -q get "network.$IFACE" >/dev/null; then
  if ask "Удалить сетевой интерфейс '$IFACE' и его peer-секции?"; then
    log "Опускаю интерфейс $IFACE..."
    ifdown "$IFACE" 2>/dev/null || true

    # удаляем все peer-секции типа amneziawg_<iface>
    # (перебираем с конца, чтобы индексы не съезжали)
    stype="amneziawg_$IFACE"
    # соберём имена секций данного типа
    peers=$(uci show network 2>/dev/null | sed -n "s/^network\.\(@$stype\[[0-9]*\]\)=.*/\1/p")
    # @-нотация не всегда доступна для delete по индексу — используем именованный проход
    i=0
    while uci -q get "network.@$stype[0]" >/dev/null; do
      uci delete "network.@$stype[0]" || break
      i=$((i+1))
      [ "$i" -gt 50 ] && break   # предохранитель
    done
    [ "$i" -gt 0 ] && log "Удалено peer-секций: $i"

    uci -q delete "network.$IFACE"
    uci commit network
    log "Интерфейс $IFACE удалён."
  else
    warn "Интерфейс $IFACE оставлен."
  fi
else
  warn "Интерфейс network.$IFACE не найден — пропускаю."
fi

# ---------- 2. firewall-зона ----------
if uci -q get "firewall.$ZONE" >/dev/null; then
  if ask "Удалить firewall-зону '$ZONE'?"; then
    uci -q delete "firewall.$ZONE"
    # подчистим возможные forwarding-секции, ссылающиеся на зону
    i=0
    while [ "$i" -lt 50 ]; do
      sec=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@forwarding\[[0-9]*\]\)\.\(src\|dest\)='$ZONE'/\1/p" | head -n1)
      [ -z "$sec" ] && break
      uci -q delete "firewall.$sec" || break
      i=$((i+1))
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
