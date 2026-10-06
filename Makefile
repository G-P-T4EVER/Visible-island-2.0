# ─────────────────────────────────────────────────────────────────────────────
#  VisibleIsland 2.0 — modular three-section Dynamic Island for A9–A15 devices
#
#  Build matrix:
#     make rootless        → Dopamine 1.x/2.x, palera1n rootless  (iphoneos-arm64)
#     make rootful         → checkra1n/unc0ver/palera1n rootful   (iphoneos-arm)
#     make both            → both .deb packages into ./packages
#
#  ARC is enabled for every compilation unit. Logos files (.x) are ARC-safe
#  because %orig/%new bodies are compiled as ordinary ObjC methods.
# ─────────────────────────────────────────────────────────────────────────────

export THEOS_PACKAGE_SCHEME ?= rootless
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:14.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VisibleIsland

VisibleIsland_FILES = \
	Tweak.x \
	VIActivitySources.x \
	VIPaths.m \
	VIPrefs.m \
	VIPresets.m \
	VIActivity.m \
	VIActivityCenter.m \
	VIActivityContentView.m \
	VIWindowManager.m \
	VIIslandView.m \
	VIMediaView.m

# -fobjc-arc            : ARC for the whole tweak (no manual retain/release)
# -fobjc-arc-exceptions : keeps ARC bookkeeping correct if a SpringBoard hook throws
VisibleIsland_CFLAGS  = -fobjc-arc -fobjc-arc-exceptions
VisibleIsland_CFLAGS += -Wall -Wno-deprecated-declarations -Wno-unused-variable
VisibleIsland_CFLAGS += -DVI_TWEAK_VERSION='@"2.0.0"'

# Compile-time knowledge of the packaging scheme. Runtime detection in
# VIPaths.m always wins — the tweak stays functional if the deb is repacked.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
VisibleIsland_CFLAGS += -DVI_ROOTLESS=1
else
VisibleIsland_CFLAGS += -DVI_ROOTLESS=0
endif

VisibleIsland_FRAMEWORKS = UIKit CoreGraphics QuartzCore AVFoundation CoreMedia ImageIO
VisibleIsland_LIBRARIES  = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += visibleislandprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: rootful rootless both

rootful:
	@$(MAKE) clean
	@$(MAKE) package THEOS_PACKAGE_SCHEME= FINALPACKAGE=1

rootless:
	@$(MAKE) clean
	@$(MAKE) package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1

both: rootful rootless

after-install::
	install.exec "killall -9 SpringBoard"
