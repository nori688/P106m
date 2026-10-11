#!/bin/bash
# Интерфейс: снимок настроек и применение «примитива».
# Подключается через `source`.
#
# Зачем снимок: у тебя свои темы (Yaru-sage-dark), свои фоны, свои расширения.
# Профиль энергосбережения должен вернуть всё это обратно, а не оставить
# Adwaita навсегда. Поэтому baseline = значения из снимка, а не константы.

SP_BASELINE="/var/lib/system-power/baseline.conf"
SP_UI_LOGIN_THEME_FALLBACK="Adwaita"

# Постоянные юниты пользователя, которые гасим в режиме EXTRAS=0
SP_EXTRA_UNITS="localsearch-3.service evolution-addressbook-factory.service
evolution-calendar-factory.service evolution-source-registry.service"

# ---------------------------------------------------------------- gsettings

ui_get()  { sp_as_user gsettings get "$1" "$2"; }
ui_set()  {
    local schema="$1" key="$2" value="$3" cur
    cur=$(ui_get "$schema" "$key")
    [ "$cur" = "$value" ] && return 0
    if sp_as_user gsettings set "$schema" "$key" "$value"; then
        sp_log "интерфейс: $schema $key: $cur -> $value"
    else
        sp_log "интерфейс: НЕ УДАЛОСЬ $schema $key = $value"
    fi
}

# расширения: включить/выключить по списку
ui_ext_disable() {
    local u
    for u in $(printf '%s' "$1" | tr ',' ' '); do
        [ -z "$u" ] && continue
        if sp_as_user gnome-extensions disable "$u"; then
            sp_log "расширение выключено: $u"
        else
            sp_log "расширение НЕ выключилось: $u (может понадобиться перелогин)"
        fi
    done
}
ui_ext_restore() {
    local u
    for u in $(printf '%s' "$1" | tr ',' ' '); do
        [ -z "$u" ] && continue
        sp_as_user gnome-extensions enable "$u" \
            && sp_log "расширение включено: $u" \
            || sp_log "расширение НЕ включилось: $u"
    done
}

# ---------------------------------------------------------------- снимок

