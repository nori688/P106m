# P106M на Ubuntu: рабочий драйвер + обои Wallpaper Engine на дискретной видеокарте

Личные заметки по оживлению NVIDIA P106M (GP106, ноутбук с Intel N95) в Ubuntu 26.04
и по переносу рендера обоев Wallpaper Engine на дискретную графику.

Всё ниже проверено на живой системе. Документ писался по факту, включая тупики —
чтобы не проходить их второй раз.

---

## TL;DR

| Что | Результат |
|---|---|
| Рабочий драйвер | **535.309.01** (DKMS, ставится вручную через `.run`) |
| Не рабочий драйвер | 580 / 595 / 610 — карта не инициализируется |
| Вывод картинки | Только через Intel. У карты нет видеовыходов (`3D controller`) |
| Оффлоад рендера | **Работает** через `__NV_PRIME_RENDER_OFFLOAD` + dma-buf (Wayland) |
| Обои | Рендерятся на P106M, композиция на Intel. Работает, автозапуск настроен |

---

## Железо и система

| | |
|---|---|
| CPU | Intel N95 (4 ядра, Alder Lake-N) |
| Встроенная графика | Intel UHD (ADL-N, 16 EU) — **она выводит картинку** |
| Дискретная | NVIDIA P106M (GP106, `10de:1c36`), 4 ГБ VRAM, **без видеовыходов** |
| PCIe-порт карты | `00:1d.0`, физически **x2** (`LnkCap: 8GT/s, x2`) |
| PCIe-линк фактически | `LnkSta: 2.5GT/s x2` — Gen1 вместо Gen3 |
| Экран | eDP-1, 1920x1080 |
| ОС | Ubuntu 26.04, GNOME Shell 50.1, **Wayland**, ядро 7.0.0-30-generic |
| Secure Boot | выключен (DKMS-модуль не требует подписи) |

**Почему `x2` — это не баг:** так распаяно, порт физически на 2 линии. А вот скорость
упала до Gen1 — карта просто не тренирует выше. Из софта не лечится, проверялось:
отключение ASPM через `setpci`, принудительная цель Gen3 в `LnkCtl2`, переинициализация
шины (`remove` + `rescan`) — линк остаётся `2.5GT/s x2`.

**Но линк не приговор:** `x2 Gen1` ≈ 700 МБ/с реальных. Кадр 1080p весит 8.3 МБ, при
60 fps это 500 МБ/с. Поэтому Windows на этом же железе тянет Elden Ring 30 fps и
Ведьмак 3 на средних 50 fps — в линк укладывается.

---

## Часть 1. Драйвер NVIDIA

### Почему 580 не работает, а 535 работает

Windows-нумерация и Linux-нумерация у NVIDIA **не совпадают**:

- Windows-ветка **532** (R535) = Linux-ветка **535.xxx**
- В Linux версии `532` **не существует вообще**, ветки идут `530 → 535 → 545 → 550 → …`

Симптом неработающего 580:

```
NVRM: GPU 0000:03:00.0: RmInitAdapter failed! (0x23:0xffff:1587)
NVRM: GPU 0000:03:00.0: rm_init_adapter failed, device minor number 0
→ nvidia-smi: No devices were found
```

Модуль к устройству **привязывается** (`Kernel driver in use: nvidia`), карта в `lspci`
видна — но чип не инициализируется. На 535.309.01 поднимается сразу, без вопросов.

`535` — это LTS-ветка, её до сих пор обновляют (актуальные версии: `535.247.01`,
`535.261.03`, `535.274.02`, `535.288.01`, `535.309.01`). Она **собирается с ядром 7.0
без единой правки** — проверено.

### Установка

```bash
sudo ./scripts/install-nvidia-535.sh
```

Скрипт делает всё, что нужно; вручную те же шаги:

