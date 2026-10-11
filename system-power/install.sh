#!/bin/bash
# Установка system-power.
#
#   sudo ./install.sh                поставить всё (файлы + автозапуск демона)
#   sudo ./install.sh --no-daemon    без демона (только CLI)
#   sudo ./install.sh --with-sudo    разрешить пользователю вызывать CLI без пароля
#                                    (нужно для кнопки в панели; см. README)
#   sudo ./install.sh --uninstall    удалить
#
# Запуск из репозитория — без установки:
#   sudo ./bin/system-power status

set -uo pipefail

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PREFIX_BIN="/usr/local/bin"
PREFIX_SBIN="/usr/local/sbin"
LIB="/usr/local/lib/system-power"
ETC="/etc/system-power"
UNIT="/etc/systemd/system/system-power.service"
SUDOERS="/etc/sudoers.d/system-power"
USER_TARGET="${SUDO_USER:-$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4=="seat0"{print $3; exit}')}"

WITH_SUDO=0; WITH_DAEMON=1

for a in "$@"; do
    case "$a" in
        --no-daemon) WITH_DAEMON=0 ;;
        --with-sudo) WITH_SUDO=1 ;;
        --uninstall) UNINSTALL=1 ;;
        *) echo "неизвестный флаг: $a" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "Запускать через sudo." >&2; exit 1; }

if [ -n "${UNINSTALL:-}" ]; then
    echo "==> Удаляю"
    systemctl disable --now system-power.service 2>/dev/null
    rm -f "$UNIT" "$PREFIX_BIN/system-power" "$PREFIX_SBIN/system-powerd" "$SUDOERS"
    rm -rf "$LIB"
    systemctl daemon-reload 2>/dev/null
    echo "Удалено. Настройки в $ETC и журнал оставил — удали вручную, если не нужны."
    exit 0
fi

echo "==> Файлы"
mkdir -p "$LIB/lib" "$ETC" /var/lib/system-power
install -m 755 "$SRC/bin/system-power"      "$PREFIX_BIN/system-power"
install -m 755 "$SRC/daemon/system-powerd"  "$PREFIX_SBIN/system-powerd"
install -m 644 "$SRC/lib/common.sh"         "$LIB/lib/common.sh"
install -m 644 "$SRC/lib/apply.sh"          "$LIB/lib/apply.sh"
install -m 644 "$SRC/lib/interface.sh"      "$LIB/lib/interface.sh"
install -m 644 "$SRC/lib/profiles.conf"     "$LIB/lib/profiles.conf"
install -m 644 "$SRC/README.md"             "$LIB/README.md"

echo "==> Настройки"
[ -f "$ETC/mode" ] || echo auto > "$ETC/mode"
if [ ! -f "$ETC/config" ]; then
    cat > "$ETC/config" <<'CFG'
# Переопределения путей для system-power.
# Эти значения подставляются автоматически из домашней папки активной
# графической сессии; раскомментируй и поправь, если что-то лежит иначе.

#SP_WALLPAPER_SETTINGS="/home/пользователь/.cache/wallpaper-picker/settings.json"
#SP_WALLPAPER_PID="/home/пользователь/.cache/wallpaper-picker/wallpaper.pid"
#SP_WALLPAPER_CTL="/home/пользователь/wallpaper-engine-gnome/start-wallpaper.sh"
CFG
fi

if [ "$WITH_SUDO" = 1 ] && [ -n "$USER_TARGET" ]; then
    echo "==> Разрешение без пароля для $USER_TARGET"
    printf '%s ALL=(root) NOPASSWD: %s/system-power, %s/system-power\n' \
        "$USER_TARGET" "$PREFIX_BIN" "$LIB" > "$SUDOERS"
    chmod 440 "$SUDOERS"
    visudo -c -f "$SUDOERS" >/dev/null 2>&1 || { echo "!! sudoers невалиден, удаляю"; rm -f "$SUDOERS"; }
fi

if [ "$WITH_DAEMON" = 1 ]; then
    echo "==> Служба"
    install -m 644 "$SRC/systemd/system-power.service" "$UNIT"
    systemctl daemon-reload
    systemctl enable --now system-power.service
    sleep 2
    systemctl --no-pager --lines=0 status system-power.service | head -4
fi

echo
echo "Готово. Проверка:"
echo "    system-power status"
echo "    system-power set power    # картошка"
echo "    system-power set auto     # по питанию"
echo "    system-power show         # все числа профилей"
