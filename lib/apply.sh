#!/bin/bash
# Применение профиля. Подключается через `source` (нужен root для sysfs).

SP_CONFIG="/etc/system-power/config"
SP_LIB_DIR="${SP_LIB_DIR:-/usr/local/lib/system-power/lib}"
[ -f "$SP_LIB_DIR/interface.sh" ] || SP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SP_LIB_DIR/interface.sh"

# Значения по умолчанию для путей обоев; переопределяются в /etc/system-power/config
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

# ---------------------------------------------------------------- CPU

sp_apply_cpu() {
    local mode="$1" state="$2" epp turbo maxmhz p

    epp=$(sp_value CPU_EPP "$mode" "$state")
    turbo=$(sp_value CPU_TURBO "$mode" "$state")
    maxmhz=$(sp_value CPU_MAX_MHZ "$mode" "$state")

    for p in /sys/devices/system/cpu/cpufreq/policy*/; do
        [ -e "$p/scaling_max_freq" ] && sp_write "$p/scaling_max_freq" "$maxmhz" "CPU max $(basename "$p")"
        [ -e "$p/energy_performance_preference" ] && \
            sp_write "$p/energy_performance_preference" "$epp" "EPP $(basename "$p")"
        if [ -e "$p/scaling_governor" ]; then
            if [ "$epp" = "performance" ]; then
                sp_write "$p/scaling_governor" performance "governor $(basename "$p")"
            else
                sp_write "$p/scaling_governor" powersave "governor $(basename "$p")"
            fi
        fi
    done

    # no_turbo: 1 = турбо ВЫКЛЮЧЕНО
    if [ "$turbo" = "1" ]; then
        sp_write /sys/devices/system/cpu/intel_pstate/no_turbo 0 "турбо вкл"
    else
        sp_write /sys/devices/system/cpu/intel_pstate/no_turbo 1 "турбо выкл"
    fi
}

# ---------------------------------------------------------------- питание

sp_apply_power() {
    local mode="$1" state="$2" long short dir
    long=$(sp_value RAPL_LONG_UW "$mode" "$state")
    short=$(sp_value RAPL_SHORT_UW "$mode" "$state")

    dir=$(sp_rapl_dir) || { sp_log "RAPL не найден"; return 0; }
    # кратковременный лимит ставим первым: он всегда >= долговременного
    sp_write "$dir/constraint_1_power_limit_uw" "$short" "RAPL короткий"
    sp_write "$dir/constraint_0_power_limit_uw" "$long"  "RAPL долгий"
}

# ---------------------------------------------------------------- графика

sp_apply_gpu() {
    local mode="$1" state="$2" gmax gmin dir cur
    gmax=$(sp_value IGPU_MAX_MHZ "$mode" "$state")
    gmin=$(sp_value IGPU_MIN_MHZ "$mode" "$state")

    if dir=$(sp_igpu_dir); then
        cur=$(cat "$dir/gt_min_freq_mhz" 2>/dev/null)
        # если текущий пол выше нового потолка — сначала опускаем пол
        if [ -n "$cur" ] && [ "$cur" -gt "$gmax" ] 2>/dev/null; then
            sp_write "$dir/gt_min_freq_mhz" "$gmax" "iGPU пол (временно)"
        fi
        sp_write "$dir/gt_max_freq_mhz" "$gmax" "iGPU потолок"
        sp_write "$dir/gt_min_freq_mhz" "$gmin" "iGPU пол"
    else
        sp_log "карта i915/xe не найдена — частоты iGPU не тронуты"
    fi
}

# ---------------------------------------------------------------- прочее

# ASPM в рантайме меняется не на всех ядрах: запись может вернуть I/O error.
# Проверено на этом ядре (7.0.0-30): политику можно задать ТОЛЬКО параметром
# загрузки pcie_aspm.policy=..., в рантайме отказ. Пробуем один раз за
# загрузку, чтобы не сыпать ошибками в журнал при каждом переключении.
sp_apply_aspm() {
    local want="$1"
    local f=/sys/module/pcie_aspm/parameters/policy
    local marker="$SP_STATE_DIR/aspm-не-меняется"
    [ -e "$f" ] || return 0

    local cur
    cur=$(grep -o '\[[^]]*\]' "$f" 2>/dev/null | tr -d '[]')
    [ "$cur" = "$want" ] && return 0
    [ -e "$marker" ] && return 0

    if printf '%s' "$want" > "$f" 2>/dev/null; then
        sp_log "PCIe ASPM: $cur -> $want"
    else
        mkdir -p "$SP_STATE_DIR" 2>/dev/null
        : > "$marker" 2>/dev/null
        sp_log "PCIe ASPM: ядро не даёт менять в рантайме (только pcie_aspm.policy= в загрузке) — пропускаю"
    fi
}

