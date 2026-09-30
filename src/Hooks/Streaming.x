//
//  Streaming.x
//  NeoFreeBird
//
//  Native Home-timeline auto-refresh ("streaming"). A floating control sits top-right; a
//  countdown ring depletes each interval and at 0 the visible timeline reloads — but only
//  while the user is at the very top, otherwise a "New Tweets" pill is shown instead.
//  TAP = on/off. LONG-PRESS = options (refresh now, interval, log recording, diagnostics).
//  For You is never auto-refreshed. Pinned lists and the Search "Latest" tab are.
//
//  Ported from the 11.35-based fork (StreamingTimeline.x, b74) to X 12.28.1:
//  - the Home container is now the Swift TwitterHomeFeatureImplementation.HomeTimelineContainerViewController
//    (activeContentViewController / isHomeSelected replace homeTimelineViewController / latestTimelineViewController)
//  - the pager is TFNUISwift.LegacyPagingViewController inside LegacySegmentedViewController
//  The iPad columns mode is NOT part of this file: its old pager hooks do not exist in 12.x.
//

#import "HookHelpers.h"
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>

// Diagnostics report (long-press → 🔍). ON unless the build defines NFB_DIAG=0.
#ifndef NFB_DIAG
#define NFB_DIAG 1
#endif

// Minimal bases so `self.view` resolves; everything else goes through objc_msgSend.
@interface _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController : UIViewController
@end
@interface THFHomeTimelineItemsViewController : UIViewController
@end
@interface T1URTViewController : UIViewController
@end

static void nfb_streamStart(UIViewController *vc);
static void nfb_streamStop(UIViewController *vc);
static UIViewController *nfb_selectedTimelineVC(UIViewController *vc);
static void nfb_streamTrigger(UIViewController *vc);
static void nfb_styleButton(BOOL on);
static void nfb_updateGauge(BOOL on, NSTimeInterval interval);
static void nfb_updateStreamStateIconForVC(UIViewController *vc);
static NSString *nfb_currentSelectedTabPage(void);
static BOOL nfb_homeTabSelectedOrUnknown(void);
static void nfb_showNewTweetsPill(UIViewController *vc);
static UIScrollView *nfb_horizontalPagingScrollViewOf(UIViewController *vc);
static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging);
static UIViewController *nfb_pagingViewControllerAtIndexPath(UIViewController *paging, NSIndexPath *indexPath);
static BOOL nfb_searchOrExplorePageSelected(void);
static UIViewController *nfb_visibleSearchAutomationController(void);
static NSString *nfb_diagShortString(NSString *value, NSUInteger maxLen);
static NSString *nfb_diagTextForView(UIView *view, NSUInteger maxLen);
static NSString *nfb_buildDiagnosticReport(void);
void NFBUpdateStreamButtonVisibility(void);
void NFBNoteTabSelectionChanged(void);
void NFBLogEvent(NSString *msg);
void NFBLogSnapshot(NSString *reason);
void NFBStreamPrefsChanged(void);

// UI strings: BHTBundle key with an inline English fallback (BHTBundle returns the KEY for
// unknown keys, e.g. when a sideload ships a stale bundle next to a fresh dylib).
static NSString *nfb_loc(NSString *key, NSString *fallback) {
    NSString *value = [[BHTBundle sharedBundle] localizedStringForKey:key];
    return (value.length && ![value isEqualToString:key]) ? value : fallback;
}

// Preferences (registered in BHTSettings, Timelines page).
static NSString * const kNFBStreamEnabledKey = @"auto_stream_timeline";
static NSString * const kNFBStreamIntervalKey = @"auto_stream_interval";
static BOOL nfb_streamEnabled(void) {
    return [BHTSettings boolForKey:kNFBStreamEnabledKey];
}
static NSInteger nfb_streamInterval(void) {
    // Seconds between auto-refreshes. Default 20s; floor 5s (X timeline rate limits).
    NSInteger seconds = [BHTSettings integerForKey:kNFBStreamIntervalKey];
    return seconds >= 5 ? seconds : 20;
}
static void nfb_setStreamEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kNFBStreamEnabledKey];
}
static void nfb_setStreamInterval(NSInteger seconds) {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:kNFBStreamIntervalKey];
}

static __weak UIViewController *gActiveItemsVC = nil;   // the visible Home timeline list
static __weak UIViewController *gPendingNewTweetsVC = nil;
static __weak UIScrollView *gActiveTimelineScrollView = nil;
static UIButton *gNewTweetsPill = nil;
static BOOL gActiveTimelineAtTop = YES;
static CGFloat gActiveTimelineOffsetY = 0.0;
static CGFloat gActiveTimelineTopY = 0.0;
static NSTimeInterval gLastUserTimelineScrollInteraction = 0.0;
static BOOL gRefreshStartedAtTop = NO;
static NSString *gNFBSelectedTabPageCache = nil;
static NSTimeInterval gNFBSelectedTabPageCacheAt = 0.0;
static char kNFBRefreshStartedAtKey;
static char kNFBRefreshStartedAtTopKey;

#pragma mark - refresh callers (no signature assumptions)

static BOOL nfb_resp(id o, SEL s) { return o && [o respondsToSelector:s]; }
static id nfb_timelineOf(id vc) { return nfb_resp(vc, @selector(timeline)) ? ((id(*)(id, SEL))objc_msgSend)(vc, @selector(timeline)) : nil; }
static UIScrollView *nfb_scrollOf(id vc) { return nfb_resp(vc, @selector(scrollView)) ? ((id(*)(id, SEL))objc_msgSend)(vc, @selector(scrollView)) : nil; }

// KVC read that never throws: only asks objects that actually answer the getter.
static id nfb_safeValueForKey(id obj, NSString *key) {
    if (!obj || !key.length || ![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *nfb_textOfView(UIView *view) {
    if (!view) return nil;
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:UIButton.class]) text = [((UIButton *)view) titleForState:UIControlStateNormal];
    if (!text.length) {
        id value = nfb_safeValueForKey(view, @"text");
        if ([value isKindOfClass:NSString.class]) text = value;
    }
    if (!text.length) text = view.accessibilityLabel;
    return text;
}

static BOOL nfb_viewOrAncestorSelected(UIView *view) {
    UIView *current = view;
    for (int i = 0; current && i < 4; i++, current = current.superview) {
        if ((current.accessibilityTraits & UIAccessibilityTraitSelected) == UIAccessibilityTraitSelected) return YES;
        if ([current isKindOfClass:UIControl.class] && ((UIControl *)current).selected) return YES;
        id selected = nfb_safeValueForKey(current, @"isSelected");
        if ([selected respondsToSelector:@selector(boolValue)] && [selected boolValue]) return YES;
    }
    return NO;
}

static NSString *nfb_selectedTextInView(UIView *view, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 10) return nil;
    NSString *text = nfb_textOfView(view);
    if (text.length && nfb_viewOrAncestorSelected(view)) return text;
    for (UIView *subview in view.subviews) {
        NSString *found = nfb_selectedTextInView(subview, depth + 1);
        if (found.length) return found;
    }
    return nil;
}

static UIViewController *nfb_parentControllerNamed(UIViewController *vc, NSString *needle) {
    UIViewController *current = vc;
    for (int i = 0; current && i < 8; i++, current = current.parentViewController) {
        if ([NSStringFromClass(current.class) containsString:needle]) return current;
    }
    return nil;
}

static BOOL nfb_textLooksRecommendedTab(NSString *text) {
    NSString *low = text.lowercaseString;
    return [text containsString:@"おすすめ"] ||
           [low containsString:@"for you"] ||
           [low containsString:@"foryou"] ||
           [low containsString:@"recommended"];
}

static BOOL nfb_textLooksLatestSearchTab(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    return [text containsString:@"最新"] ||
           [low containsString:@"latest"] ||
           [low containsString:@"recent"];
}

static BOOL nfb_textLooksTopicSearchTab(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    return [text containsString:@"話題"] ||
           [text containsString:@"おすすめ"] ||
           [text containsString:@"トレンド"] ||
           [text containsString:@"急上昇"] ||
           [low isEqualToString:@"top"] ||
           [low containsString:@"top tweets"] ||
           [low containsString:@"trending"] ||
           [low containsString:@"for you"] ||
           [low containsString:@"popular"];
}

static NSString *nfb_stringValueForKey(id obj, NSString *key) {
    id value = nfb_safeValueForKey(obj, key);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static BOOL nfb_homeTabIdentifierLooksRecommended(NSString *identifier) {
    if (!identifier.length) return NO;
    NSString *low = identifier.lowercaseString;
    return [low isEqualToString:@"home"] ||
           [low containsString:@"recommend"] ||
           [low containsString:@"for_you"] ||
           [low containsString:@"foryou"] ||
           [low containsString:@"top"];
}

static BOOL nfb_homeTabIdentifierLooksChronological(NSString *identifier) {
    if (!identifier.length) return NO;
    NSString *low = identifier.lowercaseString;
    return [low isEqualToString:@"latest"] ||
           [low containsString:@"latest"] ||
           [low containsString:@"following"] ||
           [low containsString:@"list"] ||
           [low containsString:@"communit"] ||
           [low containsString:@"creator"] ||
           [low containsString:@"subscription"];
}

static BOOL nfb_isTimelinePageController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass(vc.class);
    // THFHomeTimelineItemsViewController (For You / Following) and the Swift
    // TwitterHomeFeatureImplementation.(Subscriptions)PinnedTimelineViewController (pinned lists).
    return [cls containsString:@"HomeTimelineItemsViewController"] ||
           [cls containsString:@"PinnedTimelineViewController"];
}

static UIViewController *nfb_homeContainerOf(UIViewController *vc) {
    return nfb_parentControllerNamed(vc, @"HomeTimelineContainer");
}

