//
//  VIActivityCenter.h
//  VisibleIsland 2.0 — the piece that was missing entirely in 1.x.
//
//  The island used to be a painted rectangle: nothing in the process ever told
//  it that the system state had changed. This service is the single place that
//  listens to SpringBoard / MediaRemote / IOKit and turns those signals into
//  VIActivity snapshots, then resolves which snapshot owns which module:
//
//      [ LeadingBubble ]        [ ===== CenterPill ===== ]        [ TrailingBubble ]
//        2nd activity              highest priority                 3rd activity
//        (or primary glyph)         (title / artwork)               (or live accessory)
//
//  Resolution rule — this is what makes a single activity still read as a
//  three-section island: with exactly one activity live, the primary owns the
//  pill, its glyph flies out to the left and its live accessory (equalizer,
//  progress ring) flies out to the right. With two or three live activities the
//  satellites carry the runners-up instead.
//
//  Sources implemented here are all notification-driven, so they cost nothing
//  while idle and need no hooks:
//    • now playing  → MediaRemote (dlopen'd, never linked)
//    • charging     → UIDevice battery notifications
//    • volume       → AVSystemController notification
//    • Low Power    → NSProcessInfo power-state notification
//    • lock state   → com.apple.springboard.lockstate Darwin notification
//  The ringer switch has no notification and is hooked in VIActivitySources.x.
//

#import <Foundation/Foundation.h>
#import "VIActivity.h"

NS_ASSUME_NONNULL_BEGIN

@class VIActivityCenter;

@protocol VIActivityCenterDelegate <NSObject>
/// Fired on the main thread whenever the resolved slots changed.
- (void)activityCenterDidUpdateActivities:(VIActivityCenter *)center;
@end

@interface VIActivityCenter : NSObject

+ (instancetype)sharedCenter;

@property (nonatomic, weak, nullable) id<VIActivityCenterDelegate> delegate;

#pragma mark Resolved slots

@property (nonatomic, readonly, nullable) VIActivity *centerActivity;
@property (nonatomic, readonly, nullable) VIActivity *leadingActivity;
@property (nonatomic, readonly, nullable) VIActivity *trailingActivity;

/// How each satellite should draw its activity (glyph vs live accessory).
@property (nonatomic, readonly) VIActivityRole leadingRole;
@property (nonatomic, readonly) VIActivityRole trailingRole;

@property (nonatomic, readonly) BOOL hasActivity;

#pragma mark Lifecycle

/// Starts every notification-driven source. Idempotent.
- (void)start;

/// Removes every observer, cancels the expiry timer, clears all activities.
- (void)stop;

/// Screen off / cover sheet. While suspended, transient activities are dropped
/// and the expiry timer is parked, so a sleeping device keeps nothing on the
/// run loop. Sticky activities survive and reappear on wake.
@property (nonatomic, assign, getter=isSuspended) BOOL suspended;

#pragma mark Publication (called by sources)

/// Upsert by kind. Publishing a visually identical snapshot is a no-op, which
/// is what keeps MediaRemote's repeated bursts from causing relayout storms.
- (void)publishActivity:(VIActivity *)activity;
- (void)retireActivityOfKind:(VIActivityKind)kind;

#pragma mark Interaction

/// Executes a satellite tap against MediaRemote (play/pause, next, previous).
- (void)performAction:(VIActivityAction)action;

/// Re-reads the per-kind switches from VIPrefs and drops what the user turned
/// off. Called from the prefsChanged notification.
- (void)applyPreferences;

/// YES when the user allows this kind to reach the island.
- (BOOL)isKindEnabled:(VIActivityKind)kind;

@end

NS_ASSUME_NONNULL_END
