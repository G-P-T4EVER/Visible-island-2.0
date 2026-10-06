#import "VIWindowManager.h"
#import "VIIslandView.h"
#import "VIActivity.h"
#import "VIActivityCenter.h"
#import "VIPresets.h"
#import "VIPrefs.h"
#import "VIPaths.h"

#pragma mark - VIWindow

@implementation VIWindow

// ── Touch transparency ───────────────────────────────────────
// UIKit asks the top-most window first. Returning NO from pointInside: makes
// the whole event walk straight past us to SpringBoard's own windows — status
// bar taps, Control Center pulls and notification swipes keep working.
// Only the *live* island rectangles claim the event.

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    VIIslandContainerView *island = self.islandContainer;
    if (!island || island.hidden || island.alpha < 0.02) return NO;
    if (!island.userInteractionEnabled) return NO;

    CGPoint local = [island convertPoint:point fromView:self];
    return [island pointIsInsideInteractiveArea:local];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self pointInside:point withEvent:event]) return nil;

    UIView *hit = [super hitTest:point withEvent:event];
    // Never return the window or the root view itself: that would swallow the
    // touch without any target and still block the system UI underneath.
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

// ── Keep the window out of SpringBoard's rotation / boundary pipeline ───────
// Private UIKit entry point: when a window opts out of the boundary tracker it
// is not considered for interface-orientation arbitration, so the island cannot
// force SpringBoard to re-evaluate rotation, and we never inherit a rotated
// transform behind our back.
- (BOOL)_shouldCreateScreenWithBoundaryTracker { return NO; }

- (BOOL)_canBecomeKeyWindow          { return NO; }
- (BOOL)canBecomeFirstResponder      { return NO; }

@end

#pragma mark - VIRootViewController

@implementation VIRootViewController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.userInteractionEnabled = YES;
    self.view = view;
}

- (BOOL)prefersStatusBarHidden                          { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle             { return UIStatusBarStyleLightContent; }
- (BOOL)prefersHomeIndicatorAutoHidden                  { return NO; }
- (BOOL)shouldAutorotate                                { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeNone; }

@end

#pragma mark - VIWindowManager

@interface VIWindowManager ()
@property (nonatomic, strong, nullable) VIWindow *window;
@property (nonatomic, strong, nullable) VIIslandContainerView *island;
@property (nonatomic, assign) VISuspendReason suspendReasons;
@property (nonatomic, assign, getter=isBootstrapped) BOOL bootstrapped;
@property (nonatomic, weak, nullable) UIWindowScene *boundScene;
@end

@implementation VIWindowManager {
    BOOL     _expanded;            // user (or an activity tap) opened the card
    NSTimer *_autoCollapseTimer;
}

+ (instancetype)sharedManager {
    static VIWindowManager *shared = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _suspendReasons = VISuspendReasonNone;
        [self _registerObservers];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_autoCollapseTimer invalidate];
}

#pragma mark - Bootstrap / teardown

- (void)bootstrap {
    NSAssert(NSThread.isMainThread, @"VisibleIsland: bootstrap must run on the main thread");
    if (self.bootstrapped) return;

    if ([VIPresets deviceShouldBeSkipped]) {
        VILog(@"device has a native Dynamic Island (or is not an iPhone) — standing down");
        return;
    }
    if (!VIPrefs.shared.enabled) {
        self.suspendReasons |= VISuspendReasonUserDisabled;
        VILog(@"disabled in preferences");
        return;
    }

    self.bootstrapped = YES;
    [self _createWindowIfNeeded];
    [self applyPreferences];

    // Start the event pipeline last, so the very first callback already has a
    // window and a laid-out island to draw into.
    VIActivityCenter *center = [VIActivityCenter sharedCenter];
    center.delegate = self;
    [center start];

    VILog(@"bootstrapped on %@ (rootless=%d)", [VIPresets machineIdentifier], VIIsRootless());
}

- (void)teardown {
    VIActivityCenter *center = [VIActivityCenter sharedCenter];
    if (center.delegate == self) center.delegate = nil;
    [center stop];

    [self _cancelAutoCollapse];
    _expanded = NO;

    [self.island prepareForTeardown];      // stops CADisplayLink / AVPlayer
    self.island.delegate = nil;
    self.island = nil;

    self.window.islandContainer = nil;
    self.window.rootViewController = nil;
    self.window.hidden = YES;
    self.window = nil;
    self.boundScene = nil;
    self.bootstrapped = NO;
    VILog(@"torn down");
}

