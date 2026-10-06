#import "VIIslandView.h"
#import "VIMediaView.h"
#import "VIActivityContentView.h"
#import "VIPrefs.h"

static const CGFloat kVITouchSlop         = 6.0;
static const CGFloat kVIExpandHeightBoost = 20.0;
static const CGFloat kVIExpandMinWidth    = 190.0;
static const CGFloat kVIScreenMargin      = 12.0;

#pragma mark - Spring helper

// One tuned spring for every module transition. CASpringAnimation is used
// directly (not UIViewPropertyAnimator) because the modules are driven by
// explicit layer geometry, and because SpringBoard's own UIView animation
// context can be mid-transaction when a screen-state change arrives.
static CASpringAnimation *VISpring(NSString *keyPath, id from, id to) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass               = 0.85;
    spring.stiffness          = 320.0;
    spring.damping            = 26.0;
    spring.initialVelocity    = 0.0;
    spring.fromValue          = from;
    spring.toValue            = to;
    spring.duration           = spring.settlingDuration;
    spring.timingFunction     = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];
    spring.removedOnCompletion = YES;
    spring.fillMode           = kCAFillModeRemoved;
    return spring;
}

static inline CGFloat VIPixelAlign(CGFloat value) {
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    return round(value * scale) / scale;
}

#pragma mark - VIIslandModuleView

@implementation VIIslandModuleView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.opaque          = NO;
        self.clipsToBounds   = YES;

        CALayer *layer = self.layer;
        layer.masksToBounds       = YES;              // required for media clipping
        layer.allowsEdgeAntialiasing = YES;
        layer.shouldRasterize     = NO;               // never rasterize animated content
        if (@available(iOS 13.0, *)) {
            // Hardware continuous corner curve — matches Apple's squircle and
            // costs nothing extra on the GPU compared to a circular radius.
            layer.cornerCurve = kCACornerCurveContinuous;
        }
    }
    return self;
}

- (void)setModuleCornerRadius:(CGFloat)moduleCornerRadius {
    _moduleCornerRadius = moduleCornerRadius;
    self.layer.cornerRadius = moduleCornerRadius;
}

- (void)setModuleFrame:(CGRect)frame cornerRadius:(CGFloat)radius animated:(BOOL)animated {
    frame = CGRectMake(VIPixelAlign(frame.origin.x), VIPixelAlign(frame.origin.y),
                       VIPixelAlign(frame.size.width), VIPixelAlign(frame.size.height));
    radius = MIN(radius, MIN(frame.size.width, frame.size.height) / 2.0);

    if (!animated) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.frame = frame;
        self.moduleCornerRadius = radius;
        [CATransaction commit];
        [self setNeedsLayout];
        return;
    }

    CALayer *layer = self.layer;
    CGPoint  oldPosition = layer.position;
    CGRect   oldBounds   = layer.bounds;
    CGFloat  oldRadius   = layer.cornerRadius;

    CALayer *presentation = (CALayer *)layer.presentationLayer;
    if (presentation) {
        oldPosition = presentation.position;
        oldBounds   = presentation.bounds;
        oldRadius   = presentation.cornerRadius;
    }

    // Commit the model values first, then attach springs that animate FROM the
    // previous presentation values. This keeps the layer tree authoritative and
    // avoids the "snap back" artefact when two updates overlap.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.frame = frame;
    self.moduleCornerRadius = radius;
    [CATransaction commit];

    [layer addAnimation:VISpring(@"position", [NSValue valueWithCGPoint:oldPosition],
                                              [NSValue valueWithCGPoint:layer.position])
                 forKey:@"vi.position"];
    [layer addAnimation:VISpring(@"bounds", [NSValue valueWithCGRect:oldBounds],
                                            [NSValue valueWithCGRect:layer.bounds])
                 forKey:@"vi.bounds"];
    if (fabs(oldRadius - radius) > 0.01) {
        [layer addAnimation:VISpring(@"cornerRadius", @(oldRadius), @(radius))
                     forKey:@"vi.cornerRadius"];
    }

    [self setNeedsLayout];
}

@end

#pragma mark - VIIslandContainerView

@interface VIIslandContainerView ()
@property (nonatomic, strong) VIIslandModuleView *centerPill;
@property (nonatomic, strong) VIIslandModuleView *leadingBubble;
@property (nonatomic, strong) VIIslandModuleView *trailingBubble;
@property (nonatomic, strong) VIMediaView *mediaView;
@property (nonatomic, assign) VIIslandState islandState;
@property (nonatomic, assign) VIIslandGeometry geometry;
@property (nonatomic, assign) CGFloat containerWidth;
@end

