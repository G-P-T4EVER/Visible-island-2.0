#import "VIActivityCenter.h"
#import "VIPrefs.h"

#import <dlfcn.h>
#import <notify.h>

#pragma mark - Priorities and lifetimes

// Transient system events outrank the sticky now-playing activity while they
// are alive, then expire and hand the pill back to music. This is the same
// hierarchy Apple's own island uses.
static const NSInteger kVIPriorityRinger      = 90;
static const NSInteger kVIPriorityVolume      = 85;
static const NSInteger kVIPriorityCharging    = 80;
static const NSInteger kVIPriorityLockState   = 70;
static const NSInteger kVIPriorityLowPower    = 60;
static const NSInteger kVIPriorityNowPlaying  = 50;

static const NSTimeInterval kVILifetimeRinger    = 1.8;
static const NSTimeInterval kVILifetimeVolume    = 1.4;
static const NSTimeInterval kVILifetimeCharging  = 4.0;
static const NSTimeInterval kVILifetimeLockState = 1.5;
static const NSTimeInterval kVILifetimeLowPower  = 3.0;

#pragma mark - MediaRemote (dlopen'd, never linked)

// Linking MediaRemote would make the dylib refuse to load on any firmware that
// moved or renamed the framework. Resolving lazily keeps the tweak alive with
// music support simply switched off.
typedef void (*VIMRRegisterFn)(dispatch_queue_t);
typedef void (*VIMRUnregisterFn)(void);
typedef void (*VIMRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*VIMRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*VIMRSendCommandFn)(int, id);

static VIMRRegisterFn      VIMRRegister      = NULL;
static VIMRUnregisterFn    VIMRUnregister    = NULL;
static VIMRGetInfoFn       VIMRGetInfo       = NULL;
static VIMRGetIsPlayingFn  VIMRGetIsPlaying  = NULL;
static VIMRSendCommandFn   VIMRSendCommand   = NULL;

// MRMediaRemoteCommand values.
static const int kVIMRCommandTogglePlayPause = 2;
static const int kVIMRCommandNextTrack       = 4;
static const int kVIMRCommandPreviousTrack   = 5;

static BOOL VILoadMediaRemote(void) {
    static BOOL loaded = NO;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        // System framework: the path is identical on rootful and rootless, so
        // no jbroot translation is involved here.
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                              RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) {
            handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                            RTLD_LAZY);
        }
        if (!handle) {
            VILog(@"MediaRemote unavailable (%s) — now-playing activity disabled", dlerror());
            return;
        }

        VIMRRegister     = (VIMRRegisterFn)     dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        VIMRUnregister   = (VIMRUnregisterFn)   dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications");
        VIMRGetInfo      = (VIMRGetInfoFn)      dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        VIMRGetIsPlaying = (VIMRGetIsPlayingFn) dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        VIMRSendCommand  = (VIMRSendCommandFn)  dlsym(handle, "MRMediaRemoteSendCommand");

        loaded = (VIMRRegister && VIMRGetInfo && VIMRGetIsPlaying);
        VILog(@"MediaRemote loaded=%d (send=%d)", loaded, VIMRSendCommand != NULL);
    });
    return loaded;
}

#pragma mark - Darwin lock-state bridge

static void VILockStateCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo);

#pragma mark -

// Declared here so the Darwin callback at the bottom of this file can reach it
// without exposing an implementation detail on the public interface.
@interface VIActivityCenter ()
- (void)handleLockStateChange;
@end

@implementation VIActivityCenter {
    // kind (boxed) → VIActivity
    NSMutableDictionary<NSNumber *, VIActivity *> *_activities;
    // kind (boxed) → monotonic publication sequence, used to break priority ties
    NSMutableDictionary<NSNumber *, NSNumber *> *_sequence;
    NSUInteger _sequenceCounter;

    NSTimer *_expiryTimer;
    BOOL     _started;

    // Reused so VIActivity's pointer-identity diff stays meaningful.
    UIImage *_cachedArtwork;
    NSUInteger _cachedArtworkHash;

    BOOL _nowPlayingIsPlaying;
}

