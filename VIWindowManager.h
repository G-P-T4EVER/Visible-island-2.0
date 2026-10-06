//
//  VIWindowManager.h
//  Owns the dedicated status-bar-level UIWindow, every screen-state signal, and
//  the policy that turns activities into island states.
//
//  Design contract:
//    • The tweak NEVER adds a view into SpringBoard's status bar hierarchy.
//      SBStatusBar rebuilds its subviews on style/orientation changes, which is
//      exactly why the legacy build lost its plate (and leaked views) after a
//      rotation or a Control Center swipe.
//    • Exactly one window, one root view controller, one island container.
//    • The window is fully transparent to touches outside the live island rects.
//    • VIActivityCenter decides *what* is happening, this class decides what the
//      island should look like because of it, VIIslandContainerView draws it.
//

#import <UIKit/UIKit.h>
#import "Headers.h"
#import "VIIslandView.h"
#import "VIActivityCenter.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Window

/// UIWindow subclass with pass-through hit testing.
@interface VIWindow : UIWindow
/// Interactive island container; nil until the manager attaches it.
@property (nonatomic, weak, nullable) VIIslandContainerView *islandContainer;
@end

#pragma mark - Root view controller

/// Chrome-free host: no status bar, no home-indicator interference,
/// portrait-locked so SpringBoard's rotation never re-lays out the island.
@interface VIRootViewController : UIViewController
@end

#pragma mark - Manager

@interface VIWindowManager : NSObject <VIActivityCenterDelegate, VIIslandContainerViewDelegate>

+ (instancetype)sharedManager;

@property (nonatomic, readonly, nullable) VIWindow *window;
@property (nonatomic, readonly, nullable) VIIslandContainerView *island;

/// Current suspension bitmask (VISuspendReason). Non-zero → media paused.
@property (nonatomic, readonly) VISuspendReason suspendReasons;

/// Called once from the SpringBoard launch hook. Idempotent.
- (void)bootstrap;

/// Full teardown: invalidates the media engine, stops the activity center,
/// drops the window, releases the scene reference. Safe to call from a
/// low-memory handler.
- (void)teardown;

/// Re-reads prefs, re-resolves the hardware preset and re-applies geometry and
/// media. Called on the prefsChanged Darwin notification.
- (void)applyPreferences;

#pragma mark Screen state (driven from Tweak.x)
- (void)setScreenOn:(BOOL)on;
- (void)setCoverSheetPresented:(BOOL)presented;
- (void)handleOrientationChange;
- (void)handleMemoryPressure;

@end

NS_ASSUME_NONNULL_END
