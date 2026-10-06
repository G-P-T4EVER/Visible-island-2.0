# Как получить .deb, имея только айфон

Mac не нужен. Компьютер вообще не нужен. Ниже два пути — первый рабочий
практически всегда, второй только для джейлбрейкнутого устройства.

---

## Путь A — GitHub Actions прямо из Safari (рекомендуется)

Сборку делает бесплатный macOS-раннер GitHub. С телефона нужен только браузер.
Время: ~10 минут, из них 6–8 ждёшь.

### Шаг 1. Репозиторий

1. `github.com` в Safari → войти / зарегистрироваться.
2. Кнопка **+** справа сверху → **New repository**.
3. Имя любое, например `visibleisland`.
4. Видимость — **Public**.
   Для публичных репозиториев macOS-раннеры бесплатны и без лимита минут.
   Для приватных macOS тарифицируется 10× и бесплатная квота кончится быстро.
5. **Create repository**.

### Шаг 2. Залить архив

1. **Add file** → **Upload files**.
2. **choose your files** → приложение «Файлы» → выбрать `VisibleIsland-2.0.zip`.
3. **Commit changes**.

Папку целиком с iOS залить нельзя — Safari умеет отдавать только файлы.
Поэтому заливается именно zip, а воркфлоу распакует его сам.

### Шаг 3. Создать воркфлоу

1. **Add file** → **Create new file**.
2. В поле имени вписать ровно: `.github/workflows/build.yml`
   Слэши автоматически создадут папки — так и должно быть.
3. Вставить содержимое `.github/workflows/build-from-zip.yml` из архива.
4. **Commit changes**.

### Шаг 4. Забрать .deb

Сборка стартует сама сразу после коммита (`on: push`), жать ничего не надо.

1. Вкладка **Actions** → верхний (последний) запуск.
2. Дождаться зелёной галочки, ~6–8 минут.
3. Внизу страницы запуска блок **Artifacts** → **visibleisland-deb** → тап,
   файл уедет в «Загрузки».
4. «Файлы» → «Загрузки» → тап по скачанному zip → он распакуется в папку.

Внутри два пакета:

| Файл | Для чего |
|---|---|
| `com.sa1nt.visibleisland_2.0.0_iphoneos-arm64.deb` | **rootless**: Dopamine 1.x/2.x, palera1n rootless |
| `com.sa1nt.visibleisland_2.0.0_iphoneos-arm.deb` | **rootful**: checkra1n, unc0ver, palera1n rootful |

Взять нужно **один**, под свой джейлбрейк. Не тот встанет без ошибок, но твик
не подхватится: пути `/var/jb/Library/MobileSubstrate/...` и
`/Library/MobileSubstrate/...` не совпадают.

### Шаг 5. Установить

**Через Sileo:** «Файлы» → долгий тап по `.deb` → **Поделиться** → **Sileo** →
**Install**. Sileo сам сделает respring.

**Через Filza:** переложить `.deb` в `/var/mobile/Documents` → тап → **Install**.

**Через терминал** (NewTerm):
```sh
sudo dpkg -i /var/mobile/Downloads/com.sa1nt.visibleisland_2.0.0_iphoneos-arm64.deb
sudo sbreload
```

После respring: **Настройки → VisibleIsland** → включить, выбрать медиафайл.

---

## Путь B — сборка прямо на устройстве

Работает только на джейлбрейкнутом айфоне с bootstrap Procursus
(Dopamine, palera1n). Нужен терминал — **NewTerm 3** из Chariz/Havoc.

Честное предупреждение: займёт ~2–3 ГБ на диске и 20–40 минут, на устройствах
с 3 ГБ RAM clang может улететь по Jetsam на середине компиляции. Путь A проще.

```sh
# 1. Тулчейн из Procursus
sudo apt update
sudo apt install -y clang ldid make git perl curl unzip dpkg \
                    coreutils findutils grep sed gawk tar gzip xz-utils

# 2. Theos
export THEOS=/var/mobile/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# 3. Один SDK вместо всего репозитория (иначе ~20 ГБ)
git clone -n --depth 1 --filter=tree:0 https://github.com/theos/sdks.git /tmp/sdks
cd /tmp/sdks
git sparse-checkout set --no-cone 'iPhoneOS16.5.sdk'
git checkout
mkdir -p $THEOS/sdks && cp -R /tmp/sdks/*.sdk $THEOS/sdks/

# 4. Исходники
cd /var/mobile
unzip ~/Downloads/VisibleIsland-2.0.zip
cd VisibleIsland

# 5. Сборка и установка
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
sudo dpkg -i packages/*.deb
sudo sbreload
```

Чтобы `export THEOS` не пропадал после перезапуска терминала:
```sh
echo 'export THEOS=/var/mobile/theos' >> ~/.zshrc
```

---

## Если сборка упала

Вкладка **Actions** → красный запуск → тап по упавшему шагу → раскроется лог.
Важны последние 20–30 строк, где `error:`. Скинь их — поправлю исходники.

Типичные причины и что делать:

| Симптом в логе | Причина | Решение |
|---|---|---|
| `Unable to find any SDKs` | не докачался SDK | заменить `iPhoneOS16.5.sdk` на `iPhoneOS17.5.sdk` в шаге Fetch |
| `theos/makefiles/common.mk: No such file` | `$THEOS` не проставился | проверить блок `env:` в начале воркфлоу |
| `ldid: command not found` | brew не поставил ldid | добавить `brew install ldid` отдельным шагом без `|| true` |
| `no such file or directory: packages` | не нашёлся Makefile | архив залит не в корень репозитория |
| Actions вкладки нет | воркфлоу лежит не по тому пути | путь строго `.github/workflows/build.yml` |
