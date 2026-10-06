//
//  VIActivitySources.x
//  VisibleIsland 2.0 — the one activity source that needs a hook.
//
//  Everything else (music, charging, volume, Low Power, lock state) arrives as
//  a notification and lives in VIActivityCenter. The ringer switch does not
//  post anything public, so it has to be intercepted — and the class that owns
//  it moved between firmwares, hence two guarded groups and a runtime probe.
//

#import "Headers.h"
#import "VIActivity.h"
#import "VIActivityCenter.h"

static void VIPublishRinger(BOOL muted) {
    VIActivity *activity =
        [VIActivity activityWithKind:VIActivityKindRinger
                            priority:90
                               title:(muted ? @"Silent" : @"Ring")
                            subtitle:nil
                          symbolName:(muted ? @"bell.slash.fill" : @"bell.fill")
                             artwork:nil
                                tint:(muted ? [UIColor colorWithRed:1.0 green:0.62 blue:0.20 alpha:1.0]
                                            : [UIColor colorWithWhite:1.0 alpha:0.95])
                            progress:-1.0
                      showsEqualizer:NO
                              sticky:NO
                            lifetime:1.8
                           tapAction:VIActivityActionNone];

    // publishActivity re-checks the per-kind switch, so no preference lookup
    // is duplicated here.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VIActivityCenter sharedCenter] publishActivity:activity];
    });
}

#pragma mark - iOS 15–17: SBRingerControl

%group VIRingerControlSource

%hook SBRingerControl

- (void)setRingerMuted:(BOOL)muted {
    %orig;
    VIPublishRinger(muted);
}

%end

%end

#pragma mark - iOS 14 fallback: SBRingerHUDController

%group VIRingerHUDSource

%hook SBRingerHUDController

- (void)presentRingerHUDForVolume:(float)volume mute:(BOOL)mute {
    %orig;
    VIPublishRinger(mute);
}

%end

%end

#pragma mark - Install

// Called once from Tweak.x after SpringBoard finishes launching. Probing with
// instancesRespondToSelector: means an unexpected firmware loses the ringer
// activity instead of taking SpringBoard down with a bad hook.
void VIActivitySourcesInstall(void) {
    Class ringerControl = objc_getClass("SBRingerControl");
    if (ringerControl && [ringerControl instancesRespondToSelector:@selector(setRingerMuted:)]) {
        %init(VIRingerControlSource);
        VILog(@"ringer source: SBRingerControl");
        return;
    }

    Class ringerHUD = objc_getClass("SBRingerHUDController");
    if (ringerHUD && [ringerHUD instancesRespondToSelector:@selector(presentRingerHUDForVolume:mute:)]) {
        %init(VIRingerHUDSource);
        VILog(@"ringer source: SBRingerHUDController");
        return;
    }

    VILog(@"no ringer source on this firmware — switch activity disabled");
}