+ (instancetype)sharedCenter {
    static VIActivityCenter *shared = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _activities = [NSMutableDictionary dictionary];
        _sequence   = [NSMutableDictionary dictionary];
        _leadingRole  = VIActivityRoleGlyph;
        _trailingRole = VIActivityRoleAccessory;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Lifecycle

- (void)start {
    if (_started) return;
    _started = YES;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    // ── Now playing ─────────────────────────────────────────────────────
    if (VILoadMediaRemote()) {
        VIMRRegister(dispatch_get_main_queue());

        [nc addObserver:self
               selector:@selector(_nowPlayingInfoChanged:)
                   name:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification"
                 object:nil];

        [nc addObserver:self
               selector:@selector(_nowPlayingStateChanged:)
                   name:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
                 object:nil];

        [nc addObserver:self
               selector:@selector(_nowPlayingStateChanged:)
                   name:@"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
                 object:nil];
    }

    // ── Battery / charging ──────────────────────────────────────────────
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    [nc addObserver:self
           selector:@selector(_batteryStateChanged:)
               name:UIDeviceBatteryStateDidChangeNotification
             object:nil];

    // ── Volume ──────────────────────────────────────────────────────────
    // AVSystemController posts this for every hardware-button change; no hook
    // and no private class reference required.
    [nc addObserver:self
           selector:@selector(_volumeChanged:)
               name:@"AVSystemController_SystemVolumeDidChangeNotification"
             object:nil];

    // ── Low Power Mode ──────────────────────────────────────────────────
    [nc addObserver:self
           selector:@selector(_powerStateChanged:)
               name:NSProcessInfoPowerStateDidChangeNotification
             object:nil];

    // ── Lock / unlock ───────────────────────────────────────────────────
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    VILockStateCallback,
                                    CFSTR("com.apple.springboard.lockstate"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    [self _refreshNowPlaying];
    VILog(@"activity center started");
}

- (void)stop {
    if (!_started) return;
    _started = NO;

    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
    if (VIMRUnregister) VIMRUnregister();

    [_expiryTimer invalidate];
    _expiryTimer = nil;

    [_activities removeAllObjects];
    [_sequence removeAllObjects];
    _cachedArtwork = nil;

    [self _resolveAndNotify];
    VILog(@"activity center stopped");
}

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) return;
    _suspended = suspended;

    if (suspended) {
        // Drop everything transient and park the timer: a sleeping device must
        // not hold a run-loop source open for an activity nobody can see.
        NSArray<NSNumber *> *keys = _activities.allKeys;
        for (NSNumber *key in keys) {
            VIActivity *activity = _activities[key];
            if (!activity.sticky) {
                [_activities removeObjectForKey:key];
                [_sequence removeObjectForKey:key];
            }
        }
        [_expiryTimer invalidate];
        _expiryTimer = nil;
        [self _resolveAndNotify];
        return;
    }

    // Waking up: re-query the one source that can have changed silently.
    [self _refreshNowPlaying];
    [self _resolveAndNotify];
}

#pragma mark - Publication

- (void)publishActivity:(VIActivity *)activity {
    if (!activity || activity.kind == VIActivityKindNone) return;
    if (!VIPrefs.shared.activitiesEnabled) return;
    if (![self isKindEnabled:activity.kind]) return;

    // While the screen is off only sticky state is worth tracking.
    if (self.suspended && !activity.sticky) return;

    NSNumber *key = @(activity.kind);
    VIActivity *existing = _activities[key];

    // A visually identical *sticky* republish is genuinely nothing to do.
    // A transient one, though, must refresh its deadline — that is how holding
    // the volume button keeps the island alive instead of blinking out.
    if (existing && activity.sticky && [existing isVisuallyEqualToActivity:activity]) return;

    _activities[key] = activity;
    if (!existing) _sequence[key] = @(++_sequenceCounter);

    [self _resolveAndNotify];
}

- (void)retireActivityOfKind:(VIActivityKind)kind {
    NSNumber *key = @(kind);
    if (!_activities[key]) return;
    [_activities removeObjectForKey:key];
    [_sequence removeObjectForKey:key];
    [self _resolveAndNotify];
}

#pragma mark - Resolution

- (BOOL)hasActivity {
    return self.centerActivity != nil;
}