#pragma mark - Window construction

- (void)_createWindowIfNeeded {
    if (self.window) return;

    CGRect bounds = UIScreen.mainScreen.bounds;
    VIWindow *window = nil;

    if (@available(iOS 16.0, *)) {
        // iOS 16/17: an unparented window is not guaranteed to be rendered and
        // UIKit logs a hard warning. Bind explicitly to SpringBoard's active
        // foreground scene.
        UIWindowScene *scene = [self _activeWindowScene];
        if (scene) {
            window = [[VIWindow alloc] initWithWindowScene:scene];
            window.frame = scene.coordinateSpace.bounds;
            self.boundScene = scene;
        }
    }

    if (!window) {
        // iOS 14–15 (and the 16+ fallback if the scene is not up yet).
        window = [[VIWindow alloc] initWithFrame:bounds];
    }

    window.windowLevel                        = UIWindowLevelStatusBar + 100;
    window.backgroundColor                    = UIColor.clearColor;
    window.opaque                             = NO;
    window.userInteractionEnabled             = YES;
    window.rootViewController                 = [[VIRootViewController alloc] init];
    window.layer.allowsGroupOpacity           = NO;

    if ([window respondsToSelector:@selector(_setWindowControlsStatusBarOrientation:)]) {
        [window _setWindowControlsStatusBarOrientation:NO];
    }
    if ([window respondsToSelector:@selector(_setSecure:)]) {
        [window _setSecure:NO];    // let the island appear in screenshots
    }

    VIIslandContainerView *island = [[VIIslandContainerView alloc] initWithFrame:CGRectZero];
    island.delegate = self;
    [window.rootViewController.view addSubview:island];

    window.islandContainer = island;
    self.island = island;
    self.window = window;

    // makeKeyAndVisible would steal key status from SpringBoard — never do it.
    window.hidden = NO;

    // If the scene was not ready at launch, retry binding once the first scene
    // connects (cold boot ordering on 16/17).
    if (@available(iOS 16.0, *)) {
        if (!self.boundScene) [self _scheduleSceneRebind];
    }
}

- (nullable UIWindowScene *)_activeWindowScene {
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
        UIWindowScene *fallback = nil;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
            if (!fallback) fallback = windowScene;
        }
        return fallback;
    }
    return nil;
}

- (void)_scheduleSceneRebind {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.boundScene || !strongSelf.window) return;
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = [strongSelf _activeWindowScene];
            if (!scene) return;
            strongSelf.window.windowScene = scene;
            strongSelf.boundScene = scene;
            [strongSelf _layoutIsland];
            VILog(@"late scene rebind succeeded");
        }
    });
}

#pragma mark - Preferences / layout

- (void)applyPreferences {
    [VIPrefs.shared reload];

    if (!VIPrefs.shared.enabled) {
        self.suspendReasons |= VISuspendReasonUserDisabled;
        [self teardown];
        return;
    }

    self.suspendReasons &= ~VISuspendReasonUserDisabled;
    if (!self.bootstrapped) { [self bootstrap]; return; }

    [self _createWindowIfNeeded];
    [self _layoutIsland];
    [self.island applyPreferences];

    // Per-kind switches may have changed; the center re-resolves and calls back.
    [[VIActivityCenter sharedCenter] applyPreferences];

    [self _updateSuspensionState];
}

- (void)_layoutIsland {
    if (!self.window || !self.island) return;

    CGRect bounds = self.window.bounds;
    VIIslandGeometry geometry = [VIPresets effectiveGeometry];

    // The container spans the full width at the island's Y band; the three
    // modules are laid out inside it. Height covers the tallest module plus the
    // expansion headroom so CASpringAnimation overshoot is never clipped.
    CGFloat bandHeight = [VIIslandContainerView bandHeightForGeometry:geometry];
    self.island.frame = CGRectMake(0.0, geometry.originY, CGRectGetWidth(bounds), bandHeight);
    [self.island applyGeometry:geometry containerWidth:CGRectGetWidth(bounds)];
}

#pragma mark - Observers