# Список расширений, включённых СЕЙЧАС — чтобы вернуть именно их
ui_enabled_extensions() {
    sp_as_user gnome-extensions list --enabled 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

sp_snapshot() {
    mkdir -p "$(dirname "$SP_BASELINE")" 2>/dev/null
    local tmp="$SP_BASELINE.tmp"
    {
        echo "# Снимок настроек интерфейса. Сделан $(date '+%F %T')"
        echo "# baseline в profiles.conf ссылается сюда. Пересоздать: system-power snapshot"
        printf 'GTK_THEME=%s\n'      "$(ui_get org.gnome.desktop.interface gtk-theme)"
        printf 'ICON_THEME=%s\n'     "$(ui_get org.gnome.desktop.interface icon-theme)"
        printf 'COLOR_SCHEME=%s\n'   "$(ui_get org.gnome.desktop.interface color-scheme)"
        printf 'FONT_AA=%s\n'        "$(ui_get org.gnome.desktop.interface font-antialiasing)"
        printf 'FONT_HINTING=%s\n'   "$(ui_get org.gnome.desktop.interface font-hinting)"
        printf 'BG_URI=%s\n'         "$(ui_get org.gnome.desktop.background picture-uri)"
        printf 'BG_URI_DARK=%s\n'    "$(ui_get org.gnome.desktop.background picture-uri-dark)"
        printf 'BG_PRIMARY=%s\n'     "$(ui_get org.gnome.desktop.background primary-color)"
        printf 'DOCK_TRANSPARENCY=%s\n' "$(ui_get org.gnome.shell.extensions.dash-to-dock transparency-mode)"
        printf 'DOCK_OPACITY=%s\n'   "$(ui_get org.gnome.shell.extensions.dash-to-dock background-opacity)"
        printf 'DOCK_SHRINK=%s\n'    "$(ui_get org.gnome.shell.extensions.dash-to-dock custom-theme-shrink)"
        printf 'DOCK_AUTOHIDE=%s\n'  "$(ui_get org.gnome.shell.extensions.dash-to-dock autohide)"
        printf 'ANIMATIONS=%s\n'     "$(ui_get org.gnome.desktop.interface enable-animations)"
        printf 'EXTENSIONS=%s\n'     "$(ui_enabled_extensions)"
    } > "$tmp" 2>/dev/null
    mv "$tmp" "$SP_BASELINE"
    sp_log "снимок интерфейса сохранён: $SP_BASELINE"
}

sp_baseline_get() {
    local key="$1" v
    [ -r "$SP_BASELINE" ] || return 1
    v=$(grep -m1 "^$key=" "$SP_BASELINE" 2>/dev/null | cut -d= -f2-)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# если снимка нет — делаем сами, один раз
sp_snapshot_if_missing() {
    [ -r "$SP_BASELINE" ] || sp_snapshot
}

# ---------------------------------------------------------------- применение

sp_apply_interface() {
    local mode="$1" state="$2"
    sp_snapshot_if_missing

    # --- темы ---
    local v b
    v=$(sp_value GTK_THEME "$mode" "$state")
    if [ "$v" = "plain" ]; then
        ui_set org.gnome.desktop.interface gtk-theme "$SP_UI_LOGIN_THEME_FALLBACK"
    elif b=$(sp_baseline_get GTK_THEME); then
        ui_set org.gnome.desktop.interface gtk-theme "$b"
    fi

    v=$(sp_value ICON_THEME "$mode" "$state")
    if [ "$v" = "plain" ]; then
        ui_set org.gnome.desktop.interface icon-theme "$SP_UI_LOGIN_THEME_FALLBACK"
    elif b=$(sp_baseline_get ICON_THEME); then
        ui_set org.gnome.desktop.interface icon-theme "$b"
    fi

    v=$(sp_value COLOR_SCHEME "$mode" "$state")
    if [ "$v" = "plain" ]; then
        ui_set org.gnome.desktop.interface color-scheme default
    elif b=$(sp_baseline_get COLOR_SCHEME); then
        ui_set org.gnome.desktop.interface color-scheme "$b"
    fi

    v=$(sp_value FONT_AA "$mode" "$state")
    if [ "$v" = "baseline" ]; then
        b=$(sp_baseline_get FONT_AA) && ui_set org.gnome.desktop.interface font-antialiasing "$b"
    else
        ui_set org.gnome.desktop.interface font-antialiasing "$v"
    fi

    v=$(sp_value FONT_HINTING "$mode" "$state")
    if [ "$v" = "baseline" ]; then
        b=$(sp_baseline_get FONT_HINTING) && ui_set org.gnome.desktop.interface font-hinting "$b"
    else
        ui_set org.gnome.desktop.interface font-hinting "$v"
    fi

    # --- фон ---
    v=$(sp_value BACKGROUND "$mode" "$state")
    if [ "$v" = "solid" ]; then
        ui_set org.gnome.desktop.background picture-uri "''"
        ui_set org.gnome.desktop.background picture-uri-dark "''"
        ui_set org.gnome.desktop.background color-shading-type "'solid'"
    else
        if b=$(sp_baseline_get BG_URI); then ui_set org.gnome.desktop.background picture-uri "$b"; fi
        if b=$(sp_baseline_get BG_URI_DARK); then ui_set org.gnome.desktop.background picture-uri-dark "$b"; fi
    fi

    # --- док ---
    v=$(sp_value DOCK "$mode" "$state")
    if [ "$v" = "plain" ]; then
        # в этой версии дока enum только DEFAULT / FIXED / DYNAMIC;
        # FIXED = непрозрачный фон (значения SOLID здесь нет)
        ui_set org.gnome.shell.extensions.dash-to-dock transparency-mode "'FIXED'"
        ui_set org.gnome.shell.extensions.dash-to-dock background-opacity 1.0
        ui_set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink false
    else
        b=$(sp_baseline_get DOCK_TRANSPARENCY) && ui_set org.gnome.shell.extensions.dash-to-dock transparency-mode "$b"
        b=$(sp_baseline_get DOCK_OPACITY)      && ui_set org.gnome.shell.extensions.dash-to-dock background-opacity "$b"
        b=$(sp_baseline_get DOCK_SHRINK)       && ui_set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink "$b"
    fi

    # --- анимации ---
    v=$(sp_value GNOME_ANIM "$mode" "$state")
    if [ "$v" = "1" ]; then
        if b=$(sp_baseline_get ANIMATIONS); then
            ui_set org.gnome.desktop.interface enable-animations "$b"
        else
            ui_set org.gnome.desktop.interface enable-animations true
        fi
    else
        ui_set org.gnome.desktop.interface enable-animations false
    fi

    # --- расширения ---
    v=$(sp_value EXT_DISABLE "$mode" "$state")
    if [ "$v" = "-" ]; then
        # вернуть те, что были включены в снимке
        if b=$(sp_baseline_get EXTENSIONS); then ui_ext_restore "$b"; fi
    else
        ui_ext_disable "$v"
    fi

    # --- фоновые службы ---
    v=$(sp_value EXTRAS "$mode" "$state")
    if [ "$v" = "1" ]; then
        printf '%s\n' $SP_EXTRA_UNITS | while read -r u; do
            [ -z "$u" ] && continue
            sp_as_user systemctl --user unmask "$u" >/dev/null 2>&1
            sp_as_user systemctl --user start  "$u" >/dev/null 2>&1
        done
        sp_log "фоновые службы: возвращены"
    else
        printf '%s\n' $SP_EXTRA_UNITS | while read -r u; do
            [ -z "$u" ] && continue
            sp_as_user systemctl --user stop   "$u" >/dev/null 2>&1
            sp_as_user systemctl --user mask   "$u" >/dev/null 2>&1
        done
        sp_log "фоновые службы: остановлены (localsearch, evolution)"
    fi
}
