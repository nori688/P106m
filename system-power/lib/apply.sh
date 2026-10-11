#!/bin/bash
# Применение профиля. Подключается через `source` (нужен root для sysfs).
#
# Логика простая:
#   режим энергосбережения → картошка (числа из profiles.conf)
#   любой другой режим     → вернуть систему к снимку
#   обои                   → отдельное правило, не зависящее от картошки

SP_CONFIG="/etc/system-power/config"
SP_LIB_DIR="${SP_LIB_DIR:-/usr/local/lib/system-power/lib}"
[ -f "$SP_LIB_DIR/snapshot.sh" ] || SP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SP_LIB_DIR/snapshot.sh"

# Значения по умолчанию; переопределяются в /etc/system-power/config
sp_load_config() {
    SP_HOME=""
    local u
    u=$(sp_session_user 2>/dev/null) && SP_HOME=$(getent passwd "$u" | cut -d: -f6)
    : "${SP_HOME:=$HOME}"

    SP_WALLPAPER_SETTINGS="$SP_HOME/.cache/wallpaper-picker/settings.json"
    SP_WALLPAPER_PID="$SP_HOME/.cache/wallpaper-picker/wallpaper.pid"
    SP_WALLPAPER_CTL="$SP_HOME/wallpaper-engine-gnome/start-wallpaper.sh"
    # shellcheck disable=SC1090
    [ -r "$SP_CONFIG" ] && . "$SP_CONFIG"
}

# ---------------------------------------------------------------- картошка

# Значение ключа из таблицы: sp_potato_value <КЛЮЧ> <ac|battery>
sp_potato_value() {
    local key="$1" state="$2" col
    case "$state" in
        ac)      col=2 ;;
        battery) col=3 ;;
        *)       return 1 ;;
    esac
    awk -v k="$key" -v c="$col" '
        $1 == k { print $c; found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$SP_PROFILES"
}

sp_potato_hardware() {
    local state="$1" v p igpu rapl

    # EPP — через политики. Губернатор НЕ трогаем: с governor=performance
    # файл energy_performance_preference становится недоступен на запись
    # (EBUSY), и power-profiles-daemon после этого не может сменить профиль
    # вообще. Поэтому губернатор всегда остаётся powersave.
    v=$(sp_potato_value CPU_EPP "$state")
    for p in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
        [ -e "$p" ] && sp_write "$p" "$v" "EPP $(basename "$(dirname "$p")")"
    done

    v=$(sp_potato_value CPU_MAX_MHZ "$state")
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
        [ -e "$p" ] && sp_write "$p" "$v" "CPU max $(basename "$(dirname "$p")")"
    done

    if [ "$(sp_potato_value CPU_TURBO "$state")" = "1" ]; then
        sp_write /sys/devices/system/cpu/intel_pstate/no_turbo 0 "турбо вкл"
    else
        sp_write /sys/devices/system/cpu/intel_pstate/no_turbo 1 "турбо выкл"
    fi

    sp_write /sys/devices/system/cpu/cpuidle/current_governor \
        "$(sp_potato_value CPUIDLE "$state")" "cpuidle"
    sp_write /sys/module/usbcore/parameters/autosuspend \
        "$(sp_potato_value USB_AUTOSUSPEND "$state")" "USB autosuspend"

    if rapl=$(sp_rapl_dir); then
        # короткий лимит первым: он всегда >= долговременного
        sp_write "$rapl/constraint_1_power_limit_uw" "$(sp_potato_value RAPL_SHORT_UW "$state")" "RAPL короткий"
        sp_write "$rapl/constraint_0_power_limit_uw" "$(sp_potato_value RAPL_LONG_UW "$state")"  "RAPL долгий"
    fi

    if igpu=$(sp_igpu_dir); then
        local gmax gmin cur
        gmax=$(sp_potato_value IGPU_MAX_MHZ "$state")
        gmin=$(sp_potato_value IGPU_MIN_MHZ "$state")
        cur=$(cat "$igpu/gt_min_freq_mhz" 2>/dev/null)
        if [ -n "$cur" ] && [ "$cur" -gt "$gmax" ] 2>/dev/null; then
            sp_write "$igpu/gt_min_freq_mhz" "$gmax" "iGPU пол (временно)"
        fi
        sp_write "$igpu/gt_max_freq_mhz" "$gmax" "iGPU потолок"
        sp_write "$igpu/gt_min_freq_mhz" "$gmin" "iGPU пол"
    fi
}

# ---------------------------------------------------------------- обои

