//
//  Tweak.x
//  VisibleIsland 2.0 — entry point ONLY.
//
//  Everything this file is allowed to do:
//    1. Start the window manager once SpringBoard has finished launching.
//    2. Translate SpringBoard/IOKit state changes into manager calls.
//    3. Listen for preference notifications.
//
//  No layout, no media, no geometry math — those live in their own services.
//

#import "Headers.h"
#import "VIWindowManager.h"
#import "VIPrefs.h"
#import "VIPresets.h"
#import "VIPaths.h"
#import <notify.h>

#pragma mark - Helpers

static inline void VIOnMain(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - Darwin notification callbacks

static void VIPrefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    VIOnMain(^{
        VILog(@"prefsChanged");
        [[VIWindowManager sharedManager] applyPreferences];
    });
}

static void VIReloadCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    VIOnMain(^{
        VIWindowManager *manager = [VIWindowManager sharedManager];
        [manager teardown];
        [manager bootstrap];
    });
}

// IOKit HID display status: the authoritative screen-on/off signal. Hooks on
// SBBacklightController are kept as a belt-and-braces fallback because the
// selector set changes between 14.x and 17.x.
// Darwin notifications never carry a userInfo payload: the 0/1 value lives in
// the notify state of the name itself and has to be read back explicitly.
static void VIDisplayStatusCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    uint64_t state = 0;
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(VI_NOTIF_DISPLAY_STATUS, &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    BOOL screenOn = (state != 0);
    VIOnMain(^{ [[VIWindowManager sharedManager] setScreenOn:screenOn]; });
}

static void VIScreenBlankedCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    VIOnMain(^{ [[VIWindowManager sharedManager] setScreenOn:NO]; });
}

static void VIRegisterNotifications(void) {
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(darwin, NULL, VIPrefsChangedCallback,
                                    CFSTR(VI_NOTIF_PREFS_CHANGED), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    CFNotificationCenterAddObserver(darwin, NULL, VIPrefsChangedCallback,
                                    CFSTR(VI_NOTIF_MEDIA_CHANGED), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    CFNotificationCenterAddObserver(darwin, NULL, VIReloadCallback,
                                    CFSTR(VI_NOTIF_RELOAD), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    CFNotificationCenterAddObserver(darwin, NULL, VIDisplayStatusCallback,
                                    CFSTR(VI_NOTIF_DISPLAY_STATUS), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(darwin, NULL, VIScreenBlankedCallback,
                                    CFSTR(VI_NOTIF_SCREEN_BLANKED), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

#pragma mark - SpringBoard launch

%group VICore

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;

    // One turn of the run loop: the first UIWindowScene is not guaranteed to be
    // connected inside applicationDidFinishLaunching on iOS 16/17.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VIWindowManager sharedManager] bootstrap];
    });
}

- (void)frontDisplayDidChange:(id)display {
    %orig;
    // App switches can reshuffle window levels; re-assert the island's geometry.
    [[VIWindowManager sharedManager] handleOrientationChange];
}

%end

#pragma mark - Cover sheet (lock screen / Notification Center)

%hook SBCoverSheetPresentationManager

- (void)_finishTransitionToPresented:(BOOL)presented withEvent:(id)event {
    %orig;
    [[VIWindowManager sharedManager] setCoverSheetPresented:presented];
}

%end

%end // group VICore

#pragma mark - Backlight fallbacks

%group VIBacklightFactor

%hook SBBacklightController

- (void)setBacklightFactor:(float)factor source:(long long)source {
    %orig;
    [[VIWindowManager sharedManager] setScreenOn:(factor > 0.0f)];
}

%end

%end

%group VIBacklightFade

%hook SBBacklightController

- (void)_startFadeOutAnimationToBacklightFactor:(float)factor duration:(double)duration source:(long long)source {
    %orig;
    [[VIWindowManager sharedManager] setScreenOn:(factor > 0.0f)];
}

%end

%end

#pragma mark - Cover sheet fallback (older setPresented: only builds)

%group VICoverSheetLegacy

%hook SBCoverSheetPresentationManager

- (void)setPresented:(BOOL)presented {
    %orig;
    [[VIWindowManager sharedManager] setCoverSheetPresented:presented];
}

%end

%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        // The filter plist already scopes us to SpringBoard, but a stray
        // DYLD_INSERT_LIBRARIES must never take down another process.
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;

        if (![VIPrefs.shared enabled]) {
            VILog(@"disabled — only the preference listener will be installed");
            VIRegisterNotifications();
            return;
        }

        if ([VIPresets deviceShouldBeSkipped]) {
            VILog(@"unsupported device (%@) — not installing hooks", [VIPresets machineIdentifier]);
            VIRegisterNotifications();
            return;
        }

        %init(VICore);

        // Hook-based activity sources (ringer switch). Notification-based ones
        // are wired up by VIActivityCenter when the manager starts it.
        VIActivitySourcesInstall();

        Class backlight = objc_getClass("SBBacklightController");
        if ([backlight instancesRespondToSelector:@selector(setBacklightFactor:source:)]) {
            %init(VIBacklightFactor);
        }
        if ([backlight instancesRespondToSelector:@selector(_startFadeOutAnimationToBacklightFactor:duration:source:)]) {
            %init(VIBacklightFade);
        }

        Class coverSheet = objc_getClass("SBCoverSheetPresentationManager");
        if (![coverSheet instancesRespondToSelector:@selector(_finishTransitionToPresented:withEvent:)] &&
             [coverSheet instancesRespondToSelector:@selector(setPresented:)]) {
            %init(VICoverSheetLegacy);
        }

        VIRegisterNotifications();

        VILog(@"loaded %@ on %@ (rootless=%d, jbroot=%@)",
              VI_TWEAK_VERSION, [VIPresets machineIdentifier], VIIsRootless(), VIJBRootPrefix());
    }
}
