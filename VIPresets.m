#import "VIPresets.h"
#import "VIPrefs.h"
#import <sys/sysctl.h>

// ────────────────────────────────────────────────────────────────────────────
// Geometry notes
//
//   Notch devices: the pill is inset BELOW the notch cutout and centered on it,
//   so its width is deliberately narrower than the physical notch (the notch on
//   X/XS/11 Pro is ~209 pt wide, on XR/11 ~230 pt). A 126–134 pt pill reads as
//   a Dynamic Island rather than "a black bar".
//
//   Non-notch devices (7/8/SE2/SE3): the 20 pt status bar is the only vertical
//   budget available, so the pill is short (17–18 pt) and sits at y = 1.5 with
//   the status bar left intact behind it. Satellites shrink accordingly.
//
//   originY is measured from the TOP of the display, matching the window's
//   own coordinate space (the window ignores safe-area insets by design).
// ────────────────────────────────────────────────────────────────────────────

#define VI_G(y, w, h, r, bd, gap) (VIIslandGeometry){ .originY = (y), .width = (w), .height = (h), \
                                                     .cornerRadius = (r), .bubbleDiameter = (bd), .moduleGap = (gap) }

static const VIDevicePreset kVIPresets[] = {

    // ── Touch ID, 4.7" / 5.5" — pill overlays the 20 pt status bar ───────────
    { "iPhone9,1",  "iPhone 7",              375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },
    { "iPhone9,3",  "iPhone 7",              375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },
    { "iPhone9,2",  "iPhone 7 Plus",         414, NO, NO, VI_G(1.5,  126, 18,   9.0, 14, 5) },
    { "iPhone9,4",  "iPhone 7 Plus",         414, NO, NO, VI_G(1.5,  126, 18,   9.0, 14, 5) },
    { "iPhone10,1", "iPhone 8",              375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },
    { "iPhone10,4", "iPhone 8",              375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },
    { "iPhone10,2", "iPhone 8 Plus",         414, NO, NO, VI_G(1.5,  126, 18,   9.0, 14, 5) },
    { "iPhone10,5", "iPhone 8 Plus",         414, NO, NO, VI_G(1.5,  126, 18,   9.0, 14, 5) },
    { "iPhone12,8", "iPhone SE (2nd gen)",   375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },
    { "iPhone14,6", "iPhone SE (3rd gen)",   375, NO, NO, VI_G(1.5,  116, 17,   8.5, 13, 5) },

    // ── 5.8" notch: X / XS / 11 Pro  (375 × 812, notch 209 × 30) ─────────────
    { "iPhone10,3", "iPhone X",              375, YES, NO, VI_G(10.0, 124, 32,  16.0, 26, 8) },
    { "iPhone10,6", "iPhone X",              375, YES, NO, VI_G(10.0, 124, 32,  16.0, 26, 8) },
    { "iPhone11,2", "iPhone XS",             375, YES, NO, VI_G(10.0, 124, 32,  16.0, 26, 8) },
    { "iPhone12,3", "iPhone 11 Pro",         375, YES, NO, VI_G(10.0, 124, 32,  16.0, 26, 8) },

    // ── 6.1" LCD notch: XR / 11  (414 × 896, notch 230 × 33) ────────────────
    { "iPhone11,8", "iPhone XR",             414, YES, NO, VI_G(11.0, 132, 34,  17.0, 28, 9) },
    { "iPhone12,1", "iPhone 11",             414, YES, NO, VI_G(11.0, 132, 34,  17.0, 28, 9) },

    // ── 6.5" OLED notch: XS Max / 11 Pro Max  (414 × 896) ───────────────────
    { "iPhone11,4", "iPhone XS Max",         414, YES, NO, VI_G(11.0, 132, 33,  16.5, 27, 9) },
    { "iPhone11,6", "iPhone XS Max",         414, YES, NO, VI_G(11.0, 132, 33,  16.5, 27, 9) },
    { "iPhone12,5", "iPhone 11 Pro Max",     414, YES, NO, VI_G(11.0, 132, 33,  16.5, 27, 9) },

    // ── 6.1" flat-edge notch: 12 / 12 Pro / 13 / 13 Pro  (390 × 844) ─────────
    // 12/12 Pro notch ≈ 209 × 32; 13/13 Pro notch ≈ 161 × 31.5 → tighter pill.
    { "iPhone13,2", "iPhone 12",             390, YES, NO, VI_G(11.0, 126, 33,  16.5, 27, 8) },
    { "iPhone13,3", "iPhone 12 Pro",         390, YES, NO, VI_G(11.0, 126, 33,  16.5, 27, 8) },
    { "iPhone14,5", "iPhone 13",             390, YES, NO, VI_G(11.0, 122, 32,  16.0, 26, 8) },
    { "iPhone14,2", "iPhone 13 Pro",         390, YES, NO, VI_G(11.0, 122, 32,  16.0, 26, 8) },
    { "iPhone13,1", "iPhone 12 mini",        360, YES, NO, VI_G(10.0, 112, 30,  15.0, 24, 7) },
    { "iPhone14,4", "iPhone 13 mini",        360, YES, NO, VI_G(10.0, 112, 30,  15.0, 24, 7) },

    // ── 6.7" notch: 12 Pro Max / 13 Pro Max  (428 × 926) ────────────────────
    { "iPhone13,4", "iPhone 12 Pro Max",     428, YES, NO, VI_G(12.0, 136, 35,  17.5, 29, 9) },
    { "iPhone14,3", "iPhone 13 Pro Max",     428, YES, NO, VI_G(12.0, 136, 35,  17.5, 29, 9) },

    // ── 6.1/6.7" notch, A15 non-Pro 14 family — same metrics as the 13 ──────
    { "iPhone14,7", "iPhone 14",             390, YES, NO, VI_G(11.0, 122, 32,  16.0, 26, 8) },
    { "iPhone14,8", "iPhone 14 Plus",        428, YES, NO, VI_G(12.0, 136, 35,  17.5, 29, 9) },

    // ── Native Dynamic Island — the tweak must stand down ───────────────────
    { "iPhone15,2", "iPhone 14 Pro",         393, YES, YES, VI_G(11.0, 126, 37.33, 18.67, 30, 8) },
    { "iPhone15,3", "iPhone 14 Pro Max",     430, YES, YES, VI_G(11.0, 126, 37.33, 18.67, 30, 8) },
};