static UIViewController *nfb_containerActiveContent(UIViewController *container) {
    if (!nfb_resp(container, @selector(activeContentViewController))) return nil;
    id active = ((id(*)(id, SEL))objc_msgSend)(container, @selector(activeContentViewController));
    return [active isKindOfClass:UIViewController.class] ? (UIViewController *)active : nil;
}

static BOOL nfb_vcIsOrContains(UIViewController *outer, UIViewController *inner) {
    for (UIViewController *c = inner; c; c = c.parentViewController) {
        if (c == outer) return YES;
    }
    return NO;
}

// For You must never auto-refresh. X 12.x removed the container's homeTimelineViewController /
// latestTimelineViewController; the Swift container instead reports the selected variant through
// isHomeSelected ("home" = For You) for its activeContentViewController.
static BOOL nfb_isRecommendedHomeTimeline(UIViewController *vc) {
    if (!vc) return NO;
    UIViewController *container = nfb_homeContainerOf(vc);
    if (container && nfb_resp(container, @selector(homeTimelineViewController))) {
        // Pre-12 containers: compare by identity.
        id homeVC = ((id(*)(id, SEL))objc_msgSend)(container, @selector(homeTimelineViewController));
        if (homeVC) return nfb_vcIsOrContains((UIViewController *)homeVC, vc);
    }
    if ([NSStringFromClass(vc.class) containsString:@"PinnedTimelineViewController"]) return NO;
    if (container && nfb_resp(container, @selector(isHomeSelected))) {
        // isHomeSelected describes the DISPLAYED page only. A home-items page that is not the
        // displayed one is never a refresh target, so treat it conservatively as For You.
        UIViewController *displayed = nfb_selectedTimelineVC(vc);
        if (displayed && nfb_vcIsOrContains(displayed, vc)) {
            return ((BOOL(*)(id, SEL))objc_msgSend)(container, @selector(isHomeSelected));
        }
        if (displayed) return YES;
    }
    UIViewController *segmented = nfb_parentControllerNamed(vc, @"Segmented");
    NSString *selectedText = segmented && [segmented isViewLoaded] ? nfb_selectedTextInView(segmented.view, 0) : nil;
    if (nfb_textLooksRecommendedTab(selectedText)) return YES;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"nfb_lastSelectedTimelineTabIdentifier"];
    return nfb_homeTabIdentifierLooksRecommended(saved);
}

static CGFloat nfb_scrollViewScore(UIScrollView *sv) {
    if (!sv || sv.hidden || sv.alpha < 0.01 || sv.bounds.size.width < 100.0 || sv.bounds.size.height < 100.0) return 0;
    CGFloat area = sv.bounds.size.width * sv.bounds.size.height;
    BOOL vertical = sv.alwaysBounceVertical || sv.contentSize.height > sv.bounds.size.height + 80.0;
    BOOL horizontalOnly = sv.contentSize.width > sv.bounds.size.width * 1.4 && sv.contentSize.height <= sv.bounds.size.height + 80.0;
    if (horizontalOnly) area *= 0.2;
    if (vertical) area *= 3.0;
    return area;
}

static UIScrollView *nfb_findMainScrollViewInView(UIView *view, CGFloat *bestScore) {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    UIScrollView *best = nil;
    if ([view isKindOfClass:UIScrollView.class]) {
        CGFloat score = nfb_scrollViewScore((UIScrollView *)view);
        if (score > *bestScore) { *bestScore = score; best = (UIScrollView *)view; }
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *candidate = nfb_findMainScrollViewInView(sub, bestScore);
        if (candidate) best = candidate;
    }
    return best;
}

static UIScrollView *nfb_mainScrollViewOf(UIViewController *vc) {
    UIScrollView *sv = nfb_scrollOf(vc);
    if (nfb_scrollViewScore(sv) > 0) return sv;
    if (![vc isViewLoaded]) return nil;
    CGFloat bestScore = 0;
    return nfb_findMainScrollViewInView(vc.view, &bestScore);
}

// Search the VC subtree (+ each VC's `timeline`) for an object that responds to `sel`. The refresh
// entry point may live on a child content/data controller, not on the list VC we hook.
static id nfb_findResponder(UIViewController *vc, SEL sel, int depth) {
    if (!vc || depth > 5) return nil;
    if ([vc respondsToSelector:sel]) return vc;
    id tl = nfb_timelineOf(vc);
    if (tl && [tl respondsToSelector:sel]) return tl;
    for (UIViewController *c in vc.childViewControllers) {
        id r = nfb_findResponder(c, sel, depth + 1);
        if (r) return r;
    }
    return nil;
}

static id nfb_findLeafResponder(UIViewController *vc, SEL sel, int depth) {
    if (!vc || depth > 7) return nil;
    for (UIViewController *c in vc.childViewControllers.reverseObjectEnumerator) {
        id r = nfb_findLeafResponder(c, sel, depth + 1);
        if (r) return r;
    }
    id tl = nfb_timelineOf(vc);
    if (tl && [tl respondsToSelector:sel]) return tl;
    if ([vc respondsToSelector:sel]) return vc;
    return nil;
}

static NSInteger nfb_streamLoadSourceFromSender(id sender) {
    NSInteger (*fromSender)(id) = (NSInteger(*)(id))dlsym(RTLD_DEFAULT, "TFSTwitterStreamLoadSourceFromSender");
    if (!fromSender) fromSender = (NSInteger(*)(id))dlsym(RTLD_DEFAULT, "_TFSTwitterStreamLoadSourceFromSender");
    return fromSender ? fromSender(sender) : 0;
}

static BOOL nfb_scrollToTop(id vc, BOOL animated) {
    BOOL did = NO;
    if (nfb_resp(vc, @selector(scrollToTopAnimated:options:completion:))) {
        ((void(*)(id, SEL, BOOL, NSUInteger, id))objc_msgSend)(vc, @selector(scrollToTopAnimated:options:completion:), animated, 0, nil);
        did = YES;
    }
    if (nfb_resp(vc, @selector(scrollToTop))) {
        ((void(*)(id, SEL))objc_msgSend)(vc, @selector(scrollToTop));
        did = YES;
    }
    if (nfb_resp(vc, @selector(scrollToTop:))) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(vc, @selector(scrollToTop:), animated);
        did = YES;
    }
    UIScrollView *sv = [vc isKindOfClass:UIViewController.class] ? nfb_mainScrollViewOf((UIViewController *)vc) : nil;
    if (sv) {
        CGPoint p = sv.contentOffset;
        p.x = -sv.adjustedContentInset.left;
        p.y = -sv.adjustedContentInset.top;
        [sv setContentOffset:p animated:NO];
        [sv setContentOffset:p animated:animated];
        did = YES;
    }
    return did;
}

static BOOL nfb_isTimelineAtTop(UIViewController *vc) {
    UIScrollView *sv = nfb_mainScrollViewOf(vc);
    if (!sv) return gActiveTimelineAtTop;
    CGFloat topY = -sv.adjustedContentInset.top;
    return sv.contentOffset.y <= topY + 8.0;
}

static void nfb_noteActiveTimelineScroll(UIScrollView *sv) {
    if (!sv) return;
    gActiveTimelineScrollView = sv;
    gActiveTimelineOffsetY = sv.contentOffset.y;
    gActiveTimelineTopY = -sv.adjustedContentInset.top;
    gActiveTimelineAtTop = (gActiveTimelineOffsetY <= gActiveTimelineTopY + 8.0);
    if (sv.isDragging || sv.isTracking || sv.isDecelerating) {
        gLastUserTimelineScrollInteraction = CACurrentMediaTime();
    }
}

static BOOL nfb_visibleTimelineAtTopWithTolerance(UIViewController *vc, CGFloat tolerance) {
    if (vc) {
        UIScrollView *ownScroll = nfb_mainScrollViewOf(vc);
        if (ownScroll && ownScroll.window && ownScroll.bounds.size.height > 100.0) {
            CGFloat topY = -ownScroll.adjustedContentInset.top;
            return ownScroll.contentOffset.y <= topY + tolerance;
        }
    }
    UIScrollView *activeScroll = gActiveTimelineScrollView;
    if (activeScroll && activeScroll.window && activeScroll.bounds.size.height > 100.0) {
        CGFloat topY = -activeScroll.adjustedContentInset.top;
        return activeScroll.contentOffset.y <= topY + tolerance;
    }
    return nfb_isTimelineAtTop(vc);
}

// 8pt: pill / reveal guards.
static BOOL nfb_visibleTimelineAtTop(UIViewController *vc) {
    return nfb_visibleTimelineAtTopWithTolerance(vc, 8.0);
}

// ≤1pt: only used to decide whether an auto-refresh may fire (and scroll to top), so a user reading a
// few points below the very top gets the pill instead of being yanked up.
static BOOL nfb_timelineStrictlyAtTop(UIViewController *vc) {
    return nfb_visibleTimelineAtTopWithTolerance(vc, 1.0);
}

