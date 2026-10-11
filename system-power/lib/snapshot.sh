#!/bin/bash
# Снимок состояния системы и возврат к нему.
# Подключается через `source`.
#
# Зачем: режимы производительности и баланса ничего не настраивают — они
# возвращают систему к тому, что было до картошки. Для этого нужен снимок:
# и настроек интерфейса (темы, фон, док, расширения), и параметров железа
# (EPP, турбо, потолки частот, лимиты мощности), потому что sysfs-значения
# держатся сами по себе и после картошки их надо вернуть руками.

SP_BASELINE="/var/lib/system-power/baseline.conf"
SP_UI_PLAIN_THEME="Adwaita-dark"     # тёмная: светлая в картошке режет глаза

# Юниты пользователя, которые гасим в картошке
SP_EXTRA_UNITS="localsearch-3.service evolution-addressbook-factory.service
evolution-calendar-factory.service evolution-source-registry.service"

# ---------------------------------------------------------------- gsettings

ui_get() { sp_as_user gsettings get "$1" "$2"; }

ui_set() {
    local schema="$1" key="$2" value="$3" cur
    cur=$(ui_get "$schema" "$key")
    [ "$cur" = "$value" ] && return 0
    if sp_as_user gsettings set "$schema" "$key" "$value"; then
        sp_log "интерфейс: $schema $key: $cur -> $value"
    else
        sp_log "интерфейс: НЕ УДАЛОСЬ $schema $key = $value"
    fi
}

ui_ext() {   # ui_ext <enable|disable> <список через запятую>
    local act="$1" list="$2" u
    for u in $(printf '%s' "$list" | tr ',' ' '); do
        [ -z "$u" ] && continue
        if sp_as_user gnome-extensions "$act" "$u"; then
            sp_log "расширение $act: $u"
        else
            sp_log "расширение НЕ удалось $act: $u"
        fi
    done
}

