//
//  VIPresets.h
//  Hardware geometry database.
//
//  All values are PORTRAIT POINTS in the coordinate space of the main screen
//  (origin = top-left of the physical display, not the safe area). The center
//  pill is horizontally centered by the layout engine, so only Y / W / H /
//  radius are stored per model; originX is derived and exposed for callers who
//  need an absolute frame.
//

#import <UIKit/UIKit.h>
#import "Headers.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct VIIslandGeometry {
    CGFloat originY;          // top inset of the center pill
    CGFloat width;            // center pill width
    CGFloat height;           // center pill height
    CGFloat cornerRadius;     // center pill radius (continuous curve)
    CGFloat bubbleDiameter;   // satellite diameter
    CGFloat moduleGap;        // gap between pill and each satellite
} VIIslandGeometry;

typedef struct VIDevicePreset {
    const char      *identifier;   // hw.machine, e.g. "iPhone12,3"
    const char      *marketing;    // human readable, shown in Settings
    CGFloat          screenWidth;  // portrait reference width — sanity check
    BOOL             hasNotch;
    BOOL             nativeIsland; // YES → tweak disables itself
    VIIslandGeometry geometry;
} VIDevicePreset;

@interface VIPresets : NSObject

/// Raw hw.machine of the running device ("iPhone13,2"). Cached.
+ (NSString *)machineIdentifier;

/// Preset for the running device, honouring the Settings override.
/// Falls back to a screen-size heuristic for unknown identifiers.
+ (VIDevicePreset)activePreset;

/// Preset lookup by hw.machine. `found` reports whether the table had an entry.
+ (VIDevicePreset)presetForIdentifier:(NSString *)identifier found:(BOOL * _Nullable)found;

/// Geometry after applying the user's 0.5 pt trims from VIPrefs.
+ (VIIslandGeometry)effectiveGeometry;

/// Absolute portrait frame of the center pill on the main screen.
+ (CGRect)centerPillFrameForGeometry:(VIIslandGeometry)geometry inBounds:(CGRect)bounds;

/// YES when the device already ships a real Dynamic Island (iPhone 14 Pro+),
/// or when the tweak has no meaningful layout for it (iPad, unknown Mac idiom).
+ (BOOL)deviceShouldBeSkipped;

/// Ordered list for the Settings picker: @[ @{ @"id": ..., @"name": ... }, ... ]
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)selectablePresets;

@end

NS_ASSUME_NONNULL_END