1. **Убедиться, что модули NVIDIA не загружены.** Иначе установщик откажется работать.
   ```bash
   lsmod | grep nvidia
   sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
   ```
   ⚠️ Если `rmmod` ругается «in use» — смотри, кто держит `/dev/nvidia*`:
   ```bash
   sudo fuser -v /dev/nvidia*
   ```
   В моём случае это был системный монитор **«Resources»** (`/usr/libexec/resources/resources-processes`).
   Он открывает устройства карты просто для отображения загрузки и блокирует выгрузку модуля.

2. **Загрузить установщик:**
   ```bash
   wget https://download.nvidia.com/XFree86/Linux-x86_64/535.309.01/NVIDIA-Linux-x86_64-535.309.01.run
   ```

3. **Установить** (нужен `dkms` и `linux-headers-$(uname -r)`):
   ```bash
   sudo sh NVIDIA-Linux-x86_64-535.309.01.run \
        --no-x-check --dkms --no-install-compat32-libs --silent
   ```
   `--no-x-check` — можно ставить, не выходя из графической сессии: модуль всё равно
   вступит в силу после перезагрузки.

4. **Заблокировать nouveau и включить modeset** (`config/` → `/etc/modprobe.d/`):
   ```bash
   sudo cp config/blacklist-nouveau.conf config/zz-nvidia-modeset.conf /etc/modprobe.d/
   sudo update-initramfs -u
   ```

5. **Перезагрузиться.**

### ⚠️ Два способа сломать всё на этом этапе

1. **Перезагрузиться во время установки.** Установщик пишет файлы несколько минут;
   если прервать — остаются файлы **нулевого размера** (`nvidia.ko`, `nvidia-smi`,
   и что хуже — `libOpenCL.so.1`), и система начинает сыпаться на любом приложении,
   которое линкуется с OpenCL. Проверка на такие файлы есть в `scripts/verify.sh`.
2. **Дать apt поставить свой драйвер.** `ubuntu-drivers install` или
   unattended-upgrade притащат 580 и снова «потеряют» карту.
   Защита — `config/nvidia-535-manual.pref` → `/etc/apt/preferences.d/`.

### Проверка

```bash
nvidia-smi
cat /proc/driver/nvidia/version
nvidia-smi --query-gpu=name,clocks.sm,clocks.max.sm,pstate --format=csv
```

Ожидаемо: `NVIDIA Graphics Device`, `535.309.01`, в простое `P8 / 139 МГц`,
максимум `1290 МГц`, 4096 МиБ.

---

## Часть 2. Оффлоад рендера на дискретку

У карты нет видеовыходов, поэтому любой её кадр надо доставить на Intel. Путей два,
и они **очень разные по скорости**:

| Путь | Как | Результат 1080p |
|---|---|---|
| GLX / X11 (`__GLX_VENDOR_LIBRARY_NAME=nvidia`) | кадр идёт через системную память | **2 FPS** — не годится |
| **Wayland / EGL + dma-buf** | кадр передаётся по ссылке, без копирования | **работает** |

### Критичная деталь, из-за которой Wayland-оффлоад сначала не работал

Установщик NVIDIA кладёт свою версию `libnvidia-egl-wayland.so.1` — **1.1.11**.
С ней любой нативный Wayland-клиент с оффлоадом падает:

```
eglGetPlatformDisplayEXT failed!
```

Лечится установкой системного (более нового) пакета:

```bash
sudo apt-get install -y libnvidia-egl-wayland1     # 1:1.1.21-1
```

⚠️ После этого нельзя ставить `libnvidia-egl-wayland1` в apt-запрет. В
`config/nvidia-535-manual.pref` он перечислен отдельно и **не** заблокирован.

### Условия, без которых оффлоад не заработает

1. `options nvidia-drm modeset=1` — обязательно для Wayland (`config/zz-nvidia-modeset.conf`).
2. Переменные `__NV_PRIME_RENDER_OFFLOAD=1` и
   `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json`.

