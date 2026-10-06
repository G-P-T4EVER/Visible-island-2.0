#import "VIMediaView.h"
#import "VIPaths.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

#pragma mark - Weak display-link proxy

// CADisplayLink retains its target. A direct `self` target would keep the view
// (and therefore the whole island + window) alive forever — the single most
// common leak in island-style tweaks. The proxy breaks the cycle.
@interface VIWeakProxy : NSObject
@property (nonatomic, weak) id target;
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation VIWeakProxy
+ (instancetype)proxyWithTarget:(id)target {
    VIWeakProxy *proxy = [[self alloc] init];
    proxy.target = target;
    return proxy;
}
- (void)displayLinkFired:(CADisplayLink *)link {
    [self.target performSelector:@selector(_displayLinkFired:) withObject:link];
}
@end

#pragma mark -

@interface VIMediaView ()

// Shared
@property (nonatomic, assign) VIMediaKind kind;
@property (nonatomic, copy, nullable) NSString *mediaPath;

// MP4
@property (nonatomic, strong, nullable) AVQueuePlayer *player;
@property (nonatomic, strong, nullable) AVPlayerLooper *looper;
@property (nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, nullable) id statusObservation;

// GIF
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, strong, nullable) CALayer *gifLayer;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) NSArray<NSNumber *> *frameDelays;   // seconds per frame (metadata only)
@property (nonatomic, assign) NSUInteger frameCount;
@property (nonatomic, assign) NSUInteger currentFrameIndex;
@property (nonatomic, assign) CFTimeInterval nextFrameDeadline;
@property (nonatomic, assign) BOOL decodeInFlight;
@property (nonatomic, assign) CGFloat thumbnailMaxPixelSize;

@end

