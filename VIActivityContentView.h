//
//  VIActivityContentView.h
//  VisibleIsland 2.0 — what actually gets drawn inside the three modules.
//
//  Two renderers, deliberately kept dumb: they own no state beyond the last
//  activity they were handed, they never talk to VIPrefs, and every animation
//  they run can be frozen with a single `paused` flag when the screen goes off.
//

#import <UIKit/UIKit.h>
#import "VIActivity.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Satellite content

/// Fills a satellite bubble. Draws either the activity's identity (artwork or
/// SF Symbol) or its live accessory (equalizer bars / progress ring), according
/// to the role the activity center assigned to that slot.
@interface VIActivityGlyphView : UIView

- (void)applyActivity:(nullable VIActivity *)activity
                 role:(VIActivityRole)role
             animated:(BOOL)animated;

/// Freezes the equalizer without tearing the layers down, so waking the screen
/// resumes mid-beat instead of restarting the animation.
@property (nonatomic, assign, getter=isPaused) BOOL paused;

- (void)shedResources;

@end

#pragma mark - Expanded pill content

/// Fills the center pill once it grows: artwork, title, subtitle, and either a
/// determinate progress bar or an equalizer.
@interface VIActivityDetailView : UIView

- (void)applyActivity:(nullable VIActivity *)activity animated:(BOOL)animated;

@property (nonatomic, assign, getter=isPaused) BOOL paused;

/// Intrinsic width the card wants at this height. The island clamps the result
/// to the screen width minus its own margins.
- (CGFloat)preferredWidthForHeight:(CGFloat)height;

- (void)shedResources;

@end

NS_ASSUME_NONNULL_END