@implementation VIIslandContainerView {
    VIActivityDetailView *_detailView;
    VIActivityGlyphView  *_leadingGlyph;
    VIActivityGlyphView  *_trailingGlyph;

    VIActivity    *_centerActivity;
    VIActivity    *_leadingActivity;
    VIActivity    *_trailingActivity;
    VIActivityRole _leadingRole;
    VIActivityRole _trailingRole;

    BOOL _hasMedia;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.clipsToBounds = NO;        // let spring overshoot render
        _islandState = VIIslandStateIdle;
        _leadingRole  = VIActivityRoleGlyph;
        _trailingRole = VIActivityRoleAccessory;

        _centerPill     = [[VIIslandModuleView alloc] initWithFrame:CGRectZero];
        _leadingBubble  = [[VIIslandModuleView alloc] initWithFrame:CGRectZero];
        _trailingBubble = [[VIIslandModuleView alloc] initWithFrame:CGRectZero];

        _mediaView = [[VIMediaView alloc] initWithFrame:CGRectZero];
        _mediaView.userInteractionEnabled = NO;
        [_centerPill addSubview:_mediaView];

        // Activity content sits above the media layer inside the pill.
        _detailView = [[VIActivityDetailView alloc] initWithFrame:CGRectZero];
        _detailView.alpha = 0.0;
        [_centerPill addSubview:_detailView];

        _leadingGlyph  = [[VIActivityGlyphView alloc] initWithFrame:CGRectZero];
        _trailingGlyph = [[VIActivityGlyphView alloc] initWithFrame:CGRectZero];
        [_leadingBubble  addSubview:_leadingGlyph];
        [_trailingBubble addSubview:_trailingGlyph];

        for (VIIslandModuleView *module in @[ _leadingBubble, _centerPill, _trailingBubble ]) {
            [self addSubview:module];
        }

        _leadingBubble.alpha  = 0.0;
        _trailingBubble.alpha = 0.0;

        // Every module is independently tappable; the manager maps slot → action.
        [_centerPill     addGestureRecognizer:[self _tapRecognizerForSlot:VIActivitySlotCenter]];
        [_leadingBubble  addGestureRecognizer:[self _tapRecognizerForSlot:VIActivitySlotLeading]];
        [_trailingBubble addGestureRecognizer:[self _tapRecognizerForSlot:VIActivitySlotTrailing]];
    }
    return self;
}

- (UITapGestureRecognizer *)_tapRecognizerForSlot:(VIActivitySlot)slot {
    UITapGestureRecognizer *tap = nil;
    switch (slot) {
        case VIActivitySlotLeading:
            tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleLeadingTap:)];
            break;
        case VIActivitySlotTrailing:
            tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleTrailingTap:)];
            break;
        case VIActivitySlotCenter:
        default:
            tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleCenterTap:)];
            break;
    }
    return tap;
}

- (void)dealloc {
    // Belt and braces: the manager calls prepareForTeardown, but a stray
    // release must never leave a CADisplayLink attached to the run loop.
    [_mediaView invalidate];
}

#pragma mark - Geometry

+ (CGFloat)bandHeightForGeometry:(VIIslandGeometry)geometry {
    return MAX(geometry.height, geometry.bubbleDiameter) + kVIExpandHeightBoost + 28.0;
}