@implementation VIMediaView {
    CGImageSourceRef _imageSource;      // manual CF ownership under ARC
    CGImageRef       _pendingFrame;     // exactly one frame of look-ahead
    NSUInteger       _pendingFrameIndex;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.layer.masksToBounds = YES;

        _kind = VIMediaKindNone;
        _fillMode = VIMediaFillModeAspectFill;
        _frameRateCap = 30.0;
        _thumbnailMaxPixelSize = 0.0;
        _decodeQueue = dispatch_queue_create("com.sa1nt.visibleisland.decode",
                                             dispatch_queue_attr_make_with_qos_class(
                                                 DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    // ── GIF ──
    [_displayLink invalidate];
    _displayLink = nil;

    if (_imageSource) { CFRelease(_imageSource); _imageSource = NULL; }
    if (_pendingFrame) { CGImageRelease(_pendingFrame); _pendingFrame = NULL; }
    _frameDelays = nil;
    _frameCount = 0;
    _decodeInFlight = NO;

    _gifLayer.contents = nil;
    [_gifLayer removeFromSuperlayer];
    _gifLayer = nil;

    // ── MP4 ──
    if (_statusObservation) {
        [NSNotificationCenter.defaultCenter removeObserver:_statusObservation];
        _statusObservation = nil;
    }
    [_player pause];
    [_player removeAllItems];
    [_looper disableLooping];
    _looper = nil;
    _player = nil;

    [_playerLayer removeFromSuperlayer];
    _playerLayer.player = nil;
    _playerLayer = nil;

    _kind = VIMediaKindNone;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playerLayer.frame = self.bounds;
    _gifLayer.frame    = self.bounds;
    [CATransaction commit];

    // Re-target the decoder at the new pixel size (pill grew/shrank).
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    CGFloat wanted = ceil(MAX(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * scale);
    if (wanted > 0 && fabs(wanted - self.thumbnailMaxPixelSize) > scale) {
        self.thumbnailMaxPixelSize = wanted;
    }
}

#pragma mark - Loading

- (void)loadMediaAtPath:(NSString *)path forcedKind:(VIMediaKind)forcedKind {
    NSString *resolved = [self _resolvePath:path];

    if (resolved.length == 0) {
        [self invalidate];
        return;
    }
    if ([resolved isEqualToString:self.mediaPath] && self.kind != VIMediaKindNone) {
        return;   // already playing this file — do not restart
    }

    [self invalidate];
    self.mediaPath = resolved;

    VIMediaKind kind = (forcedKind != VIMediaKindNone) ? forcedKind : [self _detectKindAtPath:resolved];
    self.kind = kind;

    switch (kind) {
        case VIMediaKindMP4:         [self _setUpPlayerWithPath:resolved]; break;
        case VIMediaKindGIF:         [self _setUpGIFWithPath:resolved];    break;
        case VIMediaKindStaticImage: [self _setUpStaticImageWithPath:resolved]; break;
        default:
            VILog(@"unsupported media at %@", resolved);
            self.kind = VIMediaKindNone;
            break;
    }
}

// Accepts a bare filename, a data-partition path, or a legacy jailbreak-relative
// path, and normalises it through the rootless/rootful resolver.
- (NSString *)_resolvePath:(NSString *)path {
    if (path.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;

    if ([fm fileExistsAtPath:path]) return path;

    NSString *inContainer = [VIMediaContainerPath() stringByAppendingPathComponent:path.lastPathComponent];
    if ([fm fileExistsAtPath:inContainer]) return inContainer;

    NSString *jb = VIJBRoot(path);
    if ([fm fileExistsAtPath:jb]) return jb;

    VILog(@"media not found: %@ (jbroot=%@)", path, VIJBRootPrefix());
    return nil;
}

// Magic bytes first — users rename files constantly.
- (VIMediaKind)_detectKindAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *header = [handle readDataOfLength:12];
    [handle closeFile];

    if (header.length >= 6) {
        const uint8_t *b = header.bytes;
        if (memcmp(b, "GIF87a", 6) == 0 || memcmp(b, "GIF89a", 6) == 0) return VIMediaKindGIF;
        if (header.length >= 12 && memcmp(b + 4, "ftyp", 4) == 0)        return VIMediaKindMP4;
        if (memcmp(b, "\x89PNG", 4) == 0)                               return VIMediaKindStaticImage;
        if (b[0] == 0xFF && b[1] == 0xD8)                               return VIMediaKindStaticImage;
    }

    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"gif"]) return VIMediaKindGIF;
    if ([@[ @"mp4", @"mov", @"m4v" ] containsObject:ext]) return VIMediaKindMP4;
    if ([@[ @"png", @"jpg", @"jpeg", @"heic" ] containsObject:ext]) return VIMediaKindStaticImage;
    return VIMediaKindNone;
}

#pragma mark - MP4 back-end

- (void)_setUpPlayerWithPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    AVAsset *asset = [AVURLAsset URLAssetWithURL:url
                                        options:@{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES }];
    AVPlayerItem *template = [AVPlayerItem playerItemWithAsset:asset];

    AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
    player.muted = YES;
    player.volume = 0.0;
    player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    // Start immediately with whatever is buffered; a stalled island is worse
    // than a dropped frame.
    player.automaticallyWaitsToMinimizeStalling = NO;
    if (@available(iOS 12.0, *)) {
        // MUST be NO: SpringBoard would otherwise never let the display sleep.
        player.preventsDisplaySleepDuringVideoPlayback = NO;
    }

    // AVPlayerLooper keeps a rolling queue of items → gapless loop, no seek.
    AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:template];

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.frame = self.bounds;
    layer.videoGravity = (self.fillMode == VIMediaFillModeAspectFill)
                       ? AVLayerVideoGravityResizeAspectFill
                       : AVLayerVideoGravityResizeAspect;
    layer.masksToBounds = YES;
    [self.layer addSublayer:layer];

    self.player = player;
    self.looper = looper;
    self.playerLayer = layer;

    __weak typeof(self) weakSelf = self;
    self.statusObservation =
        [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                       object:nil
                                                        queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(NSNotification *note) {
            VILog(@"playback failed: %@", note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]);
            [weakSelf.player pause];
        }];

    if (!self.isSuspended) [player play];
    VILog(@"mp4 engine up: %@", path.lastPathComponent);
}

#pragma mark - GIF back-end (streaming)

- (void)_setUpGIFWithPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];

    // kCGImageSourceShouldCache = NO is the whole point: ImageIO keeps only the
    // container index in memory, not decoded bitmaps.
    NSDictionary *sourceOptions = @{
        (__bridge NSString *)kCGImageSourceShouldCache : @NO,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @NO,
    };
    _imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                              (__bridge CFDictionaryRef)sourceOptions);
    if (!_imageSource) {
        VILog(@"failed to open GIF source: %@", path);
        self.kind = VIMediaKindNone;
        return;
    }

    self.frameCount = CGImageSourceGetCount(_imageSource);
    if (self.frameCount == 0) {
        CFRelease(_imageSource); _imageSource = NULL;
        self.kind = VIMediaKindNone;
        return;
    }

    self.frameDelays = [self _readFrameDelays];       // metadata only, no bitmaps
    self.currentFrameIndex = 0;
    self.nextFrameDeadline = 0.0;

    CALayer *layer = [CALayer layer];
    layer.frame = self.bounds;
    layer.masksToBounds = YES;
    layer.contentsGravity = (self.fillMode == VIMediaFillModeAspectFill)
                          ? kCAGravityResizeAspectFill
                          : kCAGravityResizeAspect;
    layer.magnificationFilter = kCAFilterTrilinear;
    layer.minificationFilter  = kCAFilterTrilinear;
    [self.layer addSublayer:layer];
    self.gifLayer = layer;

    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    self.thumbnailMaxPixelSize = MAX(64.0, ceil(MAX(CGRectGetWidth(self.bounds),
                                                    CGRectGetHeight(self.bounds)) * scale));

    [self _renderFrameAtIndex:0 synchronously:YES];
    [self _startDisplayLinkIfNeeded];

    VILog(@"gif engine up: %@ (%lu frames, streaming, max %.0f px)",
          path.lastPathComponent, (unsigned long)self.frameCount, self.thumbnailMaxPixelSize);
}

