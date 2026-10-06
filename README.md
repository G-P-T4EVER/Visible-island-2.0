# VisibleIsland 2.0 — architectural rework

Modular three-section Dynamic Island for iPhone 7 → 13 Pro Max, iOS 14.0–17.x,
rootful **and** rootless (Dopamine 1.x/2.x, palera1n).

---

## 1. Why the monolith was replaced

| Legacy behaviour | Failure mode | 2.0 solution |
|---|---|---|
| `UIView` injected into an `SBStatusBar` subview | Status bar rebuilds its hierarchy on style/orientation/Control Center changes → plate disappears, views leak | dedicated `VIWindow` owned by `VIWindowManager` |
| Everything in `Tweak.x` | untestable, retain cycles everywhere | 6 isolated services, `Tweak.x` is entry point only |
| `+[UIImage animatedImageWithImages:]` | 200–600 MB resident for a long GIF → SpringBoard killed by Jetsam | streaming `CGImageSourceRef` decoder, peak cost = **1 frame** |
| Hardcoded iPhone X coordinates | misaligned on every other model | `VIPresets` table + `hw.machine` autodetect + 0.5 pt manual trim |
| Playback never stopped | battery drain, decode while screen off | `VISuspendReason` bitmask driven by backlight / cover sheet / orientation |

---

## 2. Service map

```
Tweak.x                    entry point, %ctor, Darwin + SpringBoard hooks only
 │
 ├─ VIWindowManager        UIWindow lifecycle, scene binding, screen state machine
 │    ├─ VIWindow          pointInside: / hitTest: pass-through, boundary-tracker opt-out
 │    └─ VIRootViewController  chrome-free, portrait-locked host
 │
 ├─ VIIslandContainerView  three-module layout + CASpringAnimation transitions
 │    ├─ leadingBubble     VIIslandModuleView (satellite)
 │    ├─ centerPill        VIIslandModuleView → hosts VIMediaView
 │    └─ trailingBubble    VIIslandModuleView (satellite)
 │
 ├─ VIMediaView            MP4: AVQueuePlayer + AVPlayerLooper + AVPlayerLayer
 │                         GIF: CGImageSourceRef + CADisplayLink, 1-frame look-ahead
 │
 ├─ VIPresets              hw.machine → VIIslandGeometry struct table
 ├─ VIPrefs                immutable settings snapshot, rebuilt on notification
 └─ VIPaths                rootful / /var/jb / Dopamine-2 randomized jbroot resolver
```

### File list

```
Makefile                       ARC, rootless/rootful schemes, aggregate subproject
control                        metadata, iphoneos-arm ↔ iphoneos-arm64 note
VisibleIsland.plist            MSFilter → com.apple.springboard
Headers.h                      SpringBoard / UIKit private interfaces, enums, logging
Tweak.x                        entry point
VIPaths.h / .m                 jbroot abstraction + media container
VIPrefs.h / .m                 settings
VIPresets.h / .m               hardware geometry database
VIWindowManager.h / .m         window + screen events
VIIslandView.h / .m            three-section layout
VIMediaView.h / .m             MP4 player + streaming GIF renderer
visibleislandprefs/
  Makefile
  RootListController.h / .m    prefs, blurred header, DocumentPicker, respring
  VIBlurHeaderCell.h / .m      UIVisualEffectView banner cell
  VIStepSliderCell.h / .m      0.5 pt quantized slider
  entry.plist                  PreferenceLoader entry
  Resources/Root.plist         UI specifiers
  Resources/Info.plist         NSPrincipalClass = VIRootListController
```

---

## 3. Window & touch transparency

```objc
window.windowLevel = UIWindowLevelStatusBar + 100;   // above the status bar, below alerts
```

* **iOS 16–17** → `-[VIWindow initWithWindowScene:]` bound to SpringBoard's
  foreground-active `UIWindowScene`, with a delayed rebind if no scene exists yet
  at `applicationDidFinishLaunching:` (cold-boot ordering) and a rebind on
  `UISceneDidDisconnectNotification`.