- (void)_resolveAndNotify {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // 1. Prune anything past its deadline.
    NSArray<NSNumber *> *keys = _activities.allKeys;
    for (NSNumber *key in keys) {
        if ([_activities[key] isExpiredAtTime:now]) {
            [_activities removeObjectForKey:key];
            [_sequence removeObjectForKey:key];
        }
    }

    // 2. Rank: priority first, most recent publication second.
    // Hoisted out of the block so the comparator does not capture self.
    NSDictionary<NSNumber *, NSNumber *> *sequence = [_sequence copy];
    NSArray<VIActivity *> *ranked =
        [_activities.allValues sortedArrayUsingComparator:^NSComparisonResult(VIActivity *a, VIActivity *b) {
            if (a.priority != b.priority) return (a.priority > b.priority) ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger sa = sequence[@(a.kind)].unsignedIntegerValue;
            NSUInteger sb = sequence[@(b.kind)].unsignedIntegerValue;
            if (sa == sb) return NSOrderedSame;
            return (sa > sb) ? NSOrderedAscending : NSOrderedDescending;
        }];

    VIActivity *previousCenter   = _centerActivity;
    VIActivity *previousLeading  = _leadingActivity;
    VIActivity *previousTrailing = _trailingActivity;
    VIActivityRole previousLeadingRole  = _leadingRole;
    VIActivityRole previousTrailingRole = _trailingRole;

    // 3. Assign modules. One activity still fills all three sections: the pill
    //    keeps the content, its identity glyph flies out left, its live
    //    accessory flies out right.
    switch (ranked.count) {
        case 0:
            _centerActivity = nil;
            _leadingActivity = nil;
            _trailingActivity = nil;
            _leadingRole  = VIActivityRoleGlyph;
            _trailingRole = VIActivityRoleAccessory;
            break;

        case 1:
            _centerActivity   = ranked[0];
            _leadingActivity  = ranked[0];
            _trailingActivity = ranked[0];
            _leadingRole  = VIActivityRoleGlyph;
            _trailingRole = VIActivityRoleAccessory;
            break;

        case 2:
            _centerActivity   = ranked[0];
            _leadingActivity  = ranked[1];
            _trailingActivity = ranked[0];
            _leadingRole  = VIActivityRoleGlyph;
            _trailingRole = VIActivityRoleAccessory;
            break;

        default:
            _centerActivity   = ranked[0];
            _leadingActivity  = ranked[1];
            _trailingActivity = ranked[2];
            _leadingRole  = VIActivityRoleGlyph;
            _trailingRole = VIActivityRoleGlyph;
            break;
    }

    // 4. Re-arm the expiry timer for the earliest remaining deadline.
    [self _rearmExpiryTimer];

    // 5. Only bother the island if something actually changed.
    BOOL changed =
        ![self _activity:previousCenter   matches:_centerActivity]   ||
        ![self _activity:previousLeading  matches:_leadingActivity]  ||
        ![self _activity:previousTrailing matches:_trailingActivity] ||
        previousLeadingRole  != _leadingRole ||
        previousTrailingRole != _trailingRole;

    if (!changed) return;

    VILog(@"activities resolved: center=%@ leading=%@ trailing=%@",
          [_centerActivity kindDescription] ?: @"-",
          [_leadingActivity kindDescription] ?: @"-",
          [_trailingActivity kindDescription] ?: @"-");

    [self.delegate activityCenterDidUpdateActivities:self];
}

- (BOOL)_activity:(VIActivity *)a matches:(VIActivity *)b {
    if (a == b) return YES;
    if (!a || !b) return NO;
    return [a isVisuallyEqualToActivity:b];
}

- (void)_rearmExpiryTimer {
    [_expiryTimer invalidate];
    _expiryTimer = nil;
    if (self.suspended) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval earliest = 0.0;
    for (VIActivity *activity in _activities.allValues) {
        if (activity.sticky) continue;
        if (earliest == 0.0 || activity.expiry < earliest) earliest = activity.expiry;
    }
    if (earliest == 0.0) return;

    NSTimeInterval delay = MAX(0.05, earliest - now);
    __weak typeof(self) weakSelf = self;
    _expiryTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                   repeats:NO
                                                     block:^(NSTimer *timer) {
        [weakSelf _resolveAndNotify];
    }];
}

#pragma mark - Now playing

- (void)_nowPlayingStateChanged:(NSNotification *)note {
    [self _refreshNowPlaying];
}

- (void)_nowPlayingInfoChanged:(NSNotification *)note {
    [self _refreshNowPlaying];
}

- (void)_refreshNowPlaying {
    if (!VILoadMediaRemote()) return;
    if (![self isKindEnabled:VIActivityKindNowPlaying]) {
        [self retireActivityOfKind:VIActivityKindNowPlaying];
        return;
    }

    __weak typeof(self) weakSelf = self;
    VIMRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_nowPlayingIsPlaying = (isPlaying != 0);

        if (!isPlaying) {
            // Paused or stopped: the island must not keep a stale track pinned.
            [strongSelf retireActivityOfKind:VIActivityKindNowPlaying];
            return;
        }

        VIMRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef rawInfo) {
            typeof(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            NSDictionary *info = (__bridge NSDictionary *)rawInfo;
            [innerSelf _publishNowPlayingWithInfo:info];
        });
    });
}