Проверка:

```bash
# GLX-путь (X11/XWayland) — должен показать NVIDIA
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B | grep renderer
```

### Измерения

glmark2 Wayland, 800×600, `-b duration=3`:

| Сцена | P106M | Intel UHD |
|---|---|---|
| terrain (тяжёлая) | **310** | 196 |
| buffer map | 303 | 375 |
| jellyfish | 620 | 2127 |
| **Общий балл** | **575** | **1692** |

glmark2 **off-screen** (без вывода на экран, то есть чистая мощность чипа):

| Сцена | P106M | Intel UHD |
|---|---|---|
| terrain | **476** | 196 |
| jellyfish | **11353** | — |
| **Общий балл** | **4019** | 1692 |

**Как это читать.** В обычном режиме дискретка проигрывает, потому что упирается не в
чип, а в **доставку кадра**: почти все лёгкие сцены выдают ровно ~645 FPS (1.55 мс на
кадр) — это потолок передачи по линку, а не предел GPU. Встроенная выводит картинку
сама, поэтому разгоняется до 2900.

В off-screen потолок исчезает, и дискретка обходит встроенную в **2.4 раза**.
Практический вывод: **дискретка выигрывает там, где узкое место — сам чип**, и не даёт
ничего, где упор в вывод. Для обоев на 30 fps (60-герцовый монитор) потолок не
включается вообще — по линку надо 250 МБ/с.

---

## Часть 3. Обои Wallpaper Engine

### Почему нельзя просто запустить linux-wallpaperengine

Рендерер на GNOME Wayland падает:

```
Failed to bind to required interfaces
```

Mutter **не реализует `wlr-layer-shell`**, на который движок опирается для фоновой
поверхности. X11-режим тоже мимо: он рисует в root-пиксмап, а под GNOME его не видно.

### Рабочая схема

```
linux-wallpaperengine (форк, режим --gnome)
     │  рендерит в обычное xdg-shell окно
     ▼
GNOME Shell расширение linux-wallpaperengine@github.io
     │  клонирует это окно в слой обоев
     ▼
рабочий стол
```

Использовались:

- Рендерер: **форк `kv9898/linux-wallpaperengine`, ветка `gnome`** (это важно — в
  апстриме Almamu режима `--gnome` нет).
- Расширение + 3 патча к рендереру: **`Fitz8863/wallpaper-engine-gnome`**.
- Сборка: `cmake -DCMAKE_BUILD_TYPE=Release .. && make -j$(nproc)`, CEF качается
  автоматически (~370 МБ).

Патчи касаются: запроса fullscreen на целевом выходе (иначе Mutter обрезает окно по
рабочей области и обои мылятся), вырезания `import` в layer-скриптах, и сравнения
аспектов вместо сырых размеров в `DefaultUVs`.

### Установка расширения

```bash
ln -s <путь>/gnome-extension ~/.local/share/gnome-shell/extensions/linux-wallpaperengine@github.io
gsettings set org.gnome.shell enabled-extensions "$(gsettings get org.gnome.shell enabled-extensions | sed "s/]$/, 'linux-wallpaperengine@github.io']/")"
```

**После этого нужен выход из сессии и вход заново** — на Wayland GNOME Shell не
подхватывает новые расширения на лету. Проверялось: `ReloadExtension` в GNOME 50 не
реализован, `org.gnome.Shell.Eval` выключен (unsafe mode).

### Ассеты и обои без Steam

Проект ищет контент в путях Steam. Steam нет — подсовываем через совместимую раскладку:

- ассеты: симлинк `~/.local/share/Steam/steamapps/common/wallpaper_engine/assets`
  → реальная папка с `assets`
- папка с обоями: ключ `workshop` в `~/.cache/wallpaper-picker/settings.json`
  (тогда рендереру отдаётся полный путь, а не ID)