- (void)_registerObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center addObserver:self
               selector:@selector(handleOrientationChange)
                   name:UIApplicationDidChangeStatusBarOrientationNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(handleOrientationChange)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(handleMemoryPressure)
                   name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];

    if (@available(iOS 13.0, *)) {
        [center addObserver:self
                   selector:@selector(_sceneDidDisconnect:)
                       name:UISceneDidDisconnectNotification
                     object:nil];
    }
}

- (void)_sceneDidDisconnect:(NSNotification *)note {
    if (@available(iOS 13.0, *)) {
        if (note.object != self.boundScene) return;
        VILog(@"bound scene disconnected — rebinding");
        self.boundScene = nil;
        [self _scheduleSceneRebind];
    }
}

#pragma mark - VIActivityCenterDelegate

- (void)activityCenterDidUpdateActivities:(VIActivityCenter *)center {
    if (!self.island) return;

    [self.island applyCenterActivity:center.centerActivity
                     leadingActivity:center.leadingActivity
                         leadingRole:center.leadingRole
                    trailingActivity:center.trailingActivity
                        trailingRole:center.trailingRole
                            animated:YES];

    // Nothing left to show → the expanded card has no reason to stay open.
    if (!center.hasActivity && _expanded) {
        _expanded = NO;
        [self _cancelAutoCollapse];
    }

    [self _refreshIslandStateAnimated:YES];
}

#pragma mark - VIIslandContainerViewDelegate

- (void)islandContainer:(VIIslandContainerView *)container didTapSlot:(VIActivitySlot)slot {
    VIActivity *activity = [container activityForSlot:slot];
    VIPrefs *prefs = VIPrefs.shared;

    // Satellites are transport controls when they carry a controllable activity.
    if (slot != VIActivitySlotCenter && prefs.satelliteActions && activity) {
        VIActivityAction action = [self _actionForActivity:activity slot:slot];
        if (action != VIActivityActionNone) {
            [[VIActivityCenter sharedCenter] performAction:action];
            [self _pulseModuleForSlot:slot];
            [self _armAutoCollapseIfNeeded];
            return;
        }
    }

    if (!prefs.tapToExpand) {
        // Expansion is off: the centre tap still drives the primary action.
        VIActivityAction action = activity ? activity.tapAction : VIActivityActionNone;
        if (action != VIActivityActionNone) {
            [[VIActivityCenter sharedCenter] performAction:action];
            [self _pulseModuleForSlot:slot];
        }
        return;
    }

    _expanded = !_expanded;
    [self _refreshIslandStateAnimated:YES];
    [self _armAutoCollapseIfNeeded];
}

- (VIActivityAction)_actionForActivity:(VIActivity *)activity slot:(VIActivitySlot)slot {
    if (activity.tapAction != VIActivityActionNone && slot == VIActivitySlotLeading) {
        return activity.tapAction;
    }
    // Now Playing gets a transport pair: left = play/pause, right = skip.
    if (activity.kind == VIActivityKindNowPlaying) {
        return (slot == VIActivitySlotTrailing) ? VIActivityActionNextTrack
                                                : VIActivityActionTogglePlayPause;
    }
    return activity.tapAction;
}

// Small confirmation bounce, so a transport tap never feels like a dead press.
- (void)_pulseModuleForSlot:(VIActivitySlot)slot {
    VIIslandModuleView *module = nil;
    switch (slot) {
        case VIActivitySlotLeading:  module = self.island.leadingBubble;  break;
        case VIActivitySlotTrailing: module = self.island.trailingBubble; break;
        case VIActivitySlotCenter:   module = self.island.centerPill;     break;
    }
    if (!module) return;

    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pulse.values   = @[ @1.0, @0.88, @1.04, @1.0 ];
    pulse.keyTimes = @[ @0.0, @0.25, @0.65, @1.0 ];
    pulse.duration = 0.28;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [module.layer addAnimation:pulse forKey:@"vi.pulse"];
}

#pragma mark - Auto-collapse

- (void)_armAutoCollapseIfNeeded {
    [self _cancelAutoCollapse];
    if (!_expanded) return;

    __weak typeof(self) weakSelf = self;
    _autoCollapseTimer =
        [NSTimer scheduledTimerWithTimeInterval:VIPrefs.shared.activityAutoCollapseDelay
                                        repeats:NO
                                          block:^(NSTimer *timer) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_expanded = NO;
            strongSelf->_autoCollapseTimer = nil;
            [strongSelf _refreshIslandStateAnimated:YES];
        }];
}

