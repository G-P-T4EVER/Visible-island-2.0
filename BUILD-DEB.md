# Как получить готовый .deb

Исходники компилируются в `.deb` только там, где есть **iPhoneOS SDK + Theos +
clang с таргетом `arm64-apple-ios`**. Ниже три рабочих пути — от самого простого
к самому контролируемому.

---

## Вариант 1 — GitHub Actions (без Mac, ничего локально ставить не надо)

В проекте лежит готовый workflow `.github/workflows/build.yml`.

1. Создай репозиторий на GitHub (можно приватный).
2. Залей туда содержимое этой папки:
   ```bash
   cd VisibleIsland
   git init -b main
   git add .
   git commit -m "VisibleIsland 2.0"
   git remote add origin git@github.com:<user>/VisibleIsland.git
   git push -u origin main
   ```
3. Вкладка **Actions** → workflow **Build VisibleIsland** → **Run workflow**.
4. Через ~5–8 минут в разделе **Artifacts** появится `visibleisland-deb`
   с двумя файлами:
   ```
   com.sa1nt.visibleisland_2.0.0_iphoneos-arm64.deb   ← Dopamine / palera1n rootless
   com.sa1nt.visibleisland_2.0.0_iphoneos-arm.deb     ← checkra1n / unc0ver rootful
   ```

Workflow собирает обе схемы двумя джобами: основная на `macos-14` (там
iPhoneOS SDK идёт с Xcode), дублирующая на `ubuntu-latest` через
`install-theos`.

---

## Вариант 2 — локально, одной командой

```bash
# один раз: поставить Theos (macOS или Linux)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"

# private-заголовки SpringBoard / Preferences
git clone --depth 1 https://github.com/theos/sdks.git
cp -r sdks/*.sdk $THEOS/sdks/

# сборка
cd VisibleIsland
chmod +x build.sh
./build.sh                  # оба .deb → ./packages
./build.sh rootless         # только rootless
./build.sh install 10.0.0.5 # собрать, поставить по SSH и сделать respring
```

`build.sh` проверяет `$THEOS`, наличие `ldid` и SDK, и понятно ругается, если
чего-то не хватает.

---

## Вариант 3 — вручную

```bash
export THEOS=~/theos

make clean && make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
make clean && make package THEOS_PACKAGE_SCHEME=      FINALPACKAGE=1
```

---

## Установка на устройство

```bash
scp packages/com.sa1nt.visibleisland_2.0.0_iphoneos-arm64.deb mobile@<ip>:/tmp/
ssh mobile@<ip> 'sudo dpkg -i /tmp/com.sa1nt.visibleisland_2.0.0_iphoneos-arm64.deb && sudo sbreload'
```

Или просто открыть `.deb` в Sileo / Zebra прямо на устройстве.

**Важно:** не перепутай схему. Rootless-пакет (`iphoneos-arm64`) на rootful
джейлбрейке установится, но твик не подхватится — и наоборот.

---

## Проверка после установки

```bash
# твик загрузился в SpringBoard?
ssh mobile@<ip> 'grep -i visibleisland /var/log/syslog | tail -20'

# rootless: файлы на месте?
ssh mobile@<ip> 'ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/VisibleIsland.*'

# rootful:
ssh mobile@<ip> 'ls -l /Library/MobileSubstrate/DynamicLibraries/VisibleIsland.*'
```

DEBUG-сборка (`make package DEBUG=1`) пишет в syslog строки вида
`[VisibleIsland] loaded 2.0.0 on iPhone12,3 (rootless=1, jbroot=/var/jb)` —
по ним сразу видно, определилась ли модель и правильно ли найден jbroot.
