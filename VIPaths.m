#import "VIPaths.h"
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *_viRootPrefix = nil;
static BOOL      _viRootless   = NO;

#pragma mark - Detection

// libroot.dylib (shipped by modern rootless bootstraps) exposes a dynamic
// resolver. Symbol names have moved around between libroot revisions, so probe
// a couple of them and fail soft — the /var/jb fallback below is authoritative
// on every shipping jailbreak.
static NSString *VITryLibroot(void) {
    void *handle = dlopen("/usr/lib/libroot.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (!handle) handle = dlopen("libroot.dylib", RTLD_LAZY);
    if (!handle) return nil;

    const char *(*prefixFn)(void) =
        dlsym(handle, "libroot_dyn_jbrootpath_prefix") ?:
        dlsym(handle, "libroot_dyn_prefix") ?:
        dlsym(handle, "jbroot_prefix");

    if (prefixFn) {
        const char *c = prefixFn();
        if (c && *c) return [NSString stringWithUTF8String:c];
    }

    char buf[PATH_MAX] = {0};
    char *(*jbrootFn)(const char *, char *, size_t) =
        dlsym(handle, "libroot_dyn_jbrootpath");
    if (jbrootFn && jbrootFn("/", buf, sizeof(buf)) && buf[0]) {
        NSString *root = [NSString stringWithUTF8String:buf];
        // "/var/jb/" → "/var/jb"
        while (root.length > 1 && [root hasSuffix:@"/"]) {
            root = [root substringToIndex:root.length - 1];
        }
        return root;
    }
    return nil;
}

static void VIResolveRootOnce(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *fm = NSFileManager.defaultManager;

        // 1) libroot, when present.
        NSString *fromLibroot = VITryLibroot();
        if (fromLibroot.length > 1 && [fm fileExistsAtPath:fromLibroot]) {
            _viRootPrefix = fromLibroot;
            _viRootless   = YES;
            return;
        }

        // 2) Environment hint exported by some bootstrap daemons.
        const char *env = getenv("JB_ROOT_PATH") ?: getenv("JBROOT");
        if (env && *env && strcmp(env, "/") != 0) {
            NSString *p = [NSString stringWithUTF8String:env];
            if ([fm fileExistsAtPath:p]) {
                _viRootPrefix = p;
                _viRootless   = YES;
                return;
            }
        }

        // 3) /var/jb — palera1n and Dopamine 1.x own it directly; Dopamine 2.x
        //    creates it as a symlink to the randomized
        //    /var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX.
        //    Resolving the symlink gives the canonical prefix and avoids a
        //    double indirection on every file read.
        if ([fm fileExistsAtPath:@"/var/jb"]) {
            NSString *resolved = [@"/var/jb" stringByResolvingSymlinksInPath];
            _viRootPrefix = (resolved.length > 1) ? resolved : @"/var/jb";
            _viRootless   = YES;
            return;
        }

        // 4) Rootful.
        _viRootPrefix = @"";
        _viRootless   = NO;
    });
}

#pragma mark - Public

NSString *VIJBRootPrefix(void) {
    VIResolveRootOnce();
    return _viRootPrefix;
}

BOOL VIIsRootless(void) {
    VIResolveRootOnce();
    return _viRootless;
}

NSString *VIJBRoot(NSString *path) {
    VIResolveRootOnce();
    if (path.length == 0) return _viRootPrefix;
    if (_viRootPrefix.length == 0) return path;
    if ([path hasPrefix:_viRootPrefix]) return path;              // already absolute
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [_viRootPrefix stringByAppendingString:path];
}

const char *VIJBRootC(NSString *path) {
    return VIJBRoot(path).fileSystemRepresentation;
}

NSString *VIMediaContainerPath(void) {
    static NSString *container = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        container = @"/var/mobile/Library/Application Support/VisibleIsland/Media";
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:container]) {
            [fm createDirectoryAtPath:container
          withIntermediateDirectories:YES
                           attributes:@{ NSFilePosixPermissions : @(0755) }
                                error:NULL];
            // Both SpringBoard and Preferences run as mobile; make sure a root
            // owned Settings process cannot leave a root-owned directory behind.
            chown(container.fileSystemRepresentation, 501, 501);
        }
    });
    return container;
}

NSString *VIPreferencesPlistPath(void) {
    return @"/var/mobile/Library/Preferences/com.sa1nt.visibleisland.plist";
}
