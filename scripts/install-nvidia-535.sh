#!/bin/bash
# Установка рабочего драйвера NVIDIA для P106M.
#
# Единственная ветка, которая поднимает эту карту — 535.x (Linux-аналог
# Windows-драйвера 532). Ветки 580+ падают с:
#     NVRM: RmInitAdapter failed! (0x23:0xffff:1587)
#
# Запуск: sudo ./scripts/install-nvidia-535.sh
#
# ⚠️ Скрипт НЕ ПРЕРЫВАТЬ. Обрыв записи файлов (перезагрузка, Ctrl-C) оставляет
#    файлы нулевого размера, включая /usr/lib/x86_64-linux-gnu/libOpenCL.so.1 —
#    после этого перестают запускаться любые приложения, линкующиеся с OpenCL.

set -uo pipefail

VER="535.309.01"
FILE="NVIDIA-Linux-x86_64-${VER}.run"
URL="https://download.nvidia.com/XFree86/Linux-x86_64/${VER}/${FILE}"
WORK="/tmp/nvidia-${VER}"
SRC="$(dirname "$(readlink -f "$0")")/../config"

if [ "$(id -u)" != "0" ]; then
    echo "Запускать через sudo." >&2
    exit 1
fi

echo "==> 1/6  Выгружаю модули NVIDIA (иначе установщик откажется работать)"
if lsmod | grep -qE '^nvidia'; then
    echo "    Занятые устройства /dev/nvidia*:"
    fuser -v /dev/nvidia* 2>&1 | sed 's/^/      /'
    echo "    (частый виновник — системный монитор «Resources»)"
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if lsmod | grep -q "^$m "; then
            rmmod "$m" 2>/dev/null && echo "    $m выгружен" || echo "    $m НЕ выгружен"
        fi
    done
fi
if lsmod | grep -qE '^nvidia'; then
    echo
    echo "!! Модули всё ещё загружены. Закрой программы, держащие /dev/nvidia*," >&2
    echo "   и повтори. Ставить поверх загруженных модулей нельзя." >&2
    exit 1
fi

echo "==> 2/6  Зависимости сборки"
apt-get update -qq
apt-get install -y dkms "linux-headers-$(uname -r)"

echo "==> 3/6  Установщик драйвера"
mkdir -p "$WORK" && cd "$WORK" || exit 1
if [ ! -f "$FILE" ]; then
    wget -O "$FILE" "$URL" || { echo "Не скачалось: $URL" >&2; exit 1; }
fi
echo "    (сборка модулей занимает несколько минут — НЕ ПРЕРЫВАТЬ)"
sh "$FILE" --no-x-check --dkms --no-install-compat32-libs --silent || {
    echo "!! Установка не удалась. Лог: /var/log/nvidia-installer.log" >&2
    exit 1
}

echo "==> 4/6  Свежий egl-wayland из репозитория"
# КРИТИЧНО для оффлоада на Wayland: установщик кладёт свою версию 1.1.11,
# с которой нативные Wayland-клиенты падают с 'eglGetPlatformDisplayEXT failed!'
apt-get install -y libnvidia-egl-wayland1

echo "==> 5/6  Запрещаю nouveau, включаю modeset"
install -m 644 "$SRC/blacklist-nouveau.conf"  /etc/modprobe.d/
install -m 644 "$SRC/zz-nvidia-modeset.conf"  /etc/modprobe.d/
update-initramfs -u
depmod -a

echo "==> 6/6  Запрещаю apt трогать драйвер"
install -m 644 "$SRC/nvidia-535-manual.pref" /etc/apt/preferences.d/

echo
echo "Версия:  $(modinfo -F version /lib/modules/"$(uname -r)"/updates/dkms/nvidia.ko 2>/dev/null || echo '(проверить после перезагрузки)')"
echo "DKMS:    $(dkms status | grep nvidia || echo 'нет записи')"
echo
echo "ГОТОВО. Дальше — ПОЛНОЕ выключение (poweroff), не reboot:"
echo "    sudo poweroff"
echo
echo "После включения проверить:  ./scripts/verify.sh"