static void nfb_markRefreshStarted(UIViewController *vc, BOOL atTop) {
    NSTimeInterval now = CACurrentMediaTime();
    gRefreshStartedAtTop = atTop;
    if (!vc) return;
    objc_setAssociatedObject(vc, &kNFBRefreshStartedAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kNFBRefreshStartedAtTopKey, @(atTop), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL nfb_canRevealRefreshStartedAtTop(UIViewController *vc) {
    if (!nfb_streamEnabled() || !vc) return NO;
    NSNumber *startedAtTop = objc_getAssociatedObject(vc, &kNFBRefreshStartedAtTopKey);
    if (!startedAtTop.boolValue) return NO;
    NSNumber *startedAtValue = objc_getAssociatedObject(vc, &kNFBRefreshStartedAtKey);
    NSTimeInterval startedAt = startedAtValue ? startedAtValue.doubleValue : 0.0;
    if (startedAt <= 0.0) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - startedAt > 12.0) return NO;
    if (gLastUserTimelineScrollInteraction > startedAt + 0.05) return NO;
    UIViewController *active = gActiveItemsVC;
    if (active && vc != active) {
        UIViewController *selected = nfb_selectedTimelineVC(active);
        if (selected && vc != selected) return NO;
    }
    return YES;
}

static void nfb_hideNewTweetsPill(void) {
    if (!gNewTweetsPill) return;
    [UIView animateWithDuration:0.16 animations:^{
        gNewTweetsPill.alpha = 0.0;
    } completion:^(BOOL finished) {
        // A show may have started while this fade ran; only detach a pill that is still hidden.
        if (finished && gNewTweetsPill.alpha < 0.01) [gNewTweetsPill removeFromSuperview];
    }];
}

static void nfb_revealTopAfterRefresh(UIViewController *vc) {
    __weak UIViewController *wvc = vc;
    void (^reveal)(void) = ^{
        UIViewController *s = wvc;
        if (!s || ![s isViewLoaded] || s.view.window == nil) return;
        UIViewController *active = gActiveItemsVC;
        if (active && s != active) {
            UIViewController *selected = nfb_selectedTimelineVC(active);
            if (s != selected) return;
        }
        UIScrollView *sv = nfb_mainScrollViewOf(s);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return;
        if (!nfb_visibleTimelineAtTop(s) && !nfb_canRevealRefreshStartedAtTop(s)) {
            nfb_showNewTweetsPill(s);
            nfb_updateStreamStateIconForVC(s);
            return;
        }
        nfb_scrollToTop(s, NO);
    };
    reveal();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
}

static void nfb_showNewTweetsPill(UIViewController *vc) {
    if (!vc || !vc.view.window) return;
    if (!nfb_homeTabSelectedOrUnknown() && !nfb_searchOrExplorePageSelected()) return;
    gPendingNewTweetsVC = vc;
    UIWindow *win = vc.view.window;
    if (!gNewTweetsPill) {
        gNewTweetsPill = [UIButton buttonWithType:UIButtonTypeCustom];
        gNewTweetsPill.translatesAutoresizingMaskIntoConstraints = NO;
        gNewTweetsPill.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        gNewTweetsPill.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
        gNewTweetsPill.layer.cornerRadius = 18;
        gNewTweetsPill.layer.masksToBounds = YES;
        gNewTweetsPill.backgroundColor = UIColor.systemBlueColor;
        [gNewTweetsPill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        Class handlerClass = objc_getClass("NFBStreamHandler");
        id handler = (handlerClass && [handlerClass respondsToSelector:@selector(shared)]) ? ((id(*)(Class, SEL))objc_msgSend)(handlerClass, @selector(shared)) : nil;
        if (handler) [gNewTweetsPill addTarget:handler action:@selector(newTweetsTap) forControlEvents:UIControlEventTouchUpInside];
    }
    [gNewTweetsPill setTitle:nfb_loc(@"NFB_NEW_TWEETS_PILL", @"New Tweets") forState:UIControlStateNormal];
    [gNewTweetsPill removeFromSuperview];
    [win addSubview:gNewTweetsPill];
    UILayoutGuide *safe = win.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [gNewTweetsPill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:48.0],
        [gNewTweetsPill.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [gNewTweetsPill.heightAnchor constraintGreaterThanOrEqualToConstant:36.0]
    ]];
    gNewTweetsPill.alpha = 0.0;
    [win bringSubviewToFront:gNewTweetsPill];
    [UIView animateWithDuration:0.16 animations:^{ gNewTweetsPill.alpha = 1.0; }];
}

static void nfb_afterRefresh(UIViewController *vc) {
    if (!nfb_visibleTimelineAtTop(vc) && !nfb_canRevealRefreshStartedAtTop(vc)) {
        nfb_showNewTweetsPill(vc);
        nfb_updateStreamStateIconForVC(vc);
        return;
    }
    nfb_hideNewTweetsPill();
    gPendingNewTweetsVC = nil;
    nfb_revealTopAfterRefresh(vc);
    nfb_updateStreamStateIconForVC(vc);
}

// The Home container's currently-visible timeline VC: For You, Following, or a pinned list.
static UIViewController *nfb_selectedTimelineVC(UIViewController *vc) {
    // X 12.x: the Swift container reports it directly.
    UIViewController *container = nfb_homeContainerOf(vc);
    UIViewController *active = nfb_containerActiveContent(container);
    // Only a real timeline page is usable: a wrapper that holds every page would let the refresh
    // responder search hit the first page (For You) instead of the displayed one.
    if (nfb_isTimelinePageController(active) && [active isViewLoaded] && active.view.window) return active;

    UIViewController *paging = nfb_parentControllerNamed(vc, @"Paging");
    if (paging) {
        UIScrollView *h = nfb_horizontalPagingScrollViewOf(paging);
        UIView *viewport = h ?: ([paging isViewLoaded] ? paging.view : nil);
        CGRect viewportBounds = viewport ? viewport.bounds : CGRectZero;
        CGFloat bestArea = 0.0;
        UIViewController *bestVisible = nil;
        for (UIViewController *child in paging.childViewControllers) {
            if (!nfb_isTimelinePageController(child) || ![child isViewLoaded] || !child.view.window ||
                child.view.hidden || child.view.alpha < 0.01 || !child.view.superview || !viewport) continue;
            CGRect frame = [child.view.superview convertRect:child.view.frame toView:viewport];
            CGRect visible = CGRectIntersection(frame, viewportBounds);
            CGFloat area = CGRectIsNull(visible) ? 0.0 : visible.size.width * visible.size.height;
            if (area > bestArea) {
                bestArea = area;
                bestVisible = child;
            }
        }
        if (bestVisible && bestArea > 4000.0) return bestVisible;
        UIViewController *selectedByIndexPath = nfb_pagingViewControllerAtIndexPath(paging, nfb_pagingSelectedIndexPath(paging));
        if (selectedByIndexPath) return selectedByIndexPath;
    }
    UIViewController *segmented = nfb_parentControllerNamed(vc, @"Segmented");
    if (nfb_resp(segmented, @selector(selectedViewController))) {
        id selected = ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(selectedViewController));
        if ([selected isKindOfClass:UIViewController.class] && nfb_isTimelinePageController((UIViewController *)selected)) {
            return (UIViewController *)selected;
        }
    }
    if (nfb_isTimelinePageController(vc) && [vc isViewLoaded] && vc.view.window &&
        !vc.view.hidden && vc.view.alpha > 0.01) {
        return vc;
    }
    return nil;
}

static BOOL nfb_streamTriggerTarget(UIViewController *target) {
    if (!target || nfb_isRecommendedHomeTimeline(target)) return NO;

    if (!nfb_timelineStrictlyAtTop(target)) {
        nfb_markRefreshStarted(target, NO);
        nfb_showNewTweetsPill(target);
        nfb_updateStreamStateIconForVC(target);
        return NO;
    }
    nfb_markRefreshStarted(target, YES);
    nfb_hideNewTweetsPill();
    nfb_scrollToTop(target, NO);

    // Resolve the refresh entry point inside the TARGET's own subtree only. Pinned timelines wrap
    // the real URT controller, so prefer leaf responders for pull/loadTop.
    id ctrlVC = nfb_findLeafResponder(target, @selector(pullToLoadTopControl), 0);
    id pullCtrl = ctrlVC ? ((id(*)(id, SEL))objc_msgSend)(ctrlVC, @selector(pullToLoadTopControl)) : nil;

    BOOL did = NO;
    BOOL willRevealFromCompletion = NO;
    id r;
    // Following's clean path: refresh the TFNTwitterHomeTimeline directly.
    if ((r = nfb_findResponder(target, @selector(refreshWithSource:completion:), 0))) {
        __weak UIViewController *weakTarget = target;
        void (^completion)(void) = [^{
            UIViewController *strongTarget = weakTarget;
            if (strongTarget) nfb_afterRefresh(strongTarget);
        } copy];
        ((void(*)(id, SEL, NSInteger, id))objc_msgSend)(r, @selector(refreshWithSource:completion:), nfb_streamLoadSourceFromSender(pullCtrl), completion);
        did = YES;
        willRevealFromCompletion = YES;
    }
    // Pinned lists: the leaf TFNDataViewController's pull handler is the useful one.
    if (!did && (r = nfb_findLeafResponder(target, @selector(_tfn_dynamic_didPullToLoadTop:), 0)) && pullCtrl) {
        ((void(*)(id, SEL, id))objc_msgSend)(r, @selector(_tfn_dynamic_didPullToLoadTop:), pullCtrl);
        did = YES;
    }
    if (!did && (r = nfb_findLeafResponder(target, @selector(loadTop:), 0))) {
        ((void(*)(id, SEL, id))objc_msgSend)(r, @selector(loadTop:), pullCtrl);
        did = YES;
    }
    if (!did && (r = nfb_findLeafResponder(target, @selector(schedulePullToRefreshUpdate), 0))) {
        ((void(*)(id, SEL))objc_msgSend)(r, @selector(schedulePullToRefreshUpdate));
        did = YES;
    }
    if (!did && (r = nfb_findLeafResponder(target, @selector(clearTimelineCacheAndRefresh), 0))) {
        ((void(*)(id, SEL))objc_msgSend)(r, @selector(clearTimelineCacheAndRefresh));
        did = YES;
    }
    if (did && !willRevealFromCompletion) nfb_afterRefresh(target);
    if (!did) NFBLogEvent([NSString stringWithFormat:@"streamTrigger noEntryPoint target=%@", NSStringFromClass(target.class)]);
    return did;
}