* **iOS 14–15** → `-initWithFrame:` on `UIScreen.mainScreen.bounds`.
* `makeKeyAndVisible` is **never** called — it would steal key status from SpringBoard.

Touch model:

```objc
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    return [island pointIsInsideInteractiveArea:[island convertPoint:p fromView:self]];
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if (![self pointInside:p withEvent:e]) return nil;   // event walks to SpringBoard
    UIView *hit = [super hitTest:p withEvent:e];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
```

Only live module rectangles (+6 pt slop) claim events; status bar taps,
Control Center pulls and notification swipes are untouched.
`-_shouldCreateScreenWithBoundaryTracker` returns `NO`, so the window never
participates in interface-orientation arbitration.

---

## 4. Media engine memory contract

**MP4** — `AVQueuePlayer` + `AVPlayerLooper` (gapless, no end-of-item seek) +
`AVPlayerLayer`. `muted = YES`, the audio session is never touched, and
`preventsDisplaySleepDuringVideoPlayback = NO` so the island cannot keep the
display awake.

**GIF** — `CGImageSourceCreateWithURL` with
`kCGImageSourceShouldCache = NO`; frame delays read from metadata only.
`CADisplayLink` (weak proxy target — a direct target would retain the whole
window) drives a deadline scheduler; each frame is produced by
`CGImageSourceCreateThumbnailAtIndex` on a utility serial queue, downsampled to
the pill's pixel size, with a strict **one-frame look-ahead**. The frame is
handed to `layer.contents` and released immediately.

Suspension (`screen off | cover sheet | landscape | memory | disabled`)
invalidates the display link, pauses the player and drops the pending frame —
zero decode work while the screen is dark. `shedDecodeResources` halves the
decode target on `UIApplicationDidReceiveMemoryWarning`.

---

## 5. Build

```bash
export THEOS=/opt/theos

make rootless            # Dopamine / palera1n rootless   → iphoneos-arm64
make rootful             # checkra1n / unc0ver             → iphoneos-arm
make both                # both .deb files in ./packages

make do THEOS_DEVICE_IP=192.168.1.20   # build, install, respring
```

Slices: `arm64 arm64e`. SDK floor `iphone:clang:16.5:14.0`.

---

## 6. Runtime notes

* Settings plist: `/var/mobile/Library/Preferences/com.sa1nt.visibleisland.plist`
  (data partition in both schemes).
* Imported media: `/var/mobile/Library/Application Support/VisibleIsland/Media`
  — only the file **name** is stored, so a rootful ↔ rootless migration keeps working.
* Live-reload notifications: `…/prefsChanged`, `…/mediaChanged`, `…/reload`.
* Screen state: `com.apple.iokit.hid.displayStatus` is authoritative;
  `SBBacklightController` hooks are installed conditionally as a fallback because
  the selector set differs between 14.x and 17.x.
* iPhone 14 Pro / 14 Pro Max are detected as `nativeIsland` and the tweak stands
  down unless the user explicitly picks a preset override.

---

## Про `control` и архитектуры

В `control` **нельзя** держать комментарии. Theos парсит этот файл своим
валидатором на этапе `internal-package`, строки с `#` он не пропускает, и любая
непарная скобка внутри такой строки роняет сборку:

```
ERROR: control file contains an unclosed parentheses
make: *** [internal-package] Error 25
```

Поэтому пояснение вынесено сюда:

| Схема | Architecture в готовом .deb | Джейлбрейки |
|---|---|---|
| `make package` (без схемы) | `iphoneos-arm` | checkra1n, unc0ver, palera1n rootful |
| `make package THEOS_PACKAGE_SCHEME=rootless` | `iphoneos-arm64` | Dopamine 1.x/2.x, palera1n rootless |

В файле лежит `iphoneos-arm`. Для rootless Theos переписывает поле сам и
дополнительно правит зависимости под ElleKit — прописывать `iphoneos-arm64`
руками не нужно и вредно.

Собираемые слайсы: `arm64` + `arm64e`. Нижняя планка iOS 14.0, `armv7` мёртв.
