#import "VIActivityContentView.h"

#pragma mark - Helpers

static const NSUInteger kVIEqualizerBarCount = 3;

static UIImage *_Nullable VISymbolImage(NSString *_Nullable name, CGFloat pointSize) {
    if (name.length == 0) return nil;
    UIImage *image = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                           weight:UIImageSymbolWeightSemibold];
        image = [UIImage systemImageNamed:name withConfiguration:config];
    }
    // A firmware without the symbol simply renders an empty bubble rather than
    // crashing on a nil image.
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

typedef NS_ENUM(NSUInteger, VIGlyphMode) {
    VIGlyphModeEmpty = 0,
    VIGlyphModeImage,
    VIGlyphModeEqualizer,
    VIGlyphModeRing,
};

#pragma mark - VIActivityGlyphView

@implementation VIActivityGlyphView {
    UIImageView   *_imageView;
    CAShapeLayer  *_ringTrack;
    CAShapeLayer  *_ringProgress;
    CALayer       *_equalizerHost;
    NSMutableArray<CALayer *> *_bars;

    VIActivity    *_activity;
    VIActivityRole _role;
    VIGlyphMode    _mode;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.clipsToBounds = YES;
        _imageView.alpha = 0.0;
        [self addSubview:_imageView];

        _ringTrack = [CAShapeLayer layer];
        _ringTrack.fillColor   = UIColor.clearColor.CGColor;
        _ringTrack.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
        _ringTrack.lineWidth   = 2.0;
        _ringTrack.lineCap     = kCALineCapRound;
        _ringTrack.opacity     = 0.0;
        [self.layer addSublayer:_ringTrack];

        _ringProgress = [CAShapeLayer layer];
        _ringProgress.fillColor   = UIColor.clearColor.CGColor;
        _ringProgress.strokeColor = UIColor.whiteColor.CGColor;
        _ringProgress.lineWidth   = 2.0;
        _ringProgress.lineCap     = kCALineCapRound;
        _ringProgress.strokeEnd   = 0.0;
        _ringProgress.opacity     = 0.0;
        [self.layer addSublayer:_ringProgress];

        _equalizerHost = [CALayer layer];
        _equalizerHost.opacity = 0.0;
        [self.layer addSublayer:_equalizerHost];

        _bars = [NSMutableArray arrayWithCapacity:kVIEqualizerBarCount];
        for (NSUInteger i = 0; i < kVIEqualizerBarCount; i++) {
            CALayer *bar = [CALayer layer];
            bar.backgroundColor = UIColor.whiteColor.CGColor;
            bar.cornerRadius = 1.0;
            // Bottom anchor: the bar grows upward like a real level meter.
            bar.anchorPoint = CGPointMake(0.5, 1.0);
            [_equalizerHost addSublayer:bar];
            [_bars addObject:bar];
        }
    }
    return self;
}

#pragma mark Content

- (void)applyActivity:(VIActivity *)activity role:(VIActivityRole)role animated:(BOOL)animated {
    _activity = activity;
    _role = role;

    VIGlyphMode mode = VIGlyphModeEmpty;
    if (activity) {
        if (role == VIActivityRoleAccessory) {
            if (activity.showsEqualizer)      mode = VIGlyphModeEqualizer;
            else if (activity.progress >= 0.0) mode = VIGlyphModeRing;
            else                               mode = VIGlyphModeImage;
        } else {
            mode = VIGlyphModeImage;
        }
    }

    _mode = mode;

    UIColor *tint = activity.tint ?: [UIColor colorWithWhite:1.0 alpha:0.94];

    if (mode == VIGlyphModeImage) {
        if (role == VIActivityRoleGlyph && activity.artwork) {
            _imageView.image = activity.artwork;
            _imageView.contentMode = UIViewContentModeScaleAspectFill;
            _imageView.tintColor = nil;
        } else {
            CGFloat point = MAX(9.0, MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5);
            _imageView.image = VISymbolImage(activity.symbolName, point);
            _imageView.contentMode = UIViewContentModeScaleAspectFit;
            _imageView.tintColor = tint;
        }
    } else {
        _imageView.image = nil;
    }

    if (mode == VIGlyphModeRing) {
        _ringProgress.strokeColor = tint.CGColor;
        CGFloat target = MIN(MAX(activity.progress, 0.0), 1.0);
        if (animated) {
            _ringProgress.strokeEnd = target;   // implicit animation is fine here
        } else {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            _ringProgress.strokeEnd = target;
            [CATransaction commit];
        }
    }

    if (mode == VIGlyphModeEqualizer) {
        for (CALayer *bar in _bars) bar.backgroundColor = tint.CGColor;
        [self _startEqualizerIfNeeded];
    } else {
        [self _stopEqualizer];
    }

    [self setNeedsLayout];
    [self _applyVisibilityAnimated:animated];
}

