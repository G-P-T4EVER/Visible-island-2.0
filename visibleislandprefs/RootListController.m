//
//  RootListController.m
//  VisibleIsland preference bundle.
//
//  • Blurred custom header (UIVisualEffectView) pinned as the table header.
//  • UIDocumentPickerViewController import with proper Security Scoped URL
//    handling — copy into the tweak's own container, then stop accessing.
//  • 0.5 pt geometry sliders (VIStepSliderCell).
//  • Respring via posix_spawn: sbreload first, killall -9 SpringBoard as the
//    fallback, both resolved through the rootless/rootful path abstraction.
//

#import "RootListController.h"
#import "VIBlurHeaderCell.h"
#import "VIStepSliderCell.h"
#import "VIPaths.h"
#import "VIPresets.h"
#import "Headers.h"

#import <spawn.h>
#import <sys/wait.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

static NSString * const kVIPrefsDomain = @"com.sa1nt.visibleisland";

#pragma mark - Preference IO

static NSMutableDictionary *VIReadPrefs(void) {
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:VIPreferencesPlistPath()];
    return onDisk ? onDisk.mutableCopy : [NSMutableDictionary dictionary];
}

static void VIWritePrefs(NSDictionary *prefs, const char *notification) {
    [prefs writeToFile:VIPreferencesPlistPath() atomically:YES];
    CFStringRef name = CFStringCreateWithCString(NULL, notification, kCFStringEncodingUTF8);
    if (!name) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, NULL, NULL, YES);
    CFRelease(name);
}

#pragma mark - Respring

static void VIRespring(void) {
    pid_t pid = -1;
    int status = 0;

    // 1) sbreload — graceful, keeps the SpringBoard state restoration path.
    NSString *sbreload = VIJBRoot(@"/usr/bin/sbreload");
    if ([NSFileManager.defaultManager isExecutableFileAtPath:sbreload]) {
        const char *path = sbreload.fileSystemRepresentation;
        char *const argv[] = { (char *)path, NULL };
        if (posix_spawn(&pid, path, NULL, NULL, argv, NULL) == 0) {
            waitpid(pid, &status, WEXITED);
            return;
        }
    }

    // 2) killall -9 SpringBoard — always available, harsher.
    NSString *killall = VIJBRoot(@"/usr/bin/killall");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:killall]) killall = @"/usr/bin/killall";
    const char *kpath = killall.fileSystemRepresentation;
    char *const kargv[] = { (char *)kpath, "-9", "SpringBoard", NULL };
    if (posix_spawn(&pid, kpath, NULL, NULL, kargv, NULL) == 0) {
        waitpid(pid, &status, WEXITED);
    }
}

#pragma mark -

@interface VIRootListController ()
@property (nonatomic, strong) UIVisualEffectView *headerBlurView;
@end

@implementation VIRootListController

#pragma mark - Specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - Lifecycle / blurred header

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"VisibleIsland";
    if (@available(iOS 13.0, *)) {
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }

    [self _installBlurredHeader];
    [self _refreshFooter];
}