Если раздел с обоями лежит на NTFS рядом с Windows и папка внутри **OneDrive** —
`ntfs-3g` не развернёт reparse point. Нужен драйвер ядра:

```bash
sudo mount -t ntfs3 -o ro,uid=1000,gid=1000 /dev/sda3 /mnt/win
```

### Оффлоад обоев на дискретку

Рендерер вызывается через обёртку (`config/linux-wallpaperengine`), которая кладётся
рядом с бинарником; сам бинарник переименовывается в `linux-wallpaperengine.real`.
Обёртка выставляет переменные оффлоада **только если карта реально доступна** —
иначе тихо работает на встроенной.

Что это даёт на тяжёлой сцене 1080p:

| | Рендер на Intel | Рендер на P106M |
|---|---|---|
| Intel Render/3D | 99% | 66% (только композиция) |
| Мощность пакета | 5.72 Вт | **1.79 Вт** |
| Дискретка | простаивает | 1290 МГц, ~52%, 783 МиБ, 51 °C |

CPU самого рендерера при оффлоаде выше (≈64% одного ядра против ≈8%) — кадры
перегоняются по линку. По сумме (мощность, температура, свобода встроенной графики)
выигрыш явный.

---

## Файлы репозитория

| Файл | Куда класть |
|---|---|
| `scripts/install-nvidia-535.sh` | запускать как `sudo`, ставит драйвер с нуля |
| `scripts/verify.sh` | диагностика: проверяет всю цепочку |
| `config/nvidia-535-manual.pref` | `/etc/apt/preferences.d/` — запрет для apt |
| `config/blacklist-nouveau.conf` | `/etc/modprobe.d/` |
| `config/zz-nvidia-modeset.conf` | `/etc/modprobe.d/` |
| `config/linux-wallpaperengine` | рядом с бинарником рендерера (обёртка оффлоада) |
| `config/wallpaper-engine.desktop` | `~/.config/autostart/` |
| `config/settings.json` | `~/.cache/wallpaper-picker/` |

Бинарники и архивы в репозиторий не положены — установщик драйвера 350 МБ, сборка
рендерера с CEF ~1.5 ГБ. Всё восстанавливается по ссылкам и версиям выше.

---

## Грабли, на которые я наступил

1. **`reboot` вместо `poweroff`.** Карта не теряет питание и остаётся в кривом
   состоянии. Если после установки драйвера карта не поднялась — сначала попробовать
   полное выключение, а не перезагрузку.
2. **Прерванная установка драйвера** → файлы нулевого размера, в том числе
   `libOpenCL.so.1` в системном пути. Ломает всё, что линкуется с OpenCL.
3. **Старый `libnvidia-egl-wayland` из `.run`** → `eglGetPlatformDisplayEXT failed`
   и оффлоад на Wayland не работает. Нужен системный пакет.
4. **`nvidia-driver-535` в Ubuntu 26.04 — пустышка**, которая ставит 580. Реальной 535
   в репозитории нет, только `.run` с сайта NVIDIA.
5. **Монитор «Resources»** держит `/dev/nvidia*` и не даёт выгрузить модуль.
6. **`pkill -f 'linux-wallpaperengine'`** убивает собственную команду, если строка
   совпала. Останавливать обои по PID из
   `~/.cache/wallpaper-picker/wallpaper.pid`.
7. **`dpkg -S` / `apt-cache policy`** — при пине с маской `libnvidia-*` под запрет
   попадает и `libnvidia-egl-wayland1`, который нужен рабочему драйверу. Поэтому в
   `.pref` пакеты перечислены поимённо.

---

## Проверка состояния

```bash
./scripts/verify.sh
```

Скрипт проверяет: драйвер и его версию, флаг `dirty` у PCIe-линка, наличие
нулевых файлов, блокировку nouveau, `egl-wayland`, apt-пин, доступность оффлоада
и запущен ли рендер обоев на дискретной карте.