- (void)_publishNowPlayingWithInfo:(NSDictionary *)info {
    if (![info isKindOfClass:NSDictionary.class]) return;

    NSString *title  = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    if (![title isKindOfClass:NSString.class])  title = nil;
    if (![artist isKindOfClass:NSString.class]) artist = nil;
    if (title.length == 0 && artist.length == 0) return;

    NSData *artworkData = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    UIImage *artwork = [self _artworkFromData:artworkData];

    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindNowPlaying
                            priority:kVIPriorityNowPlaying
                               title:title ?: artist
                            subtitle:(title.length ? artist : nil)
                          symbolName:@"music.note"
                             artwork:artwork
                                tint:[UIColor colorWithRed:1.0 green:0.29 blue:0.36 alpha:1.0]
                            progress:-1.0
                      showsEqualizer:YES
                              sticky:YES
                            lifetime:0.0
                           tapAction:VIActivityActionTogglePlayPause];

    [self publishActivity:activity];
}

// Album art arrives as full-size JPEG data on every track change. Decoding it
// at native resolution into SpringBoard is exactly the kind of allocation that
// gets the process Jetsam'd, so it is downsampled to the satellite size once
// and cached by content hash — which also keeps the pointer stable for the
// visual-equality check in VIActivity.
- (UIImage *)_artworkFromData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || data.length == 0) return nil;

    NSUInteger hash = data.length ^ (((const uint8_t *)data.bytes)[0] << 8) ^ data.hash;
    if (_cachedArtwork && hash == _cachedArtworkHash) return _cachedArtwork;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    const CGFloat maxPixel = 96.0 * (UIScreen.mainScreen.scale ?: 2.0);
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform   : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize          : @(maxPixel),
        (id)kCGImageSourceShouldCacheImmediately         : @YES,
    };

    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumb) return nil;

    UIImage *image = [UIImage imageWithCGImage:thumb
                                         scale:(UIScreen.mainScreen.scale ?: 2.0)
                                   orientation:UIImageOrientationUp];
    CGImageRelease(thumb);

    _cachedArtwork = image;
    _cachedArtworkHash = hash;
    return image;
}

#pragma mark - Battery

- (void)_batteryStateChanged:(NSNotification *)note {
    if (![self isKindEnabled:VIActivityKindCharging]) return;

    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    CGFloat level = UIDevice.currentDevice.batteryLevel;   // -1 when unknown
    BOOL charging = (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);

    NSString *title = (level >= 0.0)
        ? [NSString stringWithFormat:@"%d%%", (int)round(level * 100.0)]
        : (charging ? @"Charging" : @"Unplugged");

    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindCharging
                            priority:kVIPriorityCharging
                               title:title
                            subtitle:(charging ? @"Charging" : @"Not charging")
                          symbolName:(charging ? @"bolt.fill" : @"bolt.slash.fill")
                             artwork:nil
                                tint:(charging ? [UIColor colorWithRed:0.30 green:0.85 blue:0.39 alpha:1.0]
                                               : [UIColor colorWithWhite:0.72 alpha:1.0])
                            progress:(level >= 0.0 ? level : -1.0)
                      showsEqualizer:NO
                              sticky:NO
                            lifetime:kVILifetimeCharging
                           tapAction:VIActivityActionNone];

    [self publishActivity:activity];
}

#pragma mark - Volume

- (void)_volumeChanged:(NSNotification *)note {
    if (![self isKindEnabled:VIActivityKindVolume]) return;

    NSDictionary *userInfo = note.userInfo;
    NSString *reason = userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
    // Only react to the hardware buttons / Control Center, never to a route
    // change or an app setting its own category volume.
    if ([reason isKindOfClass:NSString.class] &&
        ![reason isEqualToString:@"ExplicitVolumeChange"]) return;

    NSNumber *value = userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
    if (![value isKindOfClass:NSNumber.class]) return;
    CGFloat volume = MIN(MAX(value.doubleValue, 0.0), 1.0);

    NSString *symbol = (volume <= 0.001) ? @"speaker.slash.fill"
                     : (volume < 0.5)    ? @"speaker.wave.1.fill"
                                         : @"speaker.wave.3.fill";

    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindVolume
                            priority:kVIPriorityVolume
                               title:[NSString stringWithFormat:@"%d%%", (int)round(volume * 100.0)]
                            subtitle:@"Volume"
                          symbolName:symbol
                             artwork:nil
                                tint:[UIColor colorWithWhite:1.0 alpha:0.95]
                            progress:volume
                      showsEqualizer:NO
                              sticky:NO
                            lifetime:kVILifetimeVolume
                           tapAction:VIActivityActionNone];

    [self publishActivity:activity];
}