- (void)_cancelAutoCollapse {
    [_autoCollapseTimer invalidate];
    _autoCollapseTimer = nil;
}

#pragma mark - Screen state

- (void)handleOrientationChange {
    if (!self.window) return;

    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    if (@available(iOS 13.0, *)) {
        orientation = self.boundScene ? self.boundScene.interfaceOrientation
                                      : UIApplication.sharedApplication.statusBarOrientation;
    } else {
        orientation = UIApplication.sharedApplication.statusBarOrientation;
    }

    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);

    // The window itself stays portrait (it opted out of rotation tracking), so
    // the only work here is: either hide, or recompute the frame against the
    // rotated reference bounds.
    if (landscape && VIPrefs.shared.hideInLandscape) {
        self.suspendReasons |= VISuspendReasonLandscape;
    } else {
        self.suspendReasons &= ~VISuspendReasonLandscape;
        CGRect reference = UIScreen.mainScreen.bounds;
        if (landscape) {
            // Keep the island pinned to the physical top edge (where the notch
            // is) rather than the rotated logical top.
            reference = CGRectMake(0, 0,
                                   MIN(reference.size.width, reference.size.height),
                                   MAX(reference.size.width, reference.size.height));
        }
        self.window.frame = reference;
        [self _layoutIsland];
    }

    [self _updateSuspensionState];
}

- (void)setScreenOn:(BOOL)on {
    VISuspendReason before = self.suspendReasons;
    if (on) self.suspendReasons &= ~VISuspendReasonScreenOff;
    else    self.suspendReasons |=  VISuspendReasonScreenOff;
    if (before != self.suspendReasons) [self _updateSuspensionState];
}

- (void)setCoverSheetPresented:(BOOL)presented {
    VISuspendReason before = self.suspendReasons;
    // Media always pauses behind the cover sheet; the island is only *hidden*
    // if the user asked for it.
    if (presented) self.suspendReasons |=  VISuspendReasonCoverSheet;
    else           self.suspendReasons &= ~VISuspendReasonCoverSheet;
    if (before != self.suspendReasons) [self _updateSuspensionState];
}

- (void)handleMemoryPressure {
    VILog(@"memory warning — shedding decode caches");
    [self.island handleMemoryPressure];
}

- (void)_updateSuspensionState {
    VISuspendReason reasons = self.suspendReasons;

    BOOL shouldPause = (reasons & (VISuspendReasonScreenOff |
                                   VISuspendReasonCoverSheet |
                                   VISuspendReasonLandscape |
                                   VISuspendReasonMemory |
                                   VISuspendReasonUserDisabled)) != 0;

    self.island.playbackSuspended = shouldPause;

    // With the screen off there is nobody to inform: stop polling MediaRemote
    // and let every non-sticky activity lapse instead of burning wakeups.
    BOOL centerAsleep = (reasons & (VISuspendReasonScreenOff | VISuspendReasonUserDisabled)) != 0;
    [VIActivityCenter sharedCenter].suspended = centerAsleep;

    [self _refreshIslandStateAnimated:!shouldPause];

    VILog(@"suspension mask=0x%lx pause=%d", (unsigned long)reasons, shouldPause);
}

#pragma mark - State policy

- (void)_refreshIslandStateAnimated:(BOOL)animated {
    if (!self.island) return;

    VISuspendReason reasons = self.suspendReasons;
    BOOL shouldHide = (reasons & (VISuspendReasonLandscape | VISuspendReasonUserDisabled)) != 0;
    if ((reasons & VISuspendReasonCoverSheet) && VIPrefs.shared.hideOnCoverSheet) shouldHide = YES;

    VIIslandState state;
    if (shouldHide) {
        state = VIIslandStateHidden;
        _expanded = NO;
        [self _cancelAutoCollapse];
    } else if (_expanded) {
        state = VIIslandStateExpanded;
    } else if (self.island.hasActivity) {
        state = VIIslandStateActivity;
    } else {
        state = VIIslandStateIdle;
    }

    self.window.hidden = shouldHide;
    [self.island setIslandState:state animated:(animated && !shouldHide)];
}

@end
