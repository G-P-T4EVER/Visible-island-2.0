//
//  VIIslandView.h
//  Three-section island container.
//
//      [ LeadingBubble ]  gap  [ ====== CenterPill ====== ]  gap  [ TrailingBubble ]
//         glyph slot                media / activity card              accessory slot
//
//  Each module is an independent subview with its own spring animation, so a
//  satellite can appear/disappear without re-laying out the pill or restarting
//  media playback.
//
//  The container renders; it never decides *what* to render. VIActivityCenter
//  resolves which activity owns which module, the window manager forwards that
//  decision here, and taps travel back out through the delegate. That split is
//  the whole reason 1.x was a dead rectangle: it had a renderer and no source.
//

#import <UIKit/UIKit.h>
#import "Headers.h"
#import "VIPresets.h"
#import "VIActivity.h"

@class VIMediaView;
@class VIIslandContainerView;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Delegate

@protocol VIIslandContainerViewDelegate <NSObject>
/// A module was tapped. The manager decides what that means (expand, play/pause,
/// skip) so the view stays free of policy.
- (void)islandContainer:(VIIslandContainerView *)container didTapSlot:(VIActivitySlot)slot;
@end

#pragma mark - Module

/// Base module: continuous-curve rounded rect, clipped, non-opaque.
@interface VIIslandModuleView : UIView
@property (nonatomic, assign) CGFloat moduleCornerRadius;
/// Animates frame + cornerRadius with a critically-tuned CASpringAnimation.
- (void)setModuleFrame:(CGRect)frame cornerRadius:(CGFloat)radius animated:(BOOL)animated;
@end

#pragma mark - Container

@interface VIIslandContainerView : UIView

@property (nonatomic, weak, nullable) id<VIIslandContainerViewDelegate> delegate;

@property (nonatomic, readonly) VIIslandModuleView *centerPill;
@property (nonatomic, readonly) VIIslandModuleView *leadingBubble;
@property (nonatomic, readonly) VIIslandModuleView *trailingBubble;
@property (nonatomic, readonly) VIMediaView *mediaView;

@property (nonatomic, readonly) VIIslandState islandState;

/// YES while at least one activity is being presented.
@property (nonatomic, readonly) BOOL hasActivity;

/// Forwarded to the media engine and to the equalizer layers. YES stops all
/// decoding and freezes every repeating animation immediately.
@property (nonatomic, assign) BOOL playbackSuspended;

/// Vertical room the container needs: the tallest module plus expansion
/// headroom plus spring overshoot.
+ (CGFloat)bandHeightForGeometry:(VIIslandGeometry)geometry;

/// Applies a preset (plus the user's trims) and recomputes module frames.
- (void)applyGeometry:(VIIslandGeometry)geometry containerWidth:(CGFloat)width;

/// Re-reads VIPrefs: media path, satellite visibility, fill mode.
- (void)applyPreferences;

- (void)setIslandState:(VIIslandState)state animated:(BOOL)animated;

/// Pushes the resolved activities into the three modules. Passing nil for all
/// three returns the island to a bare pill.
- (void)applyCenterActivity:(nullable VIActivity *)center
            leadingActivity:(nullable VIActivity *)leading
                leadingRole:(VIActivityRole)leadingRole
           trailingActivity:(nullable VIActivity *)trailing
               trailingRole:(VIActivityRole)trailingRole
                   animated:(BOOL)animated;

/// The activity currently occupying a module, if any.
- (nullable VIActivity *)activityForSlot:(VIActivitySlot)slot;

/// Hit-test support for VIWindow: YES only inside a visible module's rect
/// (plus a small touch-slop), so the rest of the window stays transparent.
- (BOOL)pointIsInsideInteractiveArea:(CGPoint)point;

- (void)handleMemoryPressure;

/// Stops timers/players and releases decode resources. Call before dropping.
- (void)prepareForTeardown;

@end

NS_ASSUME_NONNULL_END