sp_apply_misc() {
    local mode="$1" state="$2" idle aspm usb
    idle=$(sp_value CPUIDLE "$mode" "$state")
    aspm=$(sp_value ASPM "$mode" "$state")
    usb=$(sp_value USB_AUTOSUSPEND "$mode" "$state")

    sp_write /sys/devices/system/cpu/cpuidle/current_governor "$idle" "cpuidle"
    sp_write /sys/module/usbcore/parameters/autosuspend "$usb" "USB autosuspend"
    sp_apply_aspm "$aspm"
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
    sp_log "останавливаю обои (PID $pid)"
    kill "$pid" 2>/dev/null
    sleep 1
}

sp_wallpaper_start() {
    [ -x "$SP_WALLPAPER_CTL" ] || { sp_log "нет $SP_WALLPAPER_CTL — обои не запускаю"; return 0; }

    # nohup/setsid НЕ умеют запускать shell-функции, поэтому команду собираем
    # вручную и отвязываем через setsid, иначе рендерер умрёт вместе со скриптом
    local u uid
    u=$(sp_session_user) || { sp_log "графическая сессия не найдена — обои не запускаю"; return 0; }
    uid=$(id -u "$u" 2>/dev/null) || return 0
    sp_log "запускаю обои заново (от имени $u)"

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
    local mode="$1" state="$2" fps gpu wp prev changed=0 old
    fps=$(sp_value WALLPAPER_FPS "$mode" "$state")
    gpu=$(sp_value WALLPAPER_GPU "$mode" "$state")
    wp=$(sp_value WALLPAPER "$mode" "$state")

    mkdir -p "$SP_STATE_DIR" 2>/dev/null
    printf '%s\n' "$gpu" > "$SP_STATE_DIR/wallpaper-gpu" 2>/dev/null
    prev=$(cat "$SP_STATE_DIR/wallpaper-mode" 2>/dev/null)
    printf '%s\n' "$wp" > "$SP_STATE_DIR/wallpaper-mode" 2>/dev/null

    # fps хранится в настройках выбора обоев
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
                sp_log "fps обоев: $old -> $fps"
                changed=1
            else
                sp_log "fps обоев: не удалось записать"
            fi
        fi
    fi

    if [ "$wp" = "off" ]; then
        sp_wallpaper_stop
        return 0
    fi

    # включить обратно, если были выключены, или применить новый fps
    if [ "$prev" = "off" ] || [ "$changed" = "1" ]; then
        if sp_wallpaper_pid >/dev/null; then
            sp_wallpaper_stop
            sleep 1
        fi
        sp_wallpaper_start
    fi
}

# ---------------------------------------------------------------- главное

sp_apply() {
    local mode="$1" state="${2:-$(sp_power_state)}"

    case "$mode" in performance|balanced|power) ;; *) echo "неизвестный режим: $mode" >&2; return 1 ;; esac
    case "$state" in ac|battery) ;; *) state=ac ;; esac

    sp_load_config
    sp_log "=== применяю профиль: $mode / $state ==="

    sp_apply_cpu  "$mode" "$state"
    sp_apply_power "$mode" "$state"
    sp_apply_gpu  "$mode" "$state"
    sp_apply_misc "$mode" "$state"
    sp_apply_wallpaper "$mode" "$state"
    sp_apply_interface "$mode" "$state"

    mkdir -p "$SP_STATE_DIR" 2>/dev/null
    printf '%s\n' "$mode"  > "$SP_STATE_DIR/applied-mode"  2>/dev/null
    printf '%s\n' "$state" > "$SP_STATE_DIR/applied-state" 2>/dev/null

    sp_log "=== профиль применён ==="
    return 0
}