- (void)_installBlurredHeader {
    CGFloat width = self.view.bounds.size.width ?: UIScreen.mainScreen.bounds.size.width;
    CGRect frame = CGRectMake(0, 0, width, 168.0);

    UIBlurEffectStyle style;
    if (@available(iOS 13.0, *)) style = UIBlurEffectStyleSystemThinMaterial;
    else                         style = UIBlurEffectStyleLight;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    blur.frame = frame;
    blur.clipsToBounds = YES;
    blur.layer.cornerRadius = 22.0;
    if (@available(iOS 13.0, *)) blur.layer.cornerCurve = kCACornerCurveContinuous;

    // Island-shaped preview sitting inside the blur, so the header doubles as a
    // live illustration of the current geometry.
    VIIslandGeometry geometry = [VIPresets effectiveGeometry];
    CGFloat previewScale = 1.6;
    CGFloat pillW = geometry.width * previewScale * 0.55;
    CGFloat pillH = geometry.height * previewScale;
    CGFloat bubble = geometry.bubbleDiameter * previewScale * 0.8;
    CGFloat gap = MAX(4.0, geometry.moduleGap * previewScale * 0.7);
    CGFloat centerY = 62.0;

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((width - pillW) / 2.0, centerY - pillH / 2.0, pillW, pillH)];
    pill.backgroundColor = UIColor.blackColor;
    pill.layer.cornerRadius = MIN(geometry.cornerRadius * previewScale, pillH / 2.0);
    if (@available(iOS 13.0, *)) pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.masksToBounds = YES;

    UIView *leading = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMinX(pill.frame) - gap - bubble,
                                                               centerY - bubble / 2.0, bubble, bubble)];
    UIView *trailing = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMaxX(pill.frame) + gap,
                                                                centerY - bubble / 2.0, bubble, bubble)];
    for (UIView *bubbleView in @[ leading, trailing ]) {
        bubbleView.backgroundColor = UIColor.blackColor;
        bubbleView.layer.cornerRadius = bubble / 2.0;
        bubbleView.layer.masksToBounds = YES;
    }

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, width - 40, 24)];
    title.text = @"VisibleIsland";
    title.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 126, width - 40, 30)];
    VIDevicePreset preset = [VIPresets activePreset];
    subtitle.text = [NSString stringWithFormat:@"%s · %@ · %@",
                     preset.marketing,
                     [VIPresets machineIdentifier],
                     VIIsRootless() ? @"rootless" : @"rootful"];
    subtitle.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    if (@available(iOS 13.0, *)) subtitle.textColor = UIColor.secondaryLabelColor;
    else                         subtitle.textColor = UIColor.grayColor;

    for (UIView *subview in @[ leading, pill, trailing, title, subtitle ]) {
        [blur.contentView addSubview:subview];
    }

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 184.0)];
    blur.frame = CGRectMake(16, 8, width - 32, 168.0);
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [container addSubview:blur];

    self.headerBlurView = blur;
    self.table.tableHeaderView = container;
}

- (void)_refreshFooter {
    NSString *media = VIReadPrefs()[@"mediaPath"];
    PSSpecifier *specifier = [self specifierForID:@"mediaStatus"];
    if (!specifier) return;

    NSString *label = media.length ? media.lastPathComponent : @"None";
    [specifier setProperty:label forKey:@"detailTitle"];
    [specifier setProperty:label forKey:@"label2"];
    [self reloadSpecifier:specifier animated:YES];
}

#pragma mark - Preference plumbing

// PSListController's default implementation targets the Settings container.
// Read and write the tweak's plist explicitly instead.

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = VIReadPrefs()[key];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;

    NSMutableDictionary *prefs = VIReadPrefs();
    if (value) prefs[key] = value;
    else       [prefs removeObjectForKey:key];

    NSString *notification = [specifier propertyForKey:@"PostNotification"];
    VIWritePrefs(prefs, notification.length ? notification.UTF8String : VI_NOTIF_PREFS_CHANGED);

    if ([key isEqualToString:@"presetOverride"] ||
        [key hasSuffix:@"Delta"] || [key hasPrefix:@"offset"]) {
        [self _installBlurredHeader];   // keep the header preview in sync
    }
}

#pragma mark - Hardware preset picker

- (NSArray *)presetValues:(PSSpecifier *)specifier {
    NSMutableArray *values = [NSMutableArray array];
    for (NSDictionary *entry in [VIPresets selectablePresets]) [values addObject:entry[@"id"]];
    return values;
}

- (NSArray *)presetTitles:(PSSpecifier *)specifier {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSDictionary *entry in [VIPresets selectablePresets]) [titles addObject:entry[@"name"]];
    return titles;
}

#pragma mark - Media import