- (NSArray<NSNumber *> *)_readFrameDelays {
    NSMutableArray<NSNumber *> *delays = [NSMutableArray arrayWithCapacity:self.frameCount];
    for (NSUInteger i = 0; i < self.frameCount; i++) {
        NSTimeInterval delay = 0.1;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(_imageSource, i, NULL);
        if (props) {
            CFDictionaryRef gif = CFDictionaryGetValue(props, kCGImagePropertyGIFDictionary);
            if (gif) {
                NSNumber *unclamped = (__bridge NSNumber *)CFDictionaryGetValue(gif, kCGImagePropertyGIFUnclampedDelayTime);
                NSNumber *clamped   = (__bridge NSNumber *)CFDictionaryGetValue(gif, kCGImagePropertyGIFDelayTime);
                NSTimeInterval value = unclamped.doubleValue ?: clamped.doubleValue;
                // Browsers treat < 0.02 s as 0.1 s; match that so ancient GIFs
                // do not spin the display link at 200 fps.
                delay = (value < 0.02) ? 0.1 : value;
            }
            CFRelease(props);
        }
        [delays addObject:@(delay)];
    }
    return [delays copy];
}

- (void)_startDisplayLinkIfNeeded {
    if (self.displayLink || self.frameCount <= 1 || self.isSuspended) return;

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[VIWeakProxy proxyWithTarget:self]
                                                     selector:@selector(displayLinkFired:)];
    NSInteger cap = (NSInteger)self.frameRateCap;
    if (@available(iOS 15.0, *)) {
        NSInteger maximum = UIScreen.mainScreen.maximumFramesPerSecond ?: 60;
        NSInteger preferred = (cap > 0) ? MIN(cap, maximum) : maximum;
        link.preferredFrameRateRange = CAFrameRateRangeMake(MAX(10, preferred / 2), preferred, preferred);
    } else if (cap > 0) {
        link.preferredFramesPerSecond = cap;
    }

    // Common modes: keep animating during scroll/tracking of the system UI.
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.displayLink = link;
}

- (void)_displayLinkFired:(CADisplayLink *)link {
    if (self.isSuspended || !_imageSource || self.frameCount == 0) return;

    CFTimeInterval now = link.timestamp;
    if (self.nextFrameDeadline == 0.0) self.nextFrameDeadline = now;
    if (now < self.nextFrameDeadline) return;

    NSUInteger next = (self.currentFrameIndex + 1) % self.frameCount;

    if (_pendingFrame && _pendingFrameIndex == next) {
        // Hand the prefetched frame straight to the compositor and drop our
        // reference — the layer retains it, so peak cost is 1 frame, not N.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.gifLayer.contents = (__bridge id)_pendingFrame;
        [CATransaction commit];

        CGImageRelease(_pendingFrame);
        _pendingFrame = NULL;

        self.currentFrameIndex = next;
        NSTimeInterval delay = self.frameDelays[next].doubleValue;
        // Never let a slow decode accumulate debt — schedule from `now`.
        self.nextFrameDeadline = now + MAX(delay, 1.0 / 60.0);

        [self _prefetchFrameAtIndex:(next + 1) % self.frameCount];
    } else if (!self.decodeInFlight) {
        [self _prefetchFrameAtIndex:next];
    }
}

- (void)_prefetchFrameAtIndex:(NSUInteger)index {
    if (self.decodeInFlight || !_imageSource || self.isSuspended) return;
    self.decodeInFlight = YES;

    CGFloat maxPixel = self.thumbnailMaxPixelSize;
    // The decode queue keeps its own reference: -invalidate may CFRelease
    // _imageSource on the main thread while this decode is still running.
    CGImageSourceRef source = (CGImageSourceRef)CFRetain(_imageSource);
    __weak typeof(self) weakSelf = self;

    dispatch_async(self.decodeQueue, ^{
        CGImageRef image = [weakSelf _decodeFrameFromSource:source atIndex:index maxPixelSize:maxPixel];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) mainSelf = weakSelf;
            // A decode that outlived -invalidate belongs to the previous file.
            BOOL stale = (!mainSelf || mainSelf->_imageSource != source);
            CFRelease(source);
            if (stale) { if (image) CGImageRelease(image); return; }
            [mainSelf _acceptPrefetchedFrame:image index:index];
        });
    });
}

