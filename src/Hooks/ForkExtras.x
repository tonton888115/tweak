//
//  ForkExtras.x
//  NeoFreeBird (fork port)
//
//  Features of the 11.35 fork that upstream v7 does not have, carried over:
//   - hang watchdog defuse (b68): X turns a multi-second main-thread stall into
//     a deliberate abort(); a freeze the user can wait out must not kill the app.
//     The feature switch is reported as disabled in FeatureSwitches.x, and these
//     no-ops are the guarantee if a watchdog gets armed anyway.
//   - video ads (b78), under the existing "hide promoted" setting: pre/mid-roll
//     breaks of publisher (Amplify VMAP) videos, dynamic preroll ads, and Google
//     native ads between videos.
//

#import "HookHelpers.h"

void NFBLogEvent(NSString* msg);  // Streaming.x

// MARK: - Hang watchdog

static void NFBWatchdogCrashSuppressed(NSString* watchdog) {
    static _Atomic int suppressed = 0;  // watchdogs fire from arbitrary queues
    int count = atomic_fetch_add_explicit(&suppressed, 1, memory_order_relaxed) + 1;
    if (count > 5) return;
    NFBLogEvent([NSString stringWithFormat:@"watchdog crash() suppressed #%d (%@)", count, watchdog]);
}

%hook TFNTwitterWatchdog
- (void)crash {
    NFBWatchdogCrashSuppressed(@"TFNTwitterWatchdog");
}
%end

%hook TFNTwitterDefaultWatchdog
- (void)crash {
    NFBWatchdogCrashSuppressed(@"TFNTwitterDefaultWatchdog");
}
%end

%hook TFNTwitterLaunchWatchdog
- (void)crash {
    NFBWatchdogCrashSuppressed(@"TFNTwitterLaunchWatchdog");
}
%end

%hook TFNTwitterEnterForegroundWatchdog
- (void)crash {
    NFBWatchdogCrashSuppressed(@"TFNTwitterEnterForegroundWatchdog");
}
%end

%hook TFNTwitterEnterBackgroundWatchdog
- (void)crash {
    NFBWatchdogCrashSuppressed(@"TFNTwitterEnterBackgroundWatchdog");
}
%end

// MARK: - Video ads

static BOOL NFBHideVideoAds(void) {
    return [BHTSettings boolForKey:@"hide_promoted"];
}

%hook TAVAmplifyVMAPPlaylist
- (id)initWithContentItems:(NSArray*)contentItems adItems:(NSArray*)adItems {
    return %orig(contentItems, NFBHideVideoAds() ? @[] : adItems);
}

- (NSArray*)adVideoItems {
    return NFBHideVideoAds() ? @[] : %orig;
}
%end

%hook TAFDynamicVideoAdManager
- (void)prefetchDynamicAdsForVideoAdsTweetsIfNeeded:(id)tweets
                                      withAccountID:(id)accountID
                                      userReference:(id)userReference
                                             scribe:(id)scribe
                                  includeLongVideos:(BOOL)includeLongVideos
                                auditAllowedUserIDs:(id)auditAllowedUserIDs {
    if (NFBHideVideoAds()) return;
    %orig;
}
%end

%hook TFNTwitterStatus
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook TVPSessionConfiguration
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook TMAPlayableMediaAttachment
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook TFCCardData
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook _TtC14T1TwitterSwift20JetfuelImmersiveItem
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook _TtC14T1TwitterSwift34JetfuelTAVVideoPlayerSessionSource
- (BOOL)allowDynamicAd {
    return NFBHideVideoAds() ? NO : %orig;
}
%end

%hook _TtC14T1TwitterSwift18ImmersiveViewModel
- (void)googleAdManagerDidCacheAdWithNotification:(id)notification {
    if (NFBHideVideoAds()) return;
    %orig;
}
%end

%hook _TtC14T1TwitterSwift40URTTimelineGoogleNativeAdTableRowAdapter
- (void)googleAdManagerDidCacheAdWithNotification:(id)notification {
    if (NFBHideVideoAds()) return;
    %orig;
}
%end

%ctor {
    %init;
}