- (void)_applyVisibilityAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        self->_imageView.alpha = (self->_mode == VIGlyphModeImage) ? 1.0 : 0.0;
    };

    CGFloat ringOpacity = (_mode == VIGlyphModeRing) ? 1.0 : 0.0;
    CGFloat eqOpacity   = (_mode == VIGlyphModeEqualizer) ? 1.0 : 0.0;

    if (animated) {
        [UIView animateWithDuration:0.18
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:apply
                         completion:nil];
        _ringTrack.opacity     = ringOpacity;
        _ringProgress.opacity  = ringOpacity;
        _equalizerHost.opacity = eqOpacity;
    } else {
        apply();
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _ringTrack.opacity     = ringOpacity;
        _ringProgress.opacity  = ringOpacity;
        _equalizerHost.opacity = eqOpacity;
        [CATransaction commit];
    }
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) return;

    CGFloat side = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));

    // Artwork fills the bubble; a symbol is inset so it reads as an icon.
    BOOL isArtwork = (_role == VIActivityRoleGlyph && _activity.artwork != nil);
    CGFloat inset = isArtwork ? 0.0 : side * 0.26;
    _imageView.frame = CGRectInset(bounds, inset, inset);
    _imageView.layer.cornerRadius = isArtwork ? side / 2.0 : 0.0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGRect ringRect = CGRectInset(bounds, 2.5, 2.5);
    UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))
                                                       radius:CGRectGetWidth(ringRect) / 2.0
                                                   startAngle:-M_PI_2
                                                     endAngle:(3.0 * M_PI_2)
                                                    clockwise:YES];
    _ringTrack.frame    = bounds;
    _ringProgress.frame = bounds;
    _ringTrack.path     = ring.CGPath;
    _ringProgress.path  = ring.CGPath;

    // Equalizer: three bars centred, occupying 52% of the bubble.
    CGFloat hostSide  = side * 0.52;
    CGFloat barWidth  = MAX(1.5, hostSide / 5.0);
    CGFloat spacing   = (hostSide - barWidth * kVIEqualizerBarCount) / (kVIEqualizerBarCount - 1);
    _equalizerHost.frame = CGRectMake((CGRectGetWidth(bounds) - hostSide) / 2.0,
                                      (CGRectGetHeight(bounds) - hostSide) / 2.0,
                                      hostSide, hostSide);

    for (NSUInteger i = 0; i < _bars.count; i++) {
        CALayer *bar = _bars[i];
        bar.cornerRadius = barWidth / 2.0;
        bar.frame = CGRectMake(i * (barWidth + spacing), 0.0, barWidth, hostSide);
        // anchorPoint is (0.5, 1.0), so position must sit on the baseline.
        bar.position = CGPointMake(i * (barWidth + spacing) + barWidth / 2.0, hostSide);
    }

    [CATransaction commit];
}

#pragma mark Equalizer

- (void)_startEqualizerIfNeeded {
    for (NSUInteger i = 0; i < _bars.count; i++) {
        CALayer *bar = _bars[i];
        if ([bar animationForKey:@"vi.eq"]) continue;

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        pulse.fromValue    = @(0.30 + 0.08 * i);
        pulse.toValue      = @(1.0);
        pulse.duration     = 0.40 + 0.11 * i;
        pulse.autoreverses = YES;
        pulse.repeatCount  = HUGE_VALF;
        pulse.timeOffset   = 0.13 * i;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [bar addAnimation:pulse forKey:@"vi.eq"];
    }
    _equalizerHost.speed = self.paused ? 0.0 : 1.0;
}

- (void)_stopEqualizer {
    for (CALayer *bar in _bars) [bar removeAnimationForKey:@"vi.eq"];
}

- (void)setPaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    // Freezing the host layer keeps the bars where they are; unfreezing resumes
    // mid-beat instead of snapping back to the start of the animation.
    _equalizerHost.speed = paused ? 0.0 : 1.0;
}

- (void)shedResources {
    [self _stopEqualizer];
    _imageView.image = nil;
    _activity = nil;
    _mode = VIGlyphModeEmpty;
    [self _applyVisibilityAnimated:NO];
}

@end

#pragma mark - VIActivityDetailView

