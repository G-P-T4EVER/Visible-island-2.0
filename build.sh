#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  VisibleIsland 2.0 — локальная сборка .deb
#
#  Требования:
#    macOS : Xcode CLT + Theos + ldid          (brew install ldid xz)
#    Linux : Theos с swift-toolchain + iPhoneOS SDK
#
#  Установка Theos, если его нет:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
#
#  Использование:
#    ./build.sh                 # оба .deb (rootless + rootful) → ./packages
#    ./build.sh rootless        # только rootless
#    ./build.sh rootful         # только rootful
#    ./build.sh install 10.0.0.5  # собрать rootless, поставить на устройство и сделать respring
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
die()  { echo "${RED}error:${RST} $*" >&2; exit 1; }
info() { echo "${GRN}==>${RST} $*"; }
warn() { echo "${YLW}warn:${RST} $*" >&2; }

# ── Проверка окружения ──────────────────────────────────────────────────────
: "${THEOS:=$HOME/theos}"
export THEOS

[[ -d "$THEOS" ]] || die "Theos не найден в \$THEOS ($THEOS).
Установи: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)\""

[[ -f "$THEOS/makefiles/common.mk" ]] || die "\$THEOS указывает не на Theos: $THEOS"

if [[ "$(uname -s)" == "Darwin" ]]; then
  command -v xcrun >/dev/null || die "нужны Xcode Command Line Tools: xcode-select --install"
fi
command -v ldid >/dev/null || warn "ldid не найден — Theos не сможет подписать бинарник (brew install ldid)"

SDK_COUNT=$(find "$THEOS/sdks" -maxdepth 1 -name 'iPhoneOS*.sdk' 2>/dev/null | wc -l | tr -d ' ')
[[ "$SDK_COUNT" -gt 0 ]] || warn "в \$THEOS/sdks нет iPhoneOS SDK — private-заголовки SpringBoard могут не найтись.
      git clone --depth 1 https://github.com/theos/sdks.git && cp -r sdks/*.sdk \$THEOS/sdks/"

cd "$(dirname "$0")"

# ── Сборка ──────────────────────────────────────────────────────────────────
build_scheme() {
  local scheme="$1" label="$2"
  info "сборка: $label"
  make clean >/dev/null
  make package THEOS_PACKAGE_SCHEME="$scheme" FINALPACKAGE=1
}

TARGET="${1:-both}"

case "$TARGET" in
  rootless) build_scheme rootless "rootless (Dopamine / palera1n)" ;;
  rootful)  build_scheme ""       "rootful (checkra1n / unc0ver)"  ;;
  both)
    build_scheme rootless "rootless (Dopamine / palera1n)"
    build_scheme ""       "rootful (checkra1n / unc0ver)"
    ;;
  install)
    IP="${2:-}"
    [[ -n "$IP" ]] || die "укажи IP устройства: ./build.sh install 10.0.0.5"
    info "сборка + установка на $IP"
    make clean >/dev/null
    make do THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 THEOS_DEVICE_IP="$IP"
    exit 0
    ;;
  *) die "неизвестная цель: $TARGET (rootless | rootful | both | install <ip>)" ;;
esac

# ── Итог ────────────────────────────────────────────────────────────────────
echo
info "готовые пакеты:"
ls -lh packages/*.deb 2>/dev/null || die "packages/ пуст — сборка не дошла до упаковки"

echo
cat <<'EOF'
Установка на устройство:
  scp packages/*.deb mobile@<ip>:/tmp/
  ssh mobile@<ip> 'sudo dpkg -i /tmp/*.deb && sudo sbreload'

Или просто открой .deb в Sileo / Zebra на самом устройстве.
EOF
