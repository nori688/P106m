#!/bin/bash
# Общие вспомогательные функции. Подключается через `source`.

SP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP_PROFILES="${SP_PROFILES:-$SP_LIB_DIR/profiles.conf}"
SP_STATE_DIR="/run/system-power"
SP_MODE_FILE="/etc/system-power/mode"
SP_LOG="${SP_LOG:-/var/log/system-power.log}"

sp_log() {
    local msg="[$(date '+%F %T')] $*"
    if [ -w "$(dirname "$SP_LOG")" ] 2>/dev/null; then
        printf '%s\n' "$msg" >> "$SP_LOG" 2>/dev/null
    fi
    [ -n "${SP_VERBOSE:-}" ] && printf '%s\n' "$msg" >&2
    return 0
}

# Значения профиля картошки живут в lib/apply.sh (sp_potato_value):
# таблица теперь из двух колонок, читать её из общего модуля незачем.

# Текущее состояние питания.
# SP_FORCE_STATE=ac|battery — отладочный override, чтобы проверять батарейные
# профили, не выдёргивая зарядку (нужен, например, для тестов фото обоев).
sp_power_state() {
    case "${SP_FORCE_STATE:-}" in
        ac|battery) printf '%s' "$SP_FORCE_STATE"; return 0 ;;
    esac
    local online
    online=$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1)
    case "$online" in
        1) echo ac ;;
        0) echo battery ;;
        *) echo ac ;;   # нет датчика AC (стационарник) — считаем сетью
    esac
}

# ---------------------------------------------------------------- PPD
#
# Штатные три режима GNOME (Настройки → Питание → Режим работы) обслуживает
# power-profiles-daemon. Именно он и есть переключатель: пользователь щёлкает
# в системном меню, а system-power по этому событию раскладывает профиль по
# всей системе. Второе измерение — источник питания (сеть/батарея).

sp_ppd_available() { command -v powerprofilesctl >/dev/null 2>&1; }

# текущий профиль PPD: performance | balanced | power-saver
sp_ppd_get() {
    sp_ppd_available || return 1
    local p
    p=$(powerprofilesctl get 2>/dev/null)
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    return 1
}

# Сменить профиль PPD.
# ВАЖНО: polkit разрешает это только пользователю активной сессии, поэтому
# от root вызываем через sp_as_user — иначе «power-profiles-daemon недоступен».
sp_ppd_set() {
    sp_ppd_available || return 1
    if [ "$(id -u)" = "0" ]; then
        sp_as_user powerprofilesctl set "$1" >/dev/null 2>&1
    else
        powerprofilesctl set "$1" >/dev/null 2>&1
    fi
}

# PPD -> режим system-power
sp_mode_from_ppd() {
    case "$1" in
        performance) echo performance ;;
        balanced)    echo balanced ;;
        power-saver) echo power ;;
        *)           echo balanced ;;
    esac
}

# режим system-power -> PPD
sp_ppd_from_mode() {
    case "$1" in
        performance) echo performance ;;
        balanced)    echo balanced ;;
        power)       echo power-saver ;;
        *)           echo balanced ;;
    esac
}

# Текущий режим: берётся у PPD. Если PPD нет — из файла, как раньше.
sp_saved_mode() {
    local p m
    if p=$(sp_ppd_get); then
        sp_mode_from_ppd "$p"
        return 0
    fi
    m=$(cat "$SP_MODE_FILE" 2>/dev/null)
    case "$m" in
        performance|balanced|power) echo "$m" ;;
        *) echo balanced ;;
    esac
}

# Режим совпадает с выбором в GNOME; отдельного «auto» больше не нужно —
# состояние питания учитывается отдельной колонкой в таблице профилей.
sp_effective_mode() { sp_saved_mode; }

# Запись в sysfs: пишем только если значение отличается, ошибки — в лог
sp_write() {
    local path="$1" value="$2" label="$3"
    [ -e "$path" ] || { sp_log "нет $path — пропускаю $label"; return 1; }
    local cur
    cur=$(cat "$path" 2>/dev/null)
    [ "$cur" = "$value" ] && return 0
    if printf '%s' "$value" > "$path" 2>/dev/null; then
        sp_log "$label: $cur -> $value"
    else
        sp_log "НЕ УДАЛОСЬ $label ($path = $value)"
    fi
}

# Каталог карты i915 (номера card* плавают — ищем по драйверу)
sp_igpu_dir() {
    local c drv
    for c in /sys/class/drm/card*/; do
        drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
        if [ "$drv" = "i915" ] || [ "$drv" = "xe" ]; then
            [ -e "$c/gt_max_freq_mhz" ] && { echo "${c%/}"; return 0; }
        fi
    done
    return 1
}

sp_rapl_dir() {
    local d
    for d in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/amd-rapl:0; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Текущий пользователь графической сессии (для gsettings)
sp_session_user() {
    local u sid
    sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 != "-" && $4 == "seat0" {print $1; exit}')
    [ -z "$sid" ] && sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$sid" ] && return 1
    u=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
    [ -n "$u" ] && { echo "$u"; return 0; }
    return 1
}

# Выполнить команду от имени пользователя сессии, с его D-Bus.
# Если мы уже этот пользователь — runuser не нужен (и не сработает без root).
sp_as_user() {
    local u uid
    u=$(sp_session_user) || return 1
    uid=$(id -u "$u" 2>/dev/null) || return 1

    if [ "$(id -un)" = "$u" ]; then
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}" "$@" 2>/dev/null
        return $?
    fi

    [ "$(id -u)" = "0" ] || return 1
    runuser -u "$u" -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}" \
        "$@" 2>/dev/null
}

# Читаемые имена
sp_mode_ru() {
    case "$1" in
        performance) echo "производительность" ;;
        balanced)    echo "баланс" ;;
        power)       echo "энергосбережение" ;;
        auto)        echo "авто" ;;
        *) echo "$1" ;;
    esac
}
sp_state_ru() {
    case "$1" in
        ac) echo "сеть" ;;
        battery) echo "батарея" ;;
        *) echo "$1" ;;
    esac
}
