//
//  Headers.h
//  VisibleIsland 2.0
//
//  Every private interface the tweak touches, declared in one place.
//  Nothing here is imported from a private SDK — the declarations are
//  hand-written so the project builds against a stock iPhoneOS SDK.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Identifiers

#define VI_BUNDLE_ID              @"com.sa1nt.visibleisland"
#define VI_PREFS_PLIST_NAME       @"com.sa1nt.visibleisland.plist"
#define VI_NOTIF_PREFS_CHANGED    "com.sa1nt.visibleisland/prefsChanged"
#define VI_NOTIF_MEDIA_CHANGED    "com.sa1nt.visibleisland/mediaChanged"
#define VI_NOTIF_RELOAD           "com.sa1nt.visibleisland/reload"

// IOKit HID display status — the cheapest, most reliable screen-on/off signal
// available to a SpringBoard-injected dylib. state 0 = off, 1 = on.
#define VI_NOTIF_DISPLAY_STATUS   "com.apple.iokit.hid.displayStatus"
#define VI_NOTIF_SCREEN_BLANKED   "com.apple.springboard.hasBlankedScreen"

#pragma mark - Logging

#ifdef DEBUG
    #define VILog(fmt, ...) NSLog((@"[VisibleIsland] " fmt), ##__VA_ARGS__)
#else
    #define VILog(fmt, ...) do {} while (0)
#endif

#pragma mark - SpringBoard

@interface SpringBoard : UIApplication
- (long long)activeInterfaceOrientation;
- (void)_relaunchSpringBoardNow;
@end

// Backlight state. Selector availability drifts between 14.x and 17.x, so the
// tweak hooks defensively (see Tweak.x) and treats Darwin notifications as the
// primary source of truth.
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly) BOOL screenIsOn;
- (BOOL)screenIsOn;
- (void)setBacklightFactor:(float)factor source:(long long)source;
- (void)_startFadeOutAnimationToBacklightFactor:(float)factor duration:(double)duration source:(long long)source;
@end

// Lock screen / Notification Center presentation.
@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@property (nonatomic, readonly, getter=isPresented) BOOL presented;
- (void)_finishTransitionToPresented:(BOOL)presented withEvent:(id)event;
- (void)setPresented:(BOOL)presented;
@end

@interface SBOrientationLockManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUserLocked;
@end

@interface SBWindowScene : UIWindowScene
@end

@interface SBMainDisplaySceneManager : NSObject
+ (instancetype)sharedInstance;
@end

@interface SBIconController : UIViewController
+ (instancetype)sharedInstance;
@end

#pragma mark - Activity sources

// Ringer switch. The owning class moved between firmwares, so both variants
// are declared here and probed at runtime in VIActivitySources.x.
@interface SBRingerControl : NSObject
+ (instancetype)sharedInstance;
- (void)setRingerMuted:(BOOL)muted;
- (BOOL)ringerMuted;
@end

@interface SBRingerHUDController : NSObject
+ (instancetype)sharedInstance;
- (void)presentRingerHUDForVolume:(float)volume mute:(BOOL)mute;
@end

// Queried after the com.apple.springboard.lockstate Darwin notification.
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (id)nowPlayingApplication;
@end

#pragma mark - UIKit private surface

@interface UIWindow (VIPrivate)
// Keeps the window out of the screen-boundary/rotation tracking pipeline so it
// never fights SpringBoard for interface orientation. Overridden in VIWindow.
- (BOOL)_shouldCreateScreenWithBoundaryTracker;
- (void)_setSecure:(BOOL)secure;
- (void)_setWindowControlsStatusBarOrientation:(BOOL)controls;
@end

@interface UIApplication (VIPrivate)
- (long long)statusBarOrientation;
- (UIWindow *)statusBarWindow;
@end

@interface UIScreen (VIPrivate)
- (CGRect)_referenceBounds;
@end

#pragma mark - Shared enums

typedef NS_ENUM(NSUInteger, VIMediaKind) {
    VIMediaKindNone = 0,
    VIMediaKindGIF,
    VIMediaKindMP4,
    VIMediaKindStaticImage,
};

typedef NS_ENUM(NSUInteger, VIIslandState) {
    VIIslandStateHidden = 0,   // fully collapsed, nothing painted
    VIIslandStateIdle,         // center pill only
    VIIslandStateActivity,     // center pill + both satellites
    VIIslandStateExpanded,     // center pill grown, satellites tucked behind
};

// Installs the hook-based activity sources. Implemented in
// VIActivitySources.x; called once from the SpringBoard launch hook.
extern void VIActivitySourcesInstall(void);

typedef NS_ENUM(NSUInteger, VISuspendReason) {
    VISuspendReasonNone         = 0,
    VISuspendReasonScreenOff    = 1 << 0,
    VISuspendReasonCoverSheet   = 1 << 1,
    VISuspendReasonLandscape    = 1 << 2,
    VISuspendReasonMemory       = 1 << 3,
    VISuspendReasonUserDisabled = 1 << 4,
};

NS_ASSUME_NONNULL_END
