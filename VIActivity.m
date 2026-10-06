#import "VIActivity.h"

static UIColor *VIActivityDefaultTint(void) {
    static UIColor *tint = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ tint = [UIColor colorWithWhite:1.0 alpha:0.94]; });
    return tint;
}

static inline BOOL VIStringsEqual(NSString *_Nullable a, NSString *_Nullable b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    return [a isEqualToString:b];
}

@implementation VIActivity

+ (instancetype)activityWithKind:(VIActivityKind)kind
                        priority:(NSInteger)priority
                           title:(NSString *)title
                        subtitle:(NSString *)subtitle
                      symbolName:(NSString *)symbolName
                         artwork:(UIImage *)artwork
                            tint:(UIColor *)tint
                        progress:(CGFloat)progress
                  showsEqualizer:(BOOL)showsEqualizer
                          sticky:(BOOL)sticky
                        lifetime:(NSTimeInterval)lifetime
                       tapAction:(VIActivityAction)tapAction {

    VIActivity *activity = [[self alloc] init];

    activity->_kind           = kind;
    activity->_priority       = priority;
    activity->_title          = [title copy];
    activity->_subtitle       = [subtitle copy];
    activity->_symbolName     = [symbolName copy];
    activity->_artwork        = artwork;
    activity->_tint           = tint ?: VIActivityDefaultTint();
    activity->_progress       = (progress < 0.0) ? -1.0 : MIN(progress, 1.0);
    activity->_showsEqualizer = showsEqualizer;
    activity->_sticky         = sticky;
    activity->_tapAction      = tapAction;

    // A sticky activity has no deadline: only its own source may retire it.
    activity->_expiry = sticky ? 0.0
                               : ([NSDate timeIntervalSinceReferenceDate] + MAX(0.4, lifetime));

    return activity;
}

// Immutable — a copy is the object itself.
- (id)copyWithZone:(NSZone *)zone { return self; }

#pragma mark - Diffing

- (BOOL)isVisuallyEqualToActivity:(VIActivity *)other {
    if (other == self) return YES;
    if (!other) return NO;

    if (other.kind           != self.kind)           return NO;
    if (other.showsEqualizer != self.showsEqualizer) return NO;
    if (other.tapAction      != self.tapAction)      return NO;

    // Pointer identity is deliberate: a source that re-publishes unchanged
    // artwork hands back the very same downsampled UIImage, and comparing
    // pixel data on every MediaRemote burst would be far more expensive than
    // the relayout we are trying to avoid.
    if (other.artwork != self.artwork) return NO;

    if (fabs(other.progress - self.progress) > 0.01) return NO;

    if (!VIStringsEqual(self.title,      other.title))      return NO;
    if (!VIStringsEqual(self.subtitle,   other.subtitle))   return NO;
    if (!VIStringsEqual(self.symbolName, other.symbolName)) return NO;

    return YES;
}

- (BOOL)isExpiredAtTime:(NSTimeInterval)now {
    if (self.sticky) return NO;
    return now >= self.expiry;
}

#pragma mark - Debug

- (NSString *)kindDescription {
    switch (self.kind) {
        case VIActivityKindNowPlaying: return @"NowPlaying";
        case VIActivityKindCharging:   return @"Charging";
        case VIActivityKindRinger:     return @"Ringer";
        case VIActivityKindVolume:     return @"Volume";
        case VIActivityKindLowPower:   return @"LowPower";
        case VIActivityKindLockState:  return @"LockState";
        case VIActivityKindNone:       break;
    }
    return @"None";
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VIActivity %@ p=%ld title=%@ sticky=%d>",
            [self kindDescription], (long)self.priority, self.title, self.sticky];
}

@end