- (void)applyGeometry:(VIIslandGeometry)geometry containerWidth:(CGFloat)width {
    self.geometry = geometry;
    self.containerWidth = width;
    [self _layoutModulesAnimated:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.mediaView.frame = self.centerPill.bounds;
    _detailView.frame    = self.centerPill.bounds;
    _leadingGlyph.frame  = self.leadingBubble.bounds;
    _trailingGlyph.frame = self.trailingBubble.bounds;
}

- (BOOL)hasActivity {
    return _centerActivity != nil;
}

- (void)_layoutModulesAnimated:(BOOL)animated {
    VIIslandGeometry g = self.geometry;
    CGFloat width = self.containerWidth ?: CGRectGetWidth(self.bounds);
    if (width <= 0.0) return;

    BOOL hidden   = (self.islandState == VIIslandStateHidden);
    BOOL expanded = (self.islandState == VIIslandStateExpanded);

    // Satellites are driven by live activities first and by the "always show"
    // preference second. Expanding pulls them back into the pill, exactly like
    // the hardware island absorbing its side content.
    BOOL satellitesVisible = !hidden && !expanded &&
                             (self.hasActivity || VIPrefs.shared.satellitesEnabled);

    CGFloat bubble     = g.bubbleDiameter;
    CGFloat rowCenterY = MAX(g.height, bubble) / 2.0;
    CGFloat pillTop    = rowCenterY - g.height / 2.0;   // fixed: expansion grows downward

    CGFloat pillHeight = g.height + (expanded ? kVIExpandHeightBoost : 0.0);
    CGFloat pillWidth  = g.width;

    if (expanded) {
        CGFloat wanted = [_detailView preferredWidthForHeight:pillHeight];
        pillWidth = MAX(MAX(g.width, kVIExpandMinWidth), wanted);
        pillWidth = MIN(pillWidth, width - 2.0 * kVIScreenMargin);
    }

    CGFloat pillRadius = MIN(g.cornerRadius + (expanded ? kVIExpandHeightBoost / 2.0 : 0.0),
                             pillHeight / 2.0);

    // Dynamic gap: when the pill grows, the satellites must not collide with
    // it or slide off-screen. The gap shrinks proportionally, with a 2 pt floor,
    // and the satellites are clamped inside a 6 pt screen margin.
    CGFloat totalWanted = pillWidth + 2.0 * (g.moduleGap + bubble);
    CGFloat available   = width - 12.0;
    CGFloat gap         = g.moduleGap;
    if (totalWanted > available) {
        CGFloat overflow = totalWanted - available;
        gap = MAX(2.0, g.moduleGap - overflow / 2.0);
    }

    CGFloat pillX = (width - pillWidth) / 2.0 + VIPrefs.shared.offsetX;
    CGRect pillFrame = CGRectMake(pillX, pillTop, pillWidth, pillHeight);

    CGFloat leadingX  = CGRectGetMinX(pillFrame) - gap - bubble;
    CGFloat trailingX = CGRectGetMaxX(pillFrame) + gap;
    leadingX  = MAX(6.0, leadingX);
    trailingX = MIN(width - 6.0 - bubble, trailingX);

    CGRect leadingFrame  = CGRectMake(leadingX,  rowCenterY - bubble / 2.0, bubble, bubble);
    CGRect trailingFrame = CGRectMake(trailingX, rowCenterY - bubble / 2.0, bubble, bubble);

    // Collapsed satellites tuck *under* the pill edges and scale to zero width,
    // which reads as the Dynamic Island's "absorb" transition.
    if (!satellitesVisible) {
        leadingFrame  = CGRectMake(CGRectGetMinX(pillFrame) + 2.0, rowCenterY - 1.0, 0.0, 2.0);
        trailingFrame = CGRectMake(CGRectGetMaxX(pillFrame) - 2.0, rowCenterY - 1.0, 0.0, 2.0);
    }

    [self.centerPill     setModuleFrame:pillFrame     cornerRadius:pillRadius   animated:animated];
    [self.leadingBubble  setModuleFrame:leadingFrame  cornerRadius:bubble / 2.0 animated:animated];
    [self.trailingBubble setModuleFrame:trailingFrame cornerRadius:bubble / 2.0 animated:animated];

    // The activity card takes over the pill whenever there is no media to show,
    // and overlays a dimmed media layer once expanded.
    BOOL showsDetail = self.hasActivity && !hidden && (expanded || !_hasMedia);
    CGFloat mediaAlpha = (_hasMedia && showsDetail) ? 0.14 : 1.0;

    void (^applyAlpha)(void) = ^{
        self.centerPill.alpha     = hidden ? 0.0 : 1.0;
        self.leadingBubble.alpha  = satellitesVisible ? 1.0 : 0.0;
        self.trailingBubble.alpha = satellitesVisible ? 1.0 : 0.0;
        self->_detailView.alpha   = showsDetail ? 1.0 : 0.0;
        self.mediaView.alpha      = mediaAlpha;
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:applyAlpha
                         completion:nil];
    } else {
        applyAlpha();
    }

    self.mediaView.frame = self.centerPill.bounds;
    _detailView.frame    = self.centerPill.bounds;
    _leadingGlyph.frame  = self.leadingBubble.bounds;
    _trailingGlyph.frame = self.trailingBubble.bounds;
    [self.mediaView setNeedsLayout];
}

#pragma mark - State

- (void)setIslandState:(VIIslandState)state animated:(BOOL)animated {
    if (_islandState == state) return;
    _islandState = state;
    self.userInteractionEnabled = (state != VIIslandStateHidden);
    [self _layoutModulesAnimated:animated];
}