static const NSUInteger kVIPresetCount = sizeof(kVIPresets) / sizeof(kVIPresets[0]);

@implementation VIPresets

#pragma mark - Model detection

+ (NSString *)machineIdentifier {
    static NSString *machine = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        size_t size = 0;
        // hw.machine is the marketing-free identifier ( "iPhone13,2" ) on device.
        // On the simulator it returns the host arch, hence the fallback below.
        if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) == 0 && size > 0) {
            char *buf = (char *)malloc(size);
            if (buf) {
                if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
                    machine = [NSString stringWithUTF8String:buf];
                }
                free(buf);
            }
        }
        if (machine.length == 0 || ![machine hasPrefix:@"iPhone"]) {
            // SIMULATOR_MODEL_IDENTIFIER for dev builds; "unknown" otherwise.
            const char *sim = getenv("SIMULATOR_MODEL_IDENTIFIER");
            machine = sim ? [NSString stringWithUTF8String:sim] : (machine ?: @"unknown");
        }
        VILog(@"hw.machine = %@", machine);
    });
    return machine;
}

+ (VIDevicePreset)presetForIdentifier:(NSString *)identifier found:(BOOL *)found {
    const char *needle = identifier.UTF8String ?: "";
    for (NSUInteger i = 0; i < kVIPresetCount; i++) {
        if (strcmp(kVIPresets[i].identifier, needle) == 0) {
            if (found) *found = YES;
            return kVIPresets[i];
        }
    }
    if (found) *found = NO;
    return [self _heuristicPreset];
}

// Unknown identifier (new hardware, spoofed sysctl): derive from the reference
// bounds so the tweak degrades gracefully instead of drawing off-screen.
+ (VIDevicePreset)_heuristicPreset {
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat w = MIN(bounds.size.width, bounds.size.height);
    CGFloat h = MAX(bounds.size.width, bounds.size.height);
    BOOL notch = (h / w) > 1.9; // 19.5:9 and taller

    VIDevicePreset p = {
        .identifier   = "generic",
        .marketing    = "Generic (auto)",
        .screenWidth  = w,
        .hasNotch     = notch,
        .nativeIsland = NO,
        .geometry     = notch ? VI_G(11.0, MIN(136, w * 0.33), 33, 16.5, 27, 8)
                              : VI_G(1.5,  MIN(126, w * 0.31), 17,  8.5, 13, 5),
    };
    return p;
}

+ (VIDevicePreset)activePreset {
    NSString *override = VIPrefs.shared.presetOverrideIdentifier;
    NSString *identifier = override.length ? override : [self machineIdentifier];

    BOOL found = NO;
    VIDevicePreset preset = [self presetForIdentifier:identifier found:&found];

    // A manual override intentionally bypasses the nativeIsland guard: a
    // 14 Pro user may still want the tweak for a custom media pill.
    if (override.length) preset.nativeIsland = NO;
    return preset;
}

+ (BOOL)deviceShouldBeSkipped {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return YES;
    return [self activePreset].nativeIsland;
}

#pragma mark - Effective geometry

+ (VIIslandGeometry)effectiveGeometry {
    VIPrefs *p = VIPrefs.shared;
    VIIslandGeometry g = [self activePreset].geometry;

    g.originY        = MAX(0.0,  g.originY        + p.offsetY);
    g.width          = MAX(24.0, g.width          + p.widthDelta);
    g.height         = MAX(10.0, g.height         + p.heightDelta);
    g.cornerRadius   = MAX(0.0,  g.cornerRadius   + p.cornerRadiusDelta);
    g.bubbleDiameter = MAX(8.0,  g.bubbleDiameter + p.bubbleDiameterDelta);
    g.moduleGap      = MAX(0.0,  g.moduleGap      + p.moduleGapDelta);

    // A radius larger than half the height renders as a lozenge with clipped
    // corners on continuous curves — clamp it.
    g.cornerRadius = MIN(g.cornerRadius, g.height / 2.0);
    return g;
}

+ (CGRect)centerPillFrameForGeometry:(VIIslandGeometry)g inBounds:(CGRect)bounds {
    CGFloat x = round((CGRectGetWidth(bounds) - g.width) / 2.0 * 2.0) / 2.0 + VIPrefs.shared.offsetX;
    return CGRectMake(x, g.originY, g.width, g.height);
}

#pragma mark - Settings picker

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)selectablePresets {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:kVIPresetCount + 1];
    [out addObject:@{ @"id" : @"", @"name" : @"Auto-detect" }];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < kVIPresetCount; i++) {
        NSString *name = [NSString stringWithUTF8String:kVIPresets[i].marketing];
        if ([seen containsObject:name]) continue;   // 7 / 7 (GSM) share metrics
        [seen addObject:name];
        [out addObject:@{
            @"id"   : [NSString stringWithUTF8String:kVIPresets[i].identifier],
            @"name" : name,
        }];
    }
    return [out copy];
}

@end