static void nfb_streamTrigger(UIViewController *vc) {
    UIViewController *searchTarget = nfb_visibleSearchAutomationController();
    if (searchTarget) {
        nfb_streamTriggerTarget(searchTarget);
        return;
    }
    // Refresh whatever timeline is actually on screen, not just the hooked items VC.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    nfb_streamTriggerTarget(target);
}

#pragma mark - paging helpers (selected page fallback)

static CGFloat nfb_horizontalScrollScore(UIScrollView *sv) {
    if (!sv || sv.hidden || sv.alpha < 0.01 || sv.bounds.size.width < 100.0 || sv.bounds.size.height < 100.0) return 0;
    CGFloat score = sv.bounds.size.width * sv.bounds.size.height;
    BOOL horizontal = sv.pagingEnabled || sv.alwaysBounceHorizontal || sv.contentSize.width > sv.bounds.size.width * 1.2;
    if (!horizontal) return 0;
    if (sv.contentSize.height > sv.bounds.size.height * 1.4 && !sv.pagingEnabled) score *= 0.2;
    return score;
}

static UIScrollView *nfb_findHorizontalScrollViewInView(UIView *view, CGFloat *bestScore) {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    UIScrollView *best = nil;
    if ([view isKindOfClass:UIScrollView.class]) {
        CGFloat score = nfb_horizontalScrollScore((UIScrollView *)view);
        if (score > *bestScore) { *bestScore = score; best = (UIScrollView *)view; }
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *candidate = nfb_findHorizontalScrollViewInView(subview, bestScore);
        if (candidate) best = candidate;
    }
    return best;
}

static UIScrollView *nfb_horizontalPagingScrollViewOf(UIViewController *vc) {
    if (![vc isViewLoaded]) return nil;
    CGFloat bestScore = 0;
    return nfb_findHorizontalScrollViewInView(vc.view, &bestScore);
}

static id nfb_pagingDataSource(UIViewController *paging) {
    return nfb_resp(paging, @selector(dataSource)) ? ((id(*)(id, SEL))objc_msgSend)(paging, @selector(dataSource)) : nil;
}

static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging) {
    if (!nfb_resp(paging, @selector(selectedIndexPath))) return nil;
    id value = ((id(*)(id, SEL))objc_msgSend)(paging, @selector(selectedIndexPath));
    return [value isKindOfClass:NSIndexPath.class] ? (NSIndexPath *)value : nil;
}

static UIViewController *nfb_pagingViewControllerAtIndexPath(UIViewController *paging, NSIndexPath *indexPath) {
    if (!paging || !indexPath) return nil;
    SEL ownSel = @selector(viewControllerAtIndexPath:);
    if ([paging respondsToSelector:ownSel]) {
        id value = ((id(*)(id, SEL, id))objc_msgSend)(paging, ownSel, indexPath);
        if ([value isKindOfClass:UIViewController.class]) return (UIViewController *)value;
    }
    id dataSource = nfb_pagingDataSource(paging);
    SEL dsSel = @selector(pagingViewController:viewControllerAtIndexPath:);
    if (dataSource && [dataSource respondsToSelector:dsSel]) {
        id value = ((id(*)(id, SEL, id, id))objc_msgSend)(dataSource, dsSel, paging, indexPath);
        if ([value isKindOfClass:UIViewController.class]) return (UIViewController *)value;
    }
    return nil;
}

static UIViewController *nfb_findHomeContainerInTree(UIViewController *root, int depth) {
    if (!root || depth > 14) return nil;
    if ([NSStringFromClass(root.class) containsString:@"HomeTimelineContainer"]) return root;
    UIViewController *presented = nfb_findHomeContainerInTree(root.presentedViewController, depth + 1);
    if (presented) return presented;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = nfb_findHomeContainerInTree(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIViewController *nfb_findHomeContainer(void) {
    UIViewController *active = gActiveItemsVC;
    UIViewController *container = active ? nfb_homeContainerOf(active) : nil;
    if (container) return container;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *found = nfb_findHomeContainerInTree(window.rootViewController, 0);
        if (found) return found;
    }
    return nil;
}

#pragma mark - search "Latest" automation

static void nfb_appendControllerIdentity(NSMutableArray<NSString *> *parts, UIViewController *vc, int depth) {
    if (!vc || depth > 3) return;
    [parts addObject:NSStringFromClass(vc.class)];
    if (vc.title.length) [parts addObject:vc.title];
    if (vc.navigationItem.title.length) [parts addObject:vc.navigationItem.title];
    for (NSString *key in @[@"identifier", @"timelineIdentifier", @"timelineTabIdentifier", @"urtTimelineIdentifier", @"scribePage"]) {
        NSString *value = nfb_stringValueForKey(vc, key);
        if (value.length) [parts addObject:value];
    }
    for (UIViewController *child in vc.childViewControllers) {
        nfb_appendControllerIdentity(parts, child, depth + 1);
    }
}

static NSString *nfb_tabHintForController(UIViewController *vc) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    nfb_appendControllerIdentity(parts, vc, 0);
    return [parts componentsJoinedByString:@"|"];
}

static UIViewController *nfb_guideWithin(UIViewController *vc, int depth) {
    if (!vc || depth > 4) return nil;
    if ([NSStringFromClass(vc.class) containsString:@"GuideContainerViewController"]) return vc;
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *c in [(UINavigationController *)vc viewControllers]) {
            UIViewController *g = nfb_guideWithin(c, depth + 1);
            if (g) return g;
        }
    }
    for (UIViewController *c in vc.childViewControllers) {
        UIViewController *g = nfb_guideWithin(c, depth + 1);
        if (g) return g;
    }
    return nil;
}

static BOOL nfb_controllerLooksSearchTab(UIViewController *vc, NSString *hint) {
    if (nfb_guideWithin(vc, 0)) return YES;
    NSString *cls = vc ? NSStringFromClass(vc.class).lowercaseString : @"";
    if ([cls containsString:@"guide"] || [cls containsString:@"explore"] || [cls containsString:@"discover"]) return YES;
    NSString *low = (hint ?: @"").lowercaseString;
    return [low containsString:@"guidecontainer"] || [low containsString:@"explore"] || [low containsString:@"discover"];
}

static BOOL nfb_searchOrExplorePageSelected(void) {
    NSString *low = nfb_currentSelectedTabPage().lowercaseString;
    return [low containsString:@"search"] || [low containsString:@"explore"] || [low containsString:@"guide"];
}

static BOOL nfb_searchTabLooksLatestTimeline(UIViewController *tabVC, NSString *hint) {
    if (!tabVC || ![tabVC isViewLoaded]) return NO;
    NSString *selectedText = nfb_selectedTextInView(tabVC.view, 0);
    if (nfb_textLooksTopicSearchTab(selectedText)) return NO;
    if (nfb_textLooksLatestSearchTab(selectedText)) return YES;
    NSString *hintText = hint ?: @"";
    if (nfb_textLooksTopicSearchTab(hintText)) return NO;
    if (nfb_textLooksLatestSearchTab(hintText)) return YES;
    NSString *viewText = nfb_diagTextForView(tabVC.view, 240) ?: @"";
    if (nfb_textLooksTopicSearchTab(viewText)) return NO;
    return nfb_textLooksLatestSearchTab(viewText);
}

static BOOL nfb_searchControllerCanRefresh(UIViewController *tabVC) {
    if (!tabVC) return NO;
    NSString *hint = nfb_tabHintForController(tabVC);
    if (!nfb_controllerLooksSearchTab(tabVC, hint)) return NO;
    if (!nfb_searchTabLooksLatestTimeline(tabVC, hint)) return NO;
    if (![tabVC isViewLoaded] || !tabVC.view.window || tabVC.view.hidden || tabVC.view.alpha < 0.01) return NO;
    UIScrollView *sv = nfb_mainScrollViewOf(tabVC);
    return sv && sv.window && sv.bounds.size.height >= 100.0 && sv.contentSize.height >= 60.0;
}

static UIViewController *nfb_findVisibleSearchAutomationControllerInTree(UIViewController *root, int depth) {
    if (!root || depth > 10 || ![root isViewLoaded] || !root.view.window || root.view.hidden || root.view.alpha < 0.01) return nil;
    if ([root isKindOfClass:UINavigationController.class]) {
        UIViewController *visible = ((UINavigationController *)root).visibleViewController;
        UIViewController *found = (visible && visible != root) ? nfb_findVisibleSearchAutomationControllerInTree(visible, depth + 1) : nil;
        if (found) return found;
    }
    for (UIViewController *child in root.childViewControllers.reverseObjectEnumerator) {
        UIViewController *found = nfb_findVisibleSearchAutomationControllerInTree(child, depth + 1);
        if (found) return found;
    }
    NSString *cls = NSStringFromClass(root.class).lowercaseString;
    BOOL directSearchController = [cls containsString:@"guide"] || [cls containsString:@"search"] ||
                                  [cls containsString:@"explore"] || [cls containsString:@"discover"];
    if (directSearchController && nfb_searchControllerCanRefresh(root)) return root;
    return nil;
}

static UIViewController *nfb_visibleSearchAutomationController(void) {
    if (!nfb_searchOrExplorePageSelected()) return nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *root = window.rootViewController;
        while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) root = root.presentedViewController;
        UIViewController *found = nfb_findVisibleSearchAutomationControllerInTree(root, 0);
        if (found) return found;
    }
    return nil;
}

#pragma mark - text helpers (diagnostics + search detection)

static void nfb_appendDescendantText(UIView *view, NSMutableString *out, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 6) return;
    NSString *t = nfb_textOfView(view);
    if (t.length) { [out appendString:t]; [out appendString:@"\n"]; }
    for (UIView *sub in view.subviews) nfb_appendDescendantText(sub, out, depth + 1);
}