#pragma mark - Activities

- (void)applyCenterActivity:(VIActivity *)center
            leadingActivity:(VIActivity *)leading
                leadingRole:(VIActivityRole)leadingRole
           trailingActivity:(VIActivity *)trailing
               trailingRole:(VIActivityRole)trailingRole
                   animated:(BOOL)animated {

    _centerActivity   = center;
    _leadingActivity  = leading;
    _trailingActivity = trailing;
    _leadingRole      = leadingRole;
    _trailingRole     = trailingRole;

    [_detailView    applyActivity:center animated:animated];
    [_leadingGlyph  applyActivity:leading  role:leadingRole  animated:animated];
    [_trailingGlyph applyActivity:trailing role:trailingRole animated:animated];

    // Satellites pick up the activity's tint at low opacity so each event is
    // recognisable at a glance without turning the island into a colour blob.
    UIColor *leadingFill  = leading  ? [leading.tint colorWithAlphaComponent:0.16]  : nil;
    UIColor *trailingFill = trailing ? [trailing.tint colorWithAlphaComponent:0.16] : nil;
    self.leadingBubble.backgroundColor  = leadingFill  ?: UIColor.blackColor;
    self.trailingBubble.backgroundColor = trailingFill ?: UIColor.blackColor;

    [self _layoutModulesAnimated:animated];
}

- (VIActivity *)activityForSlot:(VIActivitySlot)slot {
    switch (slot) {
        case VIActivitySlotLeading:  return _leadingActivity;
        case VIActivitySlotTrailing: return _trailingActivity;
        case VIActivitySlotCenter:   return _centerActivity;
    }
    return nil;
}

#pragma mark - Taps

- (void)_handleCenterTap:(UITapGestureRecognizer *)tap {
    [self.delegate islandContainer:self didTapSlot:VIActivitySlotCenter];
}

- (void)_handleLeadingTap:(UITapGestureRecognizer *)tap {
    [self.delegate islandContainer:self didTapSlot:VIActivitySlotLeading];
}

- (void)_handleTrailingTap:(UITapGestureRecognizer *)tap {
    [self.delegate islandContainer:self didTapSlot:VIActivitySlotTrailing];
}

#pragma mark - Preferences / media

- (void)applyPreferences {
    VIPrefs *prefs = VIPrefs.shared;

    NSString *mediaPath = prefs.mediaPath;
    _hasMedia = (mediaPath.length > 0);

    self.mediaView.fillMode = prefs.mediaFillsPill ? VIMediaFillModeAspectFill
                                                   : VIMediaFillModeAspectFit;
    self.mediaView.frameRateCap = prefs.gifFrameRateCap;
    [self.mediaView loadMediaAtPath:mediaPath forcedKind:prefs.forcedMediaKind];

    if (!self.hasActivity) {
        self.leadingBubble.backgroundColor  = UIColor.blackColor;
        self.trailingBubble.backgroundColor = UIColor.blackColor;
    }

    [self _layoutModulesAnimated:YES];
}

- (void)setPlaybackSuspended:(BOOL)playbackSuspended {
    if (_playbackSuspended == playbackSuspended) return;
    _playbackSuspended = playbackSuspended;
    self.mediaView.suspended = playbackSuspended;

    // Repeating CAAnimations keep the render server busy even behind a black
    // screen, so they are frozen alongside the decoder.
    _detailView.paused    = playbackSuspended;
    _leadingGlyph.paused  = playbackSuspended;
    _trailingGlyph.paused = playbackSuspended;
}

- (void)handleMemoryPressure {
    [self.mediaView shedDecodeResources];
}

- (void)prepareForTeardown {
    [self.mediaView invalidate];
    [_detailView shedResources];
    [_leadingGlyph shedResources];
    [_trailingGlyph shedResources];
}

#pragma mark - Hit testing

- (BOOL)pointIsInsideInteractiveArea:(CGPoint)point {
    if (self.islandState == VIIslandStateHidden) return NO;

    for (VIIslandModuleView *module in @[ self.centerPill, self.leadingBubble, self.trailingBubble ]) {
        if (module.hidden || module.alpha < 0.02) continue;
        if (CGRectIsEmpty(module.frame)) continue;
        if (CGRectContainsPoint(CGRectInset(module.frame, -kVITouchSlop, -kVITouchSlop), point)) return YES;
    }
    return NO;
}

@end
