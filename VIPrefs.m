#import "VIPrefs.h"
#import "VIPaths.h"

// os_unfair_lock / OS_UNFAIR_LOCK_INIT live in the Darwin.os.lock module.
// Foundation does not pull that submodule in, and with -fmodules clang rejects
// the declaration outright instead of falling back to a textual include.
#import <os/lock.h>

// Quantise every geometry value to the 0.5 pt grid the sliders expose, so the
// layout engine never receives a value that cannot be reproduced from the UI.
static inline CGFloat VIQuantiseHalfPoint(CGFloat v) {
    return round(v * 2.0) / 2.0;
}

static inline CGFloat VIClamp(CGFloat v, CGFloat lo, CGFloat hi) {
    return MIN(MAX(v, lo), hi);
}

@implementation VIPrefs {
    // Copied out of the plist under a lock, then published atomically.
    NSDictionary *_snapshot;
    os_unfair_lock _lock;
}

+ (instancetype)shared {
    static VIPrefs *shared = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        [self reload];
    }
    return self;
}

#pragma mark - Loading

- (void)reload {
    // Direct plist read rather than CFPreferences: SpringBoard caches
    // CFPreferences aggressively and the Settings process writes from a
    // different container, so a stale read is the norm there.
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:VIPreferencesPlistPath()];
    NSMutableDictionary *merged = [[self class] defaults].mutableCopy;
    if ([onDisk isKindOfClass:NSDictionary.class]) {
        [onDisk enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && obj) merged[key] = obj;
        }];
    }

    os_unfair_lock_lock(&_lock);
    _snapshot = [merged copy];
    os_unfair_lock_unlock(&_lock);

    VILog(@"prefs reloaded (%lu keys, rootless=%d)", (unsigned long)merged.count, VIIsRootless());
}

+ (NSDictionary *)defaults {
    return @{
        @"enabled"              : @YES,
        @"hideInLandscape"      : @YES,
        @"hideOnCoverSheet"     : @NO,
        @"pauseWhenScreenOff"   : @YES,
        @"satellitesEnabled"    : @NO,
        @"tapToExpand"          : @YES,

        @"activitiesEnabled"    : @YES,
        @"activityNowPlaying"   : @YES,
        @"activityCharging"     : @YES,
        @"activityRinger"       : @YES,
        @"activityVolume"       : @YES,
        @"activityLowPower"     : @YES,
        @"activityLockState"    : @NO,
        @"satelliteActions"     : @YES,
        @"autoCollapseDelay"    : @4,

        @"mediaPath"            : @"",
        @"forcedMediaKind"      : @(VIMediaKindNone),
        @"gifFrameRateCap"      : @30,
        @"mediaFillsPill"       : @YES,

        @"offsetX"              : @0,
        @"offsetY"              : @0,
        @"widthDelta"           : @0,
        @"heightDelta"          : @0,
        @"cornerRadiusDelta"    : @0,
        @"bubbleDiameterDelta"  : @0,
        @"moduleGapDelta"       : @0,

        @"presetOverride"       : @"",
    };
}

- (id)_value:(NSString *)key {
    os_unfair_lock_lock(&_lock);
    id v = _snapshot[key];
    os_unfair_lock_unlock(&_lock);
    return v;
}

- (BOOL)_bool:(NSString *)key    { return [[self _value:key] boolValue]; }
- (CGFloat)_float:(NSString *)key { return (CGFloat)[[self _value:key] doubleValue]; }

#pragma mark - Master

- (BOOL)enabled             { return [self _bool:@"enabled"]; }
- (BOOL)hideInLandscape     { return [self _bool:@"hideInLandscape"]; }
- (BOOL)hideOnCoverSheet    { return [self _bool:@"hideOnCoverSheet"]; }
- (BOOL)pauseWhenScreenOff  { return YES; } // non-negotiable: Jetsam / battery safety
- (BOOL)satellitesEnabled   { return [self _bool:@"satellitesEnabled"]; }
- (BOOL)tapToExpand         { return [self _bool:@"tapToExpand"]; }

#pragma mark - Activities

- (BOOL)activitiesEnabled   { return [self _bool:@"activitiesEnabled"]; }
- (BOOL)activityNowPlaying  { return [self _bool:@"activityNowPlaying"]; }
- (BOOL)activityCharging    { return [self _bool:@"activityCharging"]; }
- (BOOL)activityRinger      { return [self _bool:@"activityRinger"]; }
- (BOOL)activityVolume      { return [self _bool:@"activityVolume"]; }
- (BOOL)activityLowPower    { return [self _bool:@"activityLowPower"]; }
- (BOOL)activityLockState   { return [self _bool:@"activityLockState"]; }
- (BOOL)satelliteActions    { return [self _bool:@"satelliteActions"]; }

- (CGFloat)activityAutoCollapseDelay {
    return VIClamp([self _float:@"autoCollapseDelay"], 1.5, 12.0);
}

#pragma mark - Media

- (NSString *)mediaPath {
    NSString *raw = [self _value:@"mediaPath"];
    if (![raw isKindOfClass:NSString.class] || raw.length == 0) return nil;

    // Stored value may be:
    //   • a bare file name  → resolved inside the media container
    //   • an absolute data-partition path
    //   • a jailbreak-relative path (legacy configs from the rootful build)
    if ([raw hasPrefix:@"/var/"] || [raw hasPrefix:@"/private/var/"]) return raw;
    if ([raw hasPrefix:@"/"]) {
        NSString *jb = VIJBRoot(raw);
        if ([NSFileManager.defaultManager fileExistsAtPath:jb]) return jb;
        return raw;
    }
    return [VIMediaContainerPath() stringByAppendingPathComponent:raw];
}

- (VIMediaKind)forcedMediaKind {
    NSUInteger k = [[self _value:@"forcedMediaKind"] unsignedIntegerValue];
    return (k <= VIMediaKindStaticImage) ? (VIMediaKind)k : VIMediaKindNone;
}

- (CGFloat)gifFrameRateCap { return VIClamp([self _float:@"gifFrameRateCap"], 0, 60); }
- (BOOL)mediaFillsPill     { return [self _bool:@"mediaFillsPill"]; }

#pragma mark - Geometry trim

- (CGFloat)offsetX             { return VIQuantiseHalfPoint(VIClamp([self _float:@"offsetX"],            -60, 60)); }
- (CGFloat)offsetY             { return VIQuantiseHalfPoint(VIClamp([self _float:@"offsetY"],            -20, 60)); }
- (CGFloat)widthDelta          { return VIQuantiseHalfPoint(VIClamp([self _float:@"widthDelta"],         -60, 120)); }
- (CGFloat)heightDelta         { return VIQuantiseHalfPoint(VIClamp([self _float:@"heightDelta"],        -12, 40)); }
- (CGFloat)cornerRadiusDelta   { return VIQuantiseHalfPoint(VIClamp([self _float:@"cornerRadiusDelta"],  -20, 20)); }
- (CGFloat)bubbleDiameterDelta { return VIQuantiseHalfPoint(VIClamp([self _float:@"bubbleDiameterDelta"],-10, 24)); }
- (CGFloat)moduleGapDelta      { return VIQuantiseHalfPoint(VIClamp([self _float:@"moduleGapDelta"],     -6,  30)); }

#pragma mark - Hardware override

- (NSString *)presetOverrideIdentifier {
    NSString *raw = [self _value:@"presetOverride"];
    if (![raw isKindOfClass:NSString.class] || raw.length == 0) return nil;
    return raw;
}

@end