static NSString *nfb_diagShortString(NSString *value, NSUInteger maxLen) {
    if (!value.length) return @"-";
    NSString *single = [[value stringByReplacingOccurrencesOfString:@"\n" withString:@"|"] stringByReplacingOccurrencesOfString:@"\r" withString:@"|"];
    single = [single stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (single.length > maxLen) single = [[single substringToIndex:maxLen] stringByAppendingString:@"..."];
    return single.length ? single : @"-";
}

static NSString *nfb_diagTextForView(UIView *view, NSUInteger maxLen) {
    NSMutableString *txt = [NSMutableString string];
    NSString *direct = nfb_textOfView(view);
    if (direct.length) [txt appendString:direct];
    nfb_appendDescendantText(view, txt, 0);
    NSString *ax = view.accessibilityLabel;
    if (ax.length && ![txt containsString:ax]) {
        if (txt.length) [txt appendString:@"|"];
        [txt appendString:ax];
    }
    return nfb_diagShortString(txt, maxLen);
}

#pragma mark - gauge button

@interface NFBStreamButton : UIButton
@property (nonatomic, strong) CAShapeLayer *gauge;
@end
@implementation NFBStreamButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _gauge = [CAShapeLayer layer];
        _gauge.fillColor = UIColor.clearColor.CGColor;
        _gauge.lineWidth = 2.5;
        _gauge.lineCap = kCALineCapRound;
        _gauge.strokeColor = UIColor.systemBlueColor.CGColor;
        _gauge.strokeEnd = 0.0;
        [self.layer addSublayer:_gauge];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0 - 2.0;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _gauge.frame = self.bounds;
    _gauge.path = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:-M_PI_2 endAngle:(3.0 * M_PI_2) clockwise:YES].CGPath;
}
@end

static NFBStreamButton *gStreamButton = nil;
static UIImageView *gStreamStateIcon = nil;
// A single timer drives whichever Home timeline is currently active.
static NSTimer *gNFBStreamTimer = nil;
static __weak UIViewController *gNFBStreamTimerOwner = nil;
static NSTimeInterval gNFBStreamTimerInterval = 0.0;

#pragma mark - operation log recorder (start/stop from the long-press menu)
// Records timestamped events while recording, mirrored to Documents/nfb_oplog.txt so the log
// survives an app kill; NFBLogEvent returns immediately unless recording.

static BOOL gNFBLogRecording = NO;
static NSMutableArray<NSString *> *gNFBLog = nil;
static NSTimeInterval gNFBLogStart = 0.0;
static NSFileHandle *gNFBLogFile = nil;

static NSString *nfb_logFilePath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"nfb_oplog.txt"];
}

void NFBLogEvent(NSString *msg) {
    if (!gNFBLogRecording) return;
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ NFBLogEvent(msg); }); return; }
    if (!gNFBLog) gNFBLog = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"+%7.2f %@", CACurrentMediaTime() - gNFBLogStart, msg ?: @""];
    [gNFBLog addObject:line];
    if (gNFBLog.count >= 6000) {
        [gNFBLog removeObjectsInRange:NSMakeRange(0, MIN((NSUInteger)1000, gNFBLog.count))];
    }
    @try { [gNFBLogFile writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) {}
}

static void nfb_logStart(void) {
    gNFBLog = [NSMutableArray array];
    gNFBLogStart = CACurrentMediaTime();
    @try {
        NSString *path = nfb_logFilePath();
        [[NSData data] writeToFile:path atomically:NO];
        gNFBLogFile = [NSFileHandle fileHandleForWritingAtPath:path];
    } @catch (NSException *e) { gNFBLogFile = nil; }
    gNFBLogRecording = YES;
    NFBLogEvent(@"=== REC START ===");
}

static NSString *nfb_logStop(void) {
    if (gNFBLogRecording) {
        NFBLogEvent(@"=== FINAL DIAG START ===");
        for (NSString *line in [nfb_buildDiagnosticReport() componentsSeparatedByString:@"\n"]) {
            if (line.length) NFBLogEvent(line);
        }
        NFBLogEvent(@"=== REC STOP ===");
    }
    gNFBLogRecording = NO;
    @try { [gNFBLogFile closeFile]; } @catch (NSException *e) {}
    gNFBLogFile = nil;
    return gNFBLog.count ? [gNFBLog componentsJoinedByString:@"\n"] : nfb_loc(@"NFB_LOG_EMPTY", @"(no log)");
}

static NSString *nfb_logSavedFileContents(void) {
    NSString *s = [NSString stringWithContentsOfFile:nfb_logFilePath() encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : nfb_loc(@"NFB_SAVED_LOG_EMPTY", @"(no saved log)");
}

// Crash capture: uncaught ObjC exceptions and fatal signals are appended to the same file so a
// device crash can be read back after relaunch ("Copy saved log"). Installed lazily on the first
// Home appearance so the app's own reporter is already in place; both chain to it.
static NSUncaughtExceptionHandler *gNFBPreviousExceptionHandler = NULL;
static char gNFBCrashLogPathC[1024];
static char gNFBCrashImageInfoC[512];
static const int kNFBCrashSignals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE};
static struct sigaction gNFBPrevSigActions[sizeof(kNFBCrashSignals) / sizeof(int)];

static void nfb_uncaughtExceptionHandler(NSException *exception) {
    @try {
        NSString *line = [NSString stringWithFormat:@"\n=== CRASH (uncaught exception) ===\nname: %@\nreason: %@\nstack:\n%@\n=== CRASH END ===\n",
            exception.name ?: @"?", exception.reason ?: @"?",
            [exception.callStackSymbols componentsJoinedByString:@"\n"] ?: @"-"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:nfb_logFilePath()];
        if (fh) {
            @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; } @catch (NSException *e) {}
        } else {
            [line writeToFile:nfb_logFilePath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
    if (gNFBPreviousExceptionHandler) gNFBPreviousExceptionHandler(exception);
}

static void nfb_crashWrite(int fd, const char *s) {
    if (s && s[0]) write(fd, s, strlen(s));
}

static const char *nfb_crashSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGFPE:  return "SIGFPE";
        default:      return "signal";
    }
}

// Async-signal-safe only: open/write/close + backtrace_symbols_fd on precomputed strings.
static void nfb_signalCrashHandler(int sig, siginfo_t *info, void *context) {
    int fd = open(gNFBCrashLogPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        nfb_crashWrite(fd, "\n=== CRASH (signal) ===\nsignal: ");
        nfb_crashWrite(fd, nfb_crashSignalName(sig));
        nfb_crashWrite(fd, "\n");
        nfb_crashWrite(fd, gNFBCrashImageInfoC);
        nfb_crashWrite(fd, "stack:\n");
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        nfb_crashWrite(fd, "=== CRASH END ===\n");
        close(fd);
    }
    for (size_t i = 0; i < sizeof(kNFBCrashSignals) / sizeof(int); i++) {
        if (kNFBCrashSignals[i] != sig) continue;
        struct sigaction prev = gNFBPrevSigActions[i];
        if ((prev.sa_flags & SA_SIGINFO) && prev.sa_sigaction) { prev.sa_sigaction(sig, info, context); return; }
        if (prev.sa_handler && prev.sa_handler != SIG_DFL && prev.sa_handler != SIG_IGN) { prev.sa_handler(sig); return; }
        break;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void nfb_installCrashLoggerOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gNFBPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&nfb_uncaughtExceptionHandler);
        const char *path = nfb_logFilePath().fileSystemRepresentation;
        if (path) {
            strncpy(gNFBCrashLogPathC, path, sizeof(gNFBCrashLogPathC) - 1);
            gNFBCrashLogPathC[sizeof(gNFBCrashLogPathC) - 1] = '\0';
        }
        Dl_info dlinfo;
        if (dladdr((const void *)&nfb_installCrashLoggerOnce, &dlinfo) && dlinfo.dli_fbase) {
            snprintf(gNFBCrashImageInfoC, sizeof(gNFBCrashImageInfoC), "image: %s base: %p\n",
                     dlinfo.dli_fname ?: "?", dlinfo.dli_fbase);
        }
        void *warm[4];
        backtrace(warm, 4);   // pre-warm the unwinder so the first real backtrace is signal-safe
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = nfb_signalCrashHandler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        for (size_t i = 0; i < sizeof(kNFBCrashSignals) / sizeof(int); i++) {
            sigaction(kNFBCrashSignals[i], &sa, &gNFBPrevSigActions[i]);
        }
    });
}

#pragma mark - tap / long-press handler

@interface NFBStreamHandler : NSObject
+ (instancetype)shared;
- (void)tap;
- (void)newTweetsTap;
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end

@implementation NFBStreamHandler
+ (instancetype)shared {
    static NFBStreamHandler *h;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ h = [NFBStreamHandler new]; });
    return h;
}

- (UIViewController *)topVC {
    UIWindow *w = gStreamButton.window;
    if (!w) {
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.isKeyWindow) { w = win; break; }
        }
    }
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)present:(UIAlertController *)ac {
    UIViewController *top = [self topVC];
    if (!top) return;
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = gStreamButton;
        ac.popoverPresentationController.sourceRect = gStreamButton.bounds;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)tap {
    nfb_setStreamEnabled(!nfb_streamEnabled());
    NFBStreamPrefsChanged();
}

- (void)newTweetsTap {
    UIViewController *vc = gPendingNewTweetsVC ?: gActiveItemsVC;
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    if (!vc) return;
    // Explicit user tap = jump to the top now.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    nfb_scrollToTop(target, YES);
    nfb_updateStreamStateIconForVC(vc);
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self showMain];
}