- (void)_acceptPrefetchedFrame:(CGImageRef)image index:(NSUInteger)index {
    self.decodeInFlight = NO;
    if (!image) return;
    if (self.isSuspended) { CGImageRelease(image); return; }

    if (_pendingFrame) CGImageRelease(_pendingFrame);
    _pendingFrame = image;              // ownership transferred
    _pendingFrameIndex = index;
}

// Runs on the decode queue. Returns a +1 CGImage the caller must release.
// CGImageSourceCreateThumbnailAtIndex both decodes and downsamples in one pass,
// so a 1080p GIF frame never exists at full size in memory.
- (CGImageRef)_decodeFrameFromSource:(CGImageSourceRef)source atIndex:(NSUInteger)index maxPixelSize:(CGFloat)maxPixelSize {
    if (!source || index >= CGImageSourceGetCount(source)) return NULL;

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize          : @(MAX(maxPixelSize, 64.0)),
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform   : @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately         : @YES, // decode now, off the main thread
        (__bridge NSString *)kCGImageSourceShouldCache                    : @NO,  // but do not retain it in ImageIO
    };
    return CGImageSourceCreateThumbnailAtIndex(source, index,
                                               (__bridge CFDictionaryRef)options);
}

- (void)_renderFrameAtIndex:(NSUInteger)index synchronously:(BOOL)sync {
    if (!sync) { [self _prefetchFrameAtIndex:index]; return; }

    CGImageRef image = [self _decodeFrameFromSource:_imageSource atIndex:index maxPixelSize:self.thumbnailMaxPixelSize];
    if (!image) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gifLayer.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
    self.currentFrameIndex = index;
}

#pragma mark - Static image

- (void)_setUpStaticImageWithPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    _imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!_imageSource) { self.kind = VIMediaKindNone; return; }

    self.frameCount = 1;
    self.frameDelays = @[ @0.1 ];

    CALayer *layer = [CALayer layer];
    layer.frame = self.bounds;
    layer.masksToBounds = YES;
    layer.contentsGravity = (self.fillMode == VIMediaFillModeAspectFill)
                          ? kCAGravityResizeAspectFill : kCAGravityResizeAspect;
    [self.layer addSublayer:layer];
    self.gifLayer = layer;

    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    self.thumbnailMaxPixelSize = MAX(64.0, ceil(MAX(CGRectGetWidth(self.bounds),
                                                    CGRectGetHeight(self.bounds)) * scale));
    [self _renderFrameAtIndex:0 synchronously:YES];
}

#pragma mark - Suspension

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) return;
    _suspended = suspended;

    if (suspended) {
        [self.player pause];
        [self.displayLink invalidate];
        self.displayLink = nil;
        if (_pendingFrame) { CGImageRelease(_pendingFrame); _pendingFrame = NULL; }
        self.nextFrameDeadline = 0.0;
        VILog(@"media suspended — no decoding");
    } else {
        if (self.kind == VIMediaKindMP4) {
            [self.player play];
        } else if (self.kind == VIMediaKindGIF) {
            [self _startDisplayLinkIfNeeded];
        }
        VILog(@"media resumed");
    }
}

- (void)setFillMode:(VIMediaFillMode)fillMode {
    _fillMode = fillMode;
    self.playerLayer.videoGravity = (fillMode == VIMediaFillModeAspectFill)
                                  ? AVLayerVideoGravityResizeAspectFill
                                  : AVLayerVideoGravityResizeAspect;
    self.gifLayer.contentsGravity = (fillMode == VIMediaFillModeAspectFill)
                                  ? kCAGravityResizeAspectFill : kCAGravityResizeAspect;
}

- (void)setFrameRateCap:(CGFloat)frameRateCap {
    if (fabs(_frameRateCap - frameRateCap) < 0.01) return;
    _frameRateCap = frameRateCap;
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        [self _startDisplayLinkIfNeeded];
    }
}

- (void)shedDecodeResources {
    if (_pendingFrame) { CGImageRelease(_pendingFrame); _pendingFrame = NULL; }
    // Halve the decode target; the pill is small enough that the visual cost is
    // negligible and the win under Jetsam pressure is real.
    self.thumbnailMaxPixelSize = MAX(64.0, self.thumbnailMaxPixelSize / 2.0);
    VILog(@"decode target reduced to %.0f px", self.thumbnailMaxPixelSize);
}

@end
