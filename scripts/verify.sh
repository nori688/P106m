#!/bin/bash
# Диагностика: драйвер P106M + оффлоад обоев.
# Запуск от обычного пользователя: ./scripts/verify.sh

GREY='\033[0;90m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${NC} %s\n" "$*"; }
warn() { printf "  ${YEL}!${NC} %s\n" "$*"; }
dim()  { printf "    ${GREY}%s${NC}\n" "$*"; }

echo
echo "=== Драйвер ==="
if lsmod | grep -q '^nvidia '; then ok "модуль nvidia загружен"; else bad "модуль nvidia НЕ загружен"; fi

ver=$(grep -oP 'Kernel Module\s+\K[0-9][0-9.]*' /proc/driver/nvidia/version 2>/dev/null)
if [ -z "$ver" ]; then
    bad "версия не определяется (драйвер не работает?)"
elif [ "${ver%%.*}" = "535" ]; then
    ok "версия $ver — рабочая ветка"
else
    bad "версия $ver — ветки 580+ эту карту НЕ поднимают!"
fi

echo "=== Карта ==="
if nvidia-smi -L 2>/dev/null | grep -q '^GPU'; then
    ok "видна: $(nvidia-smi -L 2>/dev/null | head -1)"
    s=$(nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,pstate,temperature.gpu --format=csv,noheader 2>/dev/null)
    [ -n "$s" ] && dim "частота/макс/режим/темп: $s"
else
    bad "nvidia-smi карту не видит (проверь: dmesg | grep NVRM)"
fi
if lspci -nnk -s 03:00.0 2>/dev/null | grep -q 'driver in use: nvidia'; then
    ok "PCI-драйвер привязан"
else
    bad "PCI-драйвер не привязан"
fi

echo "=== PCIe-линк ==="
link=$(lspci -vv -s 00:1d.0 2>/dev/null | grep -E 'LnkCap:|LnkSta:')
if [ -n "$link" ]; then
    echo "$link" | sed 's/^[[:space:]]*/    /'
else
    dim "полные данные требуют root: sudo lspci -vv -s 00:1d.0 | grep -E 'LnkCap:|LnkSta:'"
fi
dim "(x2 — так распаяно; 2.5GT/s вместо 8GT/s — карта выше не тренирует, из софта не лечится)"

echo "=== Битые файлы нулевого размера ==="
found=0
for d in /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu/vdpau /usr/bin; do
    while IFS= read -r f; do
        [ -n "$f" ] && { bad "нулевой: $f"; found=1; }
    done < <(find "$d" -maxdepth 1 \( -name 'lib*nvidia*' -o -name 'libOpenCL*' \
                                    -o -name 'libcuda*' -o -name 'nvidia-*' \) -size 0 2>/dev/null)
done
[ "$found" = 0 ] && ok "нулевых файлов нет"

echo "=== nouveau ==="
if grep -rqs 'blacklist nouveau' /etc/modprobe.d/ /lib/modprobe.d/; then ok "заблокирован"; else bad "НЕ заблокирован — перехватит карту"; fi

echo "=== Оффлоад на Wayland ==="
ew=$(dpkg-query -W -f='${Version}' libnvidia-egl-wayland1 2>/dev/null)
if [ -n "$ew" ]; then ok "libnvidia-egl-wayland1 $ew"; else bad "пакет не установлен — оффлоад упадёт с 'eglGetPlatformDisplayEXT failed!'"; fi
if grep -qs 'nvidia-drm modeset=1' /etc/modprobe.d/*.conf /lib/modprobe.d/*.conf; then
    ok "nvidia-drm modeset=1"
else
    bad "modeset не включён"
fi

echo "=== Защита от apt ==="
if [ -f /etc/apt/preferences.d/nvidia-535-manual.pref ]; then
    c=$(apt-cache policy nvidia-driver-580 2>/dev/null | awk '/andidate|Кандидат/{print $2}')
    if [ -z "$c" ] || [ "$c" = "(отсутствует)" ]; then
        ok "драйверные пакеты заблокированы"
    else
        bad "apt всё ещё может поставить $c"
    fi
else
    warn "пина нет — apt сможет перезаписать драйвер"
fi

echo "=== Обои ==="
pid=$(cat "$HOME/.cache/wallpaper-picker/wallpaper.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    ok "рендер запущен (PID $pid)"
    if nvidia-smi 2>/dev/null | grep -q " $pid "; then
        ok "рендерит на ДИСКРЕТНОЙ"
    else
        warn "рендерит на встроенной (оффлоад не активен)"
    fi
else
    warn "обои не запущены"
fi
echo