- (void)showMain {
    BOOL on = nfb_streamEnabled();
    NSInteger iv = nfb_streamInterval();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_STREAM_MENU_TITLE", @"Auto-refresh timeline (streaming)")
        message:[NSString stringWithFormat:nfb_loc(@"NFB_STREAM_MENU_STATUS", @"Status: %@ / interval: %lds"), on ? @"ON" : @"OFF", (long)iv]
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (gNFBLogRecording) {
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_STOP_AND_COPY", @"⏹ Stop log recording and copy") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self stopLogAndShow];
        }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_START", @"⏺ Start log recording (clears the previous log)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            nfb_logStart();
            [self toast:nfb_loc(@"NFB_LOG_START_TOAST", @"Recording started. Reproduce the issue, then long-press again → \"Stop and copy\". If the app gets stuck, relaunch and use \"Copy saved log\".")];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_COPY_SAVED", @"📄 Copy saved log (no stop needed, survives a kill)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self copySavedLog];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_REFRESH_NOW", @"🔄 Refresh now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIViewController *vc = gActiveItemsVC;
        if (vc) nfb_streamTrigger(vc);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:(on ? nfb_loc(@"NFB_STREAM_OFF", @"Turn auto-refresh OFF") : nfb_loc(@"NFB_STREAM_ON", @"Turn auto-refresh ON")) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        nfb_setStreamEnabled(!on);
        NFBStreamPrefsChanged();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_INTERVAL_CHANGE", @"⏱ Change refresh interval…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self showInterval];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_DIAG_SHOW", @"🔍 Diagnostics (copy & send)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self showDiag];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"CANCEL_ACTION_LABEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}

- (void)toast:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self present:ac];
}

- (void)showText:(NSString *)text title:(NSString *)title {
    UIPasteboard.generalPasteboard.string = text;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_RECOPY", @"Copy again") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_CLOSE", @"Close") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}

- (void)stopLogAndShow {
    [self showText:nfb_logStop() title:nfb_loc(@"NFB_LOG_COPIED_TITLE", @"Recorded log (copied)")];
}

- (void)copySavedLog {
    [self showText:nfb_logSavedFileContents() title:nfb_loc(@"NFB_SAVED_LOG_COPIED_TITLE", @"Saved log (copied)")];
}

- (void)showDiag {
    [self showText:nfb_buildDiagnosticReport() title:nfb_loc(@"NFB_DIAG_TITLE", @"Diagnostics")];
}

- (void)showInterval {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_INTERVAL_TITLE", @"Refresh interval") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *n in @[@5, @10, @15, @20, @30, @60]) {
        NSInteger sec = n.integerValue;
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:nfb_loc(@"NFB_SECONDS_FMT", @"%lds"), (long)sec] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            nfb_setStreamInterval(sec);
            NFBStreamPrefsChanged();
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"CANCEL_ACTION_LABEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
@end

#pragma mark - button visuals + lifecycle

static void nfb_styleButton(BOOL on) {
    if (!gStreamButton) return;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    NSString *name = on ? @"arrow.clockwise.circle.fill" : @"arrow.clockwise.circle";
    [gStreamButton setImage:[[UIImage systemImageNamed:name withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    gStreamButton.tintColor = on ? nil : [UIColor systemGrayColor];
    gStreamButton.gauge.hidden = !on;
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}

static void nfb_updateGauge(BOOL on, NSTimeInterval interval) {
    if (!gStreamButton) return;
    CAShapeLayer *g = gStreamButton.gauge;
    [g removeAnimationForKey:@"deplete"];
    if (!on || interval <= 0) { g.strokeEnd = 0.0; return; }
    g.strokeEnd = 1.0;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    anim.fromValue = @1.0;
    anim.toValue = @0.0;
    anim.duration = interval;
    anim.repeatCount = HUGE_VALF;
    anim.removedOnCompletion = NO;
    anim.fillMode = kCAFillModeForwards;
    // The central timer survives controller switches, so a restarted ring picks up where the live
    // timer actually is — otherwise the ring shows a full interval while the refresh fires earlier.
    if (gNFBStreamTimer.isValid && fabs(gNFBStreamTimerInterval - interval) < 0.01) {
        NSTimeInterval remaining = gNFBStreamTimer.fireDate.timeIntervalSinceNow;
        if (remaining > 0.0 && remaining < interval) anim.timeOffset = interval - remaining;
    }
    [g addAnimation:anim forKey:@"deplete"];
}

static BOOL nfb_streamCanRunForTarget(UIViewController *target) {
    if (!nfb_streamEnabled()) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIViewController *searchTarget = nfb_visibleSearchAutomationController();
    if (searchTarget) {
        UIScrollView *sv = nfb_mainScrollViewOf(searchTarget);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return NO;
        return nfb_visibleTimelineAtTop(searchTarget) || nfb_canRevealRefreshStartedAtTop(searchTarget);
    }
    if (!nfb_homeTabSelectedOrUnknown()) return NO;
    if (!target || ![target isViewLoaded] || target.view.window == nil) return NO;
    if (nfb_isRecommendedHomeTimeline(target)) return NO;
    UIScrollView *sv = nfb_mainScrollViewOf(target);
    if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return NO;
    return nfb_visibleTimelineAtTop(target) || nfb_canRevealRefreshStartedAtTop(target);
}

static void nfb_updateStreamStateIconForVC(UIViewController *vc) {
    if (!gStreamStateIcon) return;
    if (gStreamButton && gStreamButton.hidden) {
        gStreamStateIcon.hidden = YES;
        return;
    }
    UIViewController *target = vc ? (nfb_selectedTimelineVC(vc) ?: vc) : nil;
    BOOL globalOn = nfb_streamEnabled();
    BOOL active = nfb_streamCanRunForTarget(target);
    NSInteger state = active ? 2 : (globalOn ? 1 : 0);
    // Only touch UIKit when the state actually changes (this runs from scroll callbacks).
    static NSInteger lastState = -1;
    if (state == lastState && gStreamStateIcon.image && !gStreamStateIcon.hidden) return;
    lastState = state;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    NSString *name = active ? @"bolt.circle.fill" : (globalOn ? @"pause.circle.fill" : @"power.circle");
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    gStreamStateIcon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    gStreamStateIcon.tintColor = active ? [UIColor systemGreenColor] : (globalOn ? [UIColor systemOrangeColor] : [UIColor systemGrayColor]);
    gStreamStateIcon.accessibilityLabel = active ? nfb_loc(@"NFB_STREAM_STATE_ON", @"Streaming active") : nfb_loc(@"NFB_STREAM_STATE_PAUSED", @"Streaming paused");
    gStreamStateIcon.hidden = NO;
}

static void nfb_installButton(UIWindow *win) {
    if (!win) return;
    if (!gStreamButton) {
        gStreamButton = [[NFBStreamButton alloc] initWithFrame:CGRectZero];
        gStreamButton.translatesAutoresizingMaskIntoConstraints = NO;
        gStreamButton.accessibilityLabel = nfb_loc(@"NFB_STREAM_BUTTON_A11Y", @"Timeline auto-refresh");
        gStreamButton.backgroundColor = UIColor.clearColor;
        gStreamButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        gStreamButton.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        [gStreamButton addTarget:[NFBStreamHandler shared] action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[NFBStreamHandler shared] action:@selector(longPress:)];
        lp.minimumPressDuration = 0.4;
        [gStreamButton addGestureRecognizer:lp];
    }
    if (!gStreamStateIcon) {
        gStreamStateIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
        gStreamStateIcon.translatesAutoresizingMaskIntoConstraints = NO;
        gStreamStateIcon.contentMode = UIViewContentModeScaleAspectFit;
        gStreamStateIcon.userInteractionEnabled = NO;
    }
    if (gStreamButton.superview != win) {
        [gStreamButton removeFromSuperview];
        [win addSubview:gStreamButton];
        UILayoutGuide *safe = win.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [gStreamButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:2.0],
            [gStreamButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14.0],
            [gStreamButton.widthAnchor constraintEqualToConstant:46.0],
            [gStreamButton.heightAnchor constraintEqualToConstant:46.0],
        ]];
    }
    if (gStreamStateIcon.superview != win) {
        [gStreamStateIcon removeFromSuperview];
        [win addSubview:gStreamStateIcon];
        [NSLayoutConstraint activateConstraints:@[
            [gStreamStateIcon.centerYAnchor constraintEqualToAnchor:gStreamButton.centerYAnchor],
            [gStreamStateIcon.trailingAnchor constraintEqualToAnchor:gStreamButton.leadingAnchor constant:-1.0],
            [gStreamStateIcon.widthAnchor constraintEqualToConstant:24.0],
            [gStreamStateIcon.heightAnchor constraintEqualToConstant:24.0],
        ]];
    }
    [win bringSubviewToFront:gStreamButton];
    [win bringSubviewToFront:gStreamStateIcon];
    gStreamButton.alpha = 1.0;
    gStreamStateIcon.alpha = 1.0;
    gStreamButton.userInteractionEnabled = YES;
    BOOL on = nfb_streamEnabled();
    nfb_styleButton(on);
    nfb_updateGauge(on, (NSTimeInterval)nfb_streamInterval());
    NFBUpdateStreamButtonVisibility();
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}

static void nfb_removeButton(void) {
    if (gStreamButton) {
        [gStreamButton.gauge removeAnimationForKey:@"deplete"];
        [gStreamButton removeFromSuperview];
    }
    if (gStreamStateIcon) [gStreamStateIcon removeFromSuperview];
    nfb_hideNewTweetsPill();
    gPendingNewTweetsVC = nil;
}

void NFBUpdateStreamButtonVisibility(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBUpdateStreamButtonVisibility(); });
        return;
    }
    BOOL visible = nfb_homeTabSelectedOrUnknown() || nfb_searchOrExplorePageSelected();
    if (!visible) {
        if (gStreamButton) {
            gStreamButton.hidden = YES;
            gStreamButton.userInteractionEnabled = NO;
        }
        if (gStreamStateIcon) gStreamStateIcon.hidden = YES;
        nfb_hideNewTweetsPill();
        return;
    }
    if (gStreamButton) {
        gStreamButton.hidden = NO;
        gStreamButton.userInteractionEnabled = YES;
    }
    if (gStreamStateIcon) gStreamStateIcon.hidden = NO;
}