#pragma mark - Low Power Mode

- (void)_powerStateChanged:(NSNotification *)note {
    if (![self isKindEnabled:VIActivityKindLowPower]) return;

    BOOL low = NSProcessInfo.processInfo.lowPowerModeEnabled;

    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindLowPower
                            priority:kVIPriorityLowPower
                               title:(low ? @"Low Power" : @"Normal Power")
                            subtitle:nil
                          symbolName:(low ? @"battery.25" : @"battery.100")
                             artwork:nil
                                tint:(low ? [UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1.0]
                                          : [UIColor colorWithWhite:0.85 alpha:1.0])
                            progress:-1.0
                      showsEqualizer:NO
                              sticky:NO
                            lifetime:kVILifetimeLowPower
                           tapAction:VIActivityActionNone];

    [self publishActivity:activity];
}

#pragma mark - Lock state

- (void)handleLockStateChange {
    if (![self isKindEnabled:VIActivityKindLockState]) return;

    BOOL locked = YES;
    Class managerClass = objc_getClass("SBLockScreenManager");
    if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
        id manager = [managerClass sharedInstance];
        if ([manager respondsToSelector:@selector(isUILocked)]) {
            locked = [manager isUILocked];
        }
    }

    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindLockState
                            priority:kVIPriorityLockState
                               title:(locked ? @"Locked" : @"Unlocked")
                            subtitle:nil
                          symbolName:(locked ? @"lock.fill" : @"lock.open.fill")
                             artwork:nil
                                tint:[UIColor colorWithWhite:1.0 alpha:0.92]
                            progress:-1.0
                      showsEqualizer:NO
                              sticky:NO
                            lifetime:kVILifetimeLockState
                           tapAction:VIActivityActionNone];

    [self publishActivity:activity];
}

#pragma mark - Interaction

- (void)performAction:(VIActivityAction)action {
    if (action == VIActivityActionNone) return;
    if (!VILoadMediaRemote() || !VIMRSendCommand) return;

    int command;
    switch (action) {
        case VIActivityActionTogglePlayPause: command = kVIMRCommandTogglePlayPause; break;
        case VIActivityActionNextTrack:       command = kVIMRCommandNextTrack;       break;
        case VIActivityActionPreviousTrack:   command = kVIMRCommandPreviousTrack;   break;
        default: return;
    }

    VIMRSendCommand(command, nil);
    VILog(@"sent MediaRemote command %d", command);

    // The state notification follows asynchronously; nudge a refresh so a
    // pause reflects in the island immediately rather than a beat later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self _refreshNowPlaying];
    });
}

#pragma mark - Preferences

- (BOOL)isKindEnabled:(VIActivityKind)kind {
    VIPrefs *prefs = VIPrefs.shared;
    if (!prefs.activitiesEnabled) return NO;

    switch (kind) {
        case VIActivityKindNowPlaying: return prefs.activityNowPlaying;
        case VIActivityKindCharging:   return prefs.activityCharging;
        case VIActivityKindRinger:     return prefs.activityRinger;
        case VIActivityKindVolume:     return prefs.activityVolume;
        case VIActivityKindLowPower:   return prefs.activityLowPower;
        case VIActivityKindLockState:  return prefs.activityLockState;
        case VIActivityKindNone:       return NO;
    }
    return NO;
}

- (void)applyPreferences {
    NSArray<NSNumber *> *keys = _activities.allKeys;
    for (NSNumber *key in keys) {
        if (![self isKindEnabled:(VIActivityKind)key.unsignedIntegerValue]) {
            [_activities removeObjectForKey:key];
            [_sequence removeObjectForKey:key];
        }
    }
    [self _refreshNowPlaying];
    [self _resolveAndNotify];
}

@end

#pragma mark - Darwin callback

static void VILockStateCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VIActivityCenter sharedCenter] handleLockStateChange];
    });
}
