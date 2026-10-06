//
//  VIPrefs.h
//  Single source of truth for settings. Immutable snapshot object rebuilt on
//  every Darwin notification, so no consumer ever reads a half-written plist.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Headers.h"

NS_ASSUME_NONNULL_BEGIN

@interface VIPrefs : NSObject

+ (instancetype)shared;

/// Re-reads the plist. Cheap; called from the prefsChanged notification.
- (void)reload;

#pragma mark Master
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL hideInLandscape;
@property (nonatomic, readonly) BOOL hideOnCoverSheet;
@property (nonatomic, readonly) BOOL pauseWhenScreenOff;   // always honoured, exposed for UI
/// Keeps both satellites on screen even with nothing happening (the old 1.x
/// static look). Activities pop the satellites out regardless of this switch.
@property (nonatomic, readonly) BOOL satellitesEnabled;
@property (nonatomic, readonly) BOOL tapToExpand;

#pragma mark Activities
/// Master switch for the whole event pipeline. Off = a purely decorative pill.
@property (nonatomic, readonly) BOOL activitiesEnabled;
@property (nonatomic, readonly) BOOL activityNowPlaying;
@property (nonatomic, readonly) BOOL activityCharging;
@property (nonatomic, readonly) BOOL activityRinger;
@property (nonatomic, readonly) BOOL activityVolume;
@property (nonatomic, readonly) BOOL activityLowPower;
@property (nonatomic, readonly) BOOL activityLockState;
/// Left satellite = play/pause, right satellite = next track.
@property (nonatomic, readonly) BOOL satelliteActions;
/// Seconds the expanded card stays open before springing shut.
@property (nonatomic, readonly) CGFloat activityAutoCollapseDelay;

#pragma mark Media
@property (nonatomic, readonly, copy, nullable) NSString *mediaPath;
@property (nonatomic, readonly) VIMediaKind forcedMediaKind;    // None = auto-detect by extension/UTI
@property (nonatomic, readonly) CGFloat     gifFrameRateCap;    // 0 = follow the file's own timing
@property (nonatomic, readonly) BOOL        mediaFillsPill;     // aspect-fill vs aspect-fit

#pragma mark Geometry (manual trim, 0.5 pt steps, applied on top of the preset)
@property (nonatomic, readonly) CGFloat offsetX;
@property (nonatomic, readonly) CGFloat offsetY;
@property (nonatomic, readonly) CGFloat widthDelta;
@property (nonatomic, readonly) CGFloat heightDelta;
@property (nonatomic, readonly) CGFloat cornerRadiusDelta;
@property (nonatomic, readonly) CGFloat bubbleDiameterDelta;
@property (nonatomic, readonly) CGFloat moduleGapDelta;

#pragma mark Hardware override
/// Non-nil forces a specific hw.machine preset instead of the auto-detected one.
@property (nonatomic, readonly, copy, nullable) NSString *presetOverrideIdentifier;

NS_ASSUME_NONNULL_END

@end
