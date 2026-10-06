include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VisibleIslandPrefs

VisibleIslandPrefs_FILES = \
	RootListController.m \
	VIBlurHeaderCell.m \
	VIStepSliderCell.m \
	../VIPaths.m \
	../VIPresets.m \
	../VIPrefs.m

VisibleIslandPrefs_INSTALL_PATH = /Library/PreferenceBundles
VisibleIslandPrefs_CFLAGS  = -fobjc-arc -fobjc-arc-exceptions -I../
VisibleIslandPrefs_CFLAGS += -Wno-deprecated-declarations
# UniformTypeIdentifiers must be linked explicitly: RootListController references
# UTTypeGIF/UTTypeMPEG/... directly, and without the framework the bundle fails
# at link time with undefined symbols rather than at compile time.
VisibleIslandPrefs_FRAMEWORKS = UIKit CoreGraphics QuartzCore AVFoundation ImageIO MobileCoreServices UniformTypeIdentifiers
VisibleIslandPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/VisibleIsland.plist"$(ECHO_END)