// Fade with the header: hide while scrolling down, show at top / scrolling up.
static void nfb_visibilityForScroll(UIScrollView *sv) {
    if (!gStreamButton || gStreamButton.window == nil) return;
    NFBUpdateStreamButtonVisibility();
    if (gStreamButton.hidden) return;
    nfb_noteActiveTimelineScroll(sv);
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
    static CGFloat last = 0;
    CGFloat y = sv.contentOffset.y;
    CGFloat topY = -sv.adjustedContentInset.top;
    BOOL atTop = (y <= topY + 4.0);
    if (atTop && gNewTweetsPill) {
        nfb_hideNewTweetsPill();
        gPendingNewTweetsVC = nil;
    }
    CGFloat dy = y - last;
    last = y;
    CGFloat target = gStreamButton.alpha;
    if (atTop || dy < -2.0) target = 1.0;          // at top or scrolling up
    else if (dy > 2.0) target = 0.0;               // scrolling down
    if (fabs(gStreamButton.alpha - target) < 0.01) return;
    [UIView animateWithDuration:0.2 animations:^{
        gStreamButton.alpha = target;
        if (gStreamStateIcon) gStreamStateIcon.alpha = target;
    } completion:^(BOOL f) {
        gStreamButton.userInteractionEnabled = (target > 0.5);
    }];
}

#pragma mark - selected tab (scribePage of the selected T1TabView)

static NSString *nfb_selectedTabPageInView(UIView *view, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 12) return nil;
    Class tabClass = NSClassFromString(@"T1TabView");
    if (tabClass && [view isKindOfClass:tabClass]) {
        T1TabView *tabView = (T1TabView *)view;
        if (tabView.isSelected && tabView.scribePage.length) return tabView.scribePage;
    }
    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        NSString *page = nfb_selectedTabPageInView(subview, depth + 1);
        if (page.length) return page;
    }
    return nil;
}

static NSString *nfb_currentSelectedTabPage(void) {
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval cacheTTL = gNFBSelectedTabPageCache ? 0.12 : 0.03;
    if (gNFBSelectedTabPageCacheAt > 0.0 && now - gNFBSelectedTabPageCacheAt < cacheTTL) {
        return gNFBSelectedTabPageCache;
    }
    NSString *selectedPage = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSString *page = nfb_selectedTabPageInView(window, 0);
        if (page.length) {
            selectedPage = page;
            break;
        }
    }
    gNFBSelectedTabPageCache = [selectedPage copy];
    gNFBSelectedTabPageCacheAt = now;
    return gNFBSelectedTabPageCache;
}

void NFBNoteTabSelectionChanged(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBNoteTabSelectionChanged(); });
        return;
    }
    gNFBSelectedTabPageCache = nil;
    gNFBSelectedTabPageCacheAt = 0.0;
    NFBUpdateStreamButtonVisibility();
}

static BOOL nfb_homeTabSelectedOrUnknown(void) {
    NSString *page = nfb_currentSelectedTabPage();
    if (page.length) return [page isEqualToString:@"home"];
    return gActiveItemsVC && [gActiveItemsVC isViewLoaded] && gActiveItemsVC.view.window;
}

#pragma mark - streaming timer

static BOOL nfb_streamShouldFire(UIViewController *vc) {
    if (!nfb_streamEnabled()) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIViewController *searchTarget = nfb_visibleSearchAutomationController();
    if (searchTarget) {
        UIScrollView *sv = nfb_mainScrollViewOf(searchTarget);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) {
            nfb_updateStreamStateIconForVC(searchTarget);
            return NO;
        }
        if (!nfb_visibleTimelineAtTop(searchTarget)) {
            nfb_showNewTweetsPill(searchTarget);
            nfb_updateStreamStateIconForVC(searchTarget);
            return NO;
        }
        nfb_updateStreamStateIconForVC(searchTarget);
        return YES;
    }
    if (!nfb_homeTabSelectedOrUnknown()) return NO;
    // Gate on the timeline actually on screen (Following / pinned list), not the timer's owner.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    if (![target isViewLoaded] || target.view.window == nil) return NO;
    if (nfb_isRecommendedHomeTimeline(target)) return NO;       // For You -> never auto-refresh
    UIScrollView *sv = nfb_mainScrollViewOf(target);
    if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) {
        nfb_updateStreamStateIconForVC(target);
        return NO;
    }
    if (!nfb_visibleTimelineAtTop(target)) {
        nfb_showNewTweetsPill(target);
        nfb_updateStreamStateIconForVC(target);
        return NO;
    }
    nfb_updateStreamStateIconForVC(target);
    return YES;
}

static void nfb_streamStop(UIViewController *vc) {
    if (vc && gNFBStreamTimerOwner != vc) return;
    [gNFBStreamTimer invalidate];
    gNFBStreamTimer = nil;
    gNFBStreamTimerOwner = nil;
    gNFBStreamTimerInterval = 0.0;
}

static void nfb_streamStart(UIViewController *vc) {
    BOOL on = nfb_streamEnabled();
    NSTimeInterval interval = (NSTimeInterval)nfb_streamInterval();
    nfb_styleButton(on);
    if (!on) {
        nfb_streamStop(nil);
        nfb_updateGauge(NO, 0.0);
        nfb_updateStreamStateIconForVC(vc);
        return;
    }
    if (!vc) {
        nfb_updateGauge(YES, interval);
        return;
    }
    BOOL sameInterval = gNFBStreamTimer && gNFBStreamTimer.isValid && fabs(gNFBStreamTimerInterval - interval) < 0.01;
    gNFBStreamTimerOwner = vc;
    if (sameInterval) {
        nfb_updateGauge(YES, interval);
        nfb_updateStreamStateIconForVC(vc);
        return;
    }
    nfb_streamStop(nil);
    gNFBStreamTimerOwner = vc;
    gNFBStreamTimerInterval = interval;
    nfb_updateGauge(YES, interval);
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(__unused NSTimer *t) {
        UIViewController *target = gNFBStreamTimerOwner ?: gActiveItemsVC;
        if (!target) {
            nfb_streamStop(nil);
            return;
        }
        if (!nfb_streamEnabled()) {
            nfb_streamStop(nil);
            nfb_styleButton(NO);
            nfb_updateGauge(NO, 0);
            nfb_updateStreamStateIconForVC(target);
            return;
        }
        if (nfb_streamShouldFire(target)) nfb_streamTrigger(target);
    }];
    timer.tolerance = MIN(1.0, MAX(0.25, interval * 0.1));
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
    gNFBStreamTimer = timer;
}

void NFBStreamPrefsChanged(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBStreamPrefsChanged(); });
        return;
    }
    UIViewController *vc = gActiveItemsVC ?: nfb_findHomeContainer();
    nfb_streamStart(vc);   // restart the timer so a changed switch / interval applies immediately
}

// selectTimelineVariant:shouldRefresh: takes an NSInteger variant (type encoding q16) — it must
// never be declared as an object, or ARC would try to retain the integer.
static NSString *nfb_identifierForTimelineVariant(NSInteger variant) {
    switch (variant) {
        case 0: return @"home";
        case 1: return @"latest";
        case 2: return @"creatorSubscriptions";
        default: return nil;
    }
}

#pragma mark - diagnostics

void NFBLogSnapshot(NSString *reason) {
    if (!gNFBLogRecording) return;
    UIViewController *active = gActiveItemsVC;
    UIViewController *selected = active ? nfb_selectedTimelineVC(active) : nil;
    NFBLogEvent([NSString stringWithFormat:@"snap[%@] page=%@ active=%@ selected=%@ recommended=%d atTop=%d streamOn=%d btnHidden=%d",
        reason ?: @"?", nfb_currentSelectedTabPage() ?: @"(nil)",
        active ? NSStringFromClass(active.class) : @"nil",
        selected ? NSStringFromClass(selected.class) : @"nil",
        selected ? (nfb_isRecommendedHomeTimeline(selected) ? 1 : 0) : -1,
        selected ? (nfb_visibleTimelineAtTop(selected) ? 1 : 0) : -1,
        nfb_streamEnabled() ? 1 : 0, (gStreamButton && gStreamButton.hidden) ? 1 : 0]);
}

#if NFB_DIAG
static NSString *nfb_refreshMethodsOf(Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    Class c = cls;
    int guard = 0;
    while (c && guard++ < 8) {
        NSString *cn = NSStringFromClass(c);
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *low = NSStringFromSelector(method_getName(ms[i])).lowercaseString;
            if ([low containsString:@"refresh"] || [low containsString:@"reload"] || [low containsString:@"loadtop"] ||
                [low containsString:@"loadnewer"] || [low containsString:@"loadlatest"]) {
                [out addObject:NSStringFromSelector(method_getName(ms[i]))];
            }
        }
        free(ms);
        if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"NS"] || [cn hasPrefix:@"_UI"]) break;
        c = class_getSuperclass(c);
    }
    return [out componentsJoinedByString:@" "];
}