sp_wallpaper_pid() {
    local pid
    pid=$(cat "$SP_WALLPAPER_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
    return 1
}

sp_wallpaper_stop() {
    local pid
    pid=$(sp_wallpaper_pid) || return 0
    sp_log "обои: останавливаю движок (PID $pid)"
    kill "$pid" 2>/dev/null
    sleep 1
}

sp_wallpaper_start() {
    [ -x "$SP_WALLPAPER_CTL" ] || { sp_log "нет $SP_WALLPAPER_CTL — движок не запускаю"; return 0; }

    # nohup/setsid не умеют запускать shell-функции, поэтому команду собираем
    # вручную и отвязываем через setsid, иначе движок умрёт вместе со скриптом
    local u uid
    u=$(sp_session_user) || { sp_log "графическая сессия не найдена"; return 0; }
    uid=$(id -u "$u" 2>/dev/null) || return 0
    sp_log "обои: запускаю движок от имени $u"

    if [ "$(id -un)" = "$u" ]; then
        setsid "$SP_WALLPAPER_CTL" --apply-plan >/dev/null 2>&1 < /dev/null &
    else
        setsid runuser -u "$u" -- env \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            XDG_RUNTIME_DIR="/run/user/$uid" \
            XDG_SESSION_TYPE=wayland \
            "$SP_WALLPAPER_CTL" --apply-plan >/dev/null 2>&1 < /dev/null &
    fi
    disown 2>/dev/null
}

sp_apply_wallpaper() {
    local mode="$1" state="$2" fps gpu changed=0 old=""

    # ПРАВИЛО ЖИВЫХ ОБОЕВ: на батарее движок выключается, и остаётся обычный
    # фон рабочего стола. Единственное исключение — режим производительности.
    if [ "$state" = "battery" ] && [ "$mode" != "performance" ]; then
        sp_wallpaper_stop
        sp_log "обои: батарея без производительности — движок выключен"
        return 0
    fi

    if [ "$mode" = "power" ]; then
        fps=$(sp_potato_value WALLPAPER_FPS "$state")
        gpu=$(sp_potato_value WALLPAPER_GPU "$state")
    fi
    : "${fps:=30}"; : "${gpu:=nvidia}"

    mkdir -p "$SP_STATE_DIR" 2>/dev/null
    printf '%s\n' "$gpu" > "$SP_STATE_DIR/wallpaper-gpu" 2>/dev/null

    # fps живёт в настройках выбора обоев
    if [ -f "$SP_WALLPAPER_SETTINGS" ]; then
        old=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('fps',''))" \
              "$SP_WALLPAPER_SETTINGS" 2>/dev/null)
        if [ "$old" != "$fps" ]; then
            if python3 - "$SP_WALLPAPER_SETTINGS" "$fps" <<'PY' 2>/dev/null
import json, os, sys
path, fps = sys.argv[1], int(sys.argv[2])
d = json.load(open(path, encoding="utf-8"))
d["fps"] = fps
tmp = path + ".tmp"
json.dump(d, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
os.replace(tmp, path)
PY
            then
                sp_log "обои: fps $old -> $fps"
                changed=1
            else
                sp_log "обои: fps записать не удалось"
            fi
        fi
    fi

    if [ "$changed" = "1" ] || ! sp_wallpaper_pid >/dev/null; then
        sp_wallpaper_stop
        sp_wallpaper_start
    fi
}

# ---------------------------------------------------------------- главное

sp_apply() {
    local mode="$1" state="${2:-$(sp_power_state)}"

    case "$mode" in performance|balanced|power) ;; *) echo "неизвестный режим: $mode" >&2; return 1 ;; esac
    case "$state" in ac|battery) ;; *) state=ac ;; esac

    sp_load_config
    sp_snapshot_if_needed
    sp_log "=== применяю: $mode / $state ==="

    if [ "$mode" = "power" ]; then
        sp_potato_hardware "$state"
        sp_potato_interface "$state"
    else
        # производительность и баланс ничего не настраивают — возвращаем снимок
        sp_restore_hardware
        sp_restore_interface
    fi

    sp_apply_wallpaper "$mode" "$state"

    mkdir -p "$SP_STATE_DIR" 2>/dev/null
    printf '%s\n' "$mode"  > "$SP_STATE_DIR/applied-mode"  2>/dev/null
    printf '%s\n' "$state" > "$SP_STATE_DIR/applied-state" 2>/dev/null

    sp_log "=== применено: $mode / $state ==="
    return 0
}
