//
//  VIActivity.h
//  VisibleIsland 2.0 — activity model.
//
//  An "activity" is one live piece of system state the island is allowed to
//  present: the now-playing track, a charging event, the ringer switch, the
//  volume level, Low Power Mode, a lock/unlock transition.
//
//  Sources build these objects and hand them to VIActivityCenter; the island
//  only ever renders what the center resolved. Activities are IMMUTABLE by
//  design — a source publishes a brand new object instead of mutating a live
//  one, so a render pass can diff two snapshots cheaply and can never observe
//  a half-updated activity while SpringBoard is mid-transaction.
//

#import <UIKit/UIKit.h>
#import "Headers.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VIActivityKind) {
    VIActivityKindNone = 0,
    VIActivityKindNowPlaying,
    VIActivityKindCharging,
    VIActivityKindRinger,
    VIActivityKindVolume,
    VIActivityKindLowPower,
    VIActivityKindLockState,
};

/// Which module a resolved activity is being rendered into.
typedef NS_ENUM(NSUInteger, VIActivitySlot) {
    VIActivitySlotCenter = 0,
    VIActivitySlotLeading,
    VIActivitySlotTrailing,
};

/// How a satellite should draw an activity.
///   Glyph     → symbol or artwork (identity of the activity)
///   Accessory → equalizer / progress ring (live state of the activity)
typedef NS_ENUM(NSUInteger, VIActivityRole) {
    VIActivityRoleGlyph = 0,
    VIActivityRoleAccessory,
};

typedef NS_ENUM(NSUInteger, VIActivityAction) {
    VIActivityActionNone = 0,
    VIActivityActionTogglePlayPause,
    VIActivityActionNextTrack,
    VIActivityActionPreviousTrack,
};

#pragma mark - Model

@interface VIActivity : NSObject <NSCopying>

@property (nonatomic, readonly) VIActivityKind kind;

/// Higher priority wins the center pill. Ties break on publication order.
@property (nonatomic, readonly) NSInteger priority;

@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;

/// SF Symbol name, used whenever `artwork` is nil.
@property (nonatomic, readonly, copy, nullable) NSString *symbolName;

/// Album art or any bitmap the source supplies. Already downsampled by the
/// source — the island never receives a full-resolution image.
@property (nonatomic, readonly, strong, nullable) UIImage *artwork;

@property (nonatomic, readonly, strong) UIColor *tint;

/// 0…1 for a determinate ring/bar. Negative means "no progress to show".
@property (nonatomic, readonly) CGFloat progress;

/// YES → the accessory slot animates an equalizer instead of a static glyph.
@property (nonatomic, readonly) BOOL showsEqualizer;

/// Sticky activities live until their source retires them (music playing).
/// Transient ones self-retire at `expiry` (volume, ringer, charging).
@property (nonatomic, readonly, getter=isSticky) BOOL sticky;

/// Absolute deadline on the NSDate reference clock. Ignored when sticky.
@property (nonatomic, readonly) NSTimeInterval expiry;

@property (nonatomic, readonly) VIActivityAction tapAction;

+ (instancetype)activityWithKind:(VIActivityKind)kind
                        priority:(NSInteger)priority
                           title:(nullable NSString *)title
                        subtitle:(nullable NSString *)subtitle
                      symbolName:(nullable NSString *)symbolName
                         artwork:(nullable UIImage *)artwork
                            tint:(nullable UIColor *)tint
                        progress:(CGFloat)progress
                  showsEqualizer:(BOOL)showsEqualizer
                          sticky:(BOOL)sticky
                        lifetime:(NSTimeInterval)lifetime
                       tapAction:(VIActivityAction)tapAction;

/// YES when two snapshots would render identically. Guards against relayout
/// storms: MediaRemote re-posts now-playing info several times per track.
- (BOOL)isVisuallyEqualToActivity:(nullable VIActivity *)other;

/// YES once the reference clock passed `expiry`. Always NO while sticky.
- (BOOL)isExpiredAtTime:(NSTimeInterval)now;

/// Human-readable kind, for logs and the debug row in Settings.
- (NSString *)kindDescription;

@end

NS_ASSUME_NONNULL_END