static void nfb_dumpTree(UIViewController *vc, int depth, NSMutableString *s) {
    if (!vc || depth > 6) return;
    NSString *ind = (depth > 0) ? [@"" stringByPaddingToLength:depth * 2 withString:@". " startingAtIndex:0] : @"";
    NSMutableArray *r = [NSMutableArray array];
    if ([vc respondsToSelector:@selector(_tfn_dynamic_didPullToLoadTop:)]) [r addObject:@"pullLoadTop"];
    if ([vc respondsToSelector:@selector(pullToLoadTopControl)]) [r addObject:@"pullCtrl"];
    if ([vc respondsToSelector:@selector(loadTop:)]) [r addObject:@"loadTop"];
    if ([vc respondsToSelector:@selector(schedulePullToRefreshUpdate)]) [r addObject:@"schedulePull"];
    [s appendFormat:@"%@%@%@\n", ind, NSStringFromClass(vc.class),
        r.count ? [NSString stringWithFormat:@"  <%@>", [r componentsJoinedByString:@","]] : @""];
    NSString *meth = nfb_refreshMethodsOf(vc.class);
    if (meth.length) [s appendFormat:@"%@   m: %@\n", ind, meth];
    id tl = nfb_timelineOf(vc);
    if (tl) {
        [s appendFormat:@"%@  ⮡timeline=%@%@\n", ind, NSStringFromClass([tl class]),
            [tl respondsToSelector:@selector(refreshWithSource:completion:)] ? @"  <refreshSrc>" : @""];
    }
    for (UIViewController *c in vc.childViewControllers) nfb_dumpTree(c, depth + 1, s);
}
#endif

static NSString *nfb_buildDiagnosticReport(void) {
#if NFB_DIAG
    NSMutableString *s = [NSMutableString string];
    UIViewController *active = gActiveItemsVC;
    UIViewController *container = active ? nfb_homeContainerOf(active) : nfb_findHomeContainer();
    UIViewController *selected = active ? nfb_selectedTimelineVC(active) : nil;
    UIViewController *containerActive = nfb_containerActiveContent(container);
    BOOL homeSelected = nfb_resp(container, @selector(isHomeSelected)) ?
        ((BOOL(*)(id, SEL))objc_msgSend)(container, @selector(isHomeSelected)) : NO;
    [s appendFormat:@"streaming on=%d interval=%ld page=%@ button=%d/%d\n", nfb_streamEnabled() ? 1 : 0, (long)nfb_streamInterval(),
        nfb_currentSelectedTabPage() ?: @"(nil)", gStreamButton ? 1 : 0, (gStreamButton && !gStreamButton.hidden) ? 1 : 0];
    [s appendFormat:@"container=%@ containerActive=%@ isHomeSelected=%d\n",
        container ? NSStringFromClass(container.class) : @"nil",
        containerActive ? NSStringFromClass(containerActive.class) : @"nil", homeSelected ? 1 : 0];
    [s appendFormat:@"active=%@ selected=%@ recommended=%d strictTop=%d top8=%d canRun=%d\n",
        active ? NSStringFromClass(active.class) : @"nil",
        selected ? NSStringFromClass(selected.class) : @"nil",
        selected ? (nfb_isRecommendedHomeTimeline(selected) ? 1 : 0) : -1,
        selected ? (nfb_timelineStrictlyAtTop(selected) ? 1 : 0) : -1,
        selected ? (nfb_visibleTimelineAtTop(selected) ? 1 : 0) : -1,
        nfb_streamCanRunForTarget(selected) ? 1 : 0];
    UIViewController *search = nfb_visibleSearchAutomationController();
    [s appendFormat:@"searchLatest=%@\n", search ? NSStringFromClass(search.class) : @"nil"];
    UIViewController *paging = active ? nfb_parentControllerNamed(active, @"Paging") : nil;
    UIViewController *segmented = active ? nfb_parentControllerNamed(active, @"Segmented") : nil;
    [s appendFormat:@"paging=%@ segmented=%@\n", paging ? NSStringFromClass(paging.class) : @"nil",
        segmented ? NSStringFromClass(segmented.class) : @"nil"];
    // Columns-redesign probe (read-only): how the 12.x home pager is built. See
    // goals/port-v7-columns-redesign.md (S0).
    if (segmented) {
        NSInteger tabs = nfb_resp(segmented, @selector(numberOfTabs)) ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(numberOfTabs)) : -1;
        NSInteger selectedIndex = nfb_resp(segmented, @selector(selectedIndex)) ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(selectedIndex)) : -1;
        NSInteger hideMode = nfb_resp(segmented, @selector(tabBarHideMode)) ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(tabBarHideMode)) : -1;
        BOOL hPaging = nfb_resp(segmented, @selector(isHorizontalPagingEnabled)) ? ((BOOL(*)(id, SEL))objc_msgSend)(segmented, @selector(isHorizontalPagingEnabled)) : NO;
        id pagingVC = nfb_resp(segmented, @selector(pagingViewController)) ? ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(pagingViewController)) : nil;
        id tabBar = nfb_resp(segmented, @selector(tabBarView)) ? ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(tabBarView)) : nil;
        CGRect tabBarFrame = [tabBar isKindOfClass:UIView.class] ? ((UIView *)tabBar).frame : CGRectZero;
        [s appendFormat:@"probe segmented tabs=%ld selected=%ld tabBarHideMode=%ld hPaging=%d pagingVC=%@ tabBar=%@ f=(%.0f,%.0f,%.0f,%.0f)\n",
            (long)tabs, (long)selectedIndex, (long)hideMode, hPaging ? 1 : 0,
            pagingVC ? NSStringFromClass([pagingVC class]) : @"nil", tabBar ? NSStringFromClass([tabBar class]) : @"nil",
            tabBarFrame.origin.x, tabBarFrame.origin.y, tabBarFrame.size.width, tabBarFrame.size.height];
    }
    UIScrollView *pager = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    if ([pager isKindOfClass:UICollectionView.class]) {
        UICollectionView *cv = (UICollectionView *)pager;
        UICollectionViewLayout *layout = cv.collectionViewLayout;
        NSInteger items = cv.numberOfSections > 0 ? [cv numberOfItemsInSection:0] : -1;
        [s appendFormat:@"probe cv=%@ layout=%@ sections=%ld items=%ld paging=%d bounces=%d bounds=(%.0f,%.0f) content=(%.0f,%.0f) off=%.0f\n",
            NSStringFromClass(cv.class), NSStringFromClass(layout.class), (long)cv.numberOfSections, (long)items,
            cv.pagingEnabled ? 1 : 0, cv.alwaysBounceHorizontal ? 1 : 0, cv.bounds.size.width, cv.bounds.size.height,
            cv.contentSize.width, cv.contentSize.height, cv.contentOffset.x];
        if ([layout isKindOfClass:UICollectionViewFlowLayout.class]) {
            UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)layout;
            [s appendFormat:@"probe flow itemSize=(%.0f,%.0f) dir=%ld line=%.1f inter=%.1f\n", flow.itemSize.width, flow.itemSize.height,
                (long)flow.scrollDirection, flow.minimumLineSpacing, flow.minimumInteritemSpacing];
        }
        for (UICollectionViewCell *cell in cv.visibleCells) {
            NSIndexPath *ip = [cv indexPathForCell:cell];
            UIView *content = cell.contentView.subviews.firstObject;
            UIResponder *r = content;
            while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
            [s appendFormat:@"probe cell %ld class=%@ f=(%.0f,%.0f,%.0f,%.0f) page=%@ pageParent=%@\n", (long)ip.item,
                NSStringFromClass(cell.class), cell.frame.origin.x, cell.frame.origin.y, cell.frame.size.width, cell.frame.size.height,
                r ? NSStringFromClass(r.class) : @"nil",
                (r && ((UIViewController *)r).parentViewController) ? NSStringFromClass(((UIViewController *)r).parentViewController.class) : @"nil"];
        }
    } else if (pager) {
        [s appendFormat:@"probe pager=%@ (not a collection view)\n", NSStringFromClass(pager.class)];
    }
    if (paging) {
        for (UIViewController *child in paging.childViewControllers) {
            [s appendFormat:@"probe pagingChild %@ loaded=%d superview=%@\n", NSStringFromClass(child.class), [child isViewLoaded] ? 1 : 0,
                ([child isViewLoaded] && child.view.superview) ? NSStringFromClass(child.view.superview.class) : @"nil"];
        }
    }
    nfb_dumpTree(container ?: active, 0, s);
    return s;
#else
    return @"(diagnostics disabled: rebuild with NFB_DIAG=1)";
#endif
}

#pragma mark - Hooks

// Button lifecycle on the stable Home container (X 12.x Swift class).
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    nfb_installCrashLoggerOnce();
    NFBLogSnapshot(@"homeContainer.appear");
    nfb_installButton(self.view.window);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    NFBLogSnapshot(@"homeContainer.disappear");
    nfb_removeButton();
}

- (void)selectTimelineVariant:(NSInteger)variant shouldRefresh:(BOOL)shouldRefresh {
    NSString *identifier = nfb_identifierForTimelineVariant(variant);
    if (identifier.length) {
        [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:@"nfb_lastSelectedTimelineTabIdentifier"];
    }
    %orig;
}

%end

%hook THFHomeTimelineItemsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gActiveItemsVC = self;
    nfb_installButton(self.view.window);
    nfb_streamStart(self);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    gActiveItemsVC = self;
    nfb_noteActiveTimelineScroll(scrollView);
    nfb_visibilityForScroll(scrollView);
}

%end

// Pinned-list timelines are hosted by URT controllers inside the Home surface and never reach the
// home items VC scroll hook; refresh the state icon from the list's own scroll (Home surface only).
%hook T1URTViewController

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    if (!nfb_homeContainerOf((UIViewController *)self)) return;
    nfb_noteActiveTimelineScroll(scrollView);
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}

%end

// Tab switches invalidate the selected-tab cache so the button hides/shows immediately.
%hook T1TabBarViewController

- (void)setSelectedTabIndex:(NSInteger)tabIndex {
    %orig;
    NFBNoteTabSelectionChanged();
}

- (void)selectTabAtIndex:(NSInteger)tabIndex {
    %orig;
    NFBNoteTabSelectionChanged();
}

- (void)customTabBar:(id)tabBar selectTabAtIndex:(NSInteger)tabIndex withView:(UIView *)tabView {
    %orig;
    NFBNoteTabSelectionChanged();
}

%end