- (void)importMedia:(PSSpecifier *)specifier {
    UIDocumentPickerViewController *picker = nil;

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
    if (@available(iOS 14.0, *)) {
        NSArray<UTType *> *types = @[ UTTypeGIF, UTTypeMPEG4Movie, UTTypeQuickTimeMovie,
                                      UTTypePNG, UTTypeJPEG ];
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    }
#endif
    if (!picker) {
        NSArray<NSString *> *types = @[ @"com.compuserve.gif", @"public.mpeg-4",
                                        @"com.apple.quicktime-movie", @"public.image" ];
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types
                                                                       inMode:UIDocumentPickerModeOpen];
    }

    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    picker.presentationController.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject;
    if (!source) return;

    // ── Security Scoped URL handling ─────────────────────────────────────
    // The picker hands back a URL that is only readable between
    // startAccessingSecurityScopedResource / stopAccessing. SpringBoard cannot
    // use that scope at all, so the file must be COPIED into the tweak's own
    // container while the scope is open, inside an NSFileCoordinator block
    // (the provider may be iCloud/third-party and need to materialise it).
    BOOL scoped = [source startAccessingSecurityScopedResource];

    NSString *destinationDir = VIMediaContainerPath();
    NSString *fileName = source.lastPathComponent.length ? source.lastPathComponent : @"media";
    NSString *destination = [destinationDir stringByAppendingPathComponent:fileName];

    __block NSError *coordinateError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinateError
                                 byAccessor:^(NSURL *readURL) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;

        if ([fm fileExistsAtPath:destination]) [fm removeItemAtPath:destination error:NULL];

        if (![fm copyItemAtURL:readURL toURL:[NSURL fileURLWithPath:destination] error:&error]) {
            // Fall back to a data read for providers that refuse copyItem.
            NSData *data = [NSData dataWithContentsOfURL:readURL options:NSDataReadingMappedIfSafe error:&error];
            if (data) [data writeToFile:destination options:NSDataWritingAtomic error:&error];
        }

        if (error) {
            [self _presentError:error];
            return;
        }

        // Keep Settings (uid mobile) and SpringBoard on the same ownership.
        [fm setAttributes:@{ NSFilePosixPermissions : @(0644) } ofItemAtPath:destination error:NULL];

        // Store only the file name: the container path is resolved at runtime,
        // so the value stays valid across a rootful ↔ rootless migration.
        NSMutableDictionary *prefs = VIReadPrefs();
        prefs[@"mediaPath"] = fileName;
        VIWritePrefs(prefs, VI_NOTIF_MEDIA_CHANGED);

        [self _pruneContainerKeeping:fileName];
    }];

    if (scoped) [source stopAccessingSecurityScopedResource];
    if (coordinateError) [self _presentError:coordinateError];

    [self _refreshFooter];
    [self _promptRespringWithReason:@"Imported media is applied after a respring."];
}

// Only one active asset is ever needed; drop older imports so the container
// cannot grow unbounded on the data partition.
- (void)_pruneContainerKeeping:(NSString *)keepName {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = VIMediaContainerPath();
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([name isEqualToString:keepName]) continue;
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
    }
}

- (void)clearMedia:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = VIReadPrefs();
    prefs[@"mediaPath"] = @"";
    VIWritePrefs(prefs, VI_NOTIF_MEDIA_CHANGED);
    [self _pruneContainerKeeping:@""];
    [self _refreshFooter];
}

#pragma mark - Geometry reset

- (void)resetGeometry:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = VIReadPrefs();
    for (NSString *key in @[ @"offsetX", @"offsetY", @"widthDelta", @"heightDelta",
                             @"cornerRadiusDelta", @"bubbleDiameterDelta", @"moduleGapDelta" ]) {
        prefs[key] = @0;
    }
    VIWritePrefs(prefs, VI_NOTIF_PREFS_CHANGED);
    [self reloadSpecifiers];
    [self _installBlurredHeader];
}

#pragma mark - Respring

- (void)respring:(PSSpecifier *)specifier {
    [self _promptRespringWithReason:nil];
}

- (void)_promptRespringWithReason:(NSString *)reason {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Respring"
                                           message:reason ?: @"SpringBoard will restart now."
                                    preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        // Give the plist write a moment to hit the disk before SpringBoard dies.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            VIRespring();
        });
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Errors

- (void)_presentError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Import failed"
                                               message:error.localizedDescription
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
