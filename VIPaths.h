//
//  VIPaths.h
//  Rootful / rootless path abstraction.
//
//  Layouts handled:
//    rootful            /Library/...                 prefix = @""
//    palera1n, Dopamine 1.x   /var/jb/Library/...     prefix = @"/var/jb"
//    Dopamine 2.x       /var/containers/Bundle/Application/.jbroot-XXXXXXXX/...
//                       (/var/jb is a symlink to it — resolved at runtime)
//
//  Detection is done ONCE, lazily, and never assumes the compile-time
//  THEOS_PACKAGE_SCHEME, so a repacked deb keeps working.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Absolute jailbreak root prefix. Empty string on rootful.
FOUNDATION_EXPORT NSString *VIJBRootPrefix(void);

/// Prefix a jailbreak-relative path, e.g. VIJBRoot(@"/usr/bin/sbreload").
FOUNDATION_EXPORT NSString *VIJBRoot(NSString *path);

/// C convenience for posix_spawn / sysctl call sites.
FOUNDATION_EXPORT const char *VIJBRootC(NSString *path);

/// YES when a rootless bootstrap is active.
FOUNDATION_EXPORT BOOL VIIsRootless(void);

/// Writable media sandbox for imported .gif/.mp4.
/// Always lives on the DATA partition (/var/mobile/...) — never inside jbroot —
/// so imported media survives a bootstrap reinstall and stays writable from the
/// Settings process (uid mobile).
///
///   /var/mobile/Library/Application Support/VisibleIsland/Media
///
/// The directory is created (0755, mobile:mobile) on first call.
FOUNDATION_EXPORT NSString *VIMediaContainerPath(void);

/// Absolute path of the preferences plist (data partition in both schemes).
FOUNDATION_EXPORT NSString *VIPreferencesPlistPath(void);

NS_ASSUME_NONNULL_END