@implementation VIActivityDetailView {
    UIImageView *_artworkView;
    UILabel     *_titleLabel;
    UILabel     *_subtitleLabel;
    VIActivityGlyphView *_accessory;
    UIView      *_progressTrack;
    UIView      *_progressFill;

    VIActivity  *_activity;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 6.0;
        if (@available(iOS 13.0, *)) _artworkView.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_subtitleLabel];

        _accessory = [[VIActivityGlyphView alloc] initWithFrame:CGRectZero];
        [self addSubview:_accessory];

        _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
        _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
        _progressTrack.layer.cornerRadius = 1.5;
        _progressTrack.alpha = 0.0;
        [self addSubview:_progressTrack];

        _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
        _progressFill.backgroundColor = UIColor.whiteColor;
        _progressFill.layer.cornerRadius = 1.5;
        [_progressTrack addSubview:_progressFill];
    }
    return self;
}

- (void)applyActivity:(VIActivity *)activity animated:(BOOL)animated {
    _activity = activity;

    _titleLabel.text    = activity.title;
    _subtitleLabel.text = activity.subtitle;

    if (activity.artwork) {
        _artworkView.image = activity.artwork;
        _artworkView.tintColor = nil;
    } else {
        _artworkView.image = VISymbolImage(activity.symbolName, 15.0);
        _artworkView.tintColor = activity.tint;
    }

    // The accessory mirrors the trailing satellite: equalizer for music, ring
    // for anything with determinate progress.
    [_accessory applyActivity:activity role:VIActivityRoleAccessory animated:animated];

    BOOL showsBar = (activity.progress >= 0.0 && !activity.showsEqualizer);
    void (^apply)(void) = ^{
        self->_progressTrack.alpha = showsBar ? 1.0 : 0.0;
        self->_accessory.alpha     = showsBar ? 0.0 : 1.0;
    };
    if (animated) {
        [UIView animateWithDuration:0.18 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:apply completion:nil];
    } else {
        apply();
    }

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) return;

    const CGFloat leftPad  = 9.0;
    const CGFloat rightPad = 10.0;
    const CGFloat gap      = 8.0;
    CGFloat height = CGRectGetHeight(bounds);

    CGFloat artSide = MIN(26.0, height - 8.0);
    _artworkView.frame = CGRectMake(leftPad, (height - artSide) / 2.0, artSide, artSide);
    _artworkView.layer.cornerRadius = _activity.artwork ? 6.0 : 0.0;

    CGFloat accessorySide = MIN(20.0, height - 10.0);
    CGFloat accessoryX = CGRectGetWidth(bounds) - rightPad - accessorySide;
    _accessory.frame = CGRectMake(accessoryX, (height - accessorySide) / 2.0, accessorySide, accessorySide);

    CGFloat textX     = CGRectGetMaxX(_artworkView.frame) + gap;
    CGFloat textWidth = MAX(0.0, accessoryX - gap - textX);

    BOOL hasSubtitle = (_subtitleLabel.text.length > 0);
    if (hasSubtitle) {
        _titleLabel.frame    = CGRectMake(textX, height / 2.0 - 15.0, textWidth, 15.0);
        _subtitleLabel.frame = CGRectMake(textX, height / 2.0 + 0.5, textWidth, 13.0);
    } else {
        _titleLabel.frame    = CGRectMake(textX, (height - 15.0) / 2.0, textWidth, 15.0);
        _subtitleLabel.frame = CGRectZero;
    }

    CGFloat barWidth = textWidth;
    _progressTrack.frame = CGRectMake(textX, CGRectGetMaxY(_titleLabel.frame) + 4.0, barWidth, 3.0);
    CGFloat fillWidth = barWidth * MIN(MAX(_activity.progress, 0.0), 1.0);
    _progressFill.frame = CGRectMake(0.0, 0.0, fillWidth, 3.0);
}

- (CGFloat)preferredWidthForHeight:(CGFloat)height {
    if (!_activity) return 0.0;

    CGSize limit = CGSizeMake(CGFLOAT_MAX, height);
    CGFloat titleWidth    = [_titleLabel sizeThatFits:limit].width;
    CGFloat subtitleWidth = [_subtitleLabel sizeThatFits:limit].width;
    CGFloat textWidth = MAX(titleWidth, subtitleWidth);

    CGFloat artSide       = MIN(26.0, height - 8.0);
    CGFloat accessorySide = MIN(20.0, height - 10.0);

    return 9.0 + artSide + 8.0 + ceil(textWidth) + 8.0 + accessorySide + 10.0;
}

- (void)setPaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    _accessory.paused = paused;
}

- (void)shedResources {
    [_accessory shedResources];
    _artworkView.image = nil;
    _titleLabel.text = nil;
    _subtitleLabel.text = nil;
    _activity = nil;
}

@end
