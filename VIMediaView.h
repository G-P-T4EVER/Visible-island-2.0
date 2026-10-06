//
//  VIMediaView.h
//  Media engine (VIMediaEngine role) hosted inside CenterPill.
//
//  Two back-ends, one lifecycle:
//
//    .mp4  → AVQueuePlayer + AVPlayerLooper + AVPlayerLayer
//            Gapless looping without an AVPlayerItemDidPlayToEndTime seek
//            round-trip. Muted, no audio session touched, display-sleep
//            prevention disabled (critical inside SpringBoard).
//
//    .gif  → CGImageSourceRef opened ONCE with kCGImageSourceShouldCache = NO,
//            frames pulled one at a time by a CADisplayLink and handed to
//            layer.contents. Frame delays are read from metadata only.
//            The full frame array is NEVER materialised: a 400-frame GIF via
//            +[UIImage animatedImageWithImages:] costs 200–600 MB in
//            SpringBoard's address space and gets the whole process Jetsam'd.
//            Decoding happens on a serial background queue with a strict
//            one-frame look-ahead and CGImageSourceCreateThumbnailAtIndex
//            downsampling to the pill's pixel size.
//
//  Suspension: setting `suspended = YES` pauses the player / stops the display
//  link and releases the in-flight frame. Nothing decodes while the screen is
//  off or the cover sheet is up.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "Headers.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VIMediaFillMode) {
    VIMediaFillModeAspectFill = 0,
    VIMediaFillModeAspectFit,
};

@interface VIMediaView : UIView

@property (nonatomic, readonly) VIMediaKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *mediaPath;

@property (nonatomic, assign) VIMediaFillMode fillMode;

/// 0 = follow the file's own frame delays. Otherwise an upper FPS bound; the
/// engine also clamps to the display's maximumFramesPerSecond.
@property (nonatomic, assign) CGFloat frameRateCap;

/// YES stops all decoding immediately (screen off, cover sheet, landscape).
@property (nonatomic, assign, getter=isSuspended) BOOL suspended;

/// Loads media. Pass nil to clear. `forcedKind` = VIMediaKindNone → auto-detect
/// from the file's magic bytes, falling back to the extension.
- (void)loadMediaAtPath:(nullable NSString *)path forcedKind:(VIMediaKind)forcedKind;

/// Drops the pending decoded frame and re-opens the source at a smaller
/// thumbnail size. Called on UIApplicationDidReceiveMemoryWarning.
- (void)shedDecodeResources;

/// Full stop: invalidates the CADisplayLink, removes the looper/observers,
/// releases the CGImageSourceRef. MUST be called before the view is dropped.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