ui_enabled_extensions() {
    sp_as_user gnome-extensions list --enabled 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

# ---------------------------------------------------------------- снимок

sp_snapshot() {
    # не снимаем, пока включена картошка — иначе запомним её же значения
    if [ "$(cat "$SP_STATE_DIR/applied-mode" 2>/dev/null)" = "power" ] && [ -z "${SP_FORCE_SNAPSHOT:-}" ]; then
        echo "Сейчас включён режим энергосбережения — снимок получится неправильный." >&2
        echo "Переключись в баланс и повтори, либо запусти с SP_FORCE_SNAPSHOT=1." >&2
        return 1
    fi

    local dir igpu rapl
    igpu=$(sp_igpu_dir); rapl=$(sp_rapl_dir)
    mkdir -p "$(dirname "$SP_BASELINE")" 2>/dev/null
    local tmp="$SP_BASELINE.tmp"

    {
        echo "# Снимок состояния системы. Сделан $(date '+%F %T')"
        echo "# Режимы производительности и баланса возвращают систему сюда."
        echo "# Пересоздать: system-power snapshot"
        echo
        echo "# --- интерфейс ---"
        printf 'UI_GTK_THEME=%s\n'      "$(ui_get org.gnome.desktop.interface gtk-theme)"
        printf 'UI_ICON_THEME=%s\n'     "$(ui_get org.gnome.desktop.interface icon-theme)"
        printf 'UI_COLOR_SCHEME=%s\n'   "$(ui_get org.gnome.desktop.interface color-scheme)"
        printf 'UI_FONT_AA=%s\n'        "$(ui_get org.gnome.desktop.interface font-antialiasing)"
        printf 'UI_FONT_HINTING=%s\n'   "$(ui_get org.gnome.desktop.interface font-hinting)"
        printf 'UI_BG_URI=%s\n'         "$(ui_get org.gnome.desktop.background picture-uri)"
        printf 'UI_BG_URI_DARK=%s\n'    "$(ui_get org.gnome.desktop.background picture-uri-dark)"
        printf 'UI_DOCK_TRANSPARENCY=%s\n' "$(ui_get org.gnome.shell.extensions.dash-to-dock transparency-mode)"
        printf 'UI_DOCK_OPACITY=%s\n'   "$(ui_get org.gnome.shell.extensions.dash-to-dock background-opacity)"
        printf 'UI_DOCK_SHRINK=%s\n'    "$(ui_get org.gnome.shell.extensions.dash-to-dock custom-theme-shrink)"
        printf 'UI_ANIMATIONS=%s\n'     "$(ui_get org.gnome.desktop.interface enable-animations)"
        printf 'UI_EXTENSIONS=%s\n'     "$(ui_enabled_extensions)"
        echo
        echo "# --- железо ---"
        printf 'HW_CPU_EPP=%s\n'   "$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
        printf 'HW_CPU_TURBO=%s\n' "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
        printf 'HW_CPU_MAX=%s\n'   "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)"
        printf 'HW_CPUIDLE=%s\n'   "$(cat /sys/devices/system/cpu/cpuidle/current_governor 2>/dev/null)"
        printf 'HW_USB=%s\n'       "$(cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null)"
        [ -n "$rapl" ] && {
            printf 'HW_RAPL_LONG=%s\n'  "$(cat "$rapl/constraint_0_power_limit_uw" 2>/dev/null)"
            printf 'HW_RAPL_SHORT=%s\n' "$(cat "$rapl/constraint_1_power_limit_uw" 2>/dev/null)"
        }
        [ -n "$igpu" ] && {
            printf 'HW_IGPU_MAX=%s\n' "$(cat "$igpu/gt_max_freq_mhz" 2>/dev/null)"
            printf 'HW_IGPU_MIN=%s\n' "$(cat "$igpu/gt_min_freq_mhz" 2>/dev/null)"
        }
    } > "$tmp" 2>/dev/null

    mv "$tmp" "$SP_BASELINE"
    sp_log "снимок сохранён: $SP_BASELINE"
}

sp_baseline_get() {
    local v
    [ -r "$SP_BASELINE" ] || return 1
    v=$(grep -m1 "^$1=" "$SP_BASELINE" 2>/dev/null | cut -d= -f2-)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# Снимок есть и в нём есть и интерфейс, и железо
sp_snapshot_ok() {
    [ -r "$SP_BASELINE" ] || return 1
    grep -q '^UI_GTK_THEME=' "$SP_BASELINE" || return 1
    grep -q '^HW_CPU_EPP='   "$SP_BASELINE" || return 1
    return 0
}

sp_snapshot_if_needed() {
    sp_snapshot_ok || sp_snapshot
}

# ---------------------------------------------------------------- возврат

sp_restore_interface() {
    local b

    b=$(sp_baseline_get UI_GTK_THEME)    && ui_set org.gnome.desktop.interface gtk-theme "$b"
    b=$(sp_baseline_get UI_ICON_THEME)   && ui_set org.gnome.desktop.interface icon-theme "$b"
    b=$(sp_baseline_get UI_COLOR_SCHEME) && ui_set org.gnome.desktop.interface color-scheme "$b"
    b=$(sp_baseline_get UI_FONT_AA)      && ui_set org.gnome.desktop.interface font-antialiasing "$b"
    b=$(sp_baseline_get UI_FONT_HINTING) && ui_set org.gnome.desktop.interface font-hinting "$b"
    b=$(sp_baseline_get UI_BG_URI)       && ui_set org.gnome.desktop.background picture-uri "$b"
    b=$(sp_baseline_get UI_BG_URI_DARK)  && ui_set org.gnome.desktop.background picture-uri-dark "$b"

    b=$(sp_baseline_get UI_DOCK_TRANSPARENCY) && ui_set org.gnome.shell.extensions.dash-to-dock transparency-mode "$b"
    b=$(sp_baseline_get UI_DOCK_OPACITY)      && ui_set org.gnome.shell.extensions.dash-to-dock background-opacity "$b"
    b=$(sp_baseline_get UI_DOCK_SHRINK)       && ui_set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink "$b"

    b=$(sp_baseline_get UI_ANIMATIONS)   && ui_set org.gnome.desktop.interface enable-animations "$b"
    b=$(sp_baseline_get UI_EXTENSIONS)   && ui_ext enable "$b"

    # фоновые службы обратно
    printf '%s\n' $SP_EXTRA_UNITS | while read -r u; do
        [ -z "$u" ] && continue
        sp_as_user systemctl --user unmask "$u" >/dev/null 2>&1
        sp_as_user systemctl --user start  "$u" >/dev/null 2>&1
    done
    sp_log "интерфейс: восстановлен"
}

sp_restore_hardware() {
    local b igpu rapl

    b=$(sp_baseline_get HW_CPU_EPP)   && sp_write /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference "$b" "EPP"
    b=$(sp_baseline_get HW_CPU_TURBO) && sp_write /sys/devices/system/cpu/intel_pstate/no_turbo "$b" "турбо"

    b=$(sp_baseline_get HW_CPU_MAX)
    if [ -n "$b" ]; then
        local p
        for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
            [ -e "$p" ] && sp_write "$p" "$b" "CPU max $(basename "$(dirname "$p")")"
        done
    fi

    b=$(sp_baseline_get HW_CPUIDLE) && sp_write /sys/devices/system/cpu/cpuidle/current_governor "$b" "cpuidle"
    b=$(sp_baseline_get HW_USB)     && sp_write /sys/module/usbcore/parameters/autosuspend "$b" "USB autosuspend"

    rapl=$(sp_rapl_dir) && {
        b=$(sp_baseline_get HW_RAPL_SHORT) && sp_write "$rapl/constraint_1_power_limit_uw" "$b" "RAPL короткий"
        b=$(sp_baseline_get HW_RAPL_LONG)  && sp_write "$rapl/constraint_0_power_limit_uw" "$b" "RAPL долгий"
    }

    igpu=$(sp_igpu_dir) && {
        local gmin gmax cur
        gmax=$(sp_baseline_get HW_IGPU_MAX); gmin=$(sp_baseline_get HW_IGPU_MIN)
        if [ -n "$gmax" ] && [ -n "$gmin" ]; then
            cur=$(cat "$igpu/gt_min_freq_mhz" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" -gt "$gmax" ] 2>/dev/null; then
                sp_write "$igpu/gt_min_freq_mhz" "$gmax" "iGPU пол (временно)"
            fi
            sp_write "$igpu/gt_max_freq_mhz" "$gmax" "iGPU потолок"
            sp_write "$igpu/gt_min_freq_mhz" "$gmin" "iGPU пол"
        fi
    }
    sp_log "железо: восстановлено из снимка"
}

# ---------------------------------------------------------------- интерфейс картошки

sp_potato_interface() {
    local state="$1"

    if [ "$(sp_potato_value GTK_THEME "$state")" = "plain" ]; then
        ui_set org.gnome.desktop.interface gtk-theme  "$SP_UI_PLAIN_THEME"
        ui_set org.gnome.desktop.interface icon-theme "$SP_UI_PLAIN_THEME"
    fi
    [ "$(sp_potato_value COLOR_SCHEME "$state")" = "plain" ] && \
        ui_set org.gnome.desktop.interface color-scheme prefer-dark

    ui_set org.gnome.desktop.interface font-antialiasing "$(sp_potato_value FONT_AA "$state")"
    ui_set org.gnome.desktop.interface font-hinting      "$(sp_potato_value FONT_HINTING "$state")"

    if [ "$(sp_potato_value DOCK "$state")" = "plain" ]; then
        # в этой версии дока enum только DEFAULT/FIXED/DYNAMIC: FIXED = непрозрачный
        ui_set org.gnome.shell.extensions.dash-to-dock transparency-mode "'FIXED'"
        ui_set org.gnome.shell.extensions.dash-to-dock background-opacity 1.0
        ui_set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink false
    fi

    if [ "$(sp_potato_value GNOME_ANIM "$state")" = "1" ]; then
        ui_set org.gnome.desktop.interface enable-animations true
    else
        ui_set org.gnome.desktop.interface enable-animations false
    fi

    ui_ext disable "$(sp_potato_value EXT_DISABLE "$state")"

    if [ "$(sp_potato_value EXTRAS "$state")" = "1" ]; then
        sp_restore_interface >/dev/null 2>&1     # грубо, но редко нужно
    else
        printf '%s\n' $SP_EXTRA_UNITS | while read -r u; do
            [ -z "$u" ] && continue
            sp_as_user systemctl --user stop "$u" >/dev/null 2>&1
            sp_as_user systemctl --user mask "$u" >/dev/null 2>&1
        done
        sp_log "фоновые службы: остановлены (localsearch, evolution)"
    fi
}
