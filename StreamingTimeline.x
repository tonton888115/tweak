//
//  StreamingTimeline.x
//  NeoFreeBird
//
//  Native Home-timeline auto-refresh ("streaming" / 垂れ流し). A floating control sits
//  top-right (beside the logo row); a countdown gauge ring depletes each interval and at
//  0 the timeline reloads. TAP = on/off. LONG-PRESS = options (refresh now, interval, and
//  refresh-method tests, since Twitter's refresh entry point varies by build).
//  The control is owned by the Home *container* (stable across For-You/Following switches)
//  and fades away while scrolling down, like the header.
//

#import "TWHeaders.h"
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>

static void nfb_streamStart(UIViewController *vc);
static void nfb_streamStop(UIViewController *vc);
static void nfb_installButton(UIWindow *win);
static void nfb_removeButton(void);
static UIViewController *nfb_selectedTimelineVC(UIViewController *vc);
static void nfb_streamTrigger(UIViewController *vc);
static void nfb_styleButton(BOOL on);
static void nfb_updateGauge(BOOL on, NSTimeInterval interval);
static void nfb_updateStreamStateIconForVC(UIViewController *vc);
static NSString *nfb_currentSelectedTabPage(void);
static BOOL nfb_homeTabSelectedOrUnknown(void);
void NFBUpdateStreamButtonVisibility(void);
static void nfb_showNewTweetsPill(UIViewController *vc);
static BOOL nfb_streamTriggerColumns(void);
static void nfb_revealAllColumnTops(void);
static UIViewController *nfb_findVCByClassSubstring(UIViewController *root, NSString *sub, int depth);
#if NFB_DIAG   // 🔍 diagnostic-report builders — compiled out with `make NFB_DIAG=0` (see Makefile)
static void nfb_appendColumnsDiag(NSMutableString *s, UIViewController *active);
static void nfb_appendTopChromeDiag(NSMutableString *s);
static void nfb_appendCoveringViewsDiag(NSMutableString *s);
static void nfb_appendGestureDiag(NSMutableString *s);
static void nfb_appendSpacesCandidatesDiag(NSMutableString *s);
static void nfb_appendExploreDiscoveryDiag(NSMutableString *s);
static void nfb_appendGuideClassDiag(NSMutableString *s);
static void nfb_appendTabFactoryDiag(NSMutableString *s);
static void nfb_appendSearchChromeDiag(NSMutableString *s);
static void nfb_appendSavedColumnsChromeDiag(NSMutableString *s);
#endif
static NSString *nfb_diagShortString(NSString *value, NSUInteger maxLen);
static NSString *nfb_diagTextForView(UIView *view, NSUInteger maxLen);
static NSString *nfb_buildDiagnosticReport(void);
void NFBLogSnapshot(NSString *reason);             // compact 1-line state snapshot (records only while recording)
extern NSString *BHTColumnsLogFlags(void);          // columns flags + tab selectedIndex, from Tweak.x
static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void);
static NSArray<UIViewController *> *nfb_currentColumnRefreshControllers(void);
static NSArray<UIViewController *> *nfb_allHomePagingTimelinePages(UIViewController *paging);
// Column management (reorder / show-hide / persist) — implemented near nfb_currentColumnTimelinePages.
static NSArray<UIViewController *> *nfb_eligibleColumnPagesAll(void);
static NSString *nfb_columnDisplayName(UIViewController *page);
static NSString *nfb_columnTimelineIdentity(UIViewController *vc);
static NSSet<NSString *> *nfb_columnsHiddenSet(void);
static void nfb_columnsSetHidden(NSString *identity, BOOL hidden);
static void nfb_columnsMove(NSString *identity, NSInteger delta, NSArray<NSString *> *currentOrderIdentities);
static void nfb_columnsSetOrder(NSArray<NSString *> *order);
static NSArray<NSDictionary *> *nfb_allColumnEntriesForManagement(void);
static NSArray<NSDictionary *> *nfb_currentColumnEntriesForPaging(UIViewController *paging);
static NSString *nfb_columnEntryIdentity(NSDictionary *entry);
static NSString *nfb_columnEntryTitle(NSDictionary *entry);
static UIViewController *nfb_columnEntryViewController(NSDictionary *entry);
static BOOL nfb_columnEntryIsHidden(NSDictionary *entry);
static void nfb_columnEntrySetHidden(NSDictionary *entry, BOOL hidden);
static UIViewController *nfb_columnsAppTabControllerForEntry(NSDictionary *entry, UIViewController *paging);
static UIViewController *nfb_makeColumnsSettingsViewController(void);
static void nfb_layoutActiveHomePaging(void);
// Issue C: hide the iPad home logo/nav bar while columns are at root. Pref-gated, restored on detail push / exit.
static void nfb_applyColumnsLogoBarHidden(UIViewController *paging);
static void nfb_restoreColumnsLogoBar(void);
static UIScrollView *nfb_horizontalPagingScrollViewOf(UIViewController *vc);
static NSInteger nfb_estimatedHomePagingPageCount(UIViewController *paging);
static void nfb_requestColumnsPagingPreload(UIViewController *paging, BOOL aggressive);
static id nfb_pagingDataSource(UIViewController *paging);
static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging);
static UIViewController *nfb_pagingViewControllerAtIndexPath(UIViewController *paging, NSIndexPath *indexPath);
static UIViewController *nfb_findAnyHomePagingController(void);
static UIViewController *nfb_findVisibleHomePagingController(void);
static BOOL nfb_searchOrExplorePageSelected(void);
static UIViewController *nfb_visibleSearchAutomationController(void);
static UIViewController *nfb_firstColumnTimelineAwayFromTop(void);
static UIViewController *nfb_firstColumnTimelineAwayFromTopExcept(UIViewController *allowedRevealing);
static void nfb_rememberInlineColumnsOriginals(UIScrollView *scrollView);
static void nfb_scheduleLayoutActiveHomePaging(void);
static void nfb_scheduleLayoutActiveHomePagingLight(void);
static void nfb_columnsBeginSizeTransition(void);
static void nfb_columnsEndSizeTransition(void);
static NSString *nfb_columnsKeyForEntry(NSDictionary *entry, NSUInteger index);
static void nfb_columnsAssociateColumnView(UIView *view, UIViewController *owner, NSString *key, NSUInteger index);
static void nfb_columnsLayoutDetailNavForKey(NSString *key, CGRect frame, UIScrollView *scroll);
static BOOL nfb_columnsRouteControllerIntoTouchedColumn(UIViewController *vc, NSString *reason, BOOL animated);
static void nfb_columnsDismissDetailNav(UINavigationController *nav);
static void nfb_columnsDismissAllDetailNavs(void);
static void nfb_columnsAppendDetailControllers(NSMutableArray<UIViewController *> *controllers, BOOL refreshEligibleOnly);
void NFBSetInlineColumnsEnabled(BOOL enabled);
extern void BHTPresentColumnsMode(void);
extern NSString *BHTColumnsModeDiagnostic(void);

// Minimal bases so `self.view` resolves; everything else goes through objc_msgSend.
@interface THFHomeTimelineContainerViewController : UIViewController
@end
@interface THFHomeTimelineItemsViewController : UIViewController
@end
@interface T1HomeTimelineItemsViewController : UIViewController
@end
@interface TFNPagingViewController : UIViewController
@end
@interface TFNScrollingSegmentedViewController : UIViewController
@end
@class NFBStreamHandler;
@class NFBColumnsSettingsViewController;

// UI strings: BHTBundle key with an inline English fallback. A sideload repackage can ship a
// stale BHTwitter.bundle next to a fresh dylib, and BHTBundle returns the KEY for unknown keys —
// fall back to the English literal in that case instead of rendering a raw key.
static NSString *nfb_loc(NSString *key, NSString *fallback) {
    NSString *value = [[BHTBundle sharedBundle] localizedStringForKey:key];
    return (value.length && ![value isEqualToString:key]) ? value : fallback;
}

static __weak UIViewController *gActiveItemsVC = nil;   // the visible Home timeline list
static __weak UIViewController *gPendingNewTweetsVC = nil;
static __weak UIScrollView *gActiveTimelineScrollView = nil;
static UIButton *gNewTweetsPill = nil;
static BOOL gInlineColumnsEnabled = NO;
static NSString * const kNFBColumnsOrderKey = @"NFBColumnsOrderV1";
static NSString * const kNFBColumnsHiddenKey = @"NFBColumnsHiddenV1";
static NSString * const kNFBColumnsEnabledTabsKey = @"NFBColumnsEnabledTabsV1";
static NSString * const kNFBColumnEntryKindTimeline = @"timeline";
static NSString * const kNFBColumnEntryKindTab = @"tab";
static BOOL gActiveTimelineAtTop = YES;
static CGFloat gActiveTimelineOffsetY = 0.0;
static CGFloat gActiveTimelineTopY = 0.0;
static NSTimeInterval gLastUserTimelineScrollInteraction = 0.0;
static NSTimeInterval gRefreshStartedAt = 0.0;
static BOOL gRefreshStartedAtTop = NO;
static char kNFBRefreshStartedAtKey;
static char kNFBRefreshStartedAtTopKey;

#pragma mark - refresh callers (no signature assumptions)

static BOOL nfb_resp(id o, SEL s) { return o && [o respondsToSelector:s]; }
static id   nfb_timelineOf(id vc) { return nfb_resp(vc, @selector(timeline)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(timeline)) : nil; }
static UIScrollView *nfb_scrollOf(id vc) { return nfb_resp(vc, @selector(scrollView)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(scrollView)) : nil; }

static NSString *nfb_textOfView(UIView *view) {
    if (!view) return nil;
    NSString *text = nil;
    @try {
        if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
        else if ([view isKindOfClass:UIButton.class]) text = [((UIButton *)view) titleForState:UIControlStateNormal];
        if (!text.length) {
            id value = [view valueForKey:@"text"];
            if ([value isKindOfClass:NSString.class]) text = value;
        }
        if (!text.length) text = view.accessibilityLabel;
    } @catch (NSException *e) {
        text = nil;
    }
    return text;
}

static BOOL nfb_viewOrAncestorSelected(UIView *view) {
    UIView *current = view;
    for (int i = 0; current && i < 4; i++, current = current.superview) {
        if ((current.accessibilityTraits & UIAccessibilityTraitSelected) == UIAccessibilityTraitSelected) return YES;
        @try {
            id selected = [current valueForKey:@"selected"];
            if ([selected respondsToSelector:@selector(boolValue)] && [selected boolValue]) return YES;
        } @catch (NSException *e) {
        }
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

static NSInteger nfb_indexOfChildInPagingController(UIViewController *vc) {
    UIViewController *paging = nfb_parentControllerNamed(vc, @"Paging");
    if (!paging) return NSNotFound;
    NSInteger index = 0;
    for (UIViewController *child in paging.childViewControllers) {
        if (child == vc) return index;
        index++;
    }
    return NSNotFound;
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
           [low isEqualToString:@"latest"] ||
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

static BOOL nfb_textLooksNotificationTweetTimeline(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    if ([text containsString:@"通知したツイート"] ||
        [text containsString:@"通知設定したツイート"] ||
        [text containsString:@"通知設定済み"] ||
        [text containsString:@"ツイート通知"] ||
        [text containsString:@"ポスト通知"] ||
        [text containsString:@"通知を設定した"]) return YES;
    return [low containsString:@"tweetnotification"] ||
           [low containsString:@"tweet_notification"] ||
           [low containsString:@"tweet notifications"] ||
           [low containsString:@"notified tweets"] ||
           ([low containsString:@"tweet"] && [low containsString:@"notification"] && [low containsString:@"timeline"]);
}

static NSString *nfb_stringValueForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        id value = [obj valueForKey:key];
        if ([value isKindOfClass:NSString.class]) return value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    } @catch (NSException *e) {
    }
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

static NSString *nfb_homeTimelineTabIdentifierFromDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *keys = @[
        @"THFHomeTimelineContainerViewController.lastSelectedTimelineTabIdentifier",
        @"nfb_lastSelectedTimelineTabIdentifier",
        @"lastSelectedTimelineTabIdentifier",
        @"selectedTimelineTabIdentifier",
        @"selectedHomeTimelineTabIdentifier"
    ];
    for (NSString *key in keys) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSString *nfb_homeTimelineTabIdentifierFromObject(id obj) {
    NSArray<NSString *> *keys = @[
        @"lastSelectedTimelineTabIdentifier",
        @"selectedTimelineTabIdentifier",
        @"selectedHomeTimelineTabIdentifier",
        @"selectedTabIdentifier",
        @"timelineTabIdentifier",
        @"urtTimelineIdentifier"
    ];
    for (NSString *key in keys) {
        NSString *value = nfb_stringValueForKey(obj, key);
        if (nfb_homeTabIdentifierLooksRecommended(value) || nfb_homeTabIdentifierLooksChronological(value)) return value;
    }
    return nil;
}

static NSString *nfb_homeTimelineTabIdentifier(UIViewController *vc) {
    NSString *saved = nfb_homeTimelineTabIdentifierFromDefaults();
    if (saved.length) return saved;
    UIViewController *segmented = nfb_parentControllerNamed(vc, @"Segmented");
    UIViewController *container = nfb_parentControllerNamed(vc, @"HomeTimelineContainer");
    NSMutableArray *objects = [NSMutableArray array];
    if (vc) [objects addObject:vc];
    if (segmented) [objects addObject:segmented];
    if (container) [objects addObject:container];
    for (id obj in objects) {
        NSString *value = nfb_homeTimelineTabIdentifierFromObject(obj);
        if (value.length) return value;
    }
    return nil;
}

static BOOL nfb_isTimelinePageController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass(vc.class);
    return [cls containsString:@"HomeTimelineItemsViewController"] ||
           [cls containsString:@"PinnedTimelineViewController"];
}

static BOOL nfb_isRecommendedHomeTimeline(UIViewController *vc) {
    if (!vc) return NO;
    // Definitive: the Home container exposes the "For You" (home) and "Following"
    // (latest) list controllers as distinct objects. Compare by identity — this is
    // immune to the nil tab text/identifiers that broke the old heuristic, and it
    // never mis-flags Following or pinned lists as recommended.
    UIViewController *container = nfb_parentControllerNamed(vc, @"HomeTimelineContainer");
    if (container && nfb_resp(container, @selector(homeTimelineViewController))) {
        id homeVC = ((id(*)(id, SEL))objc_msgSend)(container, @selector(homeTimelineViewController));
        if (homeVC) {
            id latestVC = nfb_resp(container, @selector(latestTimelineViewController))
                ? ((id(*)(id, SEL))objc_msgSend)(container, @selector(latestTimelineViewController)) : nil;
            if (vc == latestVC) return NO;   // Following  -> auto-refresh allowed
            if (vc == homeVC)   return YES;  // For You    -> auto-refresh blocked
            return NO;                        // pinned list -> auto-refresh allowed
        }
    }
    // Fallback (container not ready / older builds): old text + identifier heuristic.
    UIViewController *segmented = nfb_parentControllerNamed(vc, @"Segmented");
    NSString *selectedText = segmented ? nfb_selectedTextInView(segmented.view, 0) : nil;
    if (nfb_textLooksRecommendedTab(selectedText)) return YES;
    id timeline = nfb_timelineOf(vc);
    NSString *timelineClass = timeline ? NSStringFromClass([timeline class]) : @"";
    if (![timelineClass isEqualToString:@"TFNTwitterHomeTimeline"]) return NO;
    NSString *identifier = nfb_homeTimelineTabIdentifier(vc);
    if (nfb_homeTabIdentifierLooksRecommended(identifier)) return YES;
    return NO;
}

static BOOL nfb_stringLooksSpacesTimeline(NSString *text) {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    return [text containsString:@"スペース"] ||
           [low containsString:@"spaces"] ||
           [low containsString:@"space_timeline"] ||
           [low containsString:@"audiospace"] ||
           [low containsString:@"audio_space"];
}

static void nfb_appendControllerIdentity(NSMutableArray<NSString *> *parts, UIViewController *vc, int depth) {
    if (!vc || depth > 3) return;
    [parts addObject:NSStringFromClass(vc.class)];
    if (vc.title.length) [parts addObject:vc.title];
    if (vc.navigationItem.title.length) [parts addObject:vc.navigationItem.title];
    if ([vc isViewLoaded] && vc.view.accessibilityLabel.length) [parts addObject:vc.view.accessibilityLabel];
    for (NSString *key in @[@"identifier", @"timelineIdentifier", @"timelineTabIdentifier", @"urtTimelineIdentifier", @"selectedTimelineTabIdentifier", @"scribePage"]) {
        NSString *value = nfb_stringValueForKey(vc, key);
        if (value.length) [parts addObject:value];
    }
    id timeline = nfb_timelineOf(vc);
    if (timeline) {
        [parts addObject:NSStringFromClass([timeline class])];
        for (NSString *key in @[@"identifier", @"timelineIdentifier", @"timelineTabIdentifier", @"urtTimelineIdentifier", @"timelineType"]) {
            NSString *value = nfb_stringValueForKey(timeline, key);
            if (value.length) [parts addObject:value];
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        nfb_appendControllerIdentity(parts, child, depth + 1);
    }
}

static NSString *nfb_columnTimelineIdentity(UIViewController *vc) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    nfb_appendControllerIdentity(parts, vc, 0);
    return [parts componentsJoinedByString:@"|"];
}

static BOOL nfb_shouldUseTimelinePageAsColumn(UIViewController *page) {
    if (!nfb_isTimelinePageController(page) || nfb_isRecommendedHomeTimeline(page)) return NO;
    NSString *cls = NSStringFromClass(page.class);
    if ([cls containsString:@"HomeTimelineItemsViewController"]) return YES;
    NSString *identity = nfb_columnTimelineIdentity(page);
    if (nfb_stringLooksSpacesTimeline(identity)) return NO;
    if ([cls containsString:@"PinnedTimelineViewController"]) return YES;
    return NO;
}

// Defined with the other inline-columns association keys further below; declared here so the early
// scroll-scoring helpers can identify and exclude the columns pager.
static char kNFBInlineColumnsAppliedKey;

static CGFloat nfb_scrollViewScore(UIScrollView *sv) {
    if (!sv || sv.hidden || sv.alpha < 0.01 || sv.bounds.size.width < 100.0 || sv.bounds.size.height < 100.0) return 0;
    // The inline-columns horizontal pager is the column CONTAINER, never the "main" (vertical) timeline
    // scroll. Exclude it explicitly: after the b47 right-edge stop, its contentWidth no longer exceeds
    // the 1.4x ratio below, so the old ratio-based de-prioritization would misclassify it as a tall
    // main scroll (regardless of how many columns there are). This keeps column detection count-stable.
    if (objc_getAssociatedObject(sv, &kNFBInlineColumnsAppliedKey)) return 0.0;
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

// Walk up to the Home container, then search the whole VC subtree (+ each VC's
// `timeline`) for an object that responds to `sel`. The refresh entry point may live
// on a child content/data controller, not on the list VC we hook.
static UIViewController *nfb_homeRoot(UIViewController *vc) {
    UIViewController *r = vc;
    for (int i = 0; i < 5 && r.parentViewController; i++) r = r.parentViewController;
    return r;
}
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
        ((void(*)(id,SEL,BOOL,NSUInteger,id))objc_msgSend)(vc, @selector(scrollToTopAnimated:options:completion:), animated, 0, nil);
        did = YES;
    }
    if (nfb_resp(vc, @selector(scrollToTop))) {
        ((void(*)(id,SEL))objc_msgSend)(vc, @selector(scrollToTop));
        did = YES;
    }
    if (nfb_resp(vc, @selector(scrollToTop:))) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(vc, @selector(scrollToTop:), animated);
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
static BOOL nfb_visibleTimelineAtTop(UIViewController *vc) {
    if (vc) {
        UIScrollView *ownScroll = nfb_mainScrollViewOf(vc);
        if (ownScroll && ownScroll.window && ownScroll.bounds.size.height > 100.0) {
            CGFloat topY = -ownScroll.adjustedContentInset.top;
            return ownScroll.contentOffset.y <= topY + 8.0;
        }
    }
    UIScrollView *activeScroll = gActiveTimelineScrollView;
    if (activeScroll && activeScroll.window && activeScroll.bounds.size.height > 100.0) {
        CGFloat topY = -activeScroll.adjustedContentInset.top;
        return activeScroll.contentOffset.y <= topY + 8.0;
    }
    return nfb_isTimelineAtTop(vc);
}
static void nfb_markRefreshStarted(UIViewController *vc, BOOL atTop) {
    NSTimeInterval now = CACurrentMediaTime();
    gRefreshStartedAt = now;
    gRefreshStartedAtTop = atTop;
    if (!vc) return;
    objc_setAssociatedObject(vc, &kNFBRefreshStartedAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kNFBRefreshStartedAtTopKey, @(atTop), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL nfb_canRevealRefreshStartedAtTop(UIViewController *vc) {
    if (![BHTManager autoStreamTimeline]) return NO;
    if (!vc) return NO;
    NSNumber *startedAtTop = objc_getAssociatedObject(vc, &kNFBRefreshStartedAtTopKey);
    if (!startedAtTop.boolValue) return NO;
    NSNumber *startedAtValue = objc_getAssociatedObject(vc, &kNFBRefreshStartedAtKey);
    NSTimeInterval startedAt = startedAtValue ? startedAtValue.doubleValue : 0.0;
    if (startedAt <= 0.0) return NO;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - startedAt > 12.0) return NO;
    if (gLastUserTimelineScrollInteraction > startedAt + 0.05) return NO;
    if (!gInlineColumnsEnabled) {
        UIViewController *active = gActiveItemsVC;
        if (active && vc && vc != active) {
            UIViewController *selected = nfb_selectedTimelineVC(active);
            if (selected && vc != selected) return NO;
        }
    }
    return YES;
}
static UIControl *nfb_findHomeTabControl(UIView *view, BOOL inTabBar, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 10) return nil;
    NSString *cls = NSStringFromClass([view class]);
    BOOL tabContext = inTabBar || [view isKindOfClass:UITabBar.class] || [cls containsString:@"TabBar"];
    if (tabContext && [view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        NSString *label = [control.accessibilityLabel ?: @"" lowercaseString];
        NSString *identifier = [control.accessibilityIdentifier ?: @"" lowercaseString];
        BOOL looksHome = [label containsString:@"home"] || [label containsString:@"ホーム"] ||
                         [identifier containsString:@"home"] || [identifier containsString:@"timeline"];
        if (looksHome || (control.selected && [cls containsString:@"TabBar"])) return control;
    }
    for (UIView *sub in view.subviews.reverseObjectEnumerator) {
        UIControl *found = nfb_findHomeTabControl(sub, tabContext, depth + 1);
        if (found) return found;
    }
    return nil;
}
static BOOL nfb_tapHomeTabLikeUser(void) {
    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;
    for (UIWindow *win in windows.reverseObjectEnumerator) {
        if (win.hidden || win.alpha < 0.01) continue;
        UIControl *control = nfb_findHomeTabControl(win, NO, 0);
        if (!control) continue;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}
static void nfb_hideNewTweetsPill(void) {
    if (!gNewTweetsPill) return;
    [UIView animateWithDuration:0.16 animations:^{
        gNewTweetsPill.alpha = 0.0;
    } completion:^(BOOL finished) {
        [gNewTweetsPill removeFromSuperview];
    }];
}
static void nfb_revealTopAfterRefresh(UIViewController *vc) {
    __weak UIViewController *wvc = vc;
    __block BOOL tappedHomeTab = NO;
    void (^reveal)(void) = ^{
        UIViewController *s = wvc;
        if (!s || ![s isViewLoaded] || s.view.window == nil) return;
        if (!gInlineColumnsEnabled) {
            UIViewController *active = gActiveItemsVC;
            if (active && s != active) {
                UIViewController *selected = nfb_selectedTimelineVC(active);
                if (s != selected) return;
            }
        }
        UIScrollView *sv = nfb_mainScrollViewOf(s);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return;
        if (!nfb_visibleTimelineAtTop(s) && !nfb_canRevealRefreshStartedAtTop(s)) {
            nfb_showNewTweetsPill(s);
            nfb_updateStreamStateIconForVC(s);
            return;
        }
        if (!gInlineColumnsEnabled && !tappedHomeTab && s == gActiveItemsVC) {
            tappedHomeTab = nfb_tapHomeTabLikeUser();
        }
        nfb_scrollToTop(s, NO);
    };
    reveal();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
}
static void nfb_showNewTweetsPill(UIViewController *vc) {
    if (!vc || !vc.view.window) return;
    if (!nfb_homeTabSelectedOrUnknown()) return;
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
        id handler = (handlerClass && [handlerClass respondsToSelector:@selector(shared)]) ? ((id(*)(Class,SEL))objc_msgSend)(handlerClass, @selector(shared)) : nil;
        if (handler) [gNewTweetsPill addTarget:handler action:@selector(newTweetsTap) forControlEvents:UIControlEventTouchUpInside];
    }
    NSString *title = gInlineColumnsEnabled
        ? nfb_loc(@"NFB_NEW_TWEETS_PILL_COLUMNS", @"New Tweets — all columns to top")
        : nfb_loc(@"NFB_NEW_TWEETS_PILL", @"New Tweets");
    [gNewTweetsPill setTitle:title forState:UIControlStateNormal];
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
    UIViewController *away = gInlineColumnsEnabled ? nfb_firstColumnTimelineAwayFromTopExcept(vc) : nil;
    if (away) {
        nfb_showNewTweetsPill(away);
    } else {
        nfb_hideNewTweetsPill();
        gPendingNewTweetsVC = nil;
    }
    nfb_revealTopAfterRefresh(vc);
    if (gInlineColumnsEnabled) nfb_layoutActiveHomePaging();
    nfb_updateStreamStateIconForVC(vc);
}

// The Home container's currently-visible timeline VC: the For You items VC, the
// Following items VC, or a pinned-list PinnedTimelineViewController. The old code only
// knew about the two home items VCs, so pinned lists (ニコニコ/投資) never refreshed.
static UIViewController *nfb_selectedTimelineVC(UIViewController *vc) {
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
        NSIndexPath *selectedIndexPath = nfb_pagingSelectedIndexPath(paging);
        UIViewController *selectedByIndexPath = nfb_pagingViewControllerAtIndexPath(paging, selectedIndexPath);
        if (selectedByIndexPath) return selectedByIndexPath;
        if (nfb_isTimelinePageController(vc) && [vc isViewLoaded] && vc.view.window &&
            !vc.view.hidden && vc.view.alpha > 0.01 && !nfb_isRecommendedHomeTimeline(vc)) {
            return vc;
        }
        for (NSString *name in @[@"selectedViewController", @"visibleViewController", @"primaryViewController"]) {
            SEL sel = NSSelectorFromString(name);
            if ([paging respondsToSelector:sel]) {
                id pageVC = ((id(*)(id, SEL))objc_msgSend)(paging, sel);
                if ([pageVC isKindOfClass:UIViewController.class]) return (UIViewController *)pageVC;
            }
        }
    }
    UIViewController *container = nfb_parentControllerNamed(vc, @"HomeTimelineContainer");
    if (container && nfb_resp(container, @selector(selectedTimelineViewController))) {
        id sel = ((id(*)(id, SEL))objc_msgSend)(container, @selector(selectedTimelineViewController));
        if ([sel isKindOfClass:UIViewController.class]) return (UIViewController *)sel;
    }
    return nil;
}

static BOOL nfb_streamTriggerTarget(UIViewController *target) {
    if (!target || nfb_isRecommendedHomeTimeline(target)) return NO;

    if (!nfb_visibleTimelineAtTop(target)) {
        nfb_markRefreshStarted(target, NO);
        nfb_showNewTweetsPill(target);
        nfb_updateStreamStateIconForVC(target);
        return NO;
    }
    nfb_markRefreshStarted(target, YES);
    nfb_hideNewTweetsPill();
    nfb_scrollToTop(target, NO);

    // Resolve the refresh entry point inside the TARGET's own subtree only. Pinned
    // timelines wrap the real URT controller, so prefer leaf responders for pull/loadTop.
    id ctrlVC = nfb_findLeafResponder(target, @selector(pullToLoadTopControl), 0);
    id pullCtrl = ctrlVC ? ((id(*)(id, SEL))objc_msgSend)(ctrlVC, @selector(pullToLoadTopControl)) : nil;

    BOOL did = NO;
    BOOL willRevealFromCompletion = NO;
    id r;
    // Following's clean path: refresh the TFNTwitterHomeTimeline directly.
    if (!did && (r = nfb_findResponder(target, @selector(refreshWithSource:completion:), 0))) {
        __weak UIViewController *weakTarget = target;
        void (^completion)(void) = [^{
            UIViewController *strongTarget = weakTarget;
            if (strongTarget) nfb_afterRefresh(strongTarget);
        } copy];
        ((void(*)(id, SEL, NSInteger, id))objc_msgSend)(r, @selector(refreshWithSource:completion:), nfb_streamLoadSourceFromSender(pullCtrl), completion);
        did = YES;
        willRevealFromCompletion = YES;
    }
    // Pinned lists: the parent PinnedTimelineViewController also advertises loadTop:
    // but can be a wrapper. The child T1URTViewController's pull handler is the useful one.
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
    return did;
}

static void nfb_streamTrigger(UIViewController *vc) {
    if (gInlineColumnsEnabled && nfb_streamTriggerColumns()) return;
    UIViewController *searchTarget = nfb_visibleSearchAutomationController();
    if (searchTarget) {
        nfb_streamTriggerTarget(searchTarget);
        return;
    }

    // Refresh whatever timeline is actually on screen, not just the home items VC.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    nfb_streamTriggerTarget(target);
}

#if NFB_DIAG
// List a class's own+inherited refresh-ish method names (for the diagnostic dump).
static NSString *nfb_refreshMethodsOf(Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    Class c = cls; int guard = 0;
    while (c && guard++ < 8) {
        NSString *cn = NSStringFromClass(c);
        unsigned int n = 0; Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = nm.lowercaseString;
            if ([low containsString:@"refresh"] || [low containsString:@"reload"] ||
                [low containsString:@"loadtop"] || [low containsString:@"loadnewer"] ||
                [low containsString:@"loadlatest"]) [out addObject:nm];
        }
        free(ms);
        if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"NS"] || [cn hasPrefix:@"_UI"]) break;
        c = class_getSuperclass(c);
    }
    return [out componentsJoinedByString:@" "];
}
static Method nfb_methodFor(id obj, SEL sel) {
    Class c = [obj class]; int guard = 0;
    while (c && guard++ < 8) {
        Method m = class_getInstanceMethod(c, sel);
        if (m) return m;
        c = class_getSuperclass(c);
    }
    return NULL;
}
static void nfb_appendMethodType(NSMutableString *s, NSString *ind, id obj, SEL sel) {
    Method m = nfb_methodFor(obj, sel);
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (enc) [s appendFormat:@"%@   enc %@ = %s\n", ind, NSStringFromSelector(sel), enc];
}
static void nfb_appendScrollDiag(NSMutableString *s, UIViewController *vc) {
    UIScrollView *sv = nfb_mainScrollViewOf(vc);
    UIViewController *segmented = nfb_parentControllerNamed(vc, @"Segmented");
    NSString *selectedText = segmented ? nfb_selectedTextInView(segmented.view, 0) : nil;
    NSInteger pagingIndex = nfb_indexOfChildInPagingController(vc);
    NSString *tabIdentifier = nfb_homeTimelineTabIdentifier(vc);
    id timeline = nfb_timelineOf(vc);
    if (sv) {
        [s appendFormat:@"scroll=%@ offset=(%.1f,%.1f) size=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) bounceV=%d\n",
            NSStringFromClass([sv class]), sv.contentOffset.x, sv.contentOffset.y,
            sv.contentSize.width, sv.contentSize.height, sv.bounds.size.width, sv.bounds.size.height,
            sv.adjustedContentInset.top, sv.adjustedContentInset.left, sv.adjustedContentInset.bottom, sv.adjustedContentInset.right,
            sv.alwaysBounceVertical ? 1 : 0];
        [s appendFormat:@"streamGuard vcAtTop=%d visibleAtTop=%d refreshStartedAtTop=%d canRevealStartedAtTop=%d inlineColumns=%d activeOffsetY=%.1f activeTopY=%.1f\n",
            nfb_isTimelineAtTop(vc) ? 1 : 0, nfb_visibleTimelineAtTop(vc) ? 1 : 0,
            gRefreshStartedAtTop ? 1 : 0, nfb_canRevealRefreshStartedAtTop(vc) ? 1 : 0, gInlineColumnsEnabled ? 1 : 0,
            gActiveTimelineOffsetY, gActiveTimelineTopY];
    } else {
        [s appendString:@"scroll=(nil)\n"];
    }
    [s appendFormat:@"homeVariant recommended=%d pagingIndex=%ld selectedText=%@ tabIdentifier=%@ timeline=%@\n",
        nfb_isRecommendedHomeTimeline(vc) ? 1 : 0,
        (long)pagingIndex,
        selectedText ?: @"(nil)",
        tabIdentifier ?: @"(nil)",
        timeline ? NSStringFromClass([timeline class]) : @"(nil)"];
    UIViewController *container = nfb_parentControllerNamed(vc, @"HomeTimelineContainer");
    id homeVC = (container && nfb_resp(container, @selector(homeTimelineViewController)))
        ? ((id(*)(id, SEL))objc_msgSend)(container, @selector(homeTimelineViewController)) : nil;
    id latestVC = (container && nfb_resp(container, @selector(latestTimelineViewController)))
        ? ((id(*)(id, SEL))objc_msgSend)(container, @selector(latestTimelineViewController)) : nil;
    [s appendFormat:@"identity isForYou=%d isFollowing=%d (homeVC=%p latestVC=%p self=%p)\n",
        (vc == homeVC) ? 1 : 0, (vc == latestVC) ? 1 : 0, homeVC, latestVC, vc];
    UIViewController *selected = nfb_selectedTimelineVC(vc);
    [s appendFormat:@"selectedTimelineVC=%@ (refreshTarget; recommended=%d)\n",
        selected ? NSStringFromClass([selected class]) : @"(nil)",
        selected ? (nfb_isRecommendedHomeTimeline(selected) ? 1 : 0) : -1];
}

static void nfb_dumpTree(UIViewController *vc, int depth, NSMutableString *s) {
    if (!vc || depth > 6) return;
    NSString *ind = (depth > 0) ? [@"" stringByPaddingToLength:depth * 2 withString:@". " startingAtIndex:0] : @"";
    NSMutableArray *r = [NSMutableArray array];
    if ([vc respondsToSelector:@selector(_tfn_dynamic_didPullToLoadTop:)]) [r addObject:@"pullLoadTop"];
    if ([vc respondsToSelector:@selector(pullToLoadTopControl)]) [r addObject:@"pullCtrl"];
    if ([vc respondsToSelector:@selector(loadTop:)]) [r addObject:@"loadTop"];
    if ([vc respondsToSelector:@selector(schedulePullToRefreshUpdate)]) [r addObject:@"schedulePull"];
    if ([vc respondsToSelector:@selector(loadNewer)]) [r addObject:@"loadNewer"];
    if ([vc respondsToSelector:@selector(_t1_didPullToRefresh:)]) [r addObject:@"pull"];
    if ([vc respondsToSelector:@selector(reloadTop:)]) [r addObject:@"reloadTop"];
    if ([vc respondsToSelector:@selector(_refreshContent)]) [r addObject:@"refreshContent"];
    if ([vc respondsToSelector:@selector(loadNewerWithSource:completion:)]) [r addObject:@"loadNewerSrc"];
    if ([vc respondsToSelector:@selector(refreshWithLoadSource:completion:)]) [r addObject:@"refreshSrc"];
    [s appendFormat:@"%@%@%@\n", ind, NSStringFromClass([vc class]),
        r.count ? [NSString stringWithFormat:@"  <%@>", [r componentsJoinedByString:@","]] : @""];
    NSString *meth = nfb_refreshMethodsOf([vc class]);
    if (meth.length) [s appendFormat:@"%@   m: %@\n", ind, meth];
    if ([vc respondsToSelector:@selector(loadTop:)]) nfb_appendMethodType(s, ind, vc, @selector(loadTop:));
    if ([vc respondsToSelector:@selector(_tfn_dynamic_didPullToLoadTop:)]) nfb_appendMethodType(s, ind, vc, @selector(_tfn_dynamic_didPullToLoadTop:));
    if ([vc respondsToSelector:@selector(schedulePullToRefreshUpdate)]) nfb_appendMethodType(s, ind, vc, @selector(schedulePullToRefreshUpdate));
    if ([vc respondsToSelector:@selector(selectTimelineVariant:shouldRefresh:)]) nfb_appendMethodType(s, ind, vc, @selector(selectTimelineVariant:shouldRefresh:));
    id tl = nfb_timelineOf(vc);
    if (tl) {
        NSMutableArray *tr = [NSMutableArray array];
        if ([tl respondsToSelector:@selector(refreshWithSource:completion:)]) [tr addObject:@"refreshSrc"];
        if ([tl respondsToSelector:@selector(refreshWithSource:pushToHomeTweetId:completion:)]) [tr addObject:@"refreshSrcTweet"];
        [s appendFormat:@"%@  ⮡timeline=%@%@\n", ind, NSStringFromClass([tl class]),
            tr.count ? [NSString stringWithFormat:@"  <%@>", [tr componentsJoinedByString:@","]] : @""];
        NSString *tm = nfb_refreshMethodsOf([tl class]);
        if (tm.length) [s appendFormat:@"%@   tl.m: %@\n", ind, tm];
        if ([tl respondsToSelector:@selector(refreshWithSource:completion:)]) nfb_appendMethodType(s, ind, tl, @selector(refreshWithSource:completion:));
        if ([tl respondsToSelector:@selector(refreshWithSource:pushToHomeTweetId:completion:)]) nfb_appendMethodType(s, ind, tl, @selector(refreshWithSource:pushToHomeTweetId:completion:));
    }
    for (UIViewController *c in vc.childViewControllers) nfb_dumpTree(c, depth + 1, s);
}
#endif

#pragma mark - gauge button

@interface NFBStreamButton : UIButton
@property (nonatomic, strong) CAShapeLayer *gauge;
@end
@implementation NFBStreamButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _gauge = [CAShapeLayer layer];
        _gauge.fillColor = UIColor.clearColor.CGColor;
        _gauge.lineWidth = 2.5; _gauge.lineCap = kCALineCapRound;
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
    _gauge.path = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:-M_PI_2 endAngle:(3.0*M_PI_2) clockwise:YES].CGPath;
}
@end

static NFBStreamButton *gStreamButton = nil;
static UIImageView *gStreamStateIcon = nil;
static void nfb_setStreamEnabled(BOOL on)    { [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"auto_stream_timeline"]; [[NSUserDefaults standardUserDefaults] synchronize]; }
static void nfb_setStreamInterval(NSInteger s){ [[NSUserDefaults standardUserDefaults] setInteger:s forKey:@"auto_stream_interval"]; [[NSUserDefaults standardUserDefaults] synchronize]; }

#pragma mark - operation log recorder (start/stop from the long-press menu)
// Records timestamped events (button taps, tab switches, columns present/dismiss, mode changes,
// screen appearances) continuously while recording — so dynamic / stuck states the snapshot can't
// reach are captured and pasted as text. NFBLogEvent returns immediately unless recording, so it's
// cheap to sprinkle everywhere. Shared with Tweak.x via the extern declarations there.
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
    if (gNFBLog.count > 6000) [gNFBLog removeObjectAtIndex:0];
    // Mirror each line to a file so the log survives an app kill or a stuck screen where the menu /
    // stop button isn't reachable — it can be copied next launch via "保存済みログをコピー".
    @try { [gNFBLogFile writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) {}
}
BOOL NFBLogIsRecording(void) { return gNFBLogRecording; }
void NFBLogStartRecording(void) {
    gNFBLog = [NSMutableArray array];
    gNFBLogStart = CACurrentMediaTime();
    @try {
        NSString *path = nfb_logFilePath();
        [[NSData data] writeToFile:path atomically:NO];            // truncate previous file
        gNFBLogFile = [NSFileHandle fileHandleForWritingAtPath:path];
    } @catch (NSException *e) { gNFBLogFile = nil; }
    gNFBLogRecording = YES;
    NFBLogEvent(@"=== REC START ===");
}
NSString *NFBLogStopRecording(void) {
    if (gNFBLogRecording) {
        NFBLogEvent(@"=== FINAL DIAG START ===");
        NSString *diag = nfb_buildDiagnosticReport();
        for (NSString *line in [diag componentsSeparatedByString:@"\n"]) {
            if (line.length) NFBLogEvent(line);
        }
        NFBLogEvent(@"=== FINAL DIAG END ===");
        NFBLogEvent(@"=== REC STOP ===");
    }
    gNFBLogRecording = NO;
    @try { [gNFBLogFile closeFile]; } @catch (NSException *e) {}
    gNFBLogFile = nil;
    return gNFBLog.count ? [gNFBLog componentsJoinedByString:@"\n"] : nfb_loc(@"NFB_LOG_EMPTY", @"(no log)");
}
NSString *NFBLogSavedFileContents(void) {
    NSString *s = [NSString stringWithContentsOfFile:nfb_logFilePath() encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : nfb_loc(@"NFB_SAVED_LOG_EMPTY", @"(no saved log)");
}

#pragma mark - tap / long-press handler (reliable action sheets)

@interface NFBStreamHandler : NSObject
+ (instancetype)shared;
- (void)tap;
- (void)newTweetsTap;
- (void)revealAllColumnsTap;
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end

@implementation NFBStreamHandler
+ (instancetype)shared { static NFBStreamHandler *h; static dispatch_once_t t; dispatch_once(&t, ^{ h = [NFBStreamHandler new]; }); return h; }

- (UIViewController *)topVC {
    UIWindow *w = gStreamButton.window;
    if (!w) for (UIWindow *win in UIApplication.sharedApplication.windows) if (win.isKeyWindow) { w = win; break; }
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
- (void)present:(UIAlertController *)ac {
    UIViewController *top = [self topVC];
    if (!top) return;
    if (ac.popoverPresentationController) { ac.popoverPresentationController.sourceView = gStreamButton; ac.popoverPresentationController.sourceRect = gStreamButton.bounds; }
    [top presentViewController:ac animated:YES completion:nil];
}
- (void)tap {
    BOOL on = ![BHTManager autoStreamTimeline];
    nfb_setStreamEnabled(on);
    UIViewController *vc = gActiveItemsVC;
    if (vc) nfb_streamStart(vc);
    else {
        nfb_styleButton(on);
        nfb_updateGauge(on, on ? (NSTimeInterval)[BHTManager autoStreamInterval] : 0);
    }
}
- (void)newTweetsTap {
    if (gInlineColumnsEnabled) {
        nfb_revealAllColumnTops();
        return;
    }
    UIViewController *vc = gPendingNewTweetsVC ?: gActiveItemsVC;
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    if (!vc) return;
    // Explicit user tap = jump to the top NOW. The old path (nfb_revealTopAfterRefresh) bailed to
    // re-showing the pill when not already at top, so tapping it did nothing.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    nfb_scrollToTop(target, YES);
    nfb_updateStreamStateIconForVC(vc);
}
- (void)revealAllColumnsTap {
    nfb_revealAllColumnTops();
}
- (void)longPress:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan) [self showMain]; }

- (void)showMain {
    BOOL on = [BHTManager autoStreamTimeline];
    NSInteger iv = [BHTManager autoStreamInterval];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_STREAM_MENU_TITLE", @"Auto-refresh timeline (streaming)")
        message:[NSString stringWithFormat:nfb_loc(@"NFB_STREAM_MENU_STATUS", @"Status: %@ / interval: %lds"), on ? @"ON" : @"OFF", (long)iv]
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (NFBLogIsRecording()) {
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_STOP_AND_COPY", @"⏹ Stop log recording and copy") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ [self stopLogAndShow]; }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_START", @"⏺ Start log recording (clears the previous log)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ NFBLogStartRecording(); [self toast:nfb_loc(@"NFB_LOG_START_TOAST", @"Recording started. Reproduce the issue, then long-press again → \"Stop and copy\". If the app gets stuck, relaunch and use \"Copy saved log\".")]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_LOG_COPY_SAVED", @"📄 Copy saved log (no stop needed, survives a kill)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self copySavedLog]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_REFRESH_NOW", @"🔄 Refresh now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamTrigger(vc); }]];
    if (gInlineColumnsEnabled) {
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_COLUMNS_ALL_TOP", @"⬆︎ Scroll all columns to top") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_revealAllColumnTops(); }]];
        [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_COLUMNS_MANAGE", @"📐 Manage columns (reorder / show)…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showColumnsManage]; }]];
        BOOL logoHidden = ([NSUserDefaults.standardUserDefaults objectForKey:@"NFBHideColumnsLogoBar"] == nil) ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"NFBHideColumnsLogoBar"];
        [ac addAction:[UIAlertAction actionWithTitle:(logoHidden ? nfb_loc(@"NFB_LOGOBAR_SHOW", @"Show the top logo bar") : nfb_loc(@"NFB_LOGOBAR_HIDE", @"Hide the top logo bar")) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [NSUserDefaults.standardUserDefaults setBool:!logoHidden forKey:@"NFBHideColumnsLogoBar"];
            [NSUserDefaults.standardUserDefaults synchronize];
            if (logoHidden) nfb_restoreColumnsLogoBar();   // was hiding → user turned it OFF → show again now
            nfb_layoutActiveHomePaging();
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:(on ? nfb_loc(@"NFB_STREAM_OFF", @"Turn auto-refresh OFF") : nfb_loc(@"NFB_STREAM_ON", @"Turn auto-refresh ON")) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamEnabled(!on); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:(gInlineColumnsEnabled ? nfb_loc(@"NFB_COLUMNS_OFF", @"Turn columns mode OFF") : nfb_loc(@"NFB_COLUMNS_ON", @"Turn columns mode ON")) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        if (gInlineColumnsEnabled) NFBSetInlineColumnsEnabled(NO);
        else BHTPresentColumnsMode();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_INTERVAL_CHANGE", @"⏱ Change refresh interval…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showInterval]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_DIAG_SHOW", @"🔍 Diagnostics (copy & send)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showDiag]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"CANCEL_BUTTON_TITLE", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)toast:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self present:ac];
}
- (void)stopLogAndShow {
    NSString *log = NFBLogStopRecording();
    UIPasteboard.generalPasteboard.string = log;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_LOG_COPIED_TITLE", @"Recorded log (copied)") message:log preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_RECOPY", @"Copy again") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = log; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_CLOSE", @"Close") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)copySavedLog {
    NSString *log = NFBLogSavedFileContents();
    UIPasteboard.generalPasteboard.string = log;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_SAVED_LOG_COPIED_TITLE", @"Saved log (copied)") message:log preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_RECOPY", @"Copy again") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = log; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_CLOSE", @"Close") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showDiag {
    NSString *report = nfb_buildDiagnosticReport();
    NSMutableString *s = [report mutableCopy] ?: [NSMutableString string];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_DIAG_TITLE", @"Diagnostics") message:s preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_COPY", @"Copy") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = s; }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_CLOSE", @"Close") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showColumnsManage {
    UIViewController *top = [self topVC];
    if (!top) return;
    UIViewController *vc = nfb_makeColumnsSettingsViewController();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [top presentViewController:nav animated:YES completion:nil];
}
- (void)showColumnActionsForIdentity:(NSString *)ident name:(NSString *)name {
    NSArray<UIViewController *> *pages = nfb_eligibleColumnPagesAll();
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (UIViewController *p in pages) [order addObject:nfb_columnTimelineIdentity(p)];
    NSSet<NSString *> *hidden = nfb_columnsHiddenSet();
    BOOL isHidden = [hidden containsObject:ident];
    NSUInteger visibleCount = (pages.count > hidden.count) ? (pages.count - hidden.count) : pages.count;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_COLUMN_MOVE_LEFT", @"⬅︎ Move left") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_columnsMove(ident, -1, order); nfb_layoutActiveHomePaging(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"NFB_COLUMN_MOVE_RIGHT", @"➡︎ Move right") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_columnsMove(ident, +1, order); nfb_layoutActiveHomePaging(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:(isHidden ? nfb_loc(@"NFB_COLUMN_SHOW", @"Show this column") : nfb_loc(@"NFB_COLUMN_HIDE", @"Hide this column")) style:(isHidden ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive) handler:^(UIAlertAction *a){
        if (!isHidden && visibleCount <= 1) { [self toast:nfb_loc(@"NFB_COLUMN_LAST_WARN", @"The last visible column can't be hidden.")]; return; }
        nfb_columnsSetHidden(ident, !isHidden);
        nfb_layoutActiveHomePaging();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"CANCEL_BUTTON_TITLE", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showInterval {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nfb_loc(@"NFB_INTERVAL_TITLE", @"Refresh interval") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *n in @[@5, @10, @15, @20, @30, @60]) {
        NSInteger sec = n.integerValue;
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:nfb_loc(@"NFB_SECONDS_FMT", @"%lds"), (long)sec] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamInterval(sec); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:nfb_loc(@"CANCEL_BUTTON_TITLE", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
@end

#pragma mark - columns drag settings screen

@interface NFBColumnsSettingsViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@end

@implementation NFBColumnsSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) self.title = nfb_loc(@"NFB_COLUMNS_MANAGE_TITLE", @"Manage columns");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:nfb_loc(@"NFB_RESET", @"Reset") style:UIBarButtonItemStylePlain target:self action:@selector(resetColumns)];
    self.tableView.allowsSelectionDuringEditing = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;
    [self reloadEntries];
    [self setEditing:YES animated:NO];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)resetColumns {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NFBColumnsOrderV1"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NFBColumnsHiddenV1"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NFBColumnsEnabledTabsV1"];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self reloadEntries];
    [self.tableView reloadData];
    nfb_layoutActiveHomePaging();
}

- (void)reloadEntries {
    self.entries = [[nfb_allColumnEntriesForManagement() mutableCopy] ?: [NSMutableArray array] mutableCopy];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (NSInteger)visibleEntryCount {
    NSInteger count = 0;
    for (NSDictionary *entry in self.entries) {
        if (!nfb_columnEntryIsHidden(entry)) count++;
    }
    return count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"NFBColumnsSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *identity = nfb_columnEntryIdentity(entry);
    BOOL hidden = nfb_columnEntryIsHidden(entry);
    cell.textLabel.text = nfb_columnEntryTitle(entry);
    cell.detailTextLabel.text = [entry[@"kind"] isEqualToString:@"tab"] ? nfb_loc(@"NFB_KIND_APP_TAB", @"App tab") : nfb_loc(@"NFB_KIND_TIMELINE", @"Timeline");
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsReorderControl = YES;
    cell.shouldIndentWhileEditing = NO;
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.on = !hidden;
    sw.accessibilityIdentifier = identity;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.editingAccessoryView = sw;
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSString *identity = sender.accessibilityIdentifier;
    NSDictionary *target = nil;
    for (NSDictionary *entry in self.entries) {
        if ([nfb_columnEntryIdentity(entry) isEqualToString:identity]) { target = entry; break; }
    }
    if (!target) return;
    BOOL willHide = !sender.on;
    if (willHide && [self visibleEntryCount] <= 1) {
        sender.on = YES;
        return;
    }
    nfb_columnEntrySetHidden(target, willHide);
    nfb_layoutActiveHomePaging();
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    NSDictionary *entry = self.entries[(NSUInteger)sourceIndexPath.row];
    [self.entries removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [self.entries insertObject:entry atIndex:(NSUInteger)destinationIndexPath.row];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *e in self.entries) {
        NSString *identity = nfb_columnEntryIdentity(e);
        if (identity.length) [order addObject:identity];
    }
    nfb_columnsSetOrder(order);
    nfb_layoutActiveHomePaging();
}

@end

static UIViewController *nfb_makeColumnsSettingsViewController(void) {
    return [[NFBColumnsSettingsViewController alloc] init];
}

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
    anim.fromValue = @1.0; anim.toValue = @0.0; anim.duration = interval;
    anim.repeatCount = HUGE_VALF; anim.removedOnCompletion = NO; anim.fillMode = kCAFillModeForwards;
    [g addAnimation:anim forKey:@"deplete"];
}

static BOOL nfb_streamCanRunForTarget(UIViewController *target) {
    if (![BHTManager autoStreamTimeline]) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIViewController *searchTarget = nfb_visibleSearchAutomationController();
    if (searchTarget) {
        UIScrollView *sv = nfb_mainScrollViewOf(searchTarget);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return NO;
        return nfb_visibleTimelineAtTop(searchTarget) || nfb_canRevealRefreshStartedAtTop(searchTarget);
    }
    if (!nfb_homeTabSelectedOrUnknown()) return NO;
    if (gInlineColumnsEnabled) {
        for (UIViewController *page in nfb_currentColumnRefreshControllers()) {
            if (![page isViewLoaded] || page.view.window == nil) continue;
            UIScrollView *sv = nfb_mainScrollViewOf(page);
            if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) continue;
            if (nfb_isTimelineAtTop(page)) return YES;
        }
        return NO;
    }
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
    BOOL globalOn = [BHTManager autoStreamTimeline];
    BOOL active = nfb_streamCanRunForTarget(target);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    NSString *name = active ? @"bolt.circle.fill" : (globalOn ? @"pause.circle.fill" : @"power.circle");
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!image) image = [UIImage systemImageNamed:(active ? @"checkmark.circle.fill" : @"xmark.circle") withConfiguration:cfg];
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
        gStreamStateIcon.accessibilityElementsHidden = NO;
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
    BOOL on = [BHTManager autoStreamTimeline];
    nfb_styleButton(on);
    nfb_updateGauge(on, (NSTimeInterval)[BHTManager autoStreamInterval]);
    NFBUpdateStreamButtonVisibility();
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}
static void nfb_removeButton(void) {
    if (gStreamButton) { [gStreamButton.gauge removeAnimationForKey:@"deplete"]; [gStreamButton removeFromSuperview]; }
    if (gStreamStateIcon) [gStreamStateIcon removeFromSuperview];
    nfb_hideNewTweetsPill();
    gPendingNewTweetsVC = nil;
}

void NFBUpdateStreamButtonVisibility(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBUpdateStreamButtonVisibility(); });
        return;
    }
    NSString *page = nfb_currentSelectedTabPage();
    BOOL visible = nfb_homeTabSelectedOrUnknown() || nfb_searchOrExplorePageSelected();
    static NSNumber *lastVisible = nil;
    static NSString *lastPage = nil;
    if (gNFBLogRecording && (!lastVisible || lastVisible.boolValue != visible || ![(lastPage ?: @"") isEqualToString:(page ?: @"")])) {
        NFBLogEvent([NSString stringWithFormat:@"streamButton visible=%d page=%@ inline=%d activeWin=%d",
            visible ? 1 : 0, page ?: @"(nil)", gInlineColumnsEnabled ? 1 : 0,
            (gActiveItemsVC && [gActiveItemsVC isViewLoaded] && gActiveItemsVC.view.window) ? 1 : 0]);
    }
    lastVisible = @(visible);
    lastPage = [page copy];
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
    CGFloat dy = y - last; last = y;
    CGFloat target = gStreamButton.alpha;
    if (atTop || dy < -2.0) target = 1.0;          // at top or scrolling up
    else if (dy > 2.0) target = 0.0;               // scrolling down
    // In columns mode the button is the single global control for all columns; never fade/disable
    // it on a per-column scroll, otherwise it becomes un-long-pressable (settings menu unreachable).
    if (gInlineColumnsEnabled) target = 1.0;
    if (fabs(gStreamButton.alpha - target) < 0.01) return;
    [UIView animateWithDuration:0.2 animations:^{
        gStreamButton.alpha = target;
        if (gStreamStateIcon) gStreamStateIcon.alpha = target;
    } completion:^(BOOL f){ gStreamButton.userInteractionEnabled = (target > 0.5); }];
}

static NSString *nfb_scribePageOfTabView(UIView *view) {
    NSString *page = nil;
    @try {
        id value = [view valueForKey:@"scribePage"];
        if ([value isKindOfClass:NSString.class]) page = value;
    } @catch (NSException *e) {
        page = nil;
    }
    return page;
}

static BOOL nfb_tabViewSelected(UIView *view, BOOL *known) {
    if (known) *known = NO;
    @try {
        id value = [view valueForKey:@"selected"];
        if ([value respondsToSelector:@selector(boolValue)]) {
            if (known) *known = YES;
            return [value boolValue];
        }
    } @catch (NSException *e) {
    }
    return NO;
}

static NSString *nfb_selectedTabPageInView(UIView *view, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 12) return nil;
    Class tabClass = NSClassFromString(@"T1TabView");
    BOOL looksLikeTab = (tabClass && [view isKindOfClass:tabClass]) || [NSStringFromClass(view.class) isEqualToString:@"T1TabView"];
    if (looksLikeTab) {
        BOOL known = NO;
        BOOL selected = nfb_tabViewSelected(view, &known);
        NSString *page = nfb_scribePageOfTabView(view);
        if (known && selected && page.length) return page;
    }
    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        NSString *page = nfb_selectedTabPageInView(subview, depth + 1);
        if (page.length) return page;
    }
    return nil;
}

static NSString *nfb_currentSelectedTabPage(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSString *page = nfb_selectedTabPageInView(window, 0);
        if (page.length) return page;
    }
    return nil;
}

static BOOL nfb_homeTabSelectedOrUnknown(void) {
    NSString *page = nfb_currentSelectedTabPage();
    if (page.length) {
        if ([page isEqualToString:@"home"]) return YES;
        if (gInlineColumnsEnabled && [page isEqualToString:@"communities"]) return YES;
        return NO;
    }
    if (gActiveItemsVC && [gActiveItemsVC isViewLoaded] && gActiveItemsVC.view.window) return YES;
    return NO;
}

#pragma mark - streaming timer

static char kNFBStreamTimerKey;

static NSTimeInterval gLastStreamFire = 0;   // dedup across the two home-VC timers

static BOOL nfb_streamShouldFire(UIViewController *vc) {
    if (![BHTManager autoStreamTimeline]) return NO;
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
        NFBLogEvent([NSString stringWithFormat:@"streamShould searchLatest[b63] vc=%@",
            NSStringFromClass(searchTarget.class)]);
        nfb_updateStreamStateIconForVC(searchTarget);
        return YES;
    }
    if (!nfb_homeTabSelectedOrUnknown()) return NO;
    if (gInlineColumnsEnabled) {
        BOOL hasColumns = [nfb_currentColumnRefreshControllers() count] > 0;
        nfb_updateStreamStateIconForVC(vc);
        NFBLogEvent([NSString stringWithFormat:@"streamShould columns has=%d vc=%@ active=%@",
            hasColumns ? 1 : 0,
            vc ? NSStringFromClass(vc.class) : @"nil",
            gActiveItemsVC ? NSStringFromClass(gActiveItemsVC.class) : @"nil"]);
        return hasColumns;
    }
    // Gate on whatever timeline is actually on screen (For You / Following / pinned list),
    // not on the timer's own home items VC — that's how pinned lists get refreshed.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    if (![target isViewLoaded] || target.view.window == nil) return NO;
    if (nfb_isRecommendedHomeTimeline(target)) return NO;       // For You -> never auto-refresh
    UIScrollView *sv = nfb_mainScrollViewOf(target);
    if (sv) {
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) {
            nfb_updateStreamStateIconForVC(target);
            return NO;
        }
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
    NSTimer *t = objc_getAssociatedObject(vc, &kNFBStreamTimerKey);
    [t invalidate];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void nfb_streamStart(UIViewController *vc) {
    nfb_streamStop(vc);
    BOOL on = [BHTManager autoStreamTimeline];
    NSTimeInterval interval = (NSTimeInterval)[BHTManager autoStreamInterval];
    nfb_styleButton(on);
    nfb_updateGauge(on, interval);
    if (!on) return;
    __weak UIViewController *wvc = vc;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        UIViewController *s = wvc;
        if (!s) { [t invalidate]; return; }
        if (![BHTManager autoStreamTimeline]) { nfb_streamStop(s); nfb_styleButton(NO); nfb_updateGauge(NO, 0); nfb_updateStreamStateIconForVC(s); return; }
        if (nfb_streamShouldFire(s)) {
            // Both the For-You and Following home VCs run a timer; dedup so the visible
            // timeline isn't refreshed twice per interval.
            NSTimeInterval now = CACurrentMediaTime();
            if (now - gLastStreamFire >= interval * 0.6) {
                gLastStreamFire = now;
                nfb_streamTrigger(s);
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *nfb_identifierForTimelineVariantArgument(id variant) {
    uintptr_t raw = (uintptr_t)variant;
    if (raw < 8) {
        if (raw == 0) return @"home";
        if (raw == 1) return @"latest";
        if (raw == 2) return @"creatorSubscriptions";
        return nil;
    }
    NSString *value = nil;
    @try {
        if ([variant isKindOfClass:NSString.class]) {
            value = (NSString *)variant;
        } else if ([variant respondsToSelector:@selector(identifier)]) {
            id identifier = ((id (*)(id, SEL))objc_msgSend)(variant, @selector(identifier));
            if ([identifier isKindOfClass:NSString.class]) value = identifier;
        }
        if (!value.length) {
            NSString *description = [variant description];
            if ([description isKindOfClass:NSString.class]) value = description;
        }
    } @catch (NSException *e) {
        value = nil;
    }
    if (!value.length) return nil;
    if (nfb_homeTabIdentifierLooksRecommended(value) || nfb_homeTabIdentifierLooksChronological(value)) return value;
    return nil;
}

static void nfb_persistHomeTimelineTabIdentifier(NSString *identifier) {
    if (!identifier.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:identifier forKey:@"THFHomeTimelineContainerViewController.lastSelectedTimelineTabIdentifier"];
    [defaults setObject:identifier forKey:@"nfb_lastSelectedTimelineTabIdentifier"];
    [defaults synchronize];
}

static void nfb_syncHomeTimelineTabIdentifierFromController(UIViewController *vc) {
    NSString *identifier = nfb_homeTimelineTabIdentifierFromObject(vc);
    if (identifier.length) nfb_persistHomeTimelineTabIdentifier(identifier);
}

#pragma mark - inline columns

// kNFBInlineColumnsAppliedKey is declared earlier (above nfb_scrollViewScore) so the scroll-scoring
// helpers can reference it; do not redeclare it here.
static char kNFBInlineColumnsPagingKey;
static char kNFBInlineColumnsBounceHKey;
static char kNFBInlineColumnsIndicatorKey;
static char kNFBInlineColumnsClipsKey;
static char kNFBInlineColumnsDirectionalLockKey;
static char kNFBInlineColumnsContentSizeKey;
static char kNFBInlineColumnsTargetContentWidthKey;
static char kNFBInlineColumnsChromeSavedKey;
static char kNFBInlineColumnsChromeHiddenKey;
static char kNFBInlineColumnsChromeAlphaKey;
static char kNFBInlineColumnsChromeInteractionKey;
static char kNFBInlineColumnsChromeFrameKey;
static char kNFBInlineColumnsChromeBoundsKey;
static char kNFBInlineColumnsChromeClipsKey;
static char kNFBInlineColumnsChromeConstraintsKey;
static char kNFBInlineColumnsChromeCollapsedKey;
static char kNFBInlineColumnsChromeGesturesKey;
static char kNFBColumnsOriginalSuperviewKey;
static char kNFBColumnsOriginalFrameKey;
static char kNFBColumnsOriginalAutoresizingKey;
static char kNFBColumnsOriginalHiddenKey;
static char kNFBColumnsOriginalAlphaKey;
static char kNFBColumnsOriginalClipsKey;
static char kNFBColumnsEdgeGestureSavedKey;
static char kNFBColumnsEdgeGestureEnabledKey;
static char kNFBColumnsSnapScheduledKey;
static char kNFBColumnsRefreshScheduledKey;
static UIView *gColumnsOverlayView = nil;
static UIScrollView *gColumnsOverlayScrollView = nil;
static UIButton *gColumnsAllTopButton = nil;
static NSArray<UIViewController *> *gColumnsOverlayPages = nil;
static BOOL gInlineColumnsNeedsInitialOffsetReset = NO;
// iPad only: the trends/search sidebar (T1ExtendedContentNavigationController) lives in the
// app-split secondary pane and only appears at full width. We transplant ITS view into the
// horizontal column scroll as a far-right "search column" (same 340pt width). Containment stays
// with the split (a nav controller pushes internally regardless of where its view lives), so we
// only move the view and restore it when columns mode turns off. Weak: the split owns it.
static __weak UIView *gNFBColumnsSearchColumnView = nil;
static __weak UIViewController *gNFBColumnsSearchColumnController = nil;
// iPad search column preferred content = the segmented Explore tab
// (T1TwitterSwift.GuideContainerViewController: キーワード検索 + おすすめ/トレンド/ニュース/スポーツ).
// Fresh alloc/init crashes (needs DI), so we BORROW it from Twitter's own tab factory
// (TFNTabbedViewController.dataSource -tabbedViewController:viewControllerAtIndex:), which builds a
// fully DI'd instance. We layer it over the trends column (which already empties+hides the iPad
// secondary pane and is the automatic fallback if the borrow is unavailable). Strong: we own the
// fresh instance. See [[neofreebird-liquidglass-and-open-bugs]].
static UIViewController *gNFBColumnsGuideHost = nil;             // fresh DI'd guide nav we own
static __weak UIViewController *gNFBColumnsGuideContentVC = nil; // the GuideContainerViewController inside it
static BOOL gNFBColumnsGuideBorrowFailed = NO;
static BOOL gNFBColumnsGuideContentReady = NO;  // latched once the borrowed guide loads content (Codex guard: only surface it after content-load success; until then the trends fallback stays on top)
static NSString *gNFBGuideBorrowReason = @"(not attempted)";  // last borrow outcome — surfaced in FINAL DIAG so it's visible even when the (one-time) borrow ran before recording started
static NSMutableDictionary<NSString *, UIViewController *> *gNFBColumnsAppTabControllers = nil; // strong: factory-built tab columns we own
static NSMutableSet<NSString *> *gNFBColumnsAppTabFailed = nil;
static NSMutableDictionary<NSString *, NSString *> *gNFBColumnsAppTabReasons = nil;
static char kNFBColumnsAppTabColumnKey;
static char kNFBColumnsColumnKey;
static char kNFBColumnsColumnIdentityKey;
static char kNFBColumnsColumnIndexKey;
static char kNFBColumnsColumnOwnerKey;
static char kNFBColumnsLocalDetailKey;
static char kNFBColumnsDetailCloseTargetKey;
static __weak UIView *gNFBLastTouchedColumnView = nil;
static NSString *gNFBLastTouchedColumnKey = nil;
static NSUInteger gNFBLastTouchedColumnIndex = NSNotFound;
static NSTimeInterval gNFBLastTouchedColumnAt = 0.0;
static NSMutableDictionary<NSString *, UINavigationController *> *gNFBColumnsDetailNavControllers = nil;
// Issue B (iPad): while columns are active we REMOVE the extended-content rail (the right trends/
// search pane) via the app-split's own -private_removeExtendedContentViewController, so the split
// re-lays-out the primary content (our columns) to the full width — instead of hiding it + manually
// resizing (which froze before). Restored on columns-off. See [[neofreebird-liquidglass-and-open-bugs]].
static BOOL gNFBExtendedContentRemoved = NO;        // we've decided about removal (gates trends + scheduling); does NOT mean private_remove ran
static BOOL gNFBExtendedContentActuallyRemoved = NO; // private_removeExtendedContentViewController actually ran → ONLY then may we call add (Codex: avoid unbalanced add)
static UIViewController *gNFBExtRemovedSplit = nil;  // strong: the split we removed the rail from, kept alive until restore so the rail is never abandoned (Codex). Cleared (released) on restore. The app-split is long-lived so this is plain ownership, not a cycle.
static BOOL gNFBExtRemoveScheduled = NO;   // a one-shot deferred remove is queued (Codex: don't remove during the layout pass)
// b36 native-width path: drive T1AppSplitViewController's own split-mode calculation as
// "sidebar yes, extended content no" while columns are active. This avoids child/ancestor frame
// hacks entirely and lets Twitter reflow the primary host itself.
static BOOL gNFBNativeSplitTierSuppressed = NO;
static UIViewController *gNFBNativeSplitTierSplit = nil;
static BOOL gNFBNativeSplitTierApplying = NO; // b38: prevent reentrant split rebuild loops
static BOOL gNFBLayoutActiveHomePagingRunning = NO; // b44: avoid trait/layout reentry while UIKit is laying out
static BOOL gNFBLayoutActiveHomePagingScheduled = NO;
static BOOL gNFBColumnsSizeTransitioning = NO;
static NSTimeInterval gNFBColumnsSizeTransitionStamp = 0.0;
static BOOL gNFBColumnsLightLayoutScheduled = NO;
static NSArray<UIView *> *gNFBColumnsExpandedWidthViews = nil; // content ancestors widened after rail removal; restored on columns-off
// Oscillation latch for nfb_expandColumnsPrimaryWidthIfNeeded: the app-split's Auto Layout settles
// the home scroll view a few points off our computed full-width target, so each layout pass we'd
// "fix" the same ancestor, call setNeedsLayout, re-trigger -viewDidLayoutSubviews, and run again —
// a non-converging layout loop that pins the main thread until the watchdog kills the app (the
// freeze on opening iPad columns). Once the width gap stops shrinking we latch and stop re-applying
// until the geometry really changes (rotation / Stage Manager). Cleared on convergence + columns-off.
static CGFloat gNFBColumnsExpandLastGap = -1.0;        // |scrollWidth - target| from the previous pass
static int gNFBColumnsExpandStableGapCount = 0;        // consecutive passes the gap stayed ~constant
static BOOL gNFBColumnsExpandLatched = NO;             // stop re-applying (we are oscillating, not converging)
static CGFloat gNFBColumnsExpandLatchFrom = 0.0;       // scrollWidth when latched (unlatch if it changes)
static CGFloat gNFBColumnsExpandLatchTo = 0.0;         // target when latched (unlatch if it changes)
// User chose "remove the right pane + move search into a column": we also hide the app-split
// secondary host (the persistent iPad 587pt trends/search panel) so it is not left as an empty
// panel. Captured from the search view's ancestor chain before transplant; un-hidden on restore.
static __weak UIView *gNFBColumnsSecondaryHostView = nil;
static NSArray<UIView *> *gNFBColumnsSuppressedSplitViews = nil;
static BOOL gColumnsEdgeMenuStateKnown = NO;
static BOOL gColumnsEdgeMenuLastEnabled = YES;
static char kNFBColumnLoadKickedKey;
static char kNFBColumnsGuideAppearedKey;
static char kNFBColumnsEmptyReloadCountKey;
static char kNFBColumnScrollAdjustedKey;
static char kNFBColumnScrollFrameKey;
static char kNFBColumnScrollAutoresizingKey;
static char kNFBColumnScrollInsetKey;
static char kNFBColumnScrollIndicatorInsetKey;
static char kNFBColumnScrollAdjustmentBehaviorKey;
static CGFloat gColumnsHiddenBarHeight = 0.0;   // height of the hidden home segment bar, for gap-closing
static NSHashTable<UIView *> *gNFBInlineColumnsSavedChromeViews = nil;

static void nfb_trackSavedColumnsChromeView(UIView *view) {
    if (!view) return;
    if (!gNFBInlineColumnsSavedChromeViews) {
        gNFBInlineColumnsSavedChromeViews = [NSHashTable weakObjectsHashTable];
    }
    [gNFBInlineColumnsSavedChromeViews addObject:view];
}

static BOOL nfb_columnsShouldTreatGestureAsEdgeMenu(UIGestureRecognizer *gesture) {
    if (!gesture) return NO;
    NSString *cls = NSStringFromClass(gesture.class);
    NSString *delegateClass = gesture.delegate ? NSStringFromClass([gesture.delegate class]) : @"";
    // NEVER suppress the navigation interactive-pop (back-swipe) gestures: the user must be
    // able to swipe back from a pushed detail view while columns are active. These are the
    // parallax-transition pan and the screen-edge/pan driven by the nav transition. Suppressing
    // them (the old behaviour) left back-swipe dead whenever the columns rested away from x=0.
    if ([cls containsString:@"ParallaxTransitionPan"] ||
        [delegateClass containsString:@"NavigationControllerTransitionAnimator"] ||
        [delegateClass containsString:@"NavigationInteractiveTransition"]) {
        return NO;
    }
    // Suppress ONLY the app-split / side-menu pan (it competes with starting a horizontal
    // column drag from the left edge) and the cell flex-interaction swipe (accidental action
    // menu mid horizontal scroll).
    return [delegateClass containsString:@"T1AppSplitViewController"] ||
           [delegateClass containsString:@"AppSplitViewController"] ||
           [cls containsString:@"FlexInteractionPan"] ||
           [delegateClass containsString:@"FlexInteraction"];
}

static NSInteger nfb_setColumnsEdgeMenuGesturesInView(UIView *view, BOOL enabled, int depth) {
    if (!view || depth > 14) return 0;
    NSInteger count = 0;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (!nfb_columnsShouldTreatGestureAsEdgeMenu(gesture)) continue;
        if (!objc_getAssociatedObject(gesture, &kNFBColumnsEdgeGestureSavedKey)) {
            objc_setAssociatedObject(gesture, &kNFBColumnsEdgeGestureSavedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(gesture, &kNFBColumnsEdgeGestureEnabledKey, @(gesture.enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSNumber *wasEnabled = objc_getAssociatedObject(gesture, &kNFBColumnsEdgeGestureEnabledKey);
        gesture.enabled = enabled ? (wasEnabled ? wasEnabled.boolValue : YES) : NO;
        count++;
    }
    for (UIView *subview in view.subviews) count += nfb_setColumnsEdgeMenuGesturesInView(subview, enabled, depth + 1);
    return count;
}

static NSInteger nfb_countColumnsEdgeMenuGesturesInView(UIView *view, int depth) {
    if (!view || depth > 14) return 0;
    NSInteger count = 0;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (nfb_columnsShouldTreatGestureAsEdgeMenu(gesture)) count++;
    }
    for (UIView *subview in view.subviews) count += nfb_countColumnsEdgeMenuGesturesInView(subview, depth + 1);
    return count;
}

static NSInteger nfb_countEnabledColumnsEdgeMenuGesturesInView(UIView *view, int depth) {
    if (!view || depth > 14) return 0;
    NSInteger count = 0;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (nfb_columnsShouldTreatGestureAsEdgeMenu(gesture) && gesture.enabled) count++;
    }
    for (UIView *subview in view.subviews) count += nfb_countEnabledColumnsEdgeMenuGesturesInView(subview, depth + 1);
    return count;
}

static NSInteger nfb_countColumnsEdgeMenuGestures(void) {
    NSInteger count = 0;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        count += nfb_countColumnsEdgeMenuGesturesInView(window, 0);
    }
    return count;
}

static NSInteger nfb_countEnabledColumnsEdgeMenuGestures(void) {
    NSInteger count = 0;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        count += nfb_countEnabledColumnsEdgeMenuGesturesInView(window, 0);
    }
    return count;
}

static NSInteger nfb_setColumnsEdgeMenuGesturesEnabled(BOOL enabled) {
    static NSTimeInterval lastSameStateScan = 0.0;
    static NSNumber *lastLoggedEnabled = nil;
    static NSInteger lastLoggedMatched = -1;
    static NSInteger lastLoggedEnabledCount = -1;
    NSTimeInterval now = CACurrentMediaTime();
    if (gColumnsEdgeMenuStateKnown && gColumnsEdgeMenuLastEnabled == enabled && now - lastSameStateScan < 0.25) return 0;
    gColumnsEdgeMenuStateKnown = YES;
    gColumnsEdgeMenuLastEnabled = enabled;
    lastSameStateScan = now;
    NSInteger count = 0;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        count += nfb_setColumnsEdgeMenuGesturesInView(window, enabled, 0);
    }
    if (gNFBLogRecording) {
        NSInteger enabledCount = nfb_countEnabledColumnsEdgeMenuGestures();
        if (!lastLoggedEnabled || lastLoggedEnabled.boolValue != enabled ||
            lastLoggedMatched != count || lastLoggedEnabledCount != enabledCount) {
            NFBLogEvent([NSString stringWithFormat:@"edgeMenuSet enabled=%d matched=%ld enabledNow=%ld",
                enabled ? 1 : 0, (long)count, (long)enabledCount]);
            lastLoggedEnabled = @(enabled);
            lastLoggedMatched = count;
            lastLoggedEnabledCount = enabledCount;
        }
    }
    return count;
}

static BOOL nfb_columnsShouldEnableEdgeMenuForScroll(UIScrollView *scrollView) {
    if (!gInlineColumnsEnabled) return YES;
    if (!scrollView) return NO;
    return scrollView.contentOffset.x <= 2.0;
}

static NSInteger nfb_updateColumnsEdgeMenuGesturesForScroll(UIScrollView *scrollView) {
    // In columns mode the app split/sidebar pan competes with horizontal column swipes. Keep it
    // disabled while the columns are scrolled away from x=0, but restore it at the left edge where
    // the user explicitly expects the side menu to work.
    return nfb_setColumnsEdgeMenuGesturesEnabled(nfb_columnsShouldEnableEdgeMenuForScroll(scrollView));
}

static BOOL nfb_isHomePagingController(UIViewController *vc) {
    return nfb_parentControllerNamed(vc, @"HomeTimelineContainer") != nil;
}

static BOOL nfb_inlineColumnsActiveForHomePaging(UIViewController *paging) {
    return gInlineColumnsEnabled && nfb_isHomePagingController(paging);
}

static BOOL nfb_viewContainsDescendant(UIView *root, UIView *descendant) {
    if (!root || !descendant) return NO;
    if (root == descendant) return YES;
    for (UIView *subview in root.subviews) {
        if (nfb_viewContainsDescendant(subview, descendant)) return YES;
    }
    return NO;
}

static BOOL nfb_constraintLooksLikeChromeHeight(NSLayoutConstraint *constraint, UIView *view) {
    if (!constraint || !view) return NO;
    BOOL firstHeight = constraint.firstItem == view && constraint.firstAttribute == NSLayoutAttributeHeight;
    BOOL secondHeight = constraint.secondItem == view && constraint.secondAttribute == NSLayoutAttributeHeight;
    if (!firstHeight && !secondHeight) return NO;
    CGFloat c = fabs(constraint.constant);
    return c > 0.5 && c <= 260.0;
}

static NSArray<NSLayoutConstraint *> *nfb_chromeHeightConstraintsForView(UIView *view) {
    if (!view) return @[];
    NSMutableArray<NSLayoutConstraint *> *matches = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (nfb_constraintLooksLikeChromeHeight(constraint, view)) [matches addObject:constraint];
    }
    for (NSLayoutConstraint *constraint in view.superview.constraints) {
        if (nfb_constraintLooksLikeChromeHeight(constraint, view)) [matches addObject:constraint];
    }
    return matches;
}

static void nfb_collapseColumnsChromeView(UIView *view) {
    if (!view || !gInlineColumnsEnabled) return;
    if (objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey)) {
        // Re-zero the originally-saved constraints AND any NEW height constraint Twitter
        // re-added on a data-driven reload (a fresh NSLayoutConstraint object not in our
        // saved set). Only re-zeroing the saved ones let that new 44pt constraint reassert
        // the height -> the intermittent "余白" band that survived earlier passes.
        NSMutableArray<NSDictionary *> *savedConstraints =
            [objc_getAssociatedObject(view, &kNFBInlineColumnsChromeConstraintsKey) mutableCopy] ?: [NSMutableArray array];
        for (NSDictionary *entry in savedConstraints) {
            NSLayoutConstraint *constraint = entry[@"constraint"];
            if (constraint) constraint.constant = 0.0;
        }
        for (NSLayoutConstraint *constraint in nfb_chromeHeightConstraintsForView(view)) {
            BOOL known = NO;
            for (NSDictionary *entry in savedConstraints) {
                if (entry[@"constraint"] == constraint) { known = YES; break; }
            }
            if (!known) {
                [savedConstraints addObject:@{@"constraint": constraint, @"constant": @(constraint.constant)}];
            }
            constraint.constant = 0.0;
        }
        objc_setAssociatedObject(view, &kNFBInlineColumnsChromeConstraintsKey, savedConstraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGRect frame = view.frame;
        CGRect bounds = view.bounds;
        if (frame.size.height > 0.5 && frame.size.height <= 300.0) {
            frame.size.height = 0.0;
            view.frame = frame;
        }
        if (bounds.size.height > 0.5 && bounds.size.height <= 300.0) {
            bounds.size.height = 0.0;
            view.bounds = bounds;
        }
        view.clipsToBounds = YES;
        return;
    }
    CGRect frame = view.frame;
    CGRect bounds = view.bounds;
    BOOL shortChrome = frame.size.height > 0.5 && frame.size.height <= 300.0 && frame.size.width >= 24.0;
    NSArray<NSLayoutConstraint *> *heightConstraints = nfb_chromeHeightConstraintsForView(view);
    if (!shortChrome && !heightConstraints.count) return;

    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nfb_trackSavedColumnsChromeView(view);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeBoundsKey, [NSValue valueWithCGRect:bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableArray<NSDictionary *> *savedConstraints = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in heightConstraints) {
        [savedConstraints addObject:@{@"constraint": constraint, @"constant": @(constraint.constant)}];
        constraint.constant = 0.0;
    }
    if (savedConstraints.count) {
        objc_setAssociatedObject(view, &kNFBInlineColumnsChromeConstraintsKey, savedConstraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    view.clipsToBounds = YES;
    if (shortChrome) {
        frame.size.height = 0.0;
        bounds.size.height = 0.0;
        view.frame = frame;
        view.bounds = bounds;
    }
}

static void nfb_restoreCollapsedColumnsChromeView(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey)) return;
    NSArray<NSDictionary *> *savedConstraints = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeConstraintsKey);
    for (NSDictionary *entry in savedConstraints) {
        NSLayoutConstraint *constraint = entry[@"constraint"];
        NSNumber *constant = entry[@"constant"];
        if (constraint && constant) constraint.constant = constant.doubleValue;
    }
    NSValue *frame = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeFrameKey);
    NSValue *bounds = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeBoundsKey);
    NSNumber *clips = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeClipsKey);
    if (frame) view.frame = frame.CGRectValue;
    if (bounds) view.bounds = bounds.CGRectValue;
    if (clips) view.clipsToBounds = clips.boolValue;
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeBoundsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeClipsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeConstraintsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_setColumnsChromeViewHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    if (hidden) {
        if (!gInlineColumnsEnabled) return;
        if (!objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) {
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            nfb_trackSavedColumnsChromeView(view);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSMutableArray<NSDictionary *> *gestures = [NSMutableArray array];
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                [gestures addObject:@{@"gesture": gesture, @"enabled": @(gesture.enabled)}];
            }
            if (gestures.count) {
                objc_setAssociatedObject(view, &kNFBInlineColumnsChromeGesturesKey, gestures, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            gesture.enabled = NO;
        }
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        nfb_collapseColumnsChromeView(view);
        return;
    }
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    if (!saved && !collapsed) return;
    nfb_restoreCollapsedColumnsChromeView(view);
    if (!saved) return;
    NSNumber *wasHidden = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey);
    NSNumber *alpha = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey);
    NSNumber *interactive = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey);
    NSArray<NSDictionary *> *gestures = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeGesturesKey);
    for (NSDictionary *entry in gestures) {
        UIGestureRecognizer *gesture = entry[@"gesture"];
        NSNumber *enabled = entry[@"enabled"];
        if (gesture && enabled) gesture.enabled = enabled.boolValue;
    }
    view.hidden = wasHidden ? wasHidden.boolValue : NO;
    view.alpha = alpha ? alpha.doubleValue : 1.0;
    view.userInteractionEnabled = interactive ? interactive.boolValue : YES;
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeGesturesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL nfb_columnsChromeCandidate(UIView *view, UIView *root) {
    if (!view || !root || view == root || !view.superview || view.hidden || view.alpha < 0.01) return NO;
    CGRect frame = [view.superview convertRect:view.frame toView:root];
    if (frame.size.width < 40.0 || frame.size.height < 4.0 || frame.size.height > 260.0) return NO;
    if (CGRectGetMinY(frame) > 280.0) return NO;
    NSString *cls = NSStringFromClass(view.class);
    NSString *text = nfb_textOfView(view);
    if ([text containsString:@"おすすめ"] || [text containsString:@"フォロー中"] ||
        [text.lowercaseString containsString:@"for you"] || [text.lowercaseString containsString:@"following"]) return YES;
    if (nfb_stringLooksSpacesTimeline(text) || nfb_stringLooksSpacesTimeline(cls)) return YES;
    if ([cls containsString:@"HomeSegment"] || [cls containsString:@"Segmented"] ||
        [cls containsString:@"LabelBar"] || [cls containsString:@"HorizontalLabel"] ||
        [cls containsString:@"SegmentedLabel"] || [cls containsString:@"FleetLine"]) return YES;
    return NO;
}

static BOOL nfb_columnsProtectedView(UIView *view) {
    if (!view) return NO;
    for (id candidate in @[gStreamButton ?: (id)[NSNull null],
                           gStreamStateIcon ?: (id)[NSNull null],
                           gNewTweetsPill ?: (id)[NSNull null],
                           gColumnsAllTopButton ?: (id)[NSNull null]]) {
        if (![candidate isKindOfClass:UIView.class]) continue;
        UIView *protectedView = (UIView *)candidate;
        if (view == protectedView || nfb_viewContainsDescendant(protectedView, view)) return YES;
    }
    return NO;
}

static BOOL nfb_columnsPagingSurface(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass(view.class);
    return [cls containsString:@"Paging"] || ([view isKindOfClass:UIScrollView.class] && view.bounds.size.height > 240.0);
}

static void nfb_setColumnsChromeDescendantsHidden(UIView *view, BOOL hidden, int depth) {
    if (!view || depth > 24) return;
    if (hidden && !gInlineColumnsEnabled) return;
    for (UIView *subview in view.subviews) {
        if (nfb_columnsProtectedView(subview) || nfb_columnsPagingSurface(subview)) continue;
        nfb_setColumnsChromeViewHidden(subview, hidden);
        nfb_setColumnsChromeDescendantsHidden(subview, hidden, depth + 1);
    }
}

static BOOL nfb_viewContainsColumnsPagingSurface(UIView *view, int depth) {
    if (!view || depth > 24) return NO;
    if (nfb_columnsPagingSurface(view)) return YES;
    for (UIView *subview in view.subviews) {
        if (nfb_viewContainsColumnsPagingSurface(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL nfb_viewContainsNavigationChrome(UIView *view, int depth) {
    if (!view || depth > 24) return NO;
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"NavigationBar"] || [cls containsString:@"UINavigationBar"] ||
        [cls containsString:@"_UIBarBackground"]) return YES;
    for (UIView *subview in view.subviews) {
        if (nfb_viewContainsNavigationChrome(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL nfb_viewContainsHomeTopChrome(UIView *view, int depth) {
    if (!view || depth > 24) return NO;
    NSString *cls = NSStringFromClass(view.class);
    NSString *text = nfb_textOfView(view);
    NSString *lower = text.lowercaseString;
    if ([text containsString:@"おすすめ"] || [text containsString:@"フォロー中"] ||
        [lower containsString:@"for you"] || [lower containsString:@"following"] ||
        nfb_stringLooksSpacesTimeline(text) || nfb_stringLooksSpacesTimeline(cls) ||
        [cls containsString:@"Segment"] || [cls containsString:@"LabelBar"] ||
        [cls containsString:@"HorizontalLabel"] || [cls containsString:@"FleetLine"]) return YES;
    for (UIView *subview in view.subviews) {
        if (nfb_viewContainsHomeTopChrome(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL nfb_columnsChromeAncestorRowCandidate(UIView *view, UIView *child, UIView *root) {
    if (!view || !child || !root || view == root) return NO;
    if (nfb_columnsProtectedView(view) || nfb_columnsPagingSurface(view)) return NO;
    if (nfb_viewContainsColumnsPagingSurface(view, 0)) return NO;
    if (nfb_viewContainsNavigationChrome(view, 0)) return NO;
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"NavigationBar"] || [cls containsString:@"UILayoutContainerView"] ||
        [cls containsString:@"TabBar"] || [cls containsString:@"TableView"] ||
        [cls containsString:@"CollectionView"]) return NO;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    CGRect childFrame = child.superview ? [child.superview convertRect:child.frame toView:root] : child.frame;
    if (CGRectGetMinY(frame) > 260.0) return NO;
    if (frame.size.width < MIN(root.bounds.size.width * 0.45, 180.0)) return NO;
    if (frame.size.height < 1.0 || frame.size.height > 180.0) return NO;
    if (fabs(CGRectGetMinY(frame) - CGRectGetMinY(childFrame)) > 10.0) return NO;
    BOOL knownChromeChild = nfb_viewContainsHomeTopChrome(child, 0) || nfb_columnsChromeCandidate(child, root);
    BOOL genericRow = [cls containsString:@"StackView"] ||
        [cls containsString:@"LabelBar"] ||
        [cls containsString:@"HorizontalLabel"] ||
        [cls containsString:@"Segment"] ||
        (knownChromeChild && ([cls isEqualToString:@"UIView"] || [cls containsString:@"CustomHitTest"]));
    return genericRow;
}

static void nfb_collapseColumnsChromeAncestorsForView(UIView *view, UIView *root) {
    if (!view || !root || !gInlineColumnsEnabled) return;
    UIView *child = view;
    UIView *current = view.superview;
    for (NSInteger depth = 0; current && depth < 4; depth++, child = current, current = current.superview) {
        if (!nfb_columnsChromeAncestorRowCandidate(current, child, root)) break;
        CGRect frame = current.superview ? [current.superview convertRect:current.frame toView:root] : current.frame;
        if (gColumnsHiddenBarHeight < 1.0 && frame.size.height > 1.0) {
            gColumnsHiddenBarHeight = frame.size.height;
        }
        if (gNFBLogRecording && !objc_getAssociatedObject(current, &kNFBInlineColumnsChromeSavedKey)) {
            NFBLogEvent([NSString stringWithFormat:@"columnsChromeHide ancestor class=%@ f=(%.0f,%.0f,%.0f,%.0f) child=%@",
                NSStringFromClass(current.class), frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                child ? NSStringFromClass(child.class) : @"nil"]);
        }
        nfb_setColumnsChromeViewHidden(current, YES);
        nfb_setColumnsChromeDescendantsHidden(current, YES, 0);
    }
}

static BOOL nfb_hideColumnsChromeInView(UIView *view, UIView *pagingView, UIView *root, int depth) {
    if (!view || !root || depth > 24) return NO;
    if (!gInlineColumnsEnabled) return NO;
    if (nfb_columnsProtectedView(view)) return NO;
    BOOL containsPaging = nfb_viewContainsDescendant(view, pagingView);
    BOOL pagingSurface = nfb_columnsPagingSurface(view);
    BOOL containsPagingSurface = nfb_viewContainsColumnsPagingSurface(view, 0);
    if (pagingSurface) return NO;
    BOOL did = NO;
    if (view != pagingView && !containsPaging && !pagingSurface && !containsPagingSurface && nfb_columnsChromeCandidate(view, root)) {
        if (gNFBLogRecording && !objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) {
            CGRect f = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
            NSString *text = nfb_diagShortString(nfb_textOfView(view), 60);
            NFBLogEvent([NSString stringWithFormat:@"columnsChromeHide direct class=%@ f=(%.0f,%.0f,%.0f,%.0f) text=%@",
                NSStringFromClass(view.class), f.origin.x, f.origin.y, f.size.width, f.size.height, text ?: @"-"]);
        }
        nfb_setColumnsChromeViewHidden(view, YES);
        nfb_setColumnsChromeDescendantsHidden(view, YES, 0);
        nfb_collapseColumnsChromeAncestorsForView(view, root);
        did = YES;
    }
    for (UIView *subview in view.subviews) {
        did = nfb_hideColumnsChromeInView(subview, pagingView, root, depth + 1) || did;
    }
    return did;
}

static void nfb_restoreColumnsChromeInView(UIView *view, int depth) {
    if (!view || depth > 24) return;
    nfb_setColumnsChromeViewHidden(view, NO);
    for (UIView *subview in view.subviews) {
        nfb_restoreColumnsChromeInView(subview, depth + 1);
    }
}

static void nfb_restoreAllSavedColumnsChrome(void) {
    NSArray<UIView *> *savedViews = [gNFBInlineColumnsSavedChromeViews allObjects];
    for (UIView *view in savedViews) {
        nfb_setColumnsChromeViewHidden(view, NO);
    }
    [gNFBInlineColumnsSavedChromeViews removeAllObjects];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window) continue;
        nfb_restoreColumnsChromeInView(window, 0);
    }
}

static void nfb_restoreAllSavedColumnsChromeSoon(NSString *reason) {
    nfb_restoreAllSavedColumnsChrome();
    if (gNFBLogRecording) {
        NFBLogEvent([NSString stringWithFormat:@"columnsChromeRestore %@", reason ?: @"now"]);
    }
    NSArray<NSNumber *> *delays = @[@0.15, @0.45, @1.00];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gInlineColumnsEnabled) return;
            nfb_restoreAllSavedColumnsChrome();
            if (gNFBLogRecording) {
                NFBLogEvent([NSString stringWithFormat:@"columnsChromeRestore %@+%.2f", reason ?: @"deferred", delay.doubleValue]);
            }
        });
    }
}

// nfb_textOfView reads only a view's OWN text; the home segment bar is a container whose tab
// labels (おすすめ/フォロー中/list names) are CHILD UILabels, so it never matched and never hid.
// Collect descendant text so the whole bar can be recognised by its labels.
static void nfb_appendDescendantText(UIView *view, NSMutableString *out, int depth) {
    if (!view || view.hidden || view.alpha < 0.01 || depth > 6) return;
    NSString *t = nfb_textOfView(view);
    if (t.length) { [out appendString:t]; [out appendString:@"\n"]; }
    for (UIView *sub in view.subviews) nfb_appendDescendantText(sub, out, depth + 1);
}

// A top, full-width, short horizontal strip whose descendants include 2+ home tab labels = the
// おすすめ/フォロー中/list segment bar, whatever its private class is. The height cap stops us from
// matching a tall ancestor that merely contains the bar (so we never hide the timeline body).
static BOOL nfb_viewLooksLikeHomeSegmentBar(UIView *view, UIView *root) {
    if (!view || !root || view == root) return NO;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (CGRectGetMinY(frame) > 240.0) return NO;
    if (frame.size.height < 20.0 || frame.size.height > 140.0) return NO;
    CGFloat minWidth = MIN(root.bounds.size.width * 0.45, 320.0);
    if (frame.size.width < minWidth) return NO;
    NSMutableString *txt = [NSMutableString string];
    nfb_appendDescendantText(view, txt, 0);
    NSString *lower = txt.lowercaseString;
    NSInteger hits = 0;
    if ([txt containsString:@"おすすめ"]) hits++;
    if ([txt containsString:@"フォロー中"]) hits++;
    if ([lower containsString:@"for you"]) hits++;
    if ([lower containsString:@"following"]) hits++;
    return hits >= 2;
}

static BOOL nfb_viewLooksLikeSpacesChrome(UIView *view, UIView *root) {
    if (!view || !root || view == root || view.hidden || view.alpha < 0.01 || nfb_columnsProtectedView(view)) return NO;
    if (nfb_viewContainsColumnsPagingSurface(view, 0)) return NO;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (frame.size.width < 80.0 || frame.size.height < 8.0 || frame.size.height > 260.0) return NO;
    NSString *cls = NSStringFromClass(view.class);
    NSMutableString *txt = [NSMutableString string];
    nfb_appendDescendantText(view, txt, 0);
    return nfb_stringLooksSpacesTimeline(cls) || nfb_stringLooksSpacesTimeline(txt);
}

static BOOL nfb_globalTopColumnsChromeCandidate(UIView *view, UIView *root) {
    if (!view || !root || view == root || view.hidden || view.alpha < 0.01 || nfb_columnsProtectedView(view)) return NO;
    if (nfb_columnsPagingSurface(view)) return NO;
    if (nfb_viewLooksLikeSpacesChrome(view, root)) return YES;
    // Match the bar by its labels first (covers the nav-bar-hosted bar with a generic class).
    if (!nfb_viewContainsColumnsPagingSurface(view, 0) && nfb_viewLooksLikeHomeSegmentBar(view, root)) return YES;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    NSString *cls = NSStringFromClass(view.class);
    BOOL containsTopChrome = nfb_viewContainsHomeTopChrome(view, 0);
    if (containsTopChrome && !nfb_viewContainsColumnsPagingSurface(view, 0) &&
        !nfb_viewContainsNavigationChrome(view, 0) &&
        CGRectGetMinY(frame) <= 140.0 && frame.size.width >= MIN(root.bounds.size.width * 0.45, 320.0) &&
        frame.size.height >= 1.0 && frame.size.height <= 300.0) {
        return YES;
    }
    if (CGRectGetMinY(frame) > 240.0 || frame.size.width < 24.0 || frame.size.height < 4.0 || frame.size.height > 220.0) return NO;
    NSString *text = nfb_textOfView(view);
    NSString *lower = text.lowercaseString;
    if ([text containsString:@"おすすめ"] || [text containsString:@"フォロー中"] ||
        [lower containsString:@"for you"] || [lower containsString:@"following"]) return YES;
    if ([cls containsString:@"HomeSegment"] || [cls containsString:@"Segmented"] ||
        [cls containsString:@"LabelBar"] || [cls containsString:@"HorizontalLabel"] ||
        [cls containsString:@"SegmentedLabel"]) return YES;
    return NO;
}

static NSInteger nfb_setColumnsGlobalTopChromeHiddenInView(UIView *view, UIView *root, BOOL hidden, int depth) {
    if (!view || !root || depth > 24) return 0;
    if (hidden && !gInlineColumnsEnabled) return 0;
    if (hidden && nfb_columnsPagingSurface(view)) return 0;
    NSInteger count = 0;
    if (hidden && nfb_globalTopColumnsChromeCandidate(view, root)) {
        // Capture the bar height ONCE and lock it. Re-capturing each pass made it flip 44<->0
        // (44 when detected, 0 when not), so the column shift flickered and the content/gap jumped
        // mid-swipe. A stable value keeps every column pinned at the same offset.
        if (gColumnsHiddenBarHeight < 1.0 && nfb_viewLooksLikeHomeSegmentBar(view, root)) {
            CGRect bf = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
            if (bf.size.height > 1.0) gColumnsHiddenBarHeight = bf.size.height;
        }
        if (gNFBLogRecording && !objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) {
            CGRect f = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
            NSString *text = nfb_textOfView(view);
            if (text.length > 60) text = [[text substringToIndex:60] stringByAppendingString:@"..."];
            NFBLogEvent([NSString stringWithFormat:@"columnsChromeHide global class=%@ f=(%.0f,%.0f,%.0f,%.0f) text=%@",
                NSStringFromClass(view.class), f.origin.x, f.origin.y, f.size.width, f.size.height,
                text.length ? text : @"-"]);
        }
        nfb_setColumnsChromeViewHidden(view, YES);
        nfb_setColumnsChromeDescendantsHidden(view, YES, 0);
        nfb_collapseColumnsChromeAncestorsForView(view, root);
        count++;
    }
    if (!hidden && objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) {
        nfb_setColumnsChromeViewHidden(view, NO);
        count++;
    }
    for (UIView *subview in view.subviews) {
        count += nfb_setColumnsGlobalTopChromeHiddenInView(subview, root, hidden, depth + 1);
    }
    return count;
}

static void nfb_setColumnsGlobalTopChromeHidden(BOOL hidden) {
    if (!hidden) {
        nfb_restoreAllSavedColumnsChrome();
        return;
    }
    if (!gInlineColumnsEnabled) {
        nfb_restoreAllSavedColumnsChrome();
        return;
    }
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    if (!nfb_isHomePagingController(paging)) return;
    UIViewController *segmented = paging ? nfb_parentControllerNamed(paging, @"Segmented") : nil;
    UIViewController *container = paging ? nfb_parentControllerNamed(paging, @"HomeTimelineContainer") : nil;
    if (segmented && [segmented isViewLoaded]) {
        nfb_setColumnsGlobalTopChromeHiddenInView(segmented.view, segmented.view, YES, 0);
    }
    if (container && [container isViewLoaded] && container != segmented) {
        nfb_setColumnsGlobalTopChromeHiddenInView(container.view, container.view, YES, 0);
    }
}

static void nfb_setColumnsSegmentedHiddenForPaging(UIViewController *paging, BOOL hidden) {
    if (!paging || ![paging isViewLoaded] || !nfb_isHomePagingController(paging)) return;
    if (hidden && !gInlineColumnsEnabled) return;
    UIViewController *segmented = nfb_parentControllerNamed(paging, @"Segmented");
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (hidden) {
        if (segmented && [segmented isViewLoaded]) nfb_hideColumnsChromeInView(segmented.view, paging.view, segmented.view, 0);
        if (container && [container isViewLoaded]) nfb_hideColumnsChromeInView(container.view, paging.view, container.view, 0);
        nfb_setColumnsGlobalTopChromeHidden(YES);
    } else {
        nfb_setColumnsGlobalTopChromeHidden(NO);
        if (segmented && [segmented isViewLoaded]) nfb_restoreColumnsChromeInView(segmented.view, 0);
        if (container && [container isViewLoaded]) nfb_restoreColumnsChromeInView(container.view, 0);
    }
}

static void nfb_addSegmentedChromeCandidate(NSMutableArray<UIView *> *views, NSHashTable<UIView *> *seen, UIView *view, UIView *root) {
    if (!view || !root || [seen containsObject:view] || nfb_columnsProtectedView(view)) return;
    [seen addObject:view];
    if (nfb_viewContainsColumnsPagingSurface(view, 0)) return;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    NSString *cls = NSStringFromClass(view.class);
    BOOL shortTop = CGRectGetMinY(frame) <= 280.0 && frame.size.width >= 40.0 && frame.size.height >= 4.0 && frame.size.height <= 260.0;
    BOOL classMatch = [cls containsString:@"Segment"] || [cls containsString:@"LabelBar"] ||
        [cls containsString:@"HorizontalLabel"] || [cls containsString:@"SegmentedLabel"] ||
        [cls containsString:@"FleetLine"];
    BOOL topChromeWrapper = view != root && nfb_viewContainsHomeTopChrome(view, 0) &&
        !nfb_viewContainsColumnsPagingSurface(view, 0) && !nfb_viewContainsNavigationChrome(view, 0) &&
        CGRectGetMinY(frame) <= 140.0 && frame.size.height <= 300.0 &&
        frame.size.width >= MIN(root.bounds.size.width * 0.45, 320.0);
    if (nfb_viewLooksLikeHomeSegmentBar(view, root) || nfb_viewLooksLikeSpacesChrome(view, root) ||
        topChromeWrapper ||
        (shortTop && classMatch)) {
        [views addObject:view];
    }
}

static void nfb_collectSegmentedChromeViewsFromObject(id object, NSMutableArray<UIView *> *views, NSHashTable<UIView *> *seen, UIView *root, int depth) {
    if (!object || !root || depth > 3) return;
    if ([object isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)object;
        nfb_addSegmentedChromeCandidate(views, seen, view, root);
        return;
    }
    if ([object isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)object;
        if ([vc isViewLoaded]) nfb_collectSegmentedChromeViewsFromObject(vc.view, views, seen, root, depth + 1);
    }
}

static void nfb_collectSegmentedChromeViewsInViewTree(UIView *view, NSMutableArray<UIView *> *views, NSHashTable<UIView *> *seen, UIView *root, int depth) {
    if (!view || !root || depth > 24) return;
    nfb_addSegmentedChromeCandidate(views, seen, view, root);
    if (nfb_columnsPagingSurface(view)) return;
    for (UIView *subview in view.subviews) {
        nfb_collectSegmentedChromeViewsInViewTree(subview, views, seen, root, depth + 1);
    }
}

static BOOL nfb_viewTreeContainsHomeSegmentBar(UIView *view, UIView *root, int depth) {
    if (!view || !root || depth > 18) return NO;
    if (nfb_viewLooksLikeHomeSegmentBar(view, root)) return YES;
    for (UIView *subview in view.subviews) {
        if (nfb_viewTreeContainsHomeSegmentBar(subview, root, depth + 1)) return YES;
    }
    return NO;
}

static BOOL nfb_segmentedControllerIsHomeTimeline(UIViewController *segmentedVC) {
    if (!segmentedVC || ![segmentedVC isViewLoaded]) return NO;
    return nfb_parentControllerNamed(segmentedVC, @"HomeTimelineContainer") != nil ||
        nfb_viewTreeContainsHomeSegmentBar(segmentedVC.view, segmentedVC.view, 0);
}

// Hide the Home segment bar (おすすめ / フォロー中 / pinned-list tabs) while columns mode is on by
// targeting TFNScrollingSegmentedViewController's own scrolling control directly, instead of the
// frame/text heuristics that were latching onto the wrong full-screen view. Runs from the
// segmented controller's layout pass, so it stays hidden even when the columns layout can't
// finish yet. Gated to the Home instance and reuses the save/restore used by the rest of chrome.
static void nfb_applyColumnsSegmentedControlHidden(UIViewController *segmentedVC) {
    if (!segmentedVC || ![segmentedVC isViewLoaded]) return;
    if (!gInlineColumnsEnabled) {
        nfb_restoreColumnsChromeInView(segmentedVC.view, 0);
        return;
    }
    if (!nfb_segmentedControllerIsHomeTimeline(segmentedVC)) return;
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    NSHashTable<UIView *> *seen = [NSHashTable weakObjectsHashTable];
    UIView *root = segmentedVC.view;
    for (NSString *key in @[@"_segmentedControl", @"segmentedControl", @"_scrollingSegmentedControl",
                            @"scrollingSegmentedControl", @"_labelBar", @"labelBar", @"_labelBarView",
                            @"labelBarView", @"_tabBar", @"tabBar", @"_tabsView", @"tabsView",
                            @"_headerView", @"headerView", @"_topBar", @"topBar", @"_titleBar",
                            @"titleBar", @"_titlesView", @"titlesView"]) {
        @try {
            id value = [segmentedVC valueForKey:key];
            nfb_collectSegmentedChromeViewsFromObject(value, bars, seen, root, 0);
        } @catch (NSException *e) {}
    }
    nfb_collectSegmentedChromeViewsInViewTree(root, bars, seen, root, 0);
    for (UIView *bar in bars) {
        nfb_setColumnsChromeViewHidden(bar, YES);
        nfb_setColumnsChromeDescendantsHidden(bar, YES, 0);
        nfb_collapseColumnsChromeAncestorsForView(bar, root);
    }
}

static void nfb_forceColumnsSegmentedControlHeightCollapsed(UIViewController *segmentedVC) {
    if (!gInlineColumnsEnabled || !segmentedVC || ![segmentedVC isViewLoaded]) return;
    if (!nfb_segmentedControllerIsHomeTimeline(segmentedVC)) return;
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    NSHashTable<UIView *> *seen = [NSHashTable weakObjectsHashTable];
    UIView *root = segmentedVC.view;
    for (NSString *key in @[@"_segmentedControl", @"segmentedControl", @"_scrollingSegmentedControl",
                            @"scrollingSegmentedControl", @"_labelBar", @"labelBar", @"_labelBarView",
                            @"labelBarView", @"_tabBar", @"tabBar", @"_tabsView", @"tabsView",
                            @"_headerView", @"headerView", @"_topBar", @"topBar", @"_titleBar",
                            @"titleBar", @"_titlesView", @"titlesView"]) {
        @try {
            id value = [segmentedVC valueForKey:key];
            nfb_collectSegmentedChromeViewsFromObject(value, bars, seen, root, 0);
        } @catch (NSException *e) {}
    }
    nfb_collectSegmentedChromeViewsInViewTree(root, bars, seen, root, 0);
    for (UIView *bar in bars) {
        nfb_collapseColumnsChromeView(bar);
        UIView *child = bar;
        UIView *current = bar.superview;
        for (NSInteger depth = 0; current && depth < 4; depth++, child = current, current = current.superview) {
            if (!nfb_columnsChromeAncestorRowCandidate(current, child, root)) break;
            nfb_collapseColumnsChromeView(current);
        }
    }
}

static UIView *nfb_columnsHostViewForPaging(UIViewController *paging) {
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (container && [container isViewLoaded]) return container.view;
    return [paging isViewLoaded] ? paging.view : nil;
}

static CGFloat nfb_columnsColumnWidth(CGFloat viewportWidth) {
    // Fixed 340pt columns; how many are visible varies with the content-area width (iPhone ~1,
    // iPad central column ~2-3) and the rest are reached by horizontal scroll. Never exceed the
    // viewport so a single column always fits on very narrow widths.
    return MIN(340.0, MAX(200.0, viewportWidth));
}

static CGFloat nfb_columnsContentWidth(CGFloat columnWidth, NSUInteger pageCount, CGFloat viewportWidth) {
    // b47: stop the horizontal scroll EXACTLY at the rightmost column's right edge. Earlier builds
    // added a trailing (viewportWidth - columnWidth) pad so any single column could be pulled to the
    // left edge — but that left a big black margin past the last column. Content width is now just
    // pageCount*columnWidth (floored at the viewport so columns that don't fill the screen don't
    // scroll). Recomputed every layout pass from the live bounds, so it tracks window resizes; the
    // snap/clamp helpers derive maxOffset from this, so they auto-respect the new right edge.
    CGFloat base = columnWidth * MAX((CGFloat)pageCount, 1.0);
    return MAX(base, viewportWidth);
}

static NSArray<NSNumber *> *nfb_columnsSnapCandidates(CGFloat columnWidth, CGFloat maxOffsetX) {
    if (columnWidth < 1.0 || maxOffsetX <= 0.0) return @[@0.0];
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    for (CGFloat candidate = 0.0; candidate < maxOffsetX; candidate += columnWidth) {
        [candidates addObject:@(candidate)];
    }
    NSNumber *last = candidates.lastObject;
    if (!last || last.doubleValue < maxOffsetX) {
        [candidates addObject:@(maxOffsetX)];
    }
    return candidates;
}

static CGFloat nfb_columnsSnappedOffsetX(CGFloat offsetX, CGFloat columnWidth, CGFloat maxOffsetX) {
    if (columnWidth < 1.0 || maxOffsetX <= 0.0) return 0.0;
    CGFloat clamped = MIN(MAX(offsetX, 0.0), maxOffsetX);
    NSArray<NSNumber *> *candidates = nfb_columnsSnapCandidates(columnWidth, maxOffsetX);
    CGFloat snapped = 0.0;
    CGFloat bestDistance = maxOffsetX + columnWidth + 1.0;
    for (NSNumber *candidateNumber in candidates) {
        CGFloat candidate = candidateNumber.doubleValue;
        CGFloat distance = fabs(clamped - candidate);
        if (distance < bestDistance) {
            bestDistance = distance;
            snapped = candidate;
        }
    }
    return MIN(MAX(snapped, 0.0), maxOffsetX);
}

static CGFloat nfb_columnsMaxOffsetXForScroll(UIScrollView *scrollView) {
    if (!scrollView) return 0.0;
    // contentSize.width can be a stale one-frame value: during an active horizontal
    // drag the contentSize write in nfb_layoutColumnsOverlayForPaging is intentionally
    // skipped, so reading it raw yields a too-small maxOffset and the last column
    // becomes unreachable (right-edge snap stops one column short). Floor the width at
    // the cached target column content width so the right edge / right-edge snap
    // candidate stay reachable regardless of when the contentSize write last landed.
    CGFloat contentWidth = scrollView.contentSize.width;
    NSNumber *targetWidth = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsTargetContentWidthKey);
    if (targetWidth) contentWidth = MAX(contentWidth, targetWidth.doubleValue);
    return MAX(0.0, contentWidth - scrollView.bounds.size.width);
}

static BOOL nfb_columnsHorizontalScrollIsMoving(UIScrollView *scrollView) {
    return scrollView && (scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating);
}

static BOOL nfb_columnsScrollIsActivePaging(UIScrollView *scrollView) {
    return gInlineColumnsEnabled && scrollView && objc_getAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey);
}

static CGFloat nfb_columnsDirectionalSnapOffsetX(CGFloat offsetX, CGFloat columnWidth, CGFloat maxOffsetX, BOOL rightward) {
    if (columnWidth < 1.0 || maxOffsetX <= 0.0) return 0.0;
    CGFloat clamped = MIN(MAX(offsetX, 0.0), maxOffsetX);
    NSArray<NSNumber *> *candidates = nfb_columnsSnapCandidates(columnWidth, maxOffsetX);
    if (rightward) {
        for (NSNumber *candidateNumber in candidates) {
            CGFloat candidate = candidateNumber.doubleValue;
            if (candidate > clamped) return MIN(MAX(candidate, 0.0), maxOffsetX);
        }
        return maxOffsetX;
    }
    for (NSNumber *candidateNumber in [candidates reverseObjectEnumerator]) {
        CGFloat candidate = candidateNumber.doubleValue;
        if (candidate < clamped) return MIN(MAX(candidate, 0.0), maxOffsetX);
    }
    return 0.0;
}

static CGFloat nfb_columnsTargetSnapOffsetX(UIScrollView *scrollView, CGFloat targetOffsetX, CGFloat velocityX) {
    CGFloat columnWidth = nfb_columnsColumnWidth(scrollView.bounds.size.width);
    CGFloat maxOffsetX = nfb_columnsMaxOffsetXForScroll(scrollView);
    if (columnWidth < 1.0 || maxOffsetX <= 0.0) return 0.0;
    CGFloat currentOffsetX = scrollView.contentOffset.x;
    // Snap the PROJECTED deceleration landing point (where UIScrollView's own momentum
    // would settle), NOT the lift-moment offset. The previous version ignored
    // targetOffsetX and snapped relative to currentOffsetX, which caused two bugs: a fast
    // flick whose finger barely moved only ever advanced one column, and a near-complete
    // drag released with low velocity snapped to the *nearest* boundary behind it -> the
    // column "stopped partway and sprang back". Using the projected target lets momentum
    // carry to the column it actually points at, and a slow drag settle where it rests.
    CGFloat projected = MIN(MAX(targetOffsetX, 0.0), maxOffsetX);
    CGFloat snapped = nfb_columnsSnappedOffsetX(projected, columnWidth, maxOffsetX);
    // For a clearly intentional flick, guarantee at least a one-column step in the flick
    // direction (the projected target can still round back to the current column on a
    // short flick). The 0.3 pt/ms floor keeps ignoring the tiny reverse velocity from a
    // right-edge rubber-band, so an edge release stays pinned at the edge (projected ==
    // maxOffset) instead of springing back a column.
    if (fabs(velocityX) >= 0.3) {
        CGFloat directional = nfb_columnsDirectionalSnapOffsetX(currentOffsetX, columnWidth, maxOffsetX, velocityX > 0.0);
        snapped = (velocityX > 0.0) ? MAX(snapped, directional) : MIN(snapped, directional);
    }
    return MIN(MAX(snapped, 0.0), maxOffsetX);
}

// Desired resting column offset chosen at drag-end. Twitter's TFNPaging machinery can
// re-center the horizontal scroll to a viewport-width "page" AFTER deceleration, which
// overrode our column snap (the scroll rested at bounds.width instead of a 340/680 column
// boundary, and a right-edge flick sprang back). We remember the intended offset and
// re-assert it once motion settles so our snap is the last word.
static char kNFBColumnsDesiredSnapOffsetKey;

// Pinned-list columns are vended by the pager data source without being adopted as child
// view controllers, so their -navigationController is nil -> a tweet tap's detail push is
// dropped. Adopt orphan column pages and flag them so restore can detach them again.
static char kNFBColumnsAddedAsChildKey;

static void nfb_columnsApplyTargetSnap(UIScrollView *scrollView, CGPoint velocity, CGPoint *targetContentOffset) {
    if (!targetContentOffset || !nfb_columnsScrollIsActivePaging(scrollView)) return;
    CGFloat snapped = nfb_columnsTargetSnapOffsetX(scrollView, targetContentOffset->x, velocity.x);
    if (gNFBLogRecording && fabs(targetContentOffset->x - snapped) > 0.5) {
        NFBLogEvent([NSString stringWithFormat:@"columnsTargetSnap from=%.1f to=%.1f vel=%.2f max=%.1f",
            targetContentOffset->x, snapped, velocity.x, nfb_columnsMaxOffsetXForScroll(scrollView)]);
    }
    targetContentOffset->x = snapped;
    objc_setAssociatedObject(scrollView, &kNFBColumnsDesiredSnapOffsetKey, @(snapped), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Re-assert the column boundary chosen at drag-end (or the nearest boundary as a fallback)
// so Twitter's post-deceleration page re-centering cannot leave the scroll between columns
// or bounce a right-edge flick back. Never fights an active finger.
static void nfb_columnsReassertDesiredOffset(UIScrollView *scrollView, BOOL animated) {
    if (!nfb_columnsScrollIsActivePaging(scrollView)) return;
    if (scrollView.isDragging || scrollView.isTracking) return;
    CGFloat columnWidth = nfb_columnsColumnWidth(scrollView.bounds.size.width);
    CGFloat maxOffsetX = nfb_columnsMaxOffsetXForScroll(scrollView);
    if (columnWidth < 1.0 || maxOffsetX <= 0.0) return;
    NSNumber *desired = objc_getAssociatedObject(scrollView, &kNFBColumnsDesiredSnapOffsetKey);
    CGFloat target = desired ? desired.doubleValue
                             : nfb_columnsSnappedOffsetX(scrollView.contentOffset.x, columnWidth, maxOffsetX);
    target = MIN(MAX(target, 0.0), maxOffsetX);
    if (fabs(scrollView.contentOffset.x - target) > 0.5) {
        if (gNFBLogRecording) {
            NFBLogEvent([NSString stringWithFormat:@"columnsReassert from=%.1f to=%.1f max=%.1f",
                scrollView.contentOffset.x, target, maxOffsetX]);
        }
        [scrollView setContentOffset:CGPointMake(target, scrollView.contentOffset.y) animated:animated];
    }
}

// Settle the columns scroll onto its boundary now and again after a short delay, to outlast
// any asynchronous page re-center Twitter performs after deceleration ends.
static void nfb_columnsScheduleSnapReassert(UIScrollView *scrollView) {
    if (!nfb_columnsScrollIsActivePaging(scrollView)) return;
    nfb_columnsReassertDesiredOffset(scrollView, YES);
    __weak UIScrollView *weakScrollView = scrollView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_columnsReassertDesiredOffset(weakScrollView, NO);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_columnsReassertDesiredOffset(weakScrollView, NO);
    });
}

static CGFloat nfb_columnsClampedOffsetX(CGFloat offsetX, CGFloat maxOffsetX) {
    if (maxOffsetX <= 0.0) return 0.0;
    return MIN(MAX(offsetX, 0.0), maxOffsetX);
}

static CGFloat nfb_columnsTopShift(void) {
    // Segment/header chrome is collapsed in place. Shifting pages again leaves the
    // timeline under the navigation chrome and creates the visible top gap.
    return 0.0;
}

static void nfb_scheduleColumnsSnapForScroll(UIScrollView *scrollView) {
    if (!scrollView || objc_getAssociatedObject(scrollView, &kNFBColumnsSnapScheduledKey)) return;
    objc_setAssociatedObject(scrollView, &kNFBColumnsSnapScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *weakScroll = scrollView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *strongScroll = weakScroll;
        if (!strongScroll) return;
        objc_setAssociatedObject(strongScroll, &kNFBColumnsSnapScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gInlineColumnsEnabled || !objc_getAssociatedObject(strongScroll, &kNFBInlineColumnsAppliedKey)) return;
        if (strongScroll.isDragging || strongScroll.isTracking || strongScroll.isDecelerating) {
            nfb_scheduleColumnsSnapForScroll(strongScroll);
            return;
        }
        nfb_layoutActiveHomePaging();
    });
}

static void nfb_scheduleColumnsRefreshAfterHorizontalScroll(UIScrollView *scrollView) {
    if (!scrollView || objc_getAssociatedObject(scrollView, &kNFBColumnsRefreshScheduledKey)) return;
    NSObject *token = [NSObject new];
    objc_setAssociatedObject(scrollView, &kNFBColumnsRefreshScheduledKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIScrollView *weakScroll = scrollView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *strongScroll = weakScroll;
        if (!strongScroll) return;
        if (objc_getAssociatedObject(strongScroll, &kNFBColumnsRefreshScheduledKey) != token) return;
        if (!nfb_columnsScrollIsActivePaging(strongScroll)) {
            objc_setAssociatedObject(strongScroll, &kNFBColumnsRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        if (nfb_columnsHorizontalScrollIsMoving(strongScroll)) {
            objc_setAssociatedObject(strongScroll, &kNFBColumnsRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            nfb_scheduleColumnsRefreshAfterHorizontalScroll(strongScroll);
            return;
        }
        objc_setAssociatedObject(strongScroll, &kNFBColumnsRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        nfb_streamTriggerColumns();
    });
}

static void nfb_columnsMaybeRunDeferredRefresh(UIScrollView *scrollView) {
    if (!nfb_columnsScrollIsActivePaging(scrollView)) return;
    if (!objc_getAssociatedObject(scrollView, &kNFBColumnsRefreshScheduledKey)) return;
    if (nfb_columnsHorizontalScrollIsMoving(scrollView)) return;
    objc_setAssociatedObject(scrollView, &kNFBColumnsRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nfb_scheduleColumnsRefreshAfterHorizontalScroll(scrollView);
}

static void nfb_rememberColumnOriginalViewState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey)) return;
    objc_setAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey, view.superview, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalFrameKey, [NSValue valueWithCGRect:view.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey, @(view.autoresizingMask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_restoreColumnOriginalViewState(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey)) return;
    UIView *superview = objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey);
    NSValue *frame = objc_getAssociatedObject(view, &kNFBColumnsOriginalFrameKey);
    NSNumber *autoresizing = objc_getAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey);
    NSNumber *hidden = objc_getAssociatedObject(view, &kNFBColumnsOriginalHiddenKey);
    NSNumber *alpha = objc_getAssociatedObject(view, &kNFBColumnsOriginalAlphaKey);
    NSNumber *clips = objc_getAssociatedObject(view, &kNFBColumnsOriginalClipsKey);
    if (superview && view.superview != superview) [superview addSubview:view];
    if (frame) view.frame = frame.CGRectValue;
    if (autoresizing) view.autoresizingMask = autoresizing.unsignedIntegerValue;
    view.hidden = hidden ? hidden.boolValue : NO;
    view.alpha = alpha ? alpha.doubleValue : 1.0;
    if (clips) view.clipsToBounds = clips.boolValue;
    objc_setAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalClipsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat nfb_columnsLeftSidebarWidthInView(UIView *view, UIWindow *window, int depth) {
    if (!view || !window || depth > 12) return 0.0;
    CGFloat best = 0.0;
    NSString *cls = NSStringFromClass(view.class);
    CGRect f = view.superview ? [view.superview convertRect:view.frame toView:window] : view.frame;
    if ([cls containsString:@"AppSplitHostView"] &&
        CGRectGetMinX(f) <= 2.0 &&
        f.size.width >= 60.0 && f.size.width <= 220.0 &&
        f.size.height >= window.bounds.size.height * 0.45) {
        best = f.size.width;
    }
    for (UIView *subview in view.subviews) {
        best = MAX(best, nfb_columnsLeftSidebarWidthInView(subview, window, depth + 1));
    }
    return best;
}

static CGFloat nfb_columnsTargetWidthAfterRailRemoval(UIScrollView *nativeScrollView) {
    if (!nativeScrollView || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return 0.0;
    if (!gNFBExtendedContentRemoved) return 0.0;
    CGFloat currentWidth = nativeScrollView.bounds.size.width;
    CGFloat targetWidth = currentWidth;
    UIWindow *window = nativeScrollView.window;
    if (window) {
        CGFloat sidebarWidth = nfb_columnsLeftSidebarWidthInView(window, window, 0);
        if (sidebarWidth > 0.0) {
            targetWidth = window.bounds.size.width - sidebarWidth;
        } else if (nativeScrollView.superview) {
            CGRect globalFrame = [nativeScrollView.superview convertRect:nativeScrollView.frame toView:window];
            CGFloat x = CGRectGetMinX(globalFrame);
            CGFloat fromWindowRight = window.bounds.size.width - x;
            if (isfinite(fromWindowRight) && x > 40.0 && fromWindowRight > 240.0 && fromWindowRight < 2400.0) {
                targetWidth = fromWindowRight;
            }
        }
        if (targetWidth > window.bounds.size.width) targetWidth = window.bounds.size.width;
    }
    return targetWidth;
}

static void nfb_expandColumnsPrimaryWidthIfNeeded(UIScrollView *nativeScrollView) {
    if (!nativeScrollView || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    if (!gNFBExtendedContentRemoved) return;
    // b32: hard-disable ancestor frame expansion. b31 proved this can corrupt the app-split layout
    // before the latch catches it: hframe collapsed to 12pt, page frames jumped to 5k+pt, then the app
    // crashed while opening Columns. Keep right-pane suppression + search-column transplant, but let
    // Twitter's split own primary width. A narrower stable columns viewport is better than a crash.
    if (gNFBLogRecording) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            NFBLogEvent(@"columnsExpand[b63] disabled (prevent split layout crash)");
        }
    }
    return;

    CGFloat currentWidth = nativeScrollView.bounds.size.width;
    CGFloat targetWidth = nfb_columnsTargetWidthAfterRailRemoval(nativeScrollView);
    if (targetWidth < 240.0 || targetWidth > 2400.0 || fabs(targetWidth - currentWidth) <= 1.0) {
        // At target (or N/A) → converged. Clear the oscillation latch so a later real resize re-runs.
        gNFBColumnsExpandLatched = NO;
        gNFBColumnsExpandStableGapCount = 0;
        gNFBColumnsExpandLastGap = -1.0;
        return;
    }

    // If we already latched this exact geometry as non-converging, do nothing: returning WITHOUT any
    // frame write or setNeedsLayout is what breaks the layout feedback loop that froze the app. A
    // genuine resize changes currentWidth/targetWidth, which unlatches us below and lets us re-flow.
    if (gNFBColumnsExpandLatched &&
        fabs(currentWidth - gNFBColumnsExpandLatchFrom) <= 1.0 &&
        fabs(targetWidth - gNFBColumnsExpandLatchTo) <= 1.0) {
        return;
    }
    gNFBColumnsExpandLatched = NO;   // geometry changed (or first run for it) → proceed

    // Non-convergence detector: when the split keeps resetting the scroll view a fixed few points off
    // our target, the gap stays essentially constant pass after pass. During genuine settling the gap
    // varies wildly (the chain reflows), so this only trips in the stuck steady state.
    CGFloat gap = fabs(currentWidth - targetWidth);
    if (gNFBColumnsExpandLastGap >= 0.0 && fabs(gap - gNFBColumnsExpandLastGap) <= 2.0) {
        gNFBColumnsExpandStableGapCount++;
    } else {
        gNFBColumnsExpandStableGapCount = 0;
    }
    gNFBColumnsExpandLastGap = gap;
    if (gNFBColumnsExpandStableGapCount >= 4) {
        gNFBColumnsExpandLatched = YES;
        gNFBColumnsExpandLatchFrom = currentWidth;
        gNFBColumnsExpandLatchTo = targetWidth;
        if (gNFBLogRecording) {
            NFBLogEvent([NSString stringWithFormat:@"columnsExpand[b63] latch (stuck gap=%.1f, %.1f->%.1f)",
                gap, currentWidth, targetWidth]);
        }
        return;
    }

    NSMutableArray<UIView *> *expanded = [NSMutableArray array];
    CGFloat scrollHeight = nativeScrollView.bounds.size.height;
    NSMutableArray<UIView *> *chain = [NSMutableArray array];
    for (UIView *view = nativeScrollView; view && ![view isKindOfClass:UIWindow.class] && chain.count < 16; view = view.superview) {
        [chain addObject:view];
    }
    for (UIView *view in chain) {
        if (!view.superview) continue;
        NSString *cls = NSStringFromClass(view.class);
        if ([cls containsString:@"NavigationBar"] || [cls containsString:@"TabBar"]) continue;
        CGRect f = view.frame;
        BOOL fullHeight = f.size.height >= scrollHeight - 8.0 || view.bounds.size.height >= scrollHeight - 8.0;
        BOOL startsAtContentLeft = fabs(f.origin.x) <= 1.0 || view == nativeScrollView;
        if (!fullHeight || !startsAtContentLeft) continue;
        if (fabs(f.size.width - targetWidth) > 1.0 || fabs(view.bounds.size.width - targetWidth) > 1.0) {
            nfb_rememberColumnOriginalViewState(view);
            f.size.width = targetWidth;
            view.frame = f;
            CGRect b = view.bounds;
            b.size.width = targetWidth;
            view.bounds = b;
            view.autoresizingMask |= UIViewAutoresizingFlexibleWidth;
            [view setNeedsLayout];
            [expanded addObject:view];
        }
    }
    if (expanded.count) {
        NSMutableArray<UIView *> *all = [NSMutableArray arrayWithArray:gNFBColumnsExpandedWidthViews ?: @[]];
        for (UIView *view in expanded) {
            if (![all containsObject:view]) [all addObject:view];
        }
        gNFBColumnsExpandedWidthViews = [all copy];
        if (gNFBLogRecording) {
            NFBLogEvent([NSString stringWithFormat:@"columnsExpand[b63] from=%.1f to=%.1f views=%lu",
                currentWidth, targetWidth, (unsigned long)expanded.count]);
        }
    } else if (gNFBLogRecording) {
        static NSString *lastColumnsExpandMiss = nil;
        NSString *miss = [NSString stringWithFormat:@"columnsExpand[b63] miss from=%.1f to=%.1f chain=%lu",
            currentWidth, targetWidth, (unsigned long)chain.count];
        if (![miss isEqualToString:lastColumnsExpandMiss]) {
            lastColumnsExpandMiss = [miss copy];
            NFBLogEvent(miss);
        }
    }
}

static void nfb_restoreColumnScrollAdjustmentForPage(UIViewController *page) {
    if (!page || ![page isViewLoaded]) return;
    UIScrollView *sv = nfb_mainScrollViewOf(page);
    if (!sv || !objc_getAssociatedObject(sv, &kNFBColumnScrollAdjustedKey)) return;
    NSValue *frameValue = objc_getAssociatedObject(sv, &kNFBColumnScrollFrameKey);
    NSNumber *autoresizing = objc_getAssociatedObject(sv, &kNFBColumnScrollAutoresizingKey);
    NSValue *insetValue = objc_getAssociatedObject(sv, &kNFBColumnScrollInsetKey);
    NSValue *indicatorValue = objc_getAssociatedObject(sv, &kNFBColumnScrollIndicatorInsetKey);
    NSNumber *adjustmentBehavior = objc_getAssociatedObject(sv, &kNFBColumnScrollAdjustmentBehaviorKey);

    CGFloat oldLogicalY = sv.contentOffset.y + sv.adjustedContentInset.top;
    if (frameValue) sv.frame = frameValue.CGRectValue;
    if (autoresizing) sv.autoresizingMask = autoresizing.unsignedIntegerValue;
    if (insetValue) sv.contentInset = insetValue.UIEdgeInsetsValue;
    if (indicatorValue) sv.scrollIndicatorInsets = indicatorValue.UIEdgeInsetsValue;
    if (@available(iOS 11.0, *)) {
        if (adjustmentBehavior) sv.contentInsetAdjustmentBehavior = adjustmentBehavior.integerValue;
    }
    if (!sv.isDragging && !sv.isTracking && !sv.isDecelerating) {
        CGFloat restoredY = oldLogicalY - sv.adjustedContentInset.top;
        if (isfinite(restoredY) && fabs(restoredY - sv.contentOffset.y) > 1.0) {
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, restoredY) animated:NO];
        }
    }

    objc_setAssociatedObject(sv, &kNFBColumnScrollAdjustedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sv, &kNFBColumnScrollFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sv, &kNFBColumnScrollAutoresizingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sv, &kNFBColumnScrollInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sv, &kNFBColumnScrollIndicatorInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sv, &kNFBColumnScrollAdjustmentBehaviorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat nfb_visibleNavigationBottomInView(UIView *view, UIWindow *window, int depth) {
    if (!view || !window || depth > 18 || view.hidden || view.alpha < 0.01) return 0.0;
    CGFloat bottom = 0.0;
    NSString *cls = NSStringFromClass(view.class);
    if (([cls containsString:@"NavigationBar"] || [cls containsString:@"UINavigationBar"] || [cls containsString:@"_UIBarBackground"]) &&
        ![cls containsString:@"Overlay"]) {
        CGRect frame = [view.superview convertRect:view.frame toView:window];
        if (CGRectGetMinY(frame) <= 140.0 && frame.size.height >= 20.0 && frame.size.height <= 140.0 &&
            frame.size.width >= window.bounds.size.width * 0.45) {
            bottom = MAX(bottom, CGRectGetMaxY(frame));
        }
    }
    for (UIView *subview in view.subviews) {
        bottom = MAX(bottom, nfb_visibleNavigationBottomInView(subview, window, depth + 1));
    }
    return bottom;
}

static CGFloat nfb_columnsTopContentInsetForPageView(UIView *pageView) {
    UIWindow *window = pageView.window;
    if (!pageView || !window) return 0.0;
    CGRect pageFrame = [pageView.superview convertRect:pageView.frame toView:window];
    CGFloat navBottom = nfb_visibleNavigationBottomInView(window, window, 0);
    if (navBottom < 1.0) {
        navBottom = window.safeAreaInsets.top + 54.0;
    }
    CGFloat inset = navBottom - CGRectGetMinY(pageFrame);
    if (!isfinite(inset)) return 0.0;
    return MIN(MAX(inset, 0.0), 180.0);
}

static void nfb_adjustColumnScrollForPage(UIViewController *page, UIView *pageView) {
    if (!page || !pageView || ![page isViewLoaded]) return;
    UIScrollView *sv = nfb_mainScrollViewOf(page);
    if (!sv || !sv.superview) return;
    if (!objc_getAssociatedObject(sv, &kNFBColumnScrollAdjustedKey)) {
        objc_setAssociatedObject(sv, &kNFBColumnScrollAdjustedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sv, &kNFBColumnScrollFrameKey, [NSValue valueWithCGRect:sv.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sv, &kNFBColumnScrollAutoresizingKey, @(sv.autoresizingMask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sv, &kNFBColumnScrollInsetKey, [NSValue valueWithUIEdgeInsets:sv.contentInset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sv, &kNFBColumnScrollIndicatorInsetKey, [NSValue valueWithUIEdgeInsets:sv.scrollIndicatorInsets], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (@available(iOS 11.0, *)) {
            objc_setAssociatedObject(sv, &kNFBColumnScrollAdjustmentBehaviorKey, @(sv.contentInsetAdjustmentBehavior), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    CGFloat oldAdjustedTop = sv.adjustedContentInset.top;
    CGFloat oldLogicalY = sv.contentOffset.y + oldAdjustedTop;
    BOOL wasAtTop = fabs(sv.contentOffset.y + oldAdjustedTop) <= 2.0;

    CGRect targetFrame = [pageView convertRect:pageView.bounds toView:sv.superview];
    if (targetFrame.size.width > 80.0 && targetFrame.size.height > 200.0 &&
        (fabs(sv.frame.origin.y - targetFrame.origin.y) > 0.5 ||
         fabs(sv.frame.size.height - targetFrame.size.height) > 0.5 ||
         fabs(sv.frame.size.width - targetFrame.size.width) > 0.5)) {
        sv.frame = targetFrame;
        sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }

    if (@available(iOS 11.0, *)) {
        sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    CGFloat targetTopInset = nfb_columnsTopContentInsetForPageView(pageView);
    UIEdgeInsets inset = sv.contentInset;
    if (fabs(inset.top - targetTopInset) > 0.5) {
        inset.top = targetTopInset;
        sv.contentInset = inset;
    }
    UIEdgeInsets indicatorInset = sv.scrollIndicatorInsets;
    if (fabs(indicatorInset.top - targetTopInset) > 0.5) {
        indicatorInset.top = targetTopInset;
        sv.scrollIndicatorInsets = indicatorInset;
    }
    if (!sv.isDragging && !sv.isTracking && !sv.isDecelerating) {
        CGFloat newY = wasAtTop ? -sv.adjustedContentInset.top : oldLogicalY - sv.adjustedContentInset.top;
        if (isfinite(newY) && fabs(newY - sv.contentOffset.y) > 1.0) {
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, newY) animated:NO];
        }
    }
}

static void nfb_removeColumnsOverlay(void) {
    NSArray<UIViewController *> *pages = gColumnsOverlayPages ?: @[];
    for (UIViewController *page in pages) {
        nfb_restoreColumnScrollAdjustmentForPage(page);
        if ([page isViewLoaded]) nfb_restoreColumnOriginalViewState(page.view);
    }
    UIViewController *paging = nfb_findAnyHomePagingController();
    for (UIViewController *page in paging.childViewControllers) {
        nfb_restoreColumnScrollAdjustmentForPage(page);
        if ([page isViewLoaded]) nfb_restoreColumnOriginalViewState(page.view);
    }
    for (UIViewController *page in nfb_currentColumnTimelinePages()) {
        nfb_restoreColumnScrollAdjustmentForPage(page);
        if ([page isViewLoaded]) nfb_restoreColumnOriginalViewState(page.view);
    }
    [gColumnsOverlayView removeFromSuperview];
    [gColumnsAllTopButton removeFromSuperview];
    gColumnsOverlayView = nil;
    gColumnsOverlayScrollView = nil;
    gColumnsAllTopButton = nil;
    gColumnsOverlayPages = nil;
    gPendingNewTweetsVC = nil;
    // Only un-hide the top chrome when columns mode is actually being turned off. The layout
    // routine calls this on its retry/early-out path even while columns mode is still enabled
    // (e.g. pages not ready yet); restoring the segment bar there made it flash back on screen.
    if (!gInlineColumnsEnabled) nfb_setColumnsGlobalTopChromeHidden(NO);
    nfb_hideNewTweetsPill();
}

static void nfb_ensureColumnsOverlayForPaging(UIViewController *paging) {
    UIView *host = nfb_columnsHostViewForPaging(paging);
    if (!host) return;
    if (gColumnsOverlayView || gColumnsOverlayScrollView) {
        [gColumnsOverlayView removeFromSuperview];
        gColumnsOverlayView = nil;
        gColumnsOverlayScrollView = nil;
    }
    // A permanently visible "all columns to top" button occupied the exact strip exposed after
    // removing the Home segment/Spaces chrome, making it look like the bar was still there. Keep
    // the action in the stream menu/new-tweets pill and do not place a persistent overlay on TL.
    if (gColumnsAllTopButton) {
        [gColumnsAllTopButton removeFromSuperview];
        gColumnsAllTopButton = nil;
    }
}

// A column that the pager placed but never made "current" can sit empty (no fetch) — seen on iPad
// where pinned-list columns reported contentSize height 0. Kick a single load so it populates.
static void nfb_kickEmptyColumnLoad(UIViewController *page) {
    if (!page || ![page isViewLoaded]) return;
    UIScrollView *sv = nfb_mainScrollViewOf(page);
    if (sv && sv.contentSize.height > 60.0) return;            // already has content
    // Do not direct-refresh HomeTimelineItemsViewController while it is still being materialised.
    // On iOS this can hit Following before its TFNTwitterHomeTimeline is fully attached and crash.
    // Pinned list wrappers are safe to nudge through their URT child; Following should be loaded by
    // the paging preload/reload path instead.
    NSString *cls = NSStringFromClass(page.class);
    if ([cls containsString:@"HomeTimelineItemsViewController"]) {
        UIViewController *paging = nfb_parentControllerNamed(page, @"Paging");
        if (paging) nfb_requestColumnsPagingPreload(paging, NO);
        return;
    }
    if (objc_getAssociatedObject(page, &kNFBColumnLoadKickedKey)) return;
    objc_setAssociatedObject(page, &kNFBColumnLoadKickedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nfb_streamTriggerTarget(page);
}

// Find the iPad app-split secondary search/trends navigation controller
// (T1ExtendedContentNavigationController, confirmed via the secondary pane's gesture
// delegates). Returns nil on iPhone, when there is no app-split, or when the secondary
// pane is absent (narrow widths) -> no search column is added (safe no-op).
static UIViewController *nfb_findExtendedContentNavInVC(UIViewController *vc, int depth) {
    if (!vc || depth > 5) return nil;
    if ([NSStringFromClass(vc.class) containsString:@"ExtendedContentNavigation"]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = nfb_findExtendedContentNavInVC(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIViewController *nfb_iPadColumnsSearchSidebarVC(UIViewController *paging) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return nil;
    UIViewController *split = nil;
    UIViewController *r = paging;
    for (int i = 0; i < 12 && r; i++) {
        if ([NSStringFromClass(r.class) containsString:@"AppSplitViewController"]) { split = r; break; }
        r = r.parentViewController;
    }
    if (!split) return nil;
    UIViewController *nav = nfb_findExtendedContentNavInVC(split, 0);
    if (!nav || ![nav isViewLoaded] || !nav.view) return nil;
    return nav;
}

// Walk up from the (still-secondary-pane-resident) search view to its enclosing app-split host
// (T1AppSplitHostView), so we can hide that 587pt panel while its content lives in the column.
static UIView *nfb_enclosingAppSplitHostView(UIView *view) {
    UIView *v = view.superview;
    for (int i = 0; i < 14 && v; i++) {
        if ([NSStringFromClass(v.class) containsString:@"AppSplitHostView"]) return v;
        v = v.superview;
    }
    return nil;
}

// Is vc, or something it contains (nav stack / child VCs, shallow), a GuideContainerViewController?
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

// Borrow a fully dependency-injected Explore/Guide VC from Twitter's tab factory. We find the guide
// tab index via the container's -viewControllerAtIndex:, then ask the dataSource
// -tabbedViewController:viewControllerAtIndex: for a SEPARATE instance and (per Codex's guards) only
// use it if it is (a) non-nil, (b) parentless, and (c) NOT the same object as the container's cached
// guide — so we never reparent/corrupt the live tab. Build-stamped crash guard around the factory
// calls. Cached once obtained. iPad only; returns nil (→ trends fallback) on any doubt.
static int gNFBGuideBorrowAttempts = 0;
// Walk up from paging to the T1AppSplitViewController (iPad split host).
static UIViewController *nfb_columnsAppSplitForPaging(UIViewController *paging) {
    UIViewController *r = paging;
    for (int i = 0; i < 14 && r; i++) {
        if ([NSStringFromClass(r.class) containsString:@"AppSplitViewController"]) return r;
        r = r.parentViewController;
    }
    return nil;
}

static BOOL nfb_columnsFullWidthPref(void) {
    return ([NSUserDefaults.standardUserDefaults objectForKey:@"NFBColumnsFullWidth"] == nil)
        ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"NFBColumnsFullWidth"];
}

static BOOL nfb_columnsShouldForceNativeSplitTierForSplit(UIViewController *split) {
    if (!split || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return NO;
    if (!gInlineColumnsEnabled || !nfb_columnsFullWidthPref()) return NO;
    if (![NSStringFromClass(split.class) containsString:@"AppSplitViewController"]) return NO;
    return YES;
}

static BOOL nfb_columnsNativeSplitTierGuardBegin(NSString *reason) {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    [defs removeObjectForKey:@"NFBNativeSplitTierInFlightBuild"];
    [defs removeObjectForKey:@"NFBNativeSplitTierCrashedBuild"];
    [defs synchronize];
    if (gNFBLogRecording && reason.length) {
        static NSString *lastGuardKey = nil;
        NSString *key = [NSString stringWithFormat:@"nativeSplit[b63]: guard %@", reason];
        if (![key isEqualToString:lastGuardKey]) { lastGuardKey = [key copy]; NFBLogEvent(key); }
    }
    return YES;
}

static void nfb_columnsNativeSplitTierGuardEnd(void) {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    [defs removeObjectForKey:@"NFBNativeSplitTierInFlightBuild"];
    [defs synchronize];
}

static id nfb_columnsFindVisiblePanelsRecalcTargetInTree(UIViewController *root, SEL sel, int depth) {
    if (!root || depth > 12) return nil;
    if ([root respondsToSelector:sel]) return root;
    for (UIViewController *child in root.childViewControllers) {
        id found = nfb_columnsFindVisiblePanelsRecalcTargetInTree(child, sel, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void nfb_columnsApplyNativeSplitTierForPaging(UIViewController *paging, BOOL suppress) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    suppress = suppress && gInlineColumnsEnabled && nfb_columnsFullWidthPref();
    if (!suppress && !gNFBNativeSplitTierSuppressed) return;

    UIViewController *split = suppress ? nfb_columnsAppSplitForPaging(paging) : gNFBNativeSplitTierSplit;
    if (!split || split.viewIfLoaded.window == nil) split = nfb_columnsAppSplitForPaging(paging);
    if (!split) {
        if (!suppress) { gNFBNativeSplitTierSuppressed = NO; gNFBNativeSplitTierSplit = nil; }
        if (gNFBLogRecording) NFBLogEvent(@"nativeSplit[b63]: splitNil");
        return;
    }
    if (suppress && gNFBNativeSplitTierSuppressed && gNFBNativeSplitTierSplit == split) return;
    if (gNFBNativeSplitTierApplying) {
        if (gNFBLogRecording) {
            static NSString *lastReentryKey = nil;
            NSString *key = [NSString stringWithFormat:@"nativeSplit[b63]: reentry skip %@", suppress ? @"suppress" : @"restore"];
            if (![key isEqualToString:lastReentryKey]) { lastReentryKey = [key copy]; NFBLogEvent(key); }
        }
        return;
    }
    if (!nfb_columnsNativeSplitTierGuardBegin(suppress ? @"suppress" : @"restore")) return;

    BOOL setOK = NO, updateOK = NO, recalcOK = NO;
    gNFBNativeSplitTierApplying = YES;
    if (suppress) {
        gNFBNativeSplitTierSuppressed = YES;
        gNFBNativeSplitTierSplit = split;
    }
    @try {
        SEL setAnimated = @selector(setDisplayExtendedContent:animated:);
        SEL setPlain = @selector(setDisplayExtendedContent:);
        BOOL displayExtended = suppress ? NO : YES;
        if ([split respondsToSelector:setAnimated]) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(split, setAnimated, displayExtended, NO);
            setOK = YES;
        } else if ([split respondsToSelector:setPlain]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(split, setPlain, displayExtended);
            setOK = YES;
        }

        SEL updateSplit = @selector(private_updateSplitModeAnimated:);
        if ([split respondsToSelector:updateSplit]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(split, updateSplit, NO);
            updateOK = YES;
        }

        // b37 also called recalculateVisiblePanels here. On device that caused a synchronous
        // homeContainer disappear/appear loop before columns layout completed. The split update above
        // already reaches private_splitModeForSize:, so keep this native-tier pass one-shot.
        [split.viewIfLoaded setNeedsLayout];
    } @catch (NSException *e) {
        if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"nativeSplit[b63]: %@ threw %@", suppress ? @"suppress" : @"restore", e.name ?: @"exception"]);
    }
    gNFBNativeSplitTierApplying = NO;
    nfb_columnsNativeSplitTierGuardEnd();

    if (!suppress) {
        gNFBNativeSplitTierSuppressed = NO;
        gNFBNativeSplitTierSplit = nil;
    }
    if (gNFBLogRecording) {
        static NSString *lastNativeSplitKey = nil;
        NSString *key = [NSString stringWithFormat:@"nativeSplit[b63]: %@ split=%@ set=%d update=%d recalc=%d",
            suppress ? @"medium" : @"restore", NSStringFromClass(split.class),
            setOK ? 1 : 0, updateOK ? 1 : 0, recalcOK ? 1 : 0];
        if (![key isEqualToString:lastNativeSplitKey]) { lastNativeSplitKey = [key copy]; NFBLogEvent(key); }
    }
}

// Issue B: remove/restore the iPad extended-content rail via the split's own private methods so the
// columns fill the full width. Guarded (respondsToSelector + @try + build-stamped crash guard: a hard
// crash leaves the in-flight stamp → next launch promotes it to a crashed stamp and stops trying for
// this build, so the app self-recovers). Idempotent via gNFBExtendedContentRemoved.
static void nfb_columnsSetExtendedContentRemoved(UIViewController *paging, BOOL removed) {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    static NSInteger const kExtBuild = 36;
    if (removed) {
        if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
            if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: skip notPad"); return;
        }
        if (gNFBExtendedContentRemoved) { if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: alreadyRemoved"); return; }
        UIViewController *split = nfb_columnsAppSplitForPaging(paging);
        if (!split) { if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"extContent[b63]: splitNil paging=%@", paging ? NSStringFromClass(paging.class) : @"nil"]); return; }
        // Decision paths below set gNFBExtendedContentRemoved (so we stop trying / stop showing trends)
        // but NOT gNFBExtendedContentActuallyRemoved — the latter is set ONLY when the private remove
        // really runs, so restore never calls add on a rail we never removed (Codex).
        if (!nfb_iPadColumnsSearchSidebarVC(paging)) { gNFBExtendedContentRemoved = YES; if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: noSidebar (nothing to remove)"); return; }
        SEL sel = @selector(private_removeExtendedContentViewController);
        if (![split respondsToSelector:sel]) { gNFBExtendedContentRemoved = YES; if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"extContent[b63]: noSelector on %@", NSStringFromClass(split.class)]); return; }
        if ([defs integerForKey:@"NFBExtContentCrashedBuild"] == kExtBuild) { gNFBExtendedContentRemoved = YES; if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: skip (crashed before this build)"); return; }
        if ([defs integerForKey:@"NFBExtContentInFlightBuild"] == kExtBuild) {
            [defs setInteger:kExtBuild forKey:@"NFBExtContentCrashedBuild"]; [defs synchronize];
            gNFBExtendedContentRemoved = YES;
            if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: prior remove crashed; disabled this build");
            return;
        }
        [defs setInteger:kExtBuild forKey:@"NFBExtContentInFlightBuild"]; [defs synchronize];
        BOOL removeOK = NO;
        @try { ((void (*)(id, SEL))objc_msgSend)(split, sel); removeOK = YES; } @catch (NSException *e) {}
        [defs removeObjectForKey:@"NFBExtContentInFlightBuild"]; [defs synchronize];
        gNFBExtendedContentRemoved = YES;   // stop retrying regardless
        if (removeOK) {
            gNFBExtendedContentActuallyRemoved = YES;   // ONLY on a throw-free remove — guards the add on restore
            gNFBExtRemovedSplit = split;                 // remember the exact split for a paging-independent restore
            [split.viewIfLoaded setNeedsLayout];   // re-flow the split on its own (nil-safe; no forced load, no layoutIfNeeded)
            if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"extContent[b63]: removed (columns full-width) split=%@", NSStringFromClass(split.class)]);
        } else {
            if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: remove threw (not marked removed)");
        }
    } else {
        // Restore. Only re-add if we actually removed; use the stored split so this works even when
        // paging is unavailable (e.g., disabled via a path that can't resolve the home pager).
        if (!gNFBExtendedContentActuallyRemoved) {
            gNFBExtendedContentRemoved = NO; gNFBExtRemoveScheduled = NO; gNFBExtRemovedSplit = nil;
            if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: restoreSkipped (never actually removed)");
            return;
        }
        // Stale-split guard (Codex re-audit#3/#4): the app-split can be torn down and rebuilt
        // (rotation, multitasking, scene changes), and restore may be invoked from a DIFFERENT or
        // multi-window paging than the one we removed from. The criterion is split IDENTITY +
        // liveness, NOT equality with the paging-resolved split: re-add the rail to the EXACT split
        // we removed it from, as long as that split is still attached to a window — even if the
        // paging passed here resolves to a different live split (that case must NOT drop our still-
        // live stored split — Codex re-audit#4). A detached stored split (window == nil) means it was
        // torn down/replaced; the replacement owns its own rail, so we skip the add. We never add to
        // the paging-resolved split (that would double a rail), and we always clear flags + release
        // the strong ref below, so a torn-down split is never retained as a zombie.
        UIViewController *stored = gNFBExtRemovedSplit;
        UIViewController *liveSplit = nfb_columnsAppSplitForPaging(paging);  // diagnostic only (logged below)
        BOOL storedIsLive = stored && stored.viewIfLoaded.window != nil;
        UIViewController *split = storedIsLive ? stored : nil;
        SEL sel = @selector(private_addExtendedContentViewController);
        if (split && [split respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(split, sel); } @catch (NSException *e) {}
            [split.viewIfLoaded setNeedsLayout];
            if (gNFBLogRecording) NFBLogEvent(@"extContent[b63]: restored");
        } else if (gNFBLogRecording) {
            NFBLogEvent([NSString stringWithFormat:@"extContent[b63]: restore noop (stale/rebuilt split stored=%@ live=%@)",
                         stored ? @"y" : @"n", liveSplit ? @"y" : @"n"]);
        }
        gNFBExtendedContentActuallyRemoved = NO;
        gNFBExtendedContentRemoved = NO;
        gNFBExtRemoveScheduled = NO;
        gNFBExtRemovedSplit = nil;
    }
}

static void nfb_collectSplitResidueViews(UIView *view, NSMutableArray<UIView *> *out, int depth) {
    if (!view || depth > 10) return;
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"AppSplitOverlayView"] || [cls containsString:@"LiveResizingOverlayView"]) {
        [out addObject:view];
    }
    for (UIView *subview in view.subviews) {
        nfb_collectSplitResidueViews(subview, out, depth + 1);
    }
}

static void nfb_suppressSplitResidueViews(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    nfb_collectSplitResidueViews(root, views, 0);
    if (!views.count) return;
    for (UIView *view in views) {
        nfb_rememberColumnOriginalViewState(view);
        view.hidden = YES;
        view.alpha = 0.0;
    }
    gNFBColumnsSuppressedSplitViews = [views copy];
    if (gNFBLogRecording) {
        static NSString *lastSplitResidueKey = nil;
        NSString *key = [NSString stringWithFormat:@"splitResidue[b63] hidden=%lu root=%@",
            (unsigned long)views.count, NSStringFromClass(root.class)];
        if (![key isEqualToString:lastSplitResidueKey]) {
            lastSplitResidueKey = [key copy];
            NFBLogEvent(key);
        }
    }
}

static void nfb_columnsRetryRemoveRebuiltExtendedContent(UIViewController *paging) {
    if (!paging || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    if (!gNFBExtendedContentRemoved) return;
    UIViewController *searchVC = nfb_iPadColumnsSearchSidebarVC(paging);
    if (!searchVC || ![searchVC isViewLoaded] || !searchVC.view.window) return;
    UIView *host = nfb_enclosingAppSplitHostView(searchVC.view);
    if (!host || host.hidden || host.alpha < 0.01) return;
    UIViewController *split = nfb_columnsAppSplitForPaging(paging);
    SEL sel = @selector(private_removeExtendedContentViewController);
    BOOL removeOK = NO;
    if (split && [split respondsToSelector:sel]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(split, sel); removeOK = YES; } @catch (NSException *e) {}
    }
    if (removeOK) {
        gNFBExtendedContentActuallyRemoved = YES;
        gNFBExtRemovedSplit = split;
        [split.viewIfLoaded setNeedsLayout];
        if (gNFBLogRecording) {
            static NSString *lastRetryKey = nil;
            NSString *key = [NSString stringWithFormat:@"extContent[b63]: reRemoved rebuilt split=%@", NSStringFromClass(split.class)];
            if (![key isEqualToString:lastRetryKey]) {
                lastRetryKey = [key copy];
                NFBLogEvent(key);
            }
        }
    }
}

static void nfb_suppressSecondarySearchHostIfNeeded(UIViewController *paging, UIScrollView *nativeScrollView) {
    if (!paging || !nativeScrollView || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    UIViewController *searchVC = nfb_iPadColumnsSearchSidebarVC(paging);
    if (!searchVC || ![searchVC isViewLoaded] || !searchVC.view || searchVC.view.superview == nativeScrollView) return;
    UIView *secondaryHost = nfb_enclosingAppSplitHostView(searchVC.view);
    UIView *primaryHost = nfb_enclosingAppSplitHostView((UIView *)nativeScrollView);
    if (!secondaryHost || secondaryHost == primaryHost) return;
    nfb_rememberColumnOriginalViewState(secondaryHost);
    gNFBColumnsSecondaryHostView = secondaryHost;
    secondaryHost.hidden = YES;
    secondaryHost.alpha = 0.0;
    if (gNFBLogRecording) {
        static NSString *lastSecondaryHostKey = nil;
        CGRect f = secondaryHost.frame;
        NSString *key = [NSString stringWithFormat:@"secondaryHost[b63] hidden %@ f=(%.0f,%.0f,%.0f,%.0f)",
            NSStringFromClass(secondaryHost.class), f.origin.x, f.origin.y, f.size.width, f.size.height];
        if (![key isEqualToString:lastSecondaryHostKey]) {
            lastSecondaryHostKey = [key copy];
            NFBLogEvent(key);
        }
    }
}

static BOOL nfb_viewLooksLikeSearchInput(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass(view.class);
    NSString *lower = cls.lowercaseString;
    if ([lower containsString:@"searchbar"] ||
        [lower containsString:@"searchfield"] ||
        [lower containsString:@"searchcontainer"] ||
        [lower containsString:@"textfield"] ||
        [cls containsString:@"TFNNavigationBarSearchView"] ||
        [cls containsString:@"UISearchBarTextField"]) return YES;
    NSString *text = nfb_diagTextForView(view, 80) ?: @"";
    return [text containsString:@"検索"] || [text.lowercaseString containsString:@"search"];
}

static void nfb_fitSearchColumnSubviewTree(UIView *view, CGFloat width, CGFloat height, int depth) {
    if (!view || depth > 8 || width < 100.0 || height < 100.0) return;
    for (UIView *subview in view.subviews) {
        CGRect f = subview.frame;
        NSString *cls = NSStringFromClass(subview.class);
        BOOL searchInput = nfb_viewLooksLikeSearchInput(subview);
        if (searchInput) {
            nfb_rememberColumnOriginalViewState(subview);
            subview.hidden = NO;
            subview.alpha = 1.0;
            subview.userInteractionEnabled = YES;
            if ([cls containsString:@"SearchBar"] || [cls containsString:@"NavigationBarSearchView"]) {
                f.origin.x = 12.0;
                if (f.origin.y < 0.0 || f.origin.y > 96.0) f.origin.y = 12.0;
                f.size.width = MAX(1.0, width - 24.0);
                if (f.size.height < 36.0 || f.size.height > 64.0) f.size.height = 44.0;
                subview.frame = f;
                subview.autoresizingMask |= UIViewAutoresizingFlexibleWidth;
            }
        }
        BOOL overwide = (f.size.width > width + 1.0) || (f.origin.x < -1.0);
        BOOL topChrome = (CGRectGetMinY(f) < 150.0) ||
            [cls containsString:@"NavigationBar"] ||
            [cls containsString:@"SearchBar"] ||
            [cls containsString:@"BarBackground"] ||
            [cls containsString:@"NavigationBarContent"] ||
            [cls containsString:@"TextField"];
        BOOL largePane = (f.size.height > height * 0.45) ||
            [subview isKindOfClass:UIScrollView.class] ||
            [cls containsString:@"TableView"] ||
            [cls containsString:@"CollectionView"] ||
            [cls containsString:@"ScrollView"];
        BOOL shallowContainer = depth <= 1 &&
            ([cls containsString:@"UILayoutContainerView"] ||
             [cls containsString:@"Transition"] ||
             [cls isEqualToString:@"UIView"]);
        if (overwide && (topChrome || largePane || shallowContainer)) {
            nfb_rememberColumnOriginalViewState(subview);
            CGFloat inset = ([cls containsString:@"SearchBar"] || [cls containsString:@"TextField"]) ? 12.0 : 0.0;
            f.origin.x = inset;
            f.size.width = MAX(1.0, width - inset * 2.0);
            if (f.size.height > height || (shallowContainer && f.size.height > height * 0.70)) {
                f.origin.y = 0.0;
                f.size.height = height;
            }
            subview.frame = f;
            subview.autoresizingMask |= UIViewAutoresizingFlexibleWidth;
            if (largePane || shallowContainer) subview.autoresizingMask |= UIViewAutoresizingFlexibleHeight;
            [subview setNeedsLayout];
        }
        nfb_fitSearchColumnSubviewTree(subview, width, height, depth + 1);
    }
}

// === Issue C: hide the iPad home logo/nav bar while columns are at root ==========================
// The columns root view shows only a near-empty TFNNavigationBar with the centred Twitter logo (the
// "上部ロゴバー"). Hide it via the nav controller's own API (reclaims the vertical space) ONLY while
// the home stack is at root; a pushed detail must keep its bar (back button/title), so we restore it
// the instant the stack has >1 controller (also via the pushViewController hook below). Pref-gated,
// default ON. iPad only.
static UINavigationController *gNFBColumnsLogoNav = nil;
static UINavigationController *nfb_homeTimelineNavController(UIViewController *paging) {
    UIViewController *r = paging;
    for (int i = 0; i < 14 && r; i++) {
        if ([r isKindOfClass:UINavigationController.class] &&
            [NSStringFromClass(r.class) containsString:@"TimelineNavigationController"]) return (UINavigationController *)r;
        r = r.parentViewController;
    }
    return nil;
}
static void nfb_restoreColumnsLogoBar(void) {
    if (gNFBColumnsLogoNav) {
        UINavigationController *nav = gNFBColumnsLogoNav;
        gNFBColumnsLogoNav = nil;
        @try { if (nav.navigationBarHidden) [nav setNavigationBarHidden:NO animated:NO]; } @catch (NSException *e) {}
    }
}
static void nfb_applyColumnsLogoBarHidden(UIViewController *paging) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    BOOL pref = ([NSUserDefaults.standardUserDefaults objectForKey:@"NFBHideColumnsLogoBar"] == nil)
        ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"NFBHideColumnsLogoBar"];
    UINavigationController *nav = nfb_homeTimelineNavController(paging);
    if (!nav) return;
    BOOL atRoot = nav.viewControllers.count <= 1;
    BOOL shouldHide = pref && gInlineColumnsEnabled && atRoot;
    @try {
        if (shouldHide) {
            if (!nav.navigationBarHidden) [nav setNavigationBarHidden:YES animated:NO];
            gNFBColumnsLogoNav = nav;
        } else if (gNFBColumnsLogoNav == nav || (!gInlineColumnsEnabled && nav.navigationBarHidden)) {
            if (nav.navigationBarHidden) [nav setNavigationBarHidden:NO animated:NO];
            gNFBColumnsLogoNav = nil;
        }
    } @catch (NSException *e) {}
}

// === Issue B: full-width columns via Auto Layout CONSTANT (the SAFE method) =======================
// b31 crashed by frame-fighting the split's Auto Layout every pass (non-converging -> watchdog). The
// correct way to resize an Auto-Layout-managed view is to change the CONSTRAINT CONSTANT so the engine
// computes our target and stops (no ping-pong). We widen the primary app-split host over the (hidden,
// empty) secondary trends pane. SAFETY: iPad+columns only; we ONLY touch a literal width==currentWidth
// constraint we can positively identify (else do nothing); converged passes write nothing; a hard cap
// of 8 non-converging writes LATCHES the feature off (so the split resetting the constant can never
// hang the app); and a build-stamped crash guard self-recovers across a relaunch. The diagnostic in
// showDiag dumps the host constraints so the exact one can be pinned if the heuristic misses it.
static char kNFBPrimaryWidthConstraintKey;
static char kNFBPrimaryWidthOriginalKey;
static int  gNFBFullWidthApplyCount = 0;
static BOOL gNFBFullWidthLatched = NO;

static NSLayoutConstraint *nfb_primaryHostWidthConstraint(UIView *host, CGFloat currentWidth) {
    if (!host) return nil;
    NSMutableArray<NSLayoutConstraint *> *cands = [NSMutableArray array];
    [cands addObjectsFromArray:host.constraints];
    if (host.superview) [cands addObjectsFromArray:host.superview.constraints];
    for (NSLayoutConstraint *c in cands) {
        if (c.firstItem == host && c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil &&
            c.relation == NSLayoutRelationEqual && fabs(c.constant - currentWidth) < 4.0) {
            return c;
        }
    }
    return nil;
}
static void nfb_columnsRestorePrimaryWidth(UIView *primaryHost) {
    if (!primaryHost) return;
    NSLayoutConstraint *c = objc_getAssociatedObject(primaryHost, &kNFBPrimaryWidthConstraintKey);
    NSNumber *orig = objc_getAssociatedObject(primaryHost, &kNFBPrimaryWidthOriginalKey);
    if (c && orig) { @try { c.constant = orig.doubleValue; [primaryHost setNeedsLayout]; } @catch (NSException *e) {} }
    objc_setAssociatedObject(primaryHost, &kNFBPrimaryWidthConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(primaryHost, &kNFBPrimaryWidthOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void nfb_columnsExpandPrimaryViaConstraint(UIViewController *paging, UIScrollView *nativeScrollView) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad || !gInlineColumnsEnabled) return;
    if (gNFBFullWidthLatched) return;
    BOOL pref = ([NSUserDefaults.standardUserDefaults objectForKey:@"NFBColumnsFullWidth"] == nil)
        ? YES : [NSUserDefaults.standardUserDefaults boolForKey:@"NFBColumnsFullWidth"];
    if (!pref) return;
    UIView *primaryHost = nfb_enclosingAppSplitHostView((UIView *)nativeScrollView);
    if (!primaryHost || !primaryHost.window) return;
    UIView *container = primaryHost.superview;
    if (!container) return;
    CGFloat haveW = primaryHost.bounds.size.width;
    CGFloat fullW = container.bounds.size.width;
    if (fullW - haveW < 120.0 || fullW < 320.0 || fullW > 4000.0) return;   // no meaningful empty space

    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    NSInteger kBuild = 34;
    if ([defs integerForKey:@"NFBFullWidthCrashedBuild"] == kBuild) return;

    NSLayoutConstraint *c = objc_getAssociatedObject(primaryHost, &kNFBPrimaryWidthConstraintKey);
    if (!c) {
        c = nfb_primaryHostWidthConstraint(primaryHost, haveW);
        if (!c) return;   // can't positively identify it -> do nothing (diagnostic dumps candidates)
        objc_setAssociatedObject(primaryHost, &kNFBPrimaryWidthOriginalKey, @(c.constant), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(primaryHost, &kNFBPrimaryWidthConstraintKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat target = fullW;
    if (fabs(c.constant - target) < 1.0) { gNFBFullWidthApplyCount = 0; return; }   // converged: no write, no loop

    if ([defs integerForKey:@"NFBFullWidthInFlightBuild"] == kBuild) {   // we hung here last time -> disable
        [defs setInteger:kBuild forKey:@"NFBFullWidthCrashedBuild"]; [defs synchronize];
        gNFBFullWidthLatched = YES; return;
    }
    [defs setInteger:kBuild forKey:@"NFBFullWidthInFlightBuild"]; [defs synchronize];
    @try { c.constant = target; [primaryHost setNeedsLayout]; } @catch (NSException *e) {}
    [defs removeObjectForKey:@"NFBFullWidthInFlightBuild"]; [defs synchronize];

    if (++gNFBFullWidthApplyCount > 8) {   // split keeps resetting the constant -> stop (never hang)
        gNFBFullWidthLatched = YES;
        if (gNFBLogRecording) NFBLogEvent(@"fullWidth[b63] latched (constant kept resetting; stopped to avoid hang)");
        return;
    }
    if (gNFBLogRecording) {
        static NSString *lastK = nil;
        NSString *k = [NSString stringWithFormat:@"fullWidth[b63] widen %.1f->%.1f (host=%.1f container=%.1f n=%d)",
            haveW, target, haveW, fullW, gNFBFullWidthApplyCount];
        if (![k isEqualToString:lastK]) { lastK = [k copy]; NFBLogEvent(k); }
    }
}

// Legacy frame path, kept dormant for restore compatibility only. b36 no longer calls this:
// full width is driven through Twitter's native split tier above, not by widening host frames.
static char kNFBSplitPrimaryOrigWidthKey;
static int gNFBFWChainCount = 0;
static BOOL gNFBFWChainLatched = NO;
static void nfb_layoutColumnsOverlayForPaging(UIViewController *paging) {
    if (!nfb_inlineColumnsActiveForHomePaging(paging) || ![paging isViewLoaded]) return;
    // Twitter's own paging layout runs in %orig (before us) on every pass and snaps the pages back
    // to full-width paging positions. We must ALWAYS re-apply the column frames so that snap can't
    // win mid-drag (that was the "catch and bounce back"). Only the contentSize/contentOffset
    // mutations are skipped while dragging, since those genuinely interrupt the in-flight scroll.
    UIScrollView *activeColumnsScroll = nfb_horizontalPagingScrollViewOf(paging);
    BOOL columnsScrollDragging = activeColumnsScroll && (activeColumnsScroll.isDragging || activeColumnsScroll.isTracking || activeColumnsScroll.isDecelerating);
    NSArray<NSDictionary *> *entries = nfb_currentColumnEntriesForPaging(paging);
    NSMutableArray<UIViewController *> *timelinePagesForPreload = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if ([entry[@"kind"] isEqualToString:kNFBColumnEntryKindTimeline]) {
            UIViewController *page = nfb_columnEntryViewController(entry);
            if (page) [timelinePagesForPreload addObject:page];
        }
    }
    NSInteger estimatedPages = nfb_estimatedHomePagingPageCount(paging);
    NSInteger expectedColumns = MAX(1, estimatedPages - 1);
    if (!entries.count) {
        // Transient empties happen during iPad split-view resizes (the content VC is rebuilt for a
        // moment). Tearing the columns down here made them vanish on every resize. Keep whatever is
        // laid out and just retry the preload; restore only happens when columns mode is turned off.
        static NSTimeInterval lastColumnsPageRetry = 0.0;
        NSTimeInterval now = CACurrentMediaTime();
        if (!gNFBColumnsSizeTransitioning && !columnsScrollDragging && now - lastColumnsPageRetry > 0.75) {
            lastColumnsPageRetry = now;
            nfb_requestColumnsPagingPreload(paging, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
        return;
    }
    if ((NSInteger)timelinePagesForPreload.count < expectedColumns) {
        static NSTimeInterval lastColumnsPreload = 0.0;
        NSTimeInterval now = CACurrentMediaTime();
        if (!gNFBColumnsSizeTransitioning && !columnsScrollDragging && now - lastColumnsPreload > 0.75) {
            lastColumnsPreload = now;
            nfb_requestColumnsPagingPreload(paging, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
    }
    nfb_ensureColumnsOverlayForPaging(paging);
    // b54: reuse the scroll resolved at the top of this pass — the second full view-tree scoring
    // walk per pass was pure waste (the pager scroll doesn't change mid-pass).
    UIScrollView *nativeScrollView = activeColumnsScroll ?: nfb_horizontalPagingScrollViewOf(paging);
    if (!nativeScrollView) return;
    nfb_setColumnsSegmentedHiddenForPaging(paging, YES);
    NSMutableArray<NSDictionary *> *layoutEntries = [NSMutableArray array];
    NSMutableArray<UIViewController *> *pages = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if ([entry[@"kind"] isEqualToString:kNFBColumnEntryKindTimeline]) {
            UIViewController *page = nfb_columnEntryViewController(entry);
            if (page) {
                [layoutEntries addObject:entry];
                [pages addObject:page];
            }
        } else if ([entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) {
            UIViewController *tabVC = nfb_columnsAppTabControllerForEntry(entry, paging);
            if (tabVC) {
                NSMutableDictionary *copy = [entry mutableCopy];
                copy[@"vc"] = tabVC;
                [layoutEntries addObject:copy];
            } else if (gNFBLogRecording) {
                NFBLogEvent([NSString stringWithFormat:@"appTabColumn[b63] skip id=%@", nfb_columnEntryIdentity(entry)]);
            }
        }
    }
    if (!layoutEntries.count) {
        for (UIViewController *page in nfb_allHomePagingTimelinePages(paging)) {
            if (!nfb_shouldUseTimelinePageAsColumn(page)) continue;
            NSString *identity = nfb_columnTimelineIdentity(page);
            if (!identity.length) continue;
            NSDictionary *fallback = @{ @"kind": kNFBColumnEntryKindTimeline,
                                        @"id": identity,
                                        @"title": nfb_columnDisplayName(page) ?: identity,
                                        @"vc": page };
            [layoutEntries addObject:fallback];
            [pages addObject:page];
        }
    }
    UIViewController *searchColumnVC = nil; // b37: search/explore comes from the compact app-tab Guide VC, not the wide secondary sidebar.
    // b33: rail-removal DISABLED — it was the root cause of the b32 columns crash. The deferred
    // _private_removeExtendedContentViewController was scheduled on an early pass (before the search
    // sidebar loaded, searchColumnVC==nil) and then fired unconditionally AFTER a later pass had already
    // transplanted that same T1ExtendedContentNavigationController as the 340pt search column. Removing
    // it from the split tore down the live search-column VC → searchColumnVC flipped to nil → the
    // !searchColumnVC+extRemoved fallback borrowed a fully DI'd Guide controller and adopted it into the
    // home pager (addChildViewController) → crash (the recorded log dies right at guideBorrowState,
    // before guideColumn). And nfb_expandColumnsPrimaryWidthIfNeeded is itself hard-disabled (b32), so
    // the removal bought ZERO extra width — pure downside. Keep Strategy 1 only: transplant the sidebar's
    // view as the search column + hide the empty secondary host (handled in the searchColumn block
    // below). Leaving gNFBExtendedContentRemoved==NO also disables the guide-borrow / guide-column-adopt
    // paths (they are all gated on it). Reclaiming the freed width without crashing is separate future
    // work (must not re-resize split ancestors or reparent DI'd Twitter controllers).
    // Build 32: use the app's existing right search/trends navigation controller as a real 340pt
    // column. Do not widen app-split ancestors: b31 proved that path corrupts the split layout.
    if (gNFBExtendedContentRemoved && UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nfb_columnsRetryRemoveRebuiltExtendedContent(paging);
        UIViewController *split = nfb_columnsAppSplitForPaging(paging);
        UIView *splitRoot = split.viewIfLoaded ?: nativeScrollView.window;
        nfb_suppressSplitResidueViews(splitRoot);
        nfb_suppressSecondarySearchHostIfNeeded(paging, nativeScrollView);
    }

    nfb_columnsApplyNativeSplitTierForPaging(paging, nfb_columnsFullWidthPref()); // b37: native medium tier (sidebar yes, extended content no)
    UIView *host = nfb_columnsHostViewForPaging(paging);
    nfb_applyColumnsLogoBarHidden(paging);                              // Issue C: hide iPad logo/nav bar at root
    CGRect bounds = nativeScrollView.bounds;
    if (bounds.size.width < 120.0 || bounds.size.height < 240.0) return;
    CGFloat columnWidth = nfb_columnsColumnWidth(bounds.size.width);
    CGFloat height = bounds.size.height;
    CGFloat topShift = nfb_columnsTopShift();
    gColumnsOverlayPages = [pages copy];
    BOOL firstColumnsApply = objc_getAssociatedObject(nativeScrollView, &kNFBInlineColumnsAppliedKey) == nil;
    nfb_rememberInlineColumnsOriginals(nativeScrollView);
    if (firstColumnsApply) objc_setAssociatedObject(nativeScrollView, &kNFBColumnsEmptyReloadCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nativeScrollView.pagingEnabled = NO;
    nativeScrollView.alwaysBounceHorizontal = YES;
    // The horizontal indicator floated mid-screen (big bottom inset) and looked like a stray bar; the
    // side-by-side columns already make horizontal scrollability obvious, so hide it.
    nativeScrollView.showsHorizontalScrollIndicator = NO;
    nativeScrollView.clipsToBounds = YES;
    // b56: directionalLock is decided PER GESTURE in the gestureRecognizerShouldBegin hook (clearly
    // vertical start = locked so the inner timeline scrolls; any horizontal component = unlocked so
    // the columns track the finger). Re-asserting YES here every pass re-locked a drag mid-gesture.
    nfb_updateColumnsEdgeMenuGesturesForScroll(nativeScrollView);
    // Always pin OUR column contentSize. Store the target before setting it because the
    // TFNPagingScrollView hook also sees this assignment.
    NSUInteger columnCount = layoutEntries.count + (searchColumnVC ? 1 : 0);
    CGFloat targetContentWidth = nfb_columnsContentWidth(columnWidth, columnCount, bounds.size.width);
    objc_setAssociatedObject(nativeScrollView, &kNFBInlineColumnsTargetContentWidthKey, @(targetContentWidth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!columnsScrollDragging || fabs(nativeScrollView.contentSize.width - targetContentWidth) > 1.0 || fabs(nativeScrollView.contentSize.height - height) > 1.0) {
        nativeScrollView.contentSize = CGSizeMake(targetContentWidth, height);
    }
    if (!columnsScrollDragging) {
        CGFloat maxOffsetX = nfb_columnsMaxOffsetXForScroll(nativeScrollView);
        BOOL resetToFirstColumn = firstColumnsApply || gInlineColumnsNeedsInitialOffsetReset;
        CGFloat targetOffsetX = resetToFirstColumn ? 0.0 : nfb_columnsClampedOffsetX(nativeScrollView.contentOffset.x, maxOffsetX);
        if (fabs(nativeScrollView.contentOffset.x - targetOffsetX) > 1.0) {
            if (gNFBLogRecording) {
                NFBLogEvent([NSString stringWithFormat:@"columnsClamp from=%.1f to=%.1f w=%.1f max=%.1f reset=%d",
                    nativeScrollView.contentOffset.x, targetOffsetX, columnWidth, maxOffsetX, resetToFirstColumn ? 1 : 0]);
            }
            [nativeScrollView setContentOffset:CGPointMake(targetOffsetX, nativeScrollView.contentOffset.y) animated:NO];
        }
        gInlineColumnsNeedsInitialOffsetReset = NO;
        nfb_updateColumnsEdgeMenuGesturesForScroll(nativeScrollView);
    }
    if (host && gColumnsAllTopButton) {
        CGRect hostBounds = host.bounds;
        CGFloat safeTop = host.window ? host.window.safeAreaInsets.top : host.safeAreaInsets.top;
        CGFloat buttonY = MAX(12.0, safeTop + 56.0);
        buttonY = MIN(buttonY, MAX(12.0, hostBounds.size.height - 56.0));
        CGRect allTopFrame = CGRectMake(MAX(12.0, hostBounds.size.width - 128.0), buttonY, 116.0, 34.0);
        if (!CGRectEqualToRect(gColumnsAllTopButton.frame, allTopFrame)) gColumnsAllTopButton.frame = allTopFrame;
        // b56: reordering subviews dirties the host's layout, and doing it unconditionally on every
        // pass was one of the sparks keeping the permanent layout loop alive (layoutPerf busy 56-64%
        // while idle). Reorder only when the button is not already frontmost.
        if (host.subviews.lastObject != gColumnsAllTopButton) [host bringSubviewToFront:gColumnsAllTopButton];
    }

    NSSet<UIViewController *> *pageSet = [NSSet setWithArray:pages];
    for (UIViewController *child in paging.childViewControllers) {
        if (![child isViewLoaded] || !nfb_isTimelinePageController(child)) continue;
        if (![pageSet containsObject:child]) {
            nfb_rememberColumnOriginalViewState(child.view);
            child.view.hidden = YES;
            child.view.alpha = 0.0;
        }
    }

    NSUInteger idx = 0;
    for (NSDictionary *entry in layoutEntries) {
        UIViewController *vc = nfb_columnEntryViewController(entry);
        if (!vc) continue;
        BOOL isTimeline = [entry[@"kind"] isEqualToString:kNFBColumnEntryKindTimeline];
        NSString *columnKey = nfb_columnsKeyForEntry(entry, idx);
        [vc loadViewIfNeeded];
        UIView *columnView = vc.view;
        UIScrollView *appTabScroll = isTimeline ? nil : nfb_mainScrollViewOf(vc);
        if (!isTimeline) {
            UIView *pagingView = paging.viewIfLoaded;
            BOOL containsNativePager = columnView == nativeScrollView ||
                                       nfb_viewContainsDescendant(columnView, nativeScrollView) ||
                                       (pagingView && nfb_viewContainsDescendant(columnView, pagingView));
            if (containsNativePager) {
                NSString *identity = nfb_columnEntryIdentity(entry);
                if (!gNFBColumnsAppTabFailed) gNFBColumnsAppTabFailed = [NSMutableSet set];
                if (identity.length) {
                    [gNFBColumnsAppTabFailed addObject:identity];
                    [gNFBColumnsAppTabControllers removeObjectForKey:identity];
                    if (!gNFBColumnsAppTabReasons) gNFBColumnsAppTabReasons = [NSMutableDictionary dictionary];
                    gNFBColumnsAppTabReasons[identity] = @"cycle guard: tab view contains home pager";
                }
                if (columnView.superview == nativeScrollView) [columnView removeFromSuperview];
                if (gNFBLogRecording) {
                    NFBLogEvent([NSString stringWithFormat:@"appTabColumn[b63] cycleGuard disabled id=%@ vc=%@",
                        identity ?: @"-", NSStringFromClass(vc.class)]);
                }
                idx++;
                continue;
            }
        }
        if (!isTimeline && appTabScroll && appTabScroll.contentSize.width < 1.0 && appTabScroll.contentSize.height < 1.0) {
            NSString *identity = nfb_columnEntryIdentity(entry);
            if (!gNFBColumnsAppTabFailed) gNFBColumnsAppTabFailed = [NSMutableSet set];
            if (identity.length) [gNFBColumnsAppTabFailed addObject:identity];
            [gNFBColumnsAppTabControllers removeObjectForKey:identity];
            if (columnView.superview == nativeScrollView) [columnView removeFromSuperview];
            if (gNFBLogRecording) {
                NFBLogEvent([NSString stringWithFormat:@"appTabColumn[b63] zeroContent disabled id=%@ vc=%@", identity, NSStringFromClass(vc.class)]);
            }
            idx++;
            continue;
        }
        nfb_rememberColumnOriginalViewState(columnView);
        if (columnView.superview != nativeScrollView) [nativeScrollView addSubview:columnView];
        if (isTimeline && vc.parentViewController == nil) {
            [paging addChildViewController:vc];
            [vc didMoveToParentViewController:paging];
            objc_setAssociatedObject(vc, &kNFBColumnsAddedAsChildKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!isTimeline) {
            objc_setAssociatedObject(vc, &kNFBColumnsAppTabColumnKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // b39: do not adopt Twitter app-tab controllers into the Home pager. On device b38
            // reached layout, then crashed while the Guide tab continued loading. These controllers
            // are built for TFNTabbedViewController ownership; using the view only avoids firing a
            // mismatched parent/appearance lifecycle during the loading phase.
        }
        if (columnView.hidden) columnView.hidden = NO;
        if (columnView.alpha < 1.0) columnView.alpha = 1.0;
        CGFloat y = isTimeline ? -topShift : 0.0;
        CGFloat h = isTimeline ? (height + topShift) : height;
        CGRect columnFrame = CGRectMake(columnWidth * idx, y, columnWidth, h);
        CGRect columnBounds = CGRectMake(0.0, 0.0, columnWidth, h);
        // b56: change-gate every mutation. The unconditional setNeedsLayout + layoutIfNeeded
        // re-dirtied each column subtree on EVERY pass, and a freshly dirtied tree schedules the next
        // viewDidLayoutSubviews → the next full pass: a permanent ~7Hz layout loop costing 130-160ms
        // a pass (layoutPerf[b54]: busy 56-64% while completely idle). An idle pass must mutate
        // nothing; Twitter snapping a frame back still reads as drift and gets re-asserted.
        BOOL columnDrifted = !CGRectEqualToRect(columnView.frame, columnFrame) ||
                             !CGRectEqualToRect(columnView.bounds, columnBounds);
        if (columnDrifted) {
            columnView.frame = columnFrame;
            columnView.bounds = columnBounds;
        }
        if (!columnView.clipsToBounds) columnView.clipsToBounds = YES;
        UIViewAutoresizing columnMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
        if (columnView.autoresizingMask != columnMask) columnView.autoresizingMask = columnMask;
        nfb_columnsAssociateColumnView(columnView, vc, columnKey, idx);
        if (!isTimeline && [vc isKindOfClass:UINavigationController.class]) {
            objc_setAssociatedObject(vc, &kNFBColumnsColumnIdentityKey, columnKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (columnDrifted) {
            [columnView setNeedsLayout];
            // b58: during a live window resize EVERY pass drifts EVERY column, and forcing a
            // synchronous full-table layout here is what made resize passes cost 260-300ms
            // (b57 device layoutPerf: busy 78-91% through a resize). Let UIKit batch the drifted
            // columns into its own pass during the transition; outside of resizes the immediate
            // layout keeps column taps and snaps crisp.
            if (!columnsScrollDragging && isTimeline && !gNFBColumnsSizeTransitioning) [columnView layoutIfNeeded];
        }
        if (isTimeline) {
            nfb_adjustColumnScrollForPage(vc, columnView);
            if (!columnsScrollDragging) nfb_kickEmptyColumnLoad(vc);
        } else if (gNFBLogRecording) {
            // b56: dedup per app-tab identity. One shared "last key" never matched with 3 tabs
            // cycling through it, so every pass logged all three lines (pure spam at the loop rate).
            static NSMutableDictionary<NSString *, NSString *> *lastAppTabLayoutKeys = nil;
            if (!lastAppTabLayoutKeys) lastAppTabLayoutKeys = [NSMutableDictionary dictionary];
            UIScrollView *sv = appTabScroll ?: nfb_mainScrollViewOf(vc);
            NSString *identity = nfb_columnEntryIdentity(entry) ?: @"-";
            NSString *key = [NSString stringWithFormat:@"appTabColumn[b63] layout id=%@ vc=%@ x=%.0f w=%.0f content=%.0fx%.0f text=%@",
                identity, NSStringFromClass(vc.class), columnWidth * idx, columnWidth,
                sv ? sv.contentSize.width : 0.0, sv ? sv.contentSize.height : 0.0,
                nfb_diagTextForView(columnView, 64) ?: @"-"];
            if (![key isEqualToString:lastAppTabLayoutKeys[identity]]) { lastAppTabLayoutKeys[identity] = [key copy]; NFBLogEvent(key); }
        }
        nfb_columnsLayoutDetailNavForKey(columnKey, CGRectMake(columnWidth * idx, 0.0, columnWidth, height), nativeScrollView);
        idx++;
    }

    // Legacy fallback only. b37 sources Search/Explore from the compact app-tab Guide VC instead of
    // transplanting the wide app-split trends/search sidebar.
    if (searchColumnVC && [searchColumnVC isViewLoaded] && searchColumnVC.view) {
        UIView *searchView = searchColumnVC.view;
        UIView *secondaryHost = (searchView.superview != nativeScrollView) ? nfb_enclosingAppSplitHostView(searchView) : nil;
        nfb_rememberColumnOriginalViewState(searchView);
        gNFBColumnsSearchColumnView = searchView;
        gNFBColumnsSearchColumnController = searchColumnVC;
        if (searchView.superview != nativeScrollView) [nativeScrollView addSubview:searchView];
        if (secondaryHost) {
            nfb_rememberColumnOriginalViewState(secondaryHost);
            gNFBColumnsSecondaryHostView = secondaryHost;
        }
        UIView *hiddenHost = gNFBColumnsSecondaryHostView;
        if (hiddenHost) {
            hiddenHost.hidden = YES;
            hiddenHost.alpha = 0.0;
        }
        searchView.hidden = NO;
        searchView.alpha = 1.0;
        searchView.frame = CGRectMake(columnWidth * layoutEntries.count, 0.0, columnWidth, height);
        searchView.bounds = CGRectMake(0.0, 0.0, columnWidth, height);
        searchView.clipsToBounds = YES;
        searchView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        nfb_fitSearchColumnSubviewTree(searchView, columnWidth, height, 0);
        [searchView setNeedsLayout];
        if (!columnsScrollDragging) [searchView layoutIfNeeded];
        if (gNFBLogRecording) {
            static NSString *lastSearchColKey = nil;
            UIScrollView *searchScroll = nfb_mainScrollViewOf(searchColumnVC);
            NSString *text = nfb_diagTextForView(searchView, 72);
            NSString *k = [NSString stringWithFormat:@"searchColumn[b63] vc=%@ x=%.0f w=%.0f h=%.0f scroll=%@ content=%.0fx%.0f text=%@",
                NSStringFromClass(searchColumnVC.class), columnWidth * layoutEntries.count, columnWidth, height,
                searchScroll ? NSStringFromClass(searchScroll.class) : @"nil",
                searchScroll ? searchScroll.contentSize.width : 0.0,
                searchScroll ? searchScroll.contentSize.height : 0.0,
                text ?: @"-"];
            if (![k isEqualToString:lastSearchColKey]) { lastSearchColKey = [k copy]; NFBLogEvent(k); }
        }

    }
    // On iPad the pager only loads the current page, so the off-screen pinned-list columns stay
    // empty (contentSize.height==0 → blank columns = "only 1 column"). Keep nudging the pager to
    // load its invisible pages (throttled) until every column has content.
    {
        BOOL anyEmpty = NO;
        for (UIViewController *p in pages) {
            UIScrollView *s = [p isViewLoaded] ? nfb_mainScrollViewOf(p) : nil;
            if (s && s.contentSize.height < 60.0) { anyEmpty = YES; break; }
        }
        if (anyEmpty) {
            static NSTimeInterval lastEmptyReload = 0.0;
            NSTimeInterval now = CACurrentMediaTime();
            NSNumber *reloadCountNumber = objc_getAssociatedObject(nativeScrollView, &kNFBColumnsEmptyReloadCountKey);
            NSInteger reloadCount = reloadCountNumber ? reloadCountNumber.integerValue : 0;
            if (!columnsScrollDragging && reloadCount < 3 && now - lastEmptyReload > 1.0) {
                lastEmptyReload = now;
                objc_setAssociatedObject(nativeScrollView, &kNFBColumnsEmptyReloadCountKey, @(reloadCount + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                nfb_requestColumnsPagingPreload(paging, NO);
            }
        } else {
            objc_setAssociatedObject(nativeScrollView, &kNFBColumnsEmptyReloadCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    // Record the columns layout state (only when it CHANGES) so UI breakage / scroll catching is
    // visible in the recorded log: column frames flipping or contentSize flapping mid-drag = Twitter's
    // paging layout fighting ours. The live offset is logged for context but excluded from the
    // change-key, so plain scrolling doesn't flood the log.
    if (gNFBLogRecording) {
        BOOL drag = nativeScrollView.isDragging || nativeScrollView.isTracking || nativeScrollView.isDecelerating;
        CGFloat maxOffsetX = nfb_columnsMaxOffsetXForScroll(nativeScrollView);
        CGFloat snapOffsetX = nfb_columnsSnappedOffsetX(nativeScrollView.contentOffset.x, columnWidth, maxOffsetX);
        NSMutableString *key = [NSMutableString stringWithFormat:@"entries=%lu pages=%lu w=%.0f top=%.0f drag=%d content=%.0f max=%.0f snap=%.0f hframe=(%.0f,%.0f,%.0f,%.0f)", (unsigned long)layoutEntries.count, (unsigned long)pages.count, columnWidth, topShift, drag ? 1 : 0, nativeScrollView.contentSize.width, maxOffsetX, snapOffsetX, nativeScrollView.frame.origin.x, nativeScrollView.frame.origin.y, nativeScrollView.frame.size.width, nativeScrollView.frame.size.height];
        NSUInteger ci = 0;
        for (UIViewController *p in pages) {
            if ([p isViewLoaded]) { CGRect f = p.view.frame; [key appendFormat:@" c%lu=(%.0f,%.0f,%.0f,%.0f)", (unsigned long)ci, f.origin.x, f.origin.y, f.size.width, f.size.height]; }
            ci++;
        }
        static NSString *lastLayoutKey = nil;
        if (![key isEqualToString:lastLayoutKey]) {
            lastLayoutKey = [key copy];
            NFBLogEvent([NSString stringWithFormat:@"layout[b63] %@ off=%.0f extRemoved=%d", key, nativeScrollView.contentOffset.x, gNFBExtendedContentRemoved ? 1 : 0]);
        }
    }
    nfb_setColumnsSegmentedHiddenForPaging(paging, YES);
}

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

static NSInteger nfb_estimatedHomePagingPageCount(UIViewController *paging) {
    id dataSource = nfb_pagingDataSource(paging);
    SEL sectionsSel = @selector(numberOfSectionsInPagingViewController:);
    SEL pagesSel = @selector(pagingViewController:numberOfPagesInSection:);
    if (dataSource && [dataSource respondsToSelector:sectionsSel] && [dataSource respondsToSelector:pagesSel]) {
        NSInteger sections = ((NSInteger(*)(id, SEL, id))objc_msgSend)(dataSource, sectionsSel, paging);
        NSInteger total = 0;
        for (NSInteger section = 0; section < sections; section++) {
            total += ((NSInteger(*)(id, SEL, id, NSInteger))objc_msgSend)(dataSource, pagesSel, paging, section);
        }
        if (total > 0) return total;
    }
    UIScrollView *h = nfb_horizontalPagingScrollViewOf(paging);
    if (h && h.bounds.size.width > 100.0 && h.contentSize.width > h.bounds.size.width) {
        return MAX(1, (NSInteger)llround(h.contentSize.width / h.bounds.size.width));
    }
    return MAX(1, (NSInteger)paging.childViewControllers.count);
}

static void nfb_requestColumnsPagingPreload(UIViewController *paging, BOOL aggressive) {
    if (!paging) return;
    static NSTimeInterval lastAggressivePreloadRequest = 0.0;
    static NSTimeInterval lastLightPreloadRequest = 0.0;
    NSTimeInterval now = CACurrentMediaTime();
    if (aggressive) {
        if (now - lastAggressivePreloadRequest < 1.20) return;
        lastAggressivePreloadRequest = now;
    } else {
        if (now - lastLightPreloadRequest < 2.50) return;
        lastLightPreloadRequest = now;
    }
    NFBLogEvent([NSString stringWithFormat:@"columnsPreload mode=%@ paging=%@",
        aggressive ? @"aggressive" : @"light",
        paging ? NSStringFromClass(paging.class) : @"nil"]);
    UIViewController *segmented = nfb_parentControllerNamed(paging, @"Segmented");
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (aggressive && container && [container respondsToSelector:@selector(loadInitialPinnedTimelines)]) {
        ((void(*)(id, SEL))objc_msgSend)(container, @selector(loadInitialPinnedTimelines));
    }
    if (aggressive) {
        for (NSString *name in @[@"_t1_reloadContentViewControllerContentsWhenContentReady",
                                 @"_t1_reloadContentViewControllerContents"]) {
            SEL sel = NSSelectorFromString(name);
            if (container && [container respondsToSelector:sel]) {
                ((void(*)(id, SEL))objc_msgSend)(container, sel);
            }
        }
    }
    if (segmented && [segmented respondsToSelector:@selector(setPreloadContent:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(segmented, @selector(setPreloadContent:), YES);
    }
    NSArray<NSString *> *segmentedSelectors = aggressive
        ? @[@"preloadContent", @"reloadLabelBarData", @"_tfn_reloadViewControllerDataIfNeeded", @"reloadViewControllerData"]
        : @[@"preloadContent"];
    for (NSString *name in segmentedSelectors) {
        SEL sel = NSSelectorFromString(name);
        if (segmented && [segmented respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(segmented, sel);
        }
    }
    if ([paging respondsToSelector:@selector(setPreloadPolicy:)]) {
        // Required for pinned-list pages that have not been opened manually; without this the
        // off-screen columns can remain loaded but empty.
        ((void(*)(id, SEL, NSInteger))objc_msgSend)(paging, @selector(setPreloadPolicy:), 2);
    }
    NSArray<NSString *> *pagingSelectors = aggressive
        ? @[@"reloadInvisibleViewControllers", @"reloadVisibleViewControllers", @"reloadViewControllers"]
        : @[@"reloadInvisibleViewControllers"];
    for (NSString *name in pagingSelectors) {
        SEL sel = NSSelectorFromString(name);
        if ([paging respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(paging, sel);
        }
    }
}

static id nfb_pagingDataSource(UIViewController *paging) {
    if (!paging) return nil;
    SEL sel = @selector(dataSource);
    if ([paging respondsToSelector:sel]) return ((id(*)(id, SEL))objc_msgSend)(paging, sel);
    @try {
        return [paging valueForKey:@"dataSource"];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging) {
    if (!paging) return nil;
    SEL sel = @selector(selectedIndexPath);
    if ([paging respondsToSelector:sel]) {
        id value = ((id(*)(id, SEL))objc_msgSend)(paging, sel);
        if ([value isKindOfClass:NSIndexPath.class]) return (NSIndexPath *)value;
    }
    @try {
        id value = [paging valueForKey:@"selectedIndexPath"];
        if ([value isKindOfClass:NSIndexPath.class]) return (NSIndexPath *)value;
    } @catch (NSException *e) {
    }
    return nil;
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

static UIViewController *nfb_findHomePagingControllerInTree(UIViewController *root, int depth) {
    if (!root || depth > 14) return nil;
    if ([NSStringFromClass(root.class) containsString:@"Paging"] && nfb_isHomePagingController(root)) return root;
    UIViewController *presented = nfb_findHomePagingControllerInTree(root.presentedViewController, depth + 1);
    if (presented) return presented;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = nfb_findHomePagingControllerInTree(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL nfb_homePagingControllerIsVisible(UIViewController *paging) {
    return paging && [paging isViewLoaded] && paging.view.window &&
           !paging.view.hidden && paging.view.alpha > 0.01;
}

static UIViewController *nfb_findAnyHomePagingController(void) {
    UIViewController *active = gActiveItemsVC;
    UIViewController *paging = active ? nfb_parentControllerNamed(active, @"Paging") : nil;
    if (paging) return paging;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *found = nfb_findHomePagingControllerInTree(window.rootViewController, 0);
        if (found) return found;
    }
    return nil;
}

static UIViewController *nfb_findVisibleHomePagingController(void) {
    UIViewController *active = gActiveItemsVC;
    UIViewController *paging = active ? nfb_parentControllerNamed(active, @"Paging") : nil;
    if (nfb_homePagingControllerIsVisible(paging)) return paging;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *found = nfb_findHomePagingControllerInTree(window.rootViewController, 0);
        if (nfb_homePagingControllerIsVisible(found)) return found;
    }
    return nil;
}

static void nfb_rememberInlineColumnsOriginals(UIScrollView *scrollView) {
    if (objc_getAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey)) return;
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsPagingKey, @(scrollView.pagingEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsBounceHKey, @(scrollView.alwaysBounceHorizontal), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsIndicatorKey, @(scrollView.showsHorizontalScrollIndicator), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsClipsKey, @(scrollView.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsDirectionalLockKey, @(scrollView.directionalLockEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsContentSizeKey, [NSValue valueWithCGSize:scrollView.contentSize], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_restoreInlineColumns(UIViewController *paging) {
    nfb_columnsApplyNativeSplitTierForPaging(paging, NO);
    // Issue B (Codex): restore the iPad extended-content rail FIRST, before any early return, and via
    // the stored split so it does not depend on paging being a resolvable home pager — otherwise the
    // rail could be left permanently removed when restore is reached through a short-circuit path.
    gNFBExtRemoveScheduled = NO;
    nfb_columnsSetExtendedContentRemoved(paging, NO);
    // Issue C + B: restore the logo/nav bar and the primary-width constraint, reset the full-width
    // latch. Done before any early return so columns-off always undoes them.
    nfb_restoreColumnsLogoBar();
    {
        UIScrollView *sv = nfb_horizontalPagingScrollViewOf(paging);
        UIView *primaryHost = sv ? nfb_enclosingAppSplitHostView((UIView *)sv) : nil;
        if (primaryHost) nfb_columnsRestorePrimaryWidth(primaryHost);
    }
    gNFBFullWidthLatched = NO;
    gNFBFullWidthApplyCount = 0;
    gNFBFWChainLatched = NO;
    gNFBFWChainCount = 0;
    // Legacy width latches are cleared here; b36 restores the native split tier above.
    for (UIViewController *tabVC in gNFBColumnsAppTabControllers.allValues) {
        if (!tabVC) continue;
        if (paging) { @try { [paging setOverrideTraitCollection:nil forChildViewController:tabVC]; } @catch (NSException *e) {} }
        if (tabVC.parentViewController) {
            [tabVC willMoveToParentViewController:nil];
            [tabVC removeFromParentViewController];
        }
        [tabVC.view removeFromSuperview];
        objc_setAssociatedObject(tabVC, &kNFBColumnsAddedAsChildKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tabVC, &kNFBColumnsAppTabColumnKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!nfb_isHomePagingController(paging) || ![paging isViewLoaded]) return;
    nfb_removeColumnsOverlay();
    nfb_setColumnsSegmentedHiddenForPaging(paging, NO);
    UIScrollView *scrollView = nfb_horizontalPagingScrollViewOf(paging);
    if (!scrollView) return;

    BOOL wasApplied = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey) != nil;
    if (!wasApplied) return;

    // (extended-content rail already restored at the top of this function, before early returns)
    for (UIViewController *tabVC in gNFBColumnsAppTabControllers.allValues) {
        if (!tabVC) continue;
        @try { [paging setOverrideTraitCollection:nil forChildViewController:tabVC]; } @catch (NSException *e) {}
        if (tabVC.parentViewController == paging) {
            [tabVC willMoveToParentViewController:nil];
            [tabVC removeFromParentViewController];
        }
        [tabVC.view removeFromSuperview];
        objc_setAssociatedObject(tabVC, &kNFBColumnsAddedAsChildKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tabVC, &kNFBColumnsAppTabColumnKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Detach the borrowed guide (we own it) from the paging controller + remove its view; keep the
    // cached instance for reuse on the next columns-open. Reset the content-ready latch so it re-proves
    // itself (the view tree is torn down on detach).
    UIViewController *guideHost = gNFBColumnsGuideHost;
    if (guideHost) {
        if (guideHost.parentViewController) {
            [guideHost willMoveToParentViewController:nil];
            [guideHost removeFromParentViewController];
        }
        [guideHost.view removeFromSuperview];
    }
    gNFBColumnsGuideContentReady = NO;
    // Return the transplanted iPad search column to its app-split secondary pane.
    UIView *searchColumnView = gNFBColumnsSearchColumnView;
    if (searchColumnView) {
        nfb_restoreColumnOriginalViewState(searchColumnView);
        gNFBColumnsSearchColumnView = nil;
    }
    gNFBColumnsSearchColumnController = nil;
    UIView *secondaryHostView = gNFBColumnsSecondaryHostView;
    if (secondaryHostView) {
        nfb_restoreColumnOriginalViewState(secondaryHostView);
        gNFBColumnsSecondaryHostView = nil;
    }
    NSArray<UIView *> *splitViews = gNFBColumnsSuppressedSplitViews;
    for (UIView *view in splitViews) {
        nfb_restoreColumnOriginalViewState(view);
    }
    gNFBColumnsSuppressedSplitViews = nil;
    NSArray<UIView *> *expandedViews = gNFBColumnsExpandedWidthViews;
    for (UIView *view in expandedViews) {
        nfb_restoreColumnOriginalViewState(view);
    }
    gNFBColumnsExpandedWidthViews = nil;
    // Reset the width-expand oscillation latch so the next columns-on re-flows to full width.
    gNFBColumnsExpandLatched = NO;
    gNFBColumnsExpandStableGapCount = 0;
    gNFBColumnsExpandLastGap = -1.0;

    NSNumber *pagingEnabled = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsPagingKey);
    NSNumber *bounceH = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsBounceHKey);
    NSNumber *indicator = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsIndicatorKey);
    NSNumber *clips = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsClipsKey);
    NSNumber *directionalLock = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsDirectionalLockKey);
    NSValue *contentSize = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsContentSizeKey);

    if (pagingEnabled) scrollView.pagingEnabled = pagingEnabled.boolValue;
    if (bounceH) scrollView.alwaysBounceHorizontal = bounceH.boolValue;
    if (indicator) scrollView.showsHorizontalScrollIndicator = indicator.boolValue;
    if (clips) scrollView.clipsToBounds = clips.boolValue;
    if (directionalLock) scrollView.directionalLockEnabled = directionalLock.boolValue;
    if (contentSize) scrollView.contentSize = contentSize.CGSizeValue;
    if (scrollView.contentOffset.x != 0.0) {
        [scrollView setContentOffset:CGPointMake(0.0, scrollView.contentOffset.y) animated:NO];
    }

    // Do not rely solely on saved frames: if columns were re-entered while Home was off-window, the
    // "original" saved state can already be a 340pt column frame. Rebuild the native paging geometry
    // from the data source so normal Home is full-width again.
    CGFloat pageWidth = scrollView.bounds.size.width;
    CGFloat pageHeight = scrollView.bounds.size.height;
    NSArray<UIViewController *> *allPages = nfb_allHomePagingTimelinePages(paging);
    BOOL needsNativeRestore = wasApplied;
    if (pageWidth > 100.0 && pageHeight > 100.0 && allPages.count) {
        NSUInteger checkIdx = 0;
        for (UIViewController *page in allPages) {
            if ([page isViewLoaded]) {
                CGRect f = page.view.frame;
                if (fabs(f.origin.x - pageWidth * checkIdx) > 1.0 || fabs(f.size.width - pageWidth) > 1.0) {
                    needsNativeRestore = YES;
                    break;
                }
            }
            checkIdx++;
        }
        CGFloat expectedContentWidth = MAX(pageWidth * allPages.count, pageWidth + 1.0);
        if (fabs(scrollView.contentSize.width - expectedContentWidth) > 1.0) needsNativeRestore = YES;
    }

    if (needsNativeRestore && pageWidth > 100.0 && pageHeight > 100.0 && allPages.count) {
        NSUInteger idx = 0;
        for (UIViewController *page in allPages) {
            nfb_restoreColumnScrollAdjustmentForPage(page);
            if ([page isViewLoaded]) {
                UIView *view = page.view;
                if (view.superview != scrollView) [scrollView addSubview:view];
                view.frame = CGRectMake(pageWidth * idx, 0.0, pageWidth, pageHeight);
                view.autoresizingMask = UIViewAutoresizingFlexibleHeight;
                view.alpha = 1.0;
                view.hidden = NO;
                [view setNeedsLayout];
            }
            idx++;
        }
        scrollView.contentSize = CGSizeMake(MAX(pageWidth * allPages.count, pageWidth + 1.0), pageHeight);
        [scrollView setContentOffset:CGPointMake(0.0, scrollView.contentOffset.y) animated:NO];
        [scrollView setNeedsLayout];
        [scrollView layoutIfNeeded];
    } else if (needsNativeRestore) {
        for (UIViewController *child in paging.childViewControllers) {
            nfb_restoreColumnScrollAdjustmentForPage(child);
            if ([child isViewLoaded]) {
                child.view.hidden = NO;
                child.view.alpha = 1.0;
            }
        }
    }

    for (UIViewController *child in [paging.childViewControllers copy]) {
        if (objc_getAssociatedObject(child, &kNFBColumnsAddedAsChildKey)) {
            @try { [paging setOverrideTraitCollection:nil forChildViewController:child]; } @catch (NSException *e) {}
            [child willMoveToParentViewController:nil];
            [child removeFromParentViewController];
            objc_setAssociatedObject(child, &kNFBColumnsAddedAsChildKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(child, &kNFBColumnsAppTabColumnKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsPagingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsBounceHKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsIndicatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsClipsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsDirectionalLockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsContentSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsTargetContentWidthKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBColumnsEmptyReloadCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (needsNativeRestore) {
        for (NSString *name in @[@"reloadVisibleViewControllers", @"reloadVisibleViewControllersForceUnload:", @"reloadViewControllers"]) {
            SEL sel = NSSelectorFromString(name);
            if (![paging respondsToSelector:sel]) continue;
            if ([name hasSuffix:@":"]) ((void(*)(id, SEL, BOOL))objc_msgSend)(paging, sel, NO);
            else ((void(*)(id, SEL))objc_msgSend)(paging, sel);
        }
    }
}

// b54: layout-pass cost telemetry. The columns pass re-runs on every viewDidLayoutSubviews of the
// pager AND the segmented host, so its per-pass cost IS the columns performance number. Aggregate
// and emit one recorded-log line per ~2s window instead of one per pass.
static void nfb_columnsNoteLayoutPassDuration(CFTimeInterval seconds) {
    static CFTimeInterval windowStart = 0.0;
    static CFTimeInterval total = 0.0;
    static CFTimeInterval worst = 0.0;
    static NSInteger passes = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (windowStart <= 0.0) windowStart = now;
    total += seconds;
    passes++;
    if (seconds > worst) worst = seconds;
    if (now - windowStart < 2.0) return;
    if (gNFBLogRecording && passes > 0) {
        NFBLogEvent([NSString stringWithFormat:@"layoutPerf[b63] passes=%ld avg=%.2fms max=%.2fms busy=%.1f%% window=%.1fs",
            (long)passes, total / passes * 1000.0, worst * 1000.0,
            total / (now - windowStart) * 100.0, now - windowStart]);
    }
    windowStart = now; total = 0.0; worst = 0.0; passes = 0;
}

static void nfb_applyInlineColumns(UIViewController *paging) {
    if (!nfb_inlineColumnsActiveForHomePaging(paging) || ![paging isViewLoaded]) return;
    if (!nfb_homePagingControllerIsVisible(paging)) return;
    CFTimeInterval t0 = CACurrentMediaTime();
    nfb_layoutColumnsOverlayForPaging(paging);
    nfb_columnsNoteLayoutPassDuration(CACurrentMediaTime() - t0);
}

static NSArray<UIViewController *> *nfb_allHomePagingTimelinePages(UIViewController *paging) {
    if (!paging || ![paging isViewLoaded]) return @[];
    NSMutableArray<UIViewController *> *pages = [NSMutableArray array];
    id dataSource = nfb_pagingDataSource(paging);
    SEL sectionsSel = @selector(numberOfSectionsInPagingViewController:);
    SEL pagesSel = @selector(pagingViewController:numberOfPagesInSection:);
    if (dataSource && [dataSource respondsToSelector:sectionsSel] && [dataSource respondsToSelector:pagesSel]) {
        NSInteger sections = ((NSInteger(*)(id, SEL, id))objc_msgSend)(dataSource, sectionsSel, paging);
        for (NSInteger section = 0; section < sections; section++) {
            NSInteger count = ((NSInteger(*)(id, SEL, id, NSInteger))objc_msgSend)(dataSource, pagesSel, paging, section);
            for (NSInteger item = 0; item < count; item++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForItem:item inSection:section];
                UIViewController *page = nfb_pagingViewControllerAtIndexPath(paging, indexPath);
                if (!nfb_isTimelinePageController(page) || [pages containsObject:page]) continue;
                [pages addObject:page];
            }
        }
    }
    for (UIViewController *child in paging.childViewControllers) {
        if (!nfb_isTimelinePageController(child)) continue;
        if (![pages containsObject:child]) [pages addObject:child];
    }
    return pages;
}

// === Column management (reorder / show-hide / persist) ===========================================
// Layered over the pager's natural page order. State persists in NSUserDefaults keyed by the stable
// column identity (nfb_columnTimelineIdentity). The crash path is never touched: this only changes
// WHICH live pages and in WHAT order nfb_currentColumnTimelinePages returns; the layout/transplant is
// unchanged. A hidden-everything state is impossible (the toggle UI refuses the last visible column,
// and nfb_currentColumnTimelinePages ignores the hidden set if it would empty the result).
static NSString *nfb_columnEntryIdentity(NSDictionary *entry) {
    id value = entry[@"id"];
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSString *nfb_columnEntryTitle(NSDictionary *entry) {
    id value = entry[@"title"];
    return [value isKindOfClass:NSString.class] && [value length] ? (NSString *)value : nfb_columnEntryIdentity(entry);
}

static UIViewController *nfb_columnEntryViewController(NSDictionary *entry) {
    id value = entry[@"vc"];
    return [value isKindOfClass:UIViewController.class] ? (UIViewController *)value : nil;
}

// b54: the order/hidden/enabled-tabs prefs are read on EVERY columns layout pass — and the hidden
// checks re-read them once PER ENTRY — so a single pass hit NSUserDefaults many times at layout
// cadence. Only this file writes these keys, so cache each read and invalidate all three caches via
// one generation counter bumped by the writers (all main-thread UI paths).
static NSInteger gNFBColumnsPrefsGen = 1;
static void nfb_columnsPrefsDidChange(void) { gNFBColumnsPrefsGen++; }

static NSArray *nfb_columnsEnabledTabsSavedArray(void) {
    static id cache = nil;
    static NSInteger cacheGen = 0;
    if (cacheGen != gNFBColumnsPrefsGen) {
        cache = [NSUserDefaults.standardUserDefaults objectForKey:kNFBColumnsEnabledTabsKey];
        cacheGen = gNFBColumnsPrefsGen;
    }
    return [cache isKindOfClass:NSArray.class] ? cache : nil;
}

static NSArray<NSString *> *nfb_columnsSavedOrder(void) {
    static NSArray<NSString *> *cache = nil;
    static NSInteger cacheGen = 0;
    if (cacheGen != gNFBColumnsPrefsGen) {
        NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:kNFBColumnsOrderKey];
        cache = [a isKindOfClass:NSArray.class] ? [a copy] : @[];
        cacheGen = gNFBColumnsPrefsGen;
    }
    return cache;
}

static void nfb_columnsSetOrder(NSArray<NSString *> *order) {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *identity in order) {
        if ([identity isKindOfClass:NSString.class] && identity.length && ![clean containsObject:identity]) {
            [clean addObject:identity];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:clean forKey:kNFBColumnsOrderKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    nfb_columnsPrefsDidChange();
}

static NSSet<NSString *> *nfb_columnsHiddenSet(void) {
    static NSSet<NSString *> *cache = nil;
    static NSInteger cacheGen = 0;
    if (cacheGen != gNFBColumnsPrefsGen) {
        NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:kNFBColumnsHiddenKey];
        cache = [a isKindOfClass:NSArray.class] ? [NSSet setWithArray:a] : [NSSet set];
        cacheGen = gNFBColumnsPrefsGen;
    }
    return cache;
}

static BOOL nfb_columnsSavedTabIdentityMatches(NSString *saved, NSString *identity, BOOL allowLegacyPrefix) {
    if (![saved isKindOfClass:NSString.class] || ![identity isKindOfClass:NSString.class] || !identity.length) return NO;
    if ([saved isEqualToString:identity]) return YES;
    return allowLegacyPrefix && [saved hasPrefix:[identity stringByAppendingString:@"|"]];
}

static NSMutableSet<NSString *> *nfb_columnsEnabledTabSetWithDefaults(void) {
    NSArray *saved = nfb_columnsEnabledTabsSavedArray();
    if (saved) return [NSMutableSet setWithArray:saved];
    NSMutableSet<NSString *> *defaults = [NSMutableSet set];
    for (NSDictionary *entry in nfb_allColumnEntriesForManagement()) {
        if (![entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) continue;
        if ([entry[@"defaultVisible"] boolValue]) {
            NSString *identity = nfb_columnEntryIdentity(entry);
            if (identity.length) [defaults addObject:identity];
        }
    }
    return defaults;
}

static BOOL nfb_columnEntryIsHidden(NSDictionary *entry) {
    NSString *identity = nfb_columnEntryIdentity(entry);
    if (!identity.length) return YES;
    if ([entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) {
        NSArray *saved = nfb_columnsEnabledTabsSavedArray();
        if (!saved) return ![entry[@"defaultVisible"] boolValue];
        BOOL allowLegacyPrefix = [entry[@"defaultVisible"] boolValue];
        for (NSString *savedIdentity in saved) {
            if (nfb_columnsSavedTabIdentityMatches(savedIdentity, identity, allowLegacyPrefix)) return NO;
        }
        return YES;
    }
    return [nfb_columnsHiddenSet() containsObject:identity];
}

static void nfb_columnEntrySetHidden(NSDictionary *entry, BOOL hidden) {
    NSString *identity = nfb_columnEntryIdentity(entry);
    if (!identity.length) return;
    if ([entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) {
        NSMutableSet<NSString *> *enabled = nfb_columnsEnabledTabSetWithDefaults();
        NSMutableSet<NSString *> *stale = [NSMutableSet set];
        for (NSString *savedIdentity in enabled) {
            if (nfb_columnsSavedTabIdentityMatches(savedIdentity, identity, YES)) [stale addObject:savedIdentity];
        }
        [enabled minusSet:stale];
        if (hidden) [enabled removeObject:identity];
        else [enabled addObject:identity];
        [NSUserDefaults.standardUserDefaults setObject:enabled.allObjects forKey:kNFBColumnsEnabledTabsKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        nfb_columnsPrefsDidChange();
        return;
    }
    nfb_columnsSetHidden(identity, hidden);
}

static void nfb_columnsSetHidden(NSString *identity, BOOL hidden) {
    if (!identity.length) return;
    NSMutableArray *a = [[NSUserDefaults.standardUserDefaults arrayForKey:kNFBColumnsHiddenKey] mutableCopy] ?: [NSMutableArray array];
    [a removeObject:identity];
    if (hidden) [a addObject:identity];
    [NSUserDefaults.standardUserDefaults setObject:a forKey:kNFBColumnsHiddenKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    nfb_columnsPrefsDidChange();
}
// Reorder by delta within the supplied current display order, then persist the full order so new
// (not-yet-seen) lists keep falling to the natural tail until the user moves them.
static void nfb_columnsMove(NSString *identity, NSInteger delta, NSArray<NSString *> *currentOrderIdentities) {
    if (!identity.length || !currentOrderIdentities.count) return;
    NSMutableArray *order = [currentOrderIdentities mutableCopy];
    NSUInteger idx = [order indexOfObject:identity];
    if (idx == NSNotFound) return;
    NSInteger target = (NSInteger)idx + delta;
    if (target < 0 || target >= (NSInteger)order.count) return;
    [order removeObjectAtIndex:idx];
    [order insertObject:identity atIndex:(NSUInteger)target];
    [NSUserDefaults.standardUserDefaults setObject:order forKey:kNFBColumnsOrderKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    nfb_columnsPrefsDidChange();
}

static NSArray<NSDictionary *> *nfb_columnsApplyEntryOrder(NSArray<NSDictionary *> *entries) {
    NSArray<NSString *> *order = nfb_columnsSavedOrder();
    if (!order.count) return entries;
    NSMutableArray<NSDictionary *> *remaining = [entries mutableCopy];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *identity in order) {
        NSUInteger matchIndex = NSNotFound;
        for (NSUInteger i = 0; i < remaining.count; i++) {
            if ([nfb_columnEntryIdentity(remaining[i]) isEqualToString:identity]) { matchIndex = i; break; }
        }
        if (matchIndex != NSNotFound) {
            [result addObject:remaining[matchIndex]];
            [remaining removeObjectAtIndex:matchIndex];
        }
    }
    [result addObjectsFromArray:remaining];
    return result;
}

static UIViewController *nfb_columnsTabbedControllerForPaging(UIViewController *paging) {
    UIViewController *tabbed = paging;
    for (int i = 0; i < 14 && tabbed; i++, tabbed = tabbed.parentViewController) {
        if ([NSStringFromClass(tabbed.class) isEqualToString:@"TFNTabbedViewController"]) return tabbed;
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *found = nfb_findVCByClassSubstring(window.rootViewController, @"TFNTabbedViewController", 0);
        if (found) return found;
    }
    return nil;
}

static id nfb_columnsTabbedDataSource(UIViewController *tabbed) {
    if (!tabbed) return nil;
    SEL dsGetter = @selector(dataSource);
    if ([tabbed respondsToSelector:dsGetter]) {
        id ds = ((id (*)(id, SEL))objc_msgSend)(tabbed, dsGetter);
        if (ds) return ds;
    }
    @try { return [tabbed valueForKey:@"dataSource"]; } @catch (NSException *e) { return nil; }
}

static NSString *nfb_columnsTabHintForController(UIViewController *vc) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    nfb_appendControllerIdentity(parts, vc, 0);
    return [parts componentsJoinedByString:@"|"];
}

static BOOL nfb_columnsControllerLooksSearchTab(UIViewController *vc, NSString *hint) {
    if (nfb_guideWithin(vc, 0)) return YES;
    NSString *cls = vc ? NSStringFromClass(vc.class).lowercaseString : @"";
    if ([cls containsString:@"guide"] || [cls containsString:@"explore"] || [cls containsString:@"discover"]) return YES;
    NSString *low = (hint ?: @"").lowercaseString;
    return [low containsString:@"guidecontainerviewcontroller"] ||
           [low containsString:@"guidecontainer"] ||
           [low containsString:@"explore"] ||
           [low containsString:@"discover"];
}

static BOOL nfb_columnsControllerLooksNotificationTab(UIViewController *vc, NSString *hint) {
    NSString *cls = vc ? NSStringFromClass(vc.class).lowercaseString : @"";
    NSString *low = (hint ?: @"").lowercaseString;
    return [cls containsString:@"notification"] || [low containsString:@"notification"];
}

static BOOL nfb_searchOrExplorePageSelected(void) {
    NSString *page = nfb_currentSelectedTabPage();
    NSString *low = page.lowercaseString;
    return [low containsString:@"search"] ||
           [low containsString:@"explore"] ||
           [low containsString:@"guide"];
}

static BOOL nfb_searchAppTabLooksLatestTimeline(UIViewController *tabVC, NSString *hint) {
    if (!tabVC || ![tabVC isViewLoaded]) return NO;
    NSString *selectedText = nfb_selectedTextInView(tabVC.view, 0);
    if (nfb_textLooksTopicSearchTab(selectedText)) return NO;
    if (nfb_textLooksLatestSearchTab(selectedText)) return YES;

    NSString *hintText = hint ?: @"";
    if (nfb_textLooksTopicSearchTab(hintText)) return NO;
    if (nfb_textLooksLatestSearchTab(hintText)) return YES;

    NSString *viewText = nfb_diagTextForView(tabVC.view, 240) ?: @"";
    if (nfb_textLooksTopicSearchTab(viewText)) return NO;
    if (nfb_textLooksLatestSearchTab(viewText)) return YES;
    return NO;
}

static BOOL nfb_notificationAppTabLooksTweetTimeline(UIViewController *tabVC, NSString *hint) {
    if (!tabVC || ![tabVC isViewLoaded]) return NO;
    if (nfb_textLooksNotificationTweetTimeline(hint)) return YES;
    NSString *viewText = nfb_diagTextForView(tabVC.view, 240) ?: @"";
    return nfb_textLooksNotificationTweetTimeline(viewText);
}

static BOOL nfb_appTabAutomationControllerCanRefresh(UIViewController *tabVC, UIViewController *paging, BOOL requireColumnAssociation, BOOL allowNotificationTweetTimeline) {
    if (!tabVC) return NO;
    if (requireColumnAssociation && !objc_getAssociatedObject(tabVC, &kNFBColumnsAppTabColumnKey)) return NO;
    NSString *hint = nfb_columnsTabHintForController(tabVC);
    BOOL isSearch = nfb_columnsControllerLooksSearchTab(tabVC, hint);
    BOOL isNotification = nfb_columnsControllerLooksNotificationTab(tabVC, hint);
    if (isSearch) {
        if (!nfb_searchAppTabLooksLatestTimeline(tabVC, hint)) return NO;
    } else if (allowNotificationTweetTimeline && isNotification) {
        if (!nfb_notificationAppTabLooksTweetTimeline(tabVC, hint)) return NO;
    } else {
        return NO;
    }
    if (![tabVC isViewLoaded] || !tabVC.view.window || tabVC.view.hidden || tabVC.view.alpha < 0.01) return NO;
    UIScrollView *sv = nfb_mainScrollViewOf(tabVC);
    if (!sv || !sv.window || sv.bounds.size.height < 100.0 || sv.contentSize.height < 60.0) return NO;
    UIScrollView *nativeScroll = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    UIView *pagingView = paging.viewIfLoaded;
    if (nativeScroll && nfb_viewContainsDescendant(tabVC.view, nativeScroll)) return NO;
    if (pagingView && nfb_viewContainsDescendant(tabVC.view, pagingView)) return NO;
    return YES;
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
    BOOL directSearchController = [cls containsString:@"guide"] ||
                                  [cls containsString:@"search"] ||
                                  [cls containsString:@"explore"] ||
                                  [cls containsString:@"discover"];
    if (directSearchController && nfb_appTabAutomationControllerCanRefresh(root, nil, NO, NO)) return root;
    return nil;
}

static UIViewController *nfb_visibleSearchAutomationController(void) {
    if (gInlineColumnsEnabled || !nfb_searchOrExplorePageSelected()) return nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *root = window.rootViewController;
        while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) root = root.presentedViewController;
        UIViewController *found = nfb_findVisibleSearchAutomationControllerInTree(root, 0);
        if (found) return found;
    }
    return nil;
}

static NSString *nfb_columnsAppTabDisplayName(NSUInteger index, UIViewController *vc, NSString *hint) {
    if (nfb_columnsControllerLooksSearchTab(vc, hint) || index == 1) return nfb_loc(@"NFB_COL_SEARCH_EXPLORE", @"Search / Explore");
    if (vc.title.length) return vc.title;
    if (vc.navigationItem.title.length) return vc.navigationItem.title;
    NSString *low = (hint ?: NSStringFromClass(vc.class)).lowercaseString;
    if ([low containsString:@"notification"]) return nfb_loc(@"NFB_COL_NOTIFICATIONS", @"Notifications");
    if ([low containsString:@"bookmark"]) return nfb_loc(@"NFB_COL_BOOKMARKS", @"Bookmarks");
    if ([low containsString:@"communit"]) return nfb_loc(@"NFB_COL_COMMUNITIES", @"Communities");
    if ([low containsString:@"list"]) return nfb_loc(@"NFB_COL_LISTS", @"Lists");
    if ([low containsString:@"message"] || [low containsString:@"dm"]) return nfb_loc(@"NFB_COL_MESSAGES", @"Messages");
    if ([low containsString:@"profile"]) return nfb_loc(@"NFB_COL_PROFILE", @"Profile");
    if ([low containsString:@"home"]) return nfb_loc(@"NFB_COL_HOME", @"Home");
    NSString *cls = NSStringFromClass(vc.class);
    return cls.length ? cls : [NSString stringWithFormat:nfb_loc(@"NFB_COL_TAB_N", @"Tab %lu"), (unsigned long)(index + 1)];
}

static NSString *nfb_columnsAppTabIdentity(NSUInteger index, UIViewController *vc, NSString *hint) {
    (void)hint;
    NSString *cls = vc ? NSStringFromClass(vc.class) : @"unknown";
    return [NSString stringWithFormat:@"tab|%lu|%@", (unsigned long)index, cls.length ? cls : @"unknown"];
}

static NSArray<NSDictionary *> *nfb_columnsAppTabEntriesForPaging(UIViewController *paging) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return @[];
    UIViewController *tabbed = nfb_columnsTabbedControllerForPaging(paging);
    SEL numSel = @selector(numberOfViewControllers);
    SEL atIdxSel = @selector(viewControllerAtIndex:);
    if (!tabbed || ![tabbed respondsToSelector:numSel] || ![tabbed respondsToSelector:atIdxSel]) return @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger count = 0;
    @try { count = ((NSUInteger (*)(id, SEL))objc_msgSend)((id)tabbed, numSel); } @catch (NSException *e) { count = 0; }
    count = MIN(count, (NSUInteger)16);
    for (NSUInteger i = 0; i < count; i++) {
        UIViewController *vc = nil;
        @try { vc = ((id (*)(id, SEL, NSUInteger))objc_msgSend)((id)tabbed, atIdxSel, i); } @catch (NSException *e) { vc = nil; }
        NSString *hint = nfb_columnsTabHintForController(vc);
        NSString *identity = nfb_columnsAppTabIdentity(i, vc, hint);
        NSString *title = nfb_columnsAppTabDisplayName(i, vc, hint);
        BOOL isSearch = nfb_columnsControllerLooksSearchTab(vc, hint) || i == 1;
        [entries addObject:@{ @"kind": kNFBColumnEntryKindTab,
                              @"id": identity,
                              @"title": title ?: identity,
                              @"index": @(i),
                              @"defaultVisible": @(isSearch) }];
    }
    return entries;
}

static NSArray<NSDictionary *> *nfb_allColumnEntriesForPaging(UIViewController *paging) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (UIViewController *page in nfb_allHomePagingTimelinePages(paging)) {
        if (!nfb_shouldUseTimelinePageAsColumn(page)) continue;
        NSString *identity = nfb_columnTimelineIdentity(page);
        if (!identity.length) continue;
        [entries addObject:@{ @"kind": kNFBColumnEntryKindTimeline,
                              @"id": identity,
                              @"title": nfb_columnDisplayName(page) ?: identity,
                              @"vc": page }];
    }
    [entries addObjectsFromArray:nfb_columnsAppTabEntriesForPaging(paging)];
    return nfb_columnsApplyEntryOrder(entries);
}

static NSArray<NSDictionary *> *nfb_allColumnEntriesForManagement(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    return nfb_allColumnEntriesForPaging(paging);
}

static NSArray<NSDictionary *> *nfb_currentColumnEntriesForPaging(UIViewController *paging) {
    NSArray<NSDictionary *> *all = nfb_allColumnEntriesForPaging(paging);
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    for (NSDictionary *entry in all) {
        if (!nfb_columnEntryIsHidden(entry)) [visible addObject:entry];
    }
    return visible.count ? visible : all;
}

static UIViewController *nfb_columnsAppTabControllerForEntry(NSDictionary *entry, UIViewController *paging) {
    if (![entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) return nil;
    NSString *identity = nfb_columnEntryIdentity(entry);
    if (!identity.length) return nil;
    if (!gNFBColumnsAppTabControllers) gNFBColumnsAppTabControllers = [NSMutableDictionary dictionary];
    UIViewController *cached = gNFBColumnsAppTabControllers[identity];
    if (cached) return cached;
    if (!gNFBColumnsAppTabFailed) gNFBColumnsAppTabFailed = [NSMutableSet set];
    if ([gNFBColumnsAppTabFailed containsObject:identity]) return nil;

    UIViewController *tabbed = nfb_columnsTabbedControllerForPaging(paging);
    id dataSource = nfb_columnsTabbedDataSource(tabbed);
    SEL dsSel = @selector(tabbedViewController:viewControllerAtIndex:);
    if (!tabbed || !dataSource || ![dataSource respondsToSelector:dsSel]) {
        if (!gNFBColumnsAppTabReasons) gNFBColumnsAppTabReasons = [NSMutableDictionary dictionary];
        gNFBColumnsAppTabReasons[identity] = [NSString stringWithFormat:@"not ready tabbed=%d ds=%d", tabbed ? 1 : 0, dataSource ? 1 : 0];
        return nil;
    }

    static NSInteger const kAppTabBuild = 63;
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    if ([defs integerForKey:@"NFBColumnsAppTabFactoryCrashedBuild"] == kAppTabBuild) {
        [gNFBColumnsAppTabFailed addObject:identity];
        return nil;
    }
    if ([defs integerForKey:@"NFBColumnsAppTabFactoryInFlightBuild"] == kAppTabBuild) {
        [defs setInteger:kAppTabBuild forKey:@"NFBColumnsAppTabFactoryCrashedBuild"];
        [defs removeObjectForKey:@"NFBColumnsAppTabFactoryInFlightBuild"];
        [defs synchronize];
        [gNFBColumnsAppTabFailed addObject:identity];
        return nil;
    }

    NSUInteger index = [entry[@"index"] unsignedIntegerValue];
    [defs setInteger:kAppTabBuild forKey:@"NFBColumnsAppTabFactoryInFlightBuild"];
    [defs synchronize];
    UIViewController *fresh = nil;
    NSString *reason = nil;
    @try {
        fresh = ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(dataSource, dsSel, (id)tabbed, index);
    } @catch (NSException *e) {
        reason = [NSString stringWithFormat:@"exception %@", e.reason ?: e.name ?: @"?"];
        fresh = nil;
    }
    [defs removeObjectForKey:@"NFBColumnsAppTabFactoryInFlightBuild"];
    [defs synchronize];

    UIViewController *live = nil;
    SEL atIdxSel = @selector(viewControllerAtIndex:);
    if ([tabbed respondsToSelector:atIdxSel]) {
        @try { live = ((id (*)(id, SEL, NSUInteger))objc_msgSend)((id)tabbed, atIdxSel, index); } @catch (NSException *e) { live = nil; }
    }
    BOOL usable = fresh && [fresh isKindOfClass:UIViewController.class] && fresh.parentViewController == nil && fresh != live;
    if (!usable) {
        [gNFBColumnsAppTabFailed addObject:identity];
        if (!gNFBColumnsAppTabReasons) gNFBColumnsAppTabReasons = [NSMutableDictionary dictionary];
        gNFBColumnsAppTabReasons[identity] = reason ?: [NSString stringWithFormat:@"unusable fresh=%@ parent=%d sameAsLive=%d",
            fresh ? NSStringFromClass(fresh.class) : @"nil", fresh.parentViewController ? 1 : 0, (fresh && fresh == live) ? 1 : 0];
        return nil;
    }
    [fresh loadViewIfNeeded];
    fresh.preferredContentSize = CGSizeMake(340.0, MAX(400.0, fresh.preferredContentSize.height));
    gNFBColumnsAppTabControllers[identity] = fresh;
    if (gNFBLogRecording) {
        NFBLogEvent([NSString stringWithFormat:@"appTabColumn[b63] factory OK id=%@ vc=%@", identity, NSStringFromClass(fresh.class)]);
    }
    return fresh;
}

static BOOL nfb_columnsAppTabCanJoinAutomation(UIViewController *tabVC, UIViewController *paging) {
    return nfb_appTabAutomationControllerCanRefresh(tabVC, paging, YES, YES);
}

static void nfb_appendCurrentSearchAppTabAutomationControllers(NSMutableArray<UIViewController *> *controllers, UIViewController *paging) {
    if (!paging || !gNFBColumnsAppTabControllers.count) return;
    for (NSDictionary *entry in nfb_currentColumnEntriesForPaging(paging)) {
        if (![entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) continue;
        NSString *identity = nfb_columnEntryIdentity(entry);
        UIViewController *tabVC = identity.length ? gNFBColumnsAppTabControllers[identity] : nil;
        if (!nfb_columnsAppTabCanJoinAutomation(tabVC, paging)) continue;
        if (![controllers containsObject:tabVC]) [controllers addObject:tabVC];
    }
}

static NSString *nfb_columnDisplayName(UIViewController *page) {
    if (page.title.length) return page.title;
    NSString *cls = NSStringFromClass(page.class);
    if ([cls containsString:@"HomeTimelineItemsViewController"]) return nfb_loc(@"NFB_COL_HOME_FOLLOWING", @"Home (Following)");
    NSString *ident = nfb_columnTimelineIdentity(page);
    NSArray *parts = [ident componentsSeparatedByString:@"|"];
    return (parts.count > 1 && [parts[1] length]) ? parts[1] : cls;
}
// All column-eligible pages (INCLUDING hidden), in saved display order — for the management UI.
static NSArray<UIViewController *> *nfb_eligibleColumnPagesAll(void) {
    NSMutableArray<UIViewController *> *pages = [NSMutableArray array];
    for (NSDictionary *entry in nfb_allColumnEntriesForManagement()) {
        UIViewController *page = nfb_columnEntryViewController(entry);
        if (page && [entry[@"kind"] isEqualToString:kNFBColumnEntryKindTimeline]) [pages addObject:page];
    }
    return pages;
}

static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    NSMutableArray<UIViewController *> *pages = [NSMutableArray array];
    for (NSDictionary *entry in nfb_currentColumnEntriesForPaging(paging)) {
        UIViewController *page = nfb_columnEntryViewController(entry);
        if (page && [entry[@"kind"] isEqualToString:kNFBColumnEntryKindTimeline]) [pages addObject:page];
    }
    return pages;
}

static NSArray<UIViewController *> *nfb_currentColumnRefreshControllers(void) {
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray arrayWithArray:nfb_currentColumnTimelinePages()];
    // b44: search app-tab columns can join automation only after layout has proven a real scroll.
    // The timer path must never factory-build a tab or touch a zero-content/loading Guide view.
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    nfb_appendCurrentSearchAppTabAutomationControllers(controllers, paging);
    UIViewController *search = gNFBColumnsSearchColumnController;
    if (search && [search isViewLoaded] && search.view.window && ![controllers containsObject:search]) {
        [controllers addObject:search];
    }
    nfb_columnsAppendDetailControllers(controllers, YES);
    return controllers;
}

static NSArray<UIViewController *> *nfb_currentColumnVisibleControllersForTop(void) {
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray arrayWithArray:nfb_currentColumnTimelinePages()];
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    if (paging && gNFBColumnsAppTabControllers.count) {
        for (NSDictionary *entry in nfb_currentColumnEntriesForPaging(paging)) {
            if (![entry[@"kind"] isEqualToString:kNFBColumnEntryKindTab]) continue;
            NSString *identity = nfb_columnEntryIdentity(entry);
            UIViewController *tabVC = identity.length ? gNFBColumnsAppTabControllers[identity] : nil;
            if (!tabVC || ![tabVC isViewLoaded] || !tabVC.view.window) continue;
            if (![controllers containsObject:tabVC]) [controllers addObject:tabVC];
        }
    }
    UIViewController *search = gNFBColumnsSearchColumnController;
    if (search && [search isViewLoaded] && search.view.window && ![controllers containsObject:search]) {
        [controllers addObject:search];
    }
    nfb_columnsAppendDetailControllers(controllers, NO);
    return controllers;
}

static NSString *nfb_columnsPageSummary(UIViewController *paging) {
    if (!paging) return @"-";
    NSArray<UIViewController *> *all = nfb_allHomePagingTimelinePages(paging);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger idx = 0;
    for (UIViewController *page in all) {
        NSString *identity = nfb_columnTimelineIdentity(page);
        if (identity.length > 52) identity = [[identity substringToIndex:52] stringByAppendingString:@"..."];
        UIScrollView *sv = [page isViewLoaded] ? nfb_mainScrollViewOf(page) : nil;
        [parts addObject:[NSString stringWithFormat:@"%lu:%@ use%d rec%d h%.0f %@",
            (unsigned long)idx,
            page ? NSStringFromClass(page.class) : @"nil",
            nfb_shouldUseTimelinePageAsColumn(page) ? 1 : 0,
            nfb_isRecommendedHomeTimeline(page) ? 1 : 0,
            sv ? sv.contentSize.height : -1.0,
            identity.length ? identity : @"-"]];
        idx++;
        if (parts.count >= 6) break;
    }
    return [parts componentsJoinedByString:@";"];
}

static UIViewController *nfb_firstColumnTimelineAwayFromTopExcept(UIViewController *allowedRevealing) {
    for (UIViewController *page in nfb_currentColumnRefreshControllers()) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        if (allowedRevealing && page == allowedRevealing && nfb_canRevealRefreshStartedAtTop(page)) continue;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return page;
        if (!nfb_isTimelineAtTop(page)) return page;
    }
    return nil;
}

static UIViewController *nfb_firstColumnTimelineAwayFromTop(void) {
    return nfb_firstColumnTimelineAwayFromTopExcept(nil);
}

static void nfb_revealAllColumnTops(void) {
    nfb_layoutActiveHomePaging();
    NSArray<UIViewController *> *topControllers = nfb_currentColumnVisibleControllersForTop();
    NSArray<UIViewController *> *refreshControllers = nfb_currentColumnRefreshControllers();
    for (UIViewController *page in topControllers) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        page.view.hidden = NO;
        page.view.alpha = 1.0;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        // Don't fight a column the user is actively dragging.
        if (sv && (sv.isDragging || sv.isTracking)) continue;
        nfb_scrollToTop(page, NO);
    }
    for (UIViewController *page in refreshControllers) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) continue;
        if (nfb_isTimelineAtTop(page)) nfb_streamTriggerTarget(page);
    }
    NFBLogEvent([NSString stringWithFormat:@"columnsAllTop[b63] top=%lu refresh=%lu",
        (unsigned long)topControllers.count, (unsigned long)refreshControllers.count]);
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}

void NFBColumnsRetapFocusAndRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBColumnsRetapFocusAndRefresh(); });
        return;
    }
    if (!gInlineColumnsEnabled) return;
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    nfb_layoutActiveHomePaging();
    UIScrollView *horizontalScroll = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    if (horizontalScroll) {
        objc_setAssociatedObject(horizontalScroll, &kNFBColumnsDesiredSnapOffsetKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [horizontalScroll setContentOffset:CGPointMake(0.0, horizontalScroll.contentOffset.y) animated:YES];
    }
    nfb_revealAllColumnTops();
    nfb_scheduleLayoutActiveHomePagingLight();
    NFBLogEvent([NSString stringWithFormat:@"columnsRetap[b63] focusLeft refresh h=%@",
        horizontalScroll ? NSStringFromClass(horizontalScroll.class) : @"nil"]);
}

static BOOL nfb_streamTriggerColumns(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    UIScrollView *horizontalScroll = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    if (nfb_columnsScrollIsActivePaging(horizontalScroll) && nfb_columnsHorizontalScrollIsMoving(horizontalScroll)) {
        NFBLogEvent([NSString stringWithFormat:@"streamColumns deferHorizontal off=%.1f drag=%d decel=%d",
            horizontalScroll.contentOffset.x, horizontalScroll.isDragging ? 1 : 0, horizontalScroll.isDecelerating ? 1 : 0]);
        nfb_scheduleColumnsRefreshAfterHorizontalScroll(horizontalScroll);
        nfb_updateStreamStateIconForVC(gActiveItemsVC);
        return YES;
    }
    nfb_layoutActiveHomePaging();
    NSArray<UIViewController *> *pages = nfb_currentColumnRefreshControllers();
    NFBLogEvent([NSString stringWithFormat:@"streamColumns entry pages=%lu", (unsigned long)pages.count]);
    if (!pages.count) return NO;

    BOOL did = NO;
    UIViewController *away = nil;
    NSUInteger idx = 0;
    for (UIViewController *page in pages) {
        if (![page isViewLoaded] || page.view.window == nil) {
            NFBLogEvent([NSString stringWithFormat:@"streamColumns skip%lu loaded=%d win=%d class=%@",
                (unsigned long)idx, [page isViewLoaded] ? 1 : 0, ([page isViewLoaded] && page.view.window) ? 1 : 0, page ? NSStringFromClass(page.class) : @"nil"]);
            idx++;
            continue;
        }
        if (page.view.hidden) page.view.hidden = NO;
        if (page.view.alpha < 1.0) page.view.alpha = 1.0;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) {
            if (!away) away = page;
            NFBLogEvent([NSString stringWithFormat:@"streamColumns busy%lu class=%@ off=%.1f",
                (unsigned long)idx, NSStringFromClass(page.class), sv.contentOffset.y]);
            idx++;
            continue;
        }
        if (nfb_isTimelineAtTop(page)) {
            // b59: refresh EVERY at-top column each tick (user spec change — the b57/b58 one-column
            // round-robin left the other timelines visibly stale; the request volume trade-off is
            // accepted, and there is no batch endpoint: each timeline is its own API request).
            BOOL pageDid = nfb_streamTriggerTarget(page);
            NFBLogEvent([NSString stringWithFormat:@"streamColumns refresh%lu did=%d class=%@",
                (unsigned long)idx, pageDid ? 1 : 0, NSStringFromClass(page.class)]);
            did = pageDid || did;
        } else if (!away) {
            away = page;
            NFBLogEvent([NSString stringWithFormat:@"streamColumns away%lu class=%@",
                (unsigned long)idx, NSStringFromClass(page.class)]);
        }
        idx++;
    }

    if (away) nfb_showNewTweetsPill(away);
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
    return did || away != nil;
}

static NSInteger nfb_countSavedColumnsChromeInView(UIView *view, int depth) {
    if (!view || depth > 12) return 0;
    NSInteger count = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) ? 1 : 0;
    for (UIView *subview in view.subviews) {
        count += nfb_countSavedColumnsChromeInView(subview, depth + 1);
    }
    return count;
}

static NSInteger nfb_countCollapsedColumnsChromeInView(UIView *view, int depth) {
    if (!view || depth > 12) return 0;
    NSInteger count = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) ? 1 : 0;
    for (UIView *subview in view.subviews) {
        count += nfb_countCollapsedColumnsChromeInView(subview, depth + 1);
    }
    return count;
}

#if NFB_DIAG
static NSString *nfb_columnsConstraintSummaryForView(UIView *view) {
    NSArray<NSLayoutConstraint *> *constraints = nfb_chromeHeightConstraintsForView(view);
    if (!constraints.count) return @"-";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in constraints) {
        [parts addObject:[NSString stringWithFormat:@"h%.1f/%d", constraint.constant, constraint.active ? 1 : 0]];
        if (parts.count >= 4) break;
    }
    return [parts componentsJoinedByString:@","];
}

static void nfb_appendColumnsChromeDiag(NSMutableString *s, UIView *view, UIView *pagingView, UIView *root, int depth) {
    if (!view || !root || depth > 10) return;
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    BOOL containsPaging = nfb_viewContainsDescendant(view, pagingView);
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (saved || collapsed || (depth <= 4 && !containsPaging && CGRectGetMinY(frame) <= 280.0 && frame.size.height >= 4.0)) {
        NSString *text = nfb_textOfView(view);
        [s appendFormat:@"columnsChrome d=%d saved=%d collapsed=%d containsPaging=%d hidden=%d alpha=%.2f frame=(%.1f,%.1f,%.1f,%.1f) bounds=(%.1f,%.1f) super=%@ hc=%@ class=%@ text=%@\n",
            depth, saved ? 1 : 0, collapsed ? 1 : 0, containsPaging ? 1 : 0, view.hidden ? 1 : 0, view.alpha,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.bounds.size.width, view.bounds.size.height,
            view.superview ? NSStringFromClass(view.superview.class) : @"nil",
            nfb_columnsConstraintSummaryForView(view),
            NSStringFromClass(view.class), text ?: @"(nil)"];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendColumnsChromeDiag(s, subview, pagingView, root, depth + 1);
    }
}
#endif

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
    NSString *identifier = view.accessibilityIdentifier;
    if (identifier.length && ![txt containsString:identifier]) {
        if (txt.length) [txt appendString:@"|"];
        [txt appendFormat:@"id:%@", identifier];
    }
    return nfb_diagShortString(txt, maxLen);
}

@interface NFBColumnDetailCloseTarget : NSObject
@property (nonatomic, weak) UINavigationController *nav;
@end
@implementation NFBColumnDetailCloseTarget
- (void)close:(__unused id)sender {
    nfb_columnsDismissDetailNav(self.nav);
}
@end

static NSString *nfb_columnsKeyForIndex(NSUInteger index) {
    return [NSString stringWithFormat:@"idx|%lu", (unsigned long)index];
}

static NSString *nfb_columnsKeyForEntry(NSDictionary *entry, NSUInteger index) {
    NSString *identity = nfb_columnEntryIdentity(entry);
    return identity.length ? identity : nfb_columnsKeyForIndex(index);
}

static void nfb_columnsAssociateColumnView(UIView *view, UIViewController *owner, NSString *key, NSUInteger index) {
    if (!view || !key.length) return;
    objc_setAssociatedObject(view, &kNFBColumnsColumnKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsColumnIdentityKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsColumnIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (owner) objc_setAssociatedObject(view, &kNFBColumnsColumnOwnerKey, owner, OBJC_ASSOCIATION_ASSIGN);
}

static UIView *nfb_columnsColumnViewForTouchView(UIView *view) {
    UIView *v = view;
    for (int i = 0; v && i < 28; i++, v = v.superview) {
        if (objc_getAssociatedObject(v, &kNFBColumnsColumnKey)) return v;
    }
    return nil;
}

static void nfb_columnsNoteTouchedView(UIView *view, NSString *phase) {
    if (!gInlineColumnsEnabled || !view) return;
    UIView *column = nfb_columnsColumnViewForTouchView(view);
    if (!column || !column.window) return;
    NSString *key = objc_getAssociatedObject(column, &kNFBColumnsColumnIdentityKey);
    NSNumber *idx = objc_getAssociatedObject(column, &kNFBColumnsColumnIndexKey);
    gNFBLastTouchedColumnView = column;
    gNFBLastTouchedColumnKey = [key copy] ?: nfb_columnsKeyForIndex(idx ? idx.unsignedIntegerValue : 0);
    gNFBLastTouchedColumnIndex = idx ? idx.unsignedIntegerValue : NSNotFound;
    gNFBLastTouchedColumnAt = CACurrentMediaTime();
    if (gNFBLogRecording) {
        NFBLogEvent([NSString stringWithFormat:@"columnTouch[b63] phase=%@ key=%@ idx=%lu view=%@",
            phase ?: @"?", gNFBLastTouchedColumnKey ?: @"-", (unsigned long)gNFBLastTouchedColumnIndex,
            NSStringFromClass(view.class)]);
    }
}

static BOOL nfb_columnsRecentTouchAvailable(void) {
    if (!gInlineColumnsEnabled || !gNFBLastTouchedColumnView.window || !gNFBLastTouchedColumnKey.length) return NO;
    return (CACurrentMediaTime() - gNFBLastTouchedColumnAt) < 2.0;
}

static BOOL nfb_columnsControllerLooksSystemModal(UIViewController *vc) {
    if (!vc) return YES;
    if ([vc isKindOfClass:UIAlertController.class] ||
        [vc isKindOfClass:UIActivityViewController.class] ||
        [vc isKindOfClass:UIImagePickerController.class]) return YES;
    NSString *cls = NSStringFromClass(vc.class);
    NSString *low = cls.lowercaseString;
    return [low hasPrefix:@"ui"] ||
           [low hasPrefix:@"onb"] ||              // b50: onboarding/login-history/security flows (ONBItemsDataViewController) present their own full-screen sheet; pushing them into a 340pt column renders 340x0 then escapes to a modal — let them open full-screen instead
           [low containsString:@"onboarding"] ||
           [low containsString:@"alert"] ||
           [low containsString:@"activity"] ||
           [low containsString:@"share"] ||
           [low containsString:@"compose"] ||
           [low containsString:@"imagepicker"] ||
           [low containsString:@"photopicker"];
}

static BOOL nfb_columnsControllerLooksRoutableDetail(UIViewController *vc, BOOL presenting) {
    if (!vc) return NO;
    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)vc;
        UIViewController *content = nav.topViewController ?: nav.visibleViewController ?: nav.viewControllers.firstObject;
        if (content && content != vc) return nfb_columnsControllerLooksRoutableDetail(content, presenting);
    }
    if (nfb_columnsControllerLooksSystemModal(vc)) return NO;
    NSString *cls = NSStringFromClass(vc.class);
    NSString *low = cls.lowercaseString;
    if (!presenting) return YES;
    return [low containsString:@"tweet"] ||
           [low containsString:@"status"] ||
           [low containsString:@"conversation"] ||
           [low containsString:@"detail"] ||
           [low containsString:@"urt"] ||
           [low containsString:@"timeline"] ||
           [low containsString:@"guide"] ||
           [low containsString:@"search"] ||
           [low containsString:@"trend"] ||
           [low containsString:@"notification"] ||
           [low containsString:@"profile"] ||
           [low containsString:@"user"];
}

static UIViewController *nfb_columnsRefreshControllerForDetailNav(UINavigationController *nav) {
    if (!nav) return nil;
    UIViewController *target = nav.topViewController ?: nav.visibleViewController ?: nav.viewControllers.firstObject ?: nav;
    return target;
}

static BOOL nfb_columnsDetailControllerCanJoinAutomation(UIViewController *target) {
    if (!target || ![target isViewLoaded] || !target.view.window || target.view.hidden || target.view.alpha < 0.01) return NO;
    NSString *hint = nfb_columnsTabHintForController(target);
    NSString *viewText = nfb_diagTextForView(target.view, 240) ?: @"";
    BOOL notificationTimeline = nfb_textLooksNotificationTweetTimeline(hint) ||
                                nfb_textLooksNotificationTweetTimeline(viewText);
    BOOL searchLatest = nfb_columnsControllerLooksSearchTab(target, hint) &&
                        nfb_searchAppTabLooksLatestTimeline(target, hint);
    if (!notificationTimeline && !searchLatest) return NO;
    UIScrollView *sv = nfb_mainScrollViewOf(target);
    return sv && sv.window && sv.bounds.size.height >= 100.0 && sv.contentSize.height >= 60.0;
}

static void nfb_columnsAppendDetailControllers(NSMutableArray<UIViewController *> *controllers, BOOL refreshEligibleOnly) {
    if (!controllers || !gNFBColumnsDetailNavControllers.count) return;
    NSArray<UINavigationController *> *navs = [gNFBColumnsDetailNavControllers.allValues copy];
    for (UINavigationController *nav in navs) {
        if (!nav || ![nav isViewLoaded] || !nav.view.window) continue;
        UIViewController *target = nfb_columnsRefreshControllerForDetailNav(nav);
        if (!target || ![target isViewLoaded] || !target.view.window) target = nav;
        if (refreshEligibleOnly && !nfb_columnsDetailControllerCanJoinAutomation(target)) continue;
        if (target && ![controllers containsObject:target]) [controllers addObject:target];
    }
}

static UIScrollView *nfb_columnsActiveHorizontalScroll(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    return paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
}

static CGRect nfb_columnsFrameForKeyInScroll(NSString *key, UIScrollView *scroll) {
    if (!key.length || !scroll) return CGRectNull;
    for (UIView *subview in scroll.subviews) {
        NSString *candidate = objc_getAssociatedObject(subview, &kNFBColumnsColumnIdentityKey);
        if ([candidate isEqualToString:key]) return subview.frame;
    }
    UIView *last = gNFBLastTouchedColumnView;
    if (last && last.superview == scroll) return last.frame;
    CGFloat w = nfb_columnsColumnWidth(scroll.bounds.size.width);
    NSUInteger idx = (gNFBLastTouchedColumnIndex == NSNotFound) ? 0 : gNFBLastTouchedColumnIndex;
    return CGRectMake(w * idx, 0.0, w, scroll.bounds.size.height);
}

static void nfb_columnsInstallRootCloseButton(UIViewController *vc, UINavigationController *nav) {
    if (!vc || !nav) return;
    NFBColumnDetailCloseTarget *target = [NFBColumnDetailCloseTarget new];
    target.nav = nav;
    objc_setAssociatedObject(nav, &kNFBColumnsDetailCloseTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:target action:@selector(close:)];
    vc.navigationItem.leftBarButtonItem = close;
}

// b55: TweetDeck-like persistence — each column keeps its own open detail. The b51 close-everything
// rule made opening a tweet in column B dump column A's detail (rejected on device). The b50
// full-screen blackout came from UNBOUNDED heavy conversation stacks under LiveContainer's
// render/memory limits, so the residents stay capped: at most 3 detail navs, evicting the
// least-recently-USED other column when a new one opens.
static NSMutableArray<NSString *> *gNFBColumnsDetailNavLRU = nil;   // detail keys, most-recently-used last

static void nfb_columnsNoteDetailNavUsed(NSString *key) {
    if (!key.length) return;
    if (!gNFBColumnsDetailNavLRU) gNFBColumnsDetailNavLRU = [NSMutableArray array];
    [gNFBColumnsDetailNavLRU removeObject:key];
    [gNFBColumnsDetailNavLRU addObject:key];
}

static void nfb_columnsDismissDetailNav(UINavigationController *nav) {
    if (!nav) return;
    NSString *key = objc_getAssociatedObject(nav, &kNFBColumnsColumnIdentityKey);
    [nav willMoveToParentViewController:nil];
    [nav.view removeFromSuperview];
    [nav removeFromParentViewController];
    if (key.length && gNFBColumnsDetailNavControllers[key] == nav) [gNFBColumnsDetailNavControllers removeObjectForKey:key];
    if (key.length) [gNFBColumnsDetailNavLRU removeObject:key];
    if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] close key=%@", key ?: @"-"]);
}

static void nfb_columnsDismissAllDetailNavs(void) {
    NSArray<UINavigationController *> *navs = [gNFBColumnsDetailNavControllers.allValues copy];
    for (UINavigationController *nav in navs) nfb_columnsDismissDetailNav(nav);
    [gNFBColumnsDetailNavControllers removeAllObjects];
    [gNFBColumnsDetailNavLRU removeAllObjects];
}

static void nfb_columnsTrimDetailNavsBeforeOpening(NSString *newKey) {
    while (gNFBColumnsDetailNavControllers.count >= 3) {
        NSString *victim = nil;
        for (NSString *candidate in gNFBColumnsDetailNavLRU) {
            if (![candidate isEqualToString:newKey] && gNFBColumnsDetailNavControllers[candidate]) { victim = candidate; break; }
        }
        if (!victim) {
            for (NSString *candidate in gNFBColumnsDetailNavControllers.allKeys) {
                if (![candidate isEqualToString:newKey]) { victim = candidate; break; }
            }
        }
        if (!victim) break;
        if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] evictLRU key=%@", victim]);
        nfb_columnsDismissDetailNav(gNFBColumnsDetailNavControllers[victim]);
    }
}

// b55: if the detail's content table is still empty shortly after opening, nudge its own loadTop:
// (T1ConversationContainerViewController / T1URTViewController both expose it) the same way empty
// pinned columns are kicked. One-shot, delayed, so the normal appearance-driven load wins when it
// fires on its own.
static void nfb_columnsKickDetailNavContentSoon(UINavigationController *nav) {
    if (!nav) return;
    __weak UINavigationController *weakNav = nav;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UINavigationController *strongNav = weakNav;
        if (!strongNav || ![strongNav isViewLoaded] || !strongNav.view.window) return;
        UIViewController *target = nfb_columnsRefreshControllerForDetailNav(strongNav);
        if (!target || ![target isViewLoaded]) return;
        UIScrollView *sv = nfb_mainScrollViewOf(target);
        if (sv && sv.contentSize.height > 60.0) return;          // loaded on its own
        id leaf = nfb_findLeafResponder(target, @selector(loadTop:), 0) ?: nfb_findResponder(target, @selector(loadTop:), 0);
        if (!leaf) return;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(leaf, @selector(loadTop:), nil); } @catch (__unused NSException *e) {}
        NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] kickLoad top=%@ leaf=%@ content=%.0f",
            NSStringFromClass(target.class), NSStringFromClass([leaf class]), sv ? sv.contentSize.height : -1.0]);
    });
}

static void nfb_columnsLayoutDetailNavForKey(NSString *key, CGRect frame, UIScrollView *scroll) {
    UINavigationController *nav = key.length ? gNFBColumnsDetailNavControllers[key] : nil;
    if (!nav || !scroll) return;
    if (nav.view.superview != scroll) [scroll addSubview:nav.view];
    if (nav.view.hidden) nav.view.hidden = NO;
    if (nav.view.alpha < 1.0) nav.view.alpha = 1.0;
    CGRect detailBounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
    if (!CGRectEqualToRect(nav.view.frame, frame)) nav.view.frame = frame;
    if (!CGRectEqualToRect(nav.view.bounds, detailBounds)) nav.view.bounds = detailBounds;
    if (nav.view.autoresizingMask != UIViewAutoresizingFlexibleHeight) nav.view.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    NSNumber *idx = objc_getAssociatedObject(nav, &kNFBColumnsColumnIndexKey);
    nfb_columnsAssociateColumnView(nav.view, nav, key, idx ? idx.unsignedIntegerValue : 0);
    // b56: bringSubviewToFront dirties the scroll's layout; per-pass unconditional fronting kept the
    // layout loop alive (and with one detail per column, two navs would ping-pong each other's
    // order). Re-front only when an overlapping sibling actually sits ABOVE this nav.
    NSArray<UIView *> *siblings = scroll.subviews;
    NSUInteger navIndex = [siblings indexOfObject:nav.view];
    BOOL covered = NO;
    for (NSUInteger i = (navIndex == NSNotFound ? siblings.count : navIndex + 1); i < siblings.count; i++) {
        UIView *above = siblings[i];
        if (!above.hidden && above.alpha > 0.01 && CGRectIntersectsRect(above.frame, nav.view.frame)) { covered = YES; break; }
    }
    if (covered) [scroll bringSubviewToFront:nav.view];
}

// b60: web pages opened inside a 340pt column (T1XLinkViewController hosting XLinkWebView) rendered
// the DESKTOP site and did not fit — WKWebView's default content mode on iPad requests desktop
// pages regardless of our compact trait override. Force the mobile content mode + an iPhone user
// agent on any web view hosted under a column detail controller, one-shot per web view, then
// reload so an already-rendered desktop page re-renders mobile. WebKit is reached via the runtime
// (this file does not import WebKit; the app links it).
static char kNFBColumnsWebMobileAppliedKey;

static void nfb_columnsApplyMobileWebViewInTree(UIView *view, int depth) {
    if (!view || depth > 12) return;
    Class wkClass = objc_getClass("WKWebView");
    if (wkClass && [view isKindOfClass:wkClass]) {
        if (objc_getAssociatedObject(view, &kNFBColumnsWebMobileAppliedKey)) return;
        objc_setAssociatedObject(view, &kNFBColumnsWebMobileAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            id config = nfb_resp(view, @selector(configuration)) ? ((id (*)(id, SEL))objc_msgSend)(view, @selector(configuration)) : nil;
            id prefs = (config && nfb_resp(config, @selector(defaultWebpagePreferences))) ? ((id (*)(id, SEL))objc_msgSend)(config, @selector(defaultWebpagePreferences)) : nil;
            if (prefs && nfb_resp(prefs, @selector(setPreferredContentMode:))) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(prefs, @selector(setPreferredContentMode:), 1 /* WKContentModeMobile */);
            }
            if (nfb_resp(view, @selector(setCustomUserAgent:))) {
                ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(setCustomUserAgent:),
                    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1");
            }
            if (nfb_resp(view, @selector(reload))) ((void (*)(id, SEL))objc_msgSend)(view, @selector(reload));
            NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] webMobile applied wk=%@", NSStringFromClass(view.class)]);
        } @catch (__unused NSException *e) {}
        return;
    }
    for (UIView *sub in view.subviews) nfb_columnsApplyMobileWebViewInTree(sub, depth + 1);
}

// Run the web-view check right after a detail open/push and once more shortly after — the pushed
// controller usually creates its web view asynchronously after the push animation.
static void nfb_columnsScheduleMobileWebCheckForController(UIViewController *vc) {
    if (!vc) return;
    __weak UIViewController *weakVC = vc;
    void (^check)(void) = ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC || ![strongVC isViewLoaded] || !strongVC.view.window) return;
        nfb_columnsApplyMobileWebViewInTree(strongVC.view, 0);
    };
    dispatch_async(dispatch_get_main_queue(), check);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
}

static BOOL nfb_columnsNavIsColumnLocal(UINavigationController *nav) {
    if (!nav) return NO;
    if (objc_getAssociatedObject(nav, &kNFBColumnsLocalDetailKey)) return YES;
    return NO;
}

static BOOL nfb_columnsSourceViewMatchesTouchedColumn(UIView *view) {
    if (!gNFBLastTouchedColumnKey.length || !view) return NO;
    UIView *column = nfb_columnsColumnViewForTouchView(view);
    NSString *key = column ? objc_getAssociatedObject(column, &kNFBColumnsColumnIdentityKey) : nil;
    return key.length && [key isEqualToString:gNFBLastTouchedColumnKey];
}

static BOOL nfb_columnsNavSourceMatchesTouchedColumn(UINavigationController *nav) {
    if (!nav || nfb_columnsNavIsColumnLocal(nav)) return NO;
    return nfb_columnsSourceViewMatchesTouchedColumn(nav.view);
}

static BOOL nfb_columnsControllerSourceMatchesTouchedColumn(UIViewController *source) {
    if (!source) return NO;
    if ([source isViewLoaded] && nfb_columnsSourceViewMatchesTouchedColumn(source.view)) return YES;
    UINavigationController *nav = source.navigationController;
    if (nav && nfb_columnsSourceViewMatchesTouchedColumn(nav.view)) return YES;
    return NO;
}

// Returns the app-tab column's OWN navigation controller (Guide/Search, Notifications, Bookmarks, …)
// when the most-recently-touched column is an app-tab column, else nil. App-tab columns are real
// UINavigationControllers hosted view-only as 340pt columns (owner carries kNFBColumnsAppTabColumnKey).
static UINavigationController *nfb_columnsAppTabNavForTouchedColumn(void) {
    UIView *column = gNFBLastTouchedColumnView;
    if (!column) return nil;
    UIViewController *owner = objc_getAssociatedObject(column, &kNFBColumnsColumnOwnerKey);
    if (!owner || !objc_getAssociatedObject(owner, &kNFBColumnsAppTabColumnKey)) return nil;
    return [owner isKindOfClass:UINavigationController.class] ? (UINavigationController *)owner : nil;
}

// Re-entrancy guard: while we synchronously redirect a push onto an app-tab column's own nav, that
// nav's own pushViewController: hook fires again — never re-route during that window.
static BOOL gNFBColumnsAppTabRedirecting = NO;

static BOOL nfb_columnsRouteControllerIntoTouchedColumn(UIViewController *vc, NSString *reason, BOOL animated) {
    if (!gInlineColumnsEnabled || !vc || !nfb_columnsRecentTouchAvailable()) return NO;
    if (gNFBColumnsAppTabRedirecting) return NO;   // re-entrancy from the redirect push below
    // b46: app-tab columns (Guide/Search, Notifications, Bookmarks) are real UINavigationControllers
    // whose view IS the 340pt column. Detail that would otherwise escape full-screen — a notification/
    // trend/tweet pushed onto the home T1TimelineNavigationController, or a show/showDetail/present to
    // the app split — is REDIRECTED into the app-tab column's OWN nav so it stays inside the column.
    // We never build a parallel local detail nav for app-tab columns, so there is no double-host and
    // no QuartzCore layer-tree cycle (the b44 crash). The app-tab nav's own pushes (e.g. the search
    // field) are let through by %orig in the push hook and never reach here.
    UINavigationController *appTabNav = nfb_columnsAppTabNavForTouchedColumn();
    if (appTabNav) {
        if (vc == appTabNav || vc.navigationController == appTabNav || [appTabNav.viewControllers containsObject:vc]) return YES;
        BOOL appTabPresenting = [reason.lowercaseString containsString:@"present"];
        if (!nfb_columnsControllerLooksRoutableDetail(vc, appTabPresenting)) return NO;
        gNFBColumnsAppTabRedirecting = YES;
        @try {
            [appTabNav pushViewController:vc animated:animated];
        } @catch (__unused NSException *e) {
            gNFBColumnsAppTabRedirecting = NO;
            return NO;
        }
        gNFBColumnsAppTabRedirecting = NO;
        if (gNFBLogRecording) NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] appTabRedirect reason=%@ vc=%@ depth=%lu",
            reason ?: @"?", NSStringFromClass(vc.class), (unsigned long)appTabNav.viewControllers.count]);
        nfb_columnsScheduleMobileWebCheckForController(vc);
        nfb_scheduleLayoutActiveHomePagingLight();
        return YES;
    }
    BOOL presenting = [reason.lowercaseString containsString:@"present"];
    if (!nfb_columnsControllerLooksRoutableDetail(vc, presenting)) return NO;
    UINavigationController *incomingNav = [vc isKindOfClass:UINavigationController.class] ? (UINavigationController *)vc : nil;
    BOOL useIncomingNav = incomingNav && !nfb_columnsNavIsColumnLocal(incomingNav);
    UIScrollView *scroll = nfb_columnsActiveHorizontalScroll();
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    if (!scroll || !paging || !gNFBLastTouchedColumnKey.length) return NO;
    NSString *key = [gNFBLastTouchedColumnKey copy];
    if (!gNFBColumnsDetailNavControllers) gNFBColumnsDetailNavControllers = [NSMutableDictionary dictionary];
    UINavigationController *nav = gNFBColumnsDetailNavControllers[key];
    NSUInteger columnIndex = gNFBLastTouchedColumnIndex == NSNotFound ? 0 : gNFBLastTouchedColumnIndex;
    if (nav && useIncomingNav && nav != incomingNav) {
        nfb_columnsDismissDetailNav(nav);
        nav = nil;
    }
    if (nav) {
        if (vc.navigationController == nav || [nav.viewControllers containsObject:vc]) return YES;
        [nav pushViewController:vc animated:animated];
        nfb_columnsNoteDetailNavUsed(key);
        nfb_columnsScheduleMobileWebCheckForController(vc);
        NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] push key=%@ reason=%@ vc=%@ depth=%lu",
            key, reason ?: @"?", NSStringFromClass(vc.class), (unsigned long)nav.viewControllers.count]);
    } else {
        // b55: keep one detail PER COLUMN (TweetDeck-like; the b51 "only one anywhere" rule closed
        // column A's tweet the moment one was opened in column B — rejected on device). The LRU cap
        // inside the trim still bounds the resident heavy conversation stacks (the b50 blackout cause).
        nfb_columnsTrimDetailNavsBeforeOpening(key);
        CGRect frame = nfb_columnsFrameForKeyInScroll(key, scroll);
        if (CGRectIsNull(frame)) return NO;
        nav = useIncomingNav ? incomingNav : [[UINavigationController alloc] initWithRootViewController:vc];
        objc_setAssociatedObject(nav, &kNFBColumnsLocalDetailKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(nav, &kNFBColumnsColumnIdentityKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(nav, &kNFBColumnsColumnIndexKey, @(columnIndex), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [nav setNavigationBarHidden:NO animated:NO];
        UIViewController *root = nav.viewControllers.firstObject ?: nav.topViewController ?: vc;
        nfb_columnsInstallRootCloseButton(root, nav);
        [paging addChildViewController:nav];
        // b52: lay the detail out for COMPACT width. At iPad Regular width
        // T1ConversationContainerViewController builds its wide readable-width layout (content sized
        // for the ~1400pt environment), so inside the clipped 340pt column the actual tweet content
        // sat outside the clip — the column showed only the nav bar + reply bar over black
        // (device screenshot 2026-06-10). Overriding ONLY our own local detail nav to compact makes
        // Twitter use the iPhone-style narrow conversation layout, which fits the column. No
        // Twitter-owned controller is touched (the b38/b39 crashes came from trait/layout forcing on
        // Twitter's OWN app-tab controllers; this nav is created and owned by us).
        if ([paging respondsToSelector:@selector(setOverrideTraitCollection:forChildViewController:)]) {
            UITraitCollection *compactH = [UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassCompact];
            ((void (*)(id, SEL, id, id))objc_msgSend)(paging, @selector(setOverrideTraitCollection:forChildViewController:), compactH, nav);
        }
        nav.view.frame = frame;
        nav.view.bounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
        nav.view.clipsToBounds = YES;
        nav.view.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        nfb_columnsAssociateColumnView(nav.view, nav, key, columnIndex);
        [scroll addSubview:nav.view];
        [nav didMoveToParentViewController:paging];
        // b55: the b54 device diag proved the detail rendered its chrome over an EMPTY table
        // (columnDetail content=340x0 while traitH=1 — the b52 width fix held, the DATA never
        // loaded). Twitter's URT controllers load on their first viewWillAppear
        // (shouldReloadDataOnFirstViewWillAppear), and a nav hosted view-only inside the pager
        // scroll does not reliably receive that appearance pass. Drive it explicitly, then kick
        // loadTop: as a fallback if the table is still empty shortly after.
        @try {
            [nav beginAppearanceTransition:YES animated:NO];
            [nav endAppearanceTransition];
        } @catch (__unused NSException *e) {}
        nfb_columnsKickDetailNavContentSoon(nav);
        nfb_columnsScheduleMobileWebCheckForController(vc);
        gNFBColumnsDetailNavControllers[key] = nav;
        nfb_columnsNoteDetailNavUsed(key);
        [scroll bringSubviewToFront:nav.view];
        NFBLogEvent([NSString stringWithFormat:@"columnDetail[b63] open key=%@ reason=%@ vc=%@ frame=(%.0f,%.0f,%.0f,%.0f)",
            key, reason ?: @"?", NSStringFromClass(vc.class),
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
    }
    nfb_scheduleLayoutActiveHomePagingLight();
    return YES;
}

#if NFB_DIAG
static NSString *nfb_diagGestureSummaryForView(UIView *view) {
    if (!view.gestureRecognizers.count) return @"-";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        NSString *cls = NSStringFromClass(gesture.class);
        NSString *delegate = gesture.delegate ? NSStringFromClass([gesture.delegate class]) : @"nil";
        BOOL edgeMenu = nfb_columnsShouldTreatGestureAsEdgeMenu(gesture);
        NSMutableString *part = [NSMutableString stringWithFormat:@"%@ en%d st%ld edgeMenu%d cancel%d del=%@",
            cls, gesture.enabled ? 1 : 0, (long)gesture.state, edgeMenu ? 1 : 0,
            gesture.cancelsTouchesInView ? 1 : 0, delegate];
        if ([gesture isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            [part appendFormat:@" edges%lu", (unsigned long)((UIScreenEdgePanGestureRecognizer *)gesture).edges];
        }
        [parts addObject:part];
        if (parts.count >= 5) {
            [parts addObject:@"..."];
            break;
        }
    }
    return [parts componentsJoinedByString:@";"];
}

static NSString *nfb_diagScrollSummaryForView(UIView *view) {
    if (![view isKindOfClass:[UIScrollView class]]) return @"-";
    UIScrollView *sv = (UIScrollView *)view;
    return [NSString stringWithFormat:@"off=(%.1f,%.1f) content=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) adjusted=(%.1f,%.1f,%.1f,%.1f) paging=%d bounceH=%d drag=%d",
        sv.contentOffset.x, sv.contentOffset.y,
        sv.contentSize.width, sv.contentSize.height,
        sv.bounds.size.width, sv.bounds.size.height,
        sv.contentInset.top, sv.contentInset.left, sv.contentInset.bottom, sv.contentInset.right,
        sv.adjustedContentInset.top, sv.adjustedContentInset.left, sv.adjustedContentInset.bottom, sv.adjustedContentInset.right,
        sv.pagingEnabled ? 1 : 0,
        sv.alwaysBounceHorizontal ? 1 : 0,
        (sv.isDragging || sv.isTracking || sv.isDecelerating) ? 1 : 0];
}

static BOOL nfb_viewLooksLikeSearchChromeForDiag(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass(view.class);
    NSString *text = nfb_diagTextForView(view, 160);
    NSString *lowerClass = cls.lowercaseString;
    NSString *lowerText = text.lowercaseString;
    return [lowerClass containsString:@"search"] ||
        [lowerClass containsString:@"textfield"] ||
        [lowerClass containsString:@"textinput"] ||
        [cls containsString:@"UISearchBar"] ||
        [cls containsString:@"UITextField"] ||
        [lowerText containsString:@"search"] ||
        [text containsString:@"検索"] ||
        [text containsString:@"調べる"];
}

static void nfb_appendSearchChromeDiagInView(NSMutableString *s, UIView *view, UIView *root, int depth, NSInteger *count) {
    if (!view || !root || depth > 18 || *count >= 140) return;
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    BOOL topSized = CGRectGetMinY(frame) <= 340.0 && frame.size.width >= 24.0 && frame.size.height >= 1.0 && frame.size.height <= 340.0;
    BOOL interesting = (topSized && nfb_viewLooksLikeSearchChromeForDiag(view)) || (saved || collapsed);
    if (interesting) {
        (*count)++;
        [s appendFormat:@"searchChrome[%ld] d=%d class=%@ f=(%.1f,%.1f,%.1f,%.1f) hidden=%d alpha=%.2f ui=%d saved=%d collapsed=%d hc=%@ gestures=%@ super=%@ text=%@\n",
            (long)*count, depth, NSStringFromClass(view.class),
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.hidden ? 1 : 0, view.alpha, view.userInteractionEnabled ? 1 : 0,
            saved ? 1 : 0, collapsed ? 1 : 0,
            nfb_columnsConstraintSummaryForView(view),
            nfb_diagGestureSummaryForView(view),
            view.superview ? NSStringFromClass(view.superview.class) : @"nil",
            nfb_diagTextForView(view, 120)];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendSearchChromeDiagInView(s, subview, root, depth + 1, count);
    }
}

static void nfb_appendSearchChromeDiag(NSMutableString *s) {
    [s appendString:@"--- searchChrome / saved chrome audit ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        [s appendFormat:@"searchWindow key=%d root=%@\n",
            w.isKeyWindow ? 1 : 0,
            w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil"];
        nfb_appendSearchChromeDiagInView(s, w, w, 0, &count);
    }
}

static void nfb_appendSavedColumnsChromeDiagInView(NSMutableString *s, UIView *view, UIView *root, int depth, NSInteger *count) {
    if (!view || !root || depth > 18 || *count >= 160) return;
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    if (saved || collapsed) {
        (*count)++;
        CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
        [s appendFormat:@"savedChrome[%ld] d=%d class=%@ f=(%.1f,%.1f,%.1f,%.1f) hidden=%d alpha=%.2f saved=%d collapsed=%d super=%@ text=%@\n",
            (long)*count, depth, NSStringFromClass(view.class),
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.hidden ? 1 : 0, view.alpha, saved ? 1 : 0, collapsed ? 1 : 0,
            view.superview ? NSStringFromClass(view.superview.class) : @"nil",
            nfb_diagTextForView(view, 100)];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendSavedColumnsChromeDiagInView(s, subview, root, depth + 1, count);
    }
}

static void nfb_appendSavedColumnsChromeDiag(NSMutableString *s) {
    [s appendString:@"--- savedColumnsChrome (all windows) ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        nfb_appendSavedColumnsChromeDiagInView(s, w, w, 0, &count);
    }
}

static BOOL nfb_diagStringLooksSpaces(NSString *value) {
    if (!value.length) return NO;
    NSString *lower = [value lowercaseString];
    return [lower containsString:@"space"] ||
        [lower containsString:@"spaces"] ||
        [value containsString:@"スペース"] ||
        [value containsString:@"スペースバー"] ||
        [value containsString:@"進行中"];
}

static void nfb_appendTopChromeDiagInView(NSMutableString *s, UIView *view, UIView *root, int depth, NSInteger *count) {
    if (!view || !root || depth > 12 || *count >= 180) return;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    if (CGRectGetMinY(frame) <= 320.0 && frame.size.height >= 1.0 && frame.size.height <= 320.0 && frame.size.width >= 36.0) {
        NSString *cls = NSStringFromClass(view.class);
        BOOL barLike = [cls containsString:@"Segment"] || [cls containsString:@"Bar"] || [cls containsString:@"Label"] ||
            [cls containsString:@"Header"] || [cls containsString:@"Tab"] || [cls containsString:@"Space"] ||
            [cls containsString:@"Fleet"] || [cls containsString:@"Audio"] || [cls containsString:@"Voice"];
        NSString *t = nfb_diagTextForView(view, 72);
        BOOL hasText = ![t isEqualToString:@"-"];
        BOOL chromeLike = barLike || nfb_viewLooksLikeHomeSegmentBar(view, root) || nfb_viewLooksLikeSpacesChrome(view, root);
        BOOL interesting = hasText || chromeLike || saved || collapsed || view.gestureRecognizers.count ||
            ((view.hidden || view.alpha < 0.99) && CGRectGetMinY(frame) <= 240.0 && frame.size.height >= 8.0);
        if (interesting) {
            (*count)++;
            [s appendFormat:@"  top d=%d class=%@ f=(%.0f,%.0f,%.0f,%.0f) hidden=%d alpha=%.2f ui=%d gestures=%lu saved=%d collapsed=%d hc=%@ super=%@ text=%@\n",
                depth, cls, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                view.hidden ? 1 : 0, view.alpha, view.userInteractionEnabled ? 1 : 0,
                (unsigned long)view.gestureRecognizers.count, saved ? 1 : 0, collapsed ? 1 : 0,
                nfb_columnsConstraintSummaryForView(view),
                view.superview ? NSStringFromClass(view.superview.class) : @"nil",
                t];
        }
    }
    for (UIView *sub in view.subviews) {
        nfb_appendTopChromeDiagInView(s, sub, root, depth + 1, count);
        if (*count >= 180) break;
    }
}
static void nfb_appendTopChromeDiag(NSMutableString *s) {
    [s appendString:@"--- topChrome (MinY<=320, includes hidden/transparent candidates) ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        nfb_appendTopChromeDiagInView(s, w, w, 0, &count);
        if (count >= 180) break;
    }
    if (count >= 180) [s appendString:@"  top truncated=1 limit=180\n"];
}

static void nfb_appendCoveringViewsDiagInView(NSMutableString *s, UIView *view, UIView *root, UIView *pagingView, CGRect focus, int depth, NSInteger *count) {
    if (!view || !root || depth > 14 || *count >= 120) return;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    BOOL intersects = CGRectIntersectsRect(frame, focus);
    BOOL containsPaging = pagingView && nfb_viewContainsDescendant(view, pagingView);
    BOOL pagingSurface = nfb_columnsPagingSurface(view);
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL collapsed = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeCollapsedKey) != nil;
    NSString *cls = NSStringFromClass(view.class);
    NSString *text = nfb_diagTextForView(view, 72);
    BOOL hasText = ![text isEqualToString:@"-"];
    BOOL chromeLike = nfb_viewLooksLikeHomeSegmentBar(view, root) || nfb_viewLooksLikeSpacesChrome(view, root) ||
        [cls containsString:@"Segment"] || [cls containsString:@"Bar"] || [cls containsString:@"Header"] ||
        [cls containsString:@"Space"] || [cls containsString:@"Fleet"] || [cls containsString:@"Audio"] ||
        [cls containsString:@"Voice"];
    BOOL potentialBlocker = view.userInteractionEnabled && !containsPaging && !pagingSurface &&
        frame.size.width >= 36.0 && frame.size.height >= 1.0 &&
        (CGRectGetMinY(frame) <= 320.0 || (gInlineColumnsEnabled && frame.size.height >= 32.0));
    BOOL interesting = intersects && depth > 0 && !containsPaging && !pagingSurface &&
        (saved || collapsed || chromeLike || hasText || view.gestureRecognizers.count || potentialBlocker);
    if (interesting) {
        (*count)++;
        [s appendFormat:@"cover[%ld] d=%d class=%@ f=(%.1f,%.1f,%.1f,%.1f) hidden=%d alpha=%.2f ui=%d gestures=%@ saved=%d collapsed=%d hc=%@ super=%@ text=%@\n",
            (long)*count, depth, cls,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.hidden ? 1 : 0, view.alpha, view.userInteractionEnabled ? 1 : 0,
            nfb_diagGestureSummaryForView(view), saved ? 1 : 0, collapsed ? 1 : 0,
            nfb_columnsConstraintSummaryForView(view),
            view.superview ? NSStringFromClass(view.superview.class) : @"nil",
            text];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendCoveringViewsDiagInView(s, subview, root, pagingView, focus, depth + 1, count);
    }
}

static void nfb_appendCoveringViewsDiag(NSMutableString *s) {
    [s appendString:@"--- coveringViews (non-paging views intersecting column/top area) ---\n"];
    UIViewController *paging = nfb_findVisibleHomePagingController();
    UIView *pagingView = (paging && [paging isViewLoaded]) ? paging.view : nil;
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        CGRect focus = w.bounds;
        if (pagingView && pagingView.window == w) {
            focus = pagingView.superview ? [pagingView.superview convertRect:pagingView.frame toView:w] : [pagingView convertRect:pagingView.bounds toView:w];
            focus = CGRectInset(focus, -4.0, -80.0);
        }
        [s appendFormat:@"coverWindow key=%d hidden=%d alpha=%.2f root=%@ focus=(%.1f,%.1f,%.1f,%.1f)\n",
            w.isKeyWindow ? 1 : 0, w.hidden ? 1 : 0, w.alpha,
            w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil",
            focus.origin.x, focus.origin.y, focus.size.width, focus.size.height];
        nfb_appendCoveringViewsDiagInView(s, w, w, pagingView, focus, 0, &count);
    }
}

static void nfb_appendGestureDiagInView(NSMutableString *s, UIView *view, UIView *root, int depth, NSInteger *count) {
    if (!view || !root || depth > 16 || *count >= 160) return;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    NSString *viewClass = NSStringFromClass(view.class);
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        NSString *gestureClass = NSStringFromClass(gesture.class);
        BOOL edgeMenu = nfb_columnsShouldTreatGestureAsEdgeMenu(gesture);
        BOOL interesting = edgeMenu || [gestureClass containsString:@"Pan"] || [gestureClass containsString:@"Swipe"] ||
            [gestureClass containsString:@"Edge"] || [viewClass containsString:@"Scroll"] ||
            [viewClass containsString:@"Paging"] || CGRectGetMinY(frame) <= 320.0;
        if (!interesting) continue;
        (*count)++;
        NSString *delegate = gesture.delegate ? NSStringFromClass([gesture.delegate class]) : @"nil";
        NSString *edges = @"-";
        if ([gesture isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            edges = [NSString stringWithFormat:@"%lu", (unsigned long)((UIScreenEdgePanGestureRecognizer *)gesture).edges];
        }
        [s appendFormat:@"gesture[%ld] d=%d view=%@ f=(%.1f,%.1f,%.1f,%.1f) hidden=%d alpha=%.2f g=%@ en=%d st=%ld edgeMenu=%d edges=%@ cancel=%d del=%@ scroll=%@\n",
            (long)*count, depth, viewClass,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.hidden ? 1 : 0, view.alpha,
            gestureClass, gesture.enabled ? 1 : 0, (long)gesture.state,
            edgeMenu ? 1 : 0, edges, gesture.cancelsTouchesInView ? 1 : 0,
            delegate, nfb_diagScrollSummaryForView(view)];
        if (*count >= 160) break;
    }
    for (UIView *subview in view.subviews) {
        nfb_appendGestureDiagInView(s, subview, root, depth + 1, count);
    }
}

static void nfb_appendGestureDiag(NSMutableString *s) {
    [s appendString:@"--- gestures (pan/edge/menu candidates) ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        nfb_appendGestureDiagInView(s, w, w, 0, &count);
    }
}

static void nfb_appendSpacesCandidatesDiagInView(NSMutableString *s, UIView *view, UIView *root, int depth, NSInteger *count) {
    if (!view || !root || depth > 14 || *count >= 100) return;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    NSString *cls = NSStringFromClass(view.class);
    NSString *text = nfb_diagTextForView(view, 96);
    BOOL classLooksSpaces = [cls containsString:@"Space"] || [cls containsString:@"Fleet"] ||
        [cls containsString:@"Audio"] || [cls containsString:@"Voice"] ||
        [cls containsString:@"Presence"] || [cls containsString:@"Broadcast"];
    BOOL looksSpaces = nfb_viewLooksLikeSpacesChrome(view, root) || classLooksSpaces || nfb_diagStringLooksSpaces(text);
    if (looksSpaces) {
        (*count)++;
        [s appendFormat:@"spaces[%ld] d=%d class=%@ f=(%.1f,%.1f,%.1f,%.1f) hidden=%d alpha=%.2f ui=%d gestures=%@ hc=%@ super=%@ text=%@\n",
            (long)*count, depth, cls,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            view.hidden ? 1 : 0, view.alpha, view.userInteractionEnabled ? 1 : 0,
            nfb_diagGestureSummaryForView(view), nfb_columnsConstraintSummaryForView(view),
            view.superview ? NSStringFromClass(view.superview.class) : @"nil", text];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendSpacesCandidatesDiagInView(s, subview, root, depth + 1, count);
    }
}

static void nfb_appendSpacesCandidatesDiag(NSMutableString *s) {
    [s appendString:@"--- spacesCandidates ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        nfb_appendSpacesCandidatesDiagInView(s, w, w, 0, &count);
    }
}

// Explore-tab discovery (iPad): the current search column transplants the condensed app-split
// trends/search sidebar (T1ExtendedContentNavigationController), which by design shows only a
// search field + a few trends (content ~340x301). To match the iPhone Explore tab (search bar +
// おすすめ/トレンド/ニュース/スポーツ segmented categories + long list) we need the *real*
// explore/search content VC instead. It has no clean accessor, so this read-only diag walks the
// full view-controller hierarchy of every window and flags explore/search/trends/guide candidates
// with their reachable path (depth/parent), load state, and main-scroll content size, so the next
// build can transplant the right VC. Capped to stay readable; only computes scroll for candidates.
static BOOL nfb_vcClassLooksExplore(NSString *cls) {
    return [cls containsString:@"Explore"] || [cls containsString:@"Guide"] ||
        [cls containsString:@"Discover"] || [cls containsString:@"Search"] ||
        [cls containsString:@"Trend"] || [cls containsString:@"Moment"] ||
        [cls containsString:@"ExtendedContent"];
}

static void nfb_appendVCTreeDiag(NSMutableString *s, UIViewController *vc, int depth, NSInteger *count) {
    if (!vc || depth > 14 || *count >= 200) return;
    (*count)++;
    NSString *cls = NSStringFromClass(vc.class);
    BOOL candidate = nfb_vcClassLooksExplore(cls);
    BOOL loaded = [vc isViewLoaded];
    UIView *v = loaded ? vc.view : nil;
    BOOL inWindow = (v && v.window) ? YES : NO;
    NSString *parent = vc.parentViewController ? NSStringFromClass(vc.parentViewController.class) : @"-";
    NSString *title = vc.title.length ? vc.title : @"";
    UINavigationController *navParent = vc.navigationController;
    // Only pay for the deep scroll search on candidates (cheap for the rest of the 200-cap tree).
    UIScrollView *sv = (candidate && loaded) ? nfb_mainScrollViewOf(vc) : nil;
    [s appendFormat:@"vc%@ d=%d %@ loaded=%d win=%d hidden=%d kids=%lu parent=%@ nav=%@ scroll=%@ content=%.0fx%.0f title=%@\n",
        candidate ? @"*" : @" ", depth, cls,
        loaded ? 1 : 0, inWindow ? 1 : 0, (v && v.hidden) ? 1 : 0,
        (unsigned long)vc.childViewControllers.count, parent,
        navParent ? NSStringFromClass(navParent.class) : @"-",
        sv ? NSStringFromClass(sv.class) : @"-",
        sv ? sv.contentSize.width : 0.0, sv ? sv.contentSize.height : 0.0,
        title];
    for (UIViewController *child in vc.childViewControllers) {
        nfb_appendVCTreeDiag(s, child, depth + 1, count);
    }
    if (vc.presentedViewController && vc.presentedViewController.presentingViewController == vc) {
        nfb_appendVCTreeDiag(s, vc.presentedViewController, depth + 1, count);
    }
}

// Dump the initializer + class(factory) methods + superclass chain of a class, so we can decide how
// to SAFELY construct a fresh Explore/Guide VC for the search column. A Swift VC has a designated
// initializer; calling the wrong one (e.g. bare alloc/init when it requires a view model) is a hard
// fatalError crash that @try cannot catch — so we must read the real init/factory before building it.
static void nfb_appendInitAndClassMethods(NSMutableString *s, Class c) {
    if (!c) return;
    NSMutableString *chain = [NSMutableString string];
    Class sup = c;
    for (int i = 0; i < 8 && sup; i++) { [chain appendFormat:@" %@", NSStringFromClass(sup)]; sup = class_getSuperclass(sup); }
    [s appendFormat:@"  super:%@\n", chain];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableArray<NSString *> *inits = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(ms[i]));
        if ([sel hasPrefix:@"init"]) [inits addObject:sel];
    }
    if (ms) free(ms);
    [s appendFormat:@"  init(inst): %@\n", inits.count ? [inits componentsJoinedByString:@" "] : @"(none-on-this-class)"];
    unsigned int cn = 0;
    Method *cms = class_copyMethodList(object_getClass(c), &cn);
    NSMutableArray<NSString *> *factories = [NSMutableArray array];
    for (unsigned int i = 0; i < cn; i++) [factories addObject:NSStringFromSelector(method_getName(cms[i]))];
    if (cms) free(cms);
    [s appendFormat:@"  class(factory): %@\n", factories.count ? [factories componentsJoinedByString:@" "] : @"(none)"];
}

static void nfb_appendGuideClassDiag(NSMutableString *s) {
    [s appendString:@"--- guideClassDiag ---\n"];
    NSArray<NSString *> *names = @[ @"T1TwitterSwift.GuideContainerViewController",
                                    @"T1TwitterSwift_GuideContainerViewController",
                                    @"T1TwitterSwift.TrendsSidebarViewController",
                                    @"T1TwitterSwift_TrendsSidebarViewController",
                                    @"T1ExtendedContentNavigationController" ];
    for (NSString *name in names) {
        Class c = NSClassFromString(name);
        [s appendFormat:@"guideClass %@ = %@\n", name, c ? @"FOUND" : @"nil"];
        if (c) nfb_appendInitAndClassMethods(s, c);
    }
}
#endif

// Find the factory that builds the Explore/Guide tab VC WITH proper dependency injection. Fresh
// alloc/init of GuideContainerViewController crashes (confirmed on device); the only safe way to get
// one is to call Twitter's own creation path. This read-only diag locates the tab-content controllers
// + their data sources/delegates and dumps method selectors that look like VC factories (so the next
// build can call the right one and host the result in the column, with the trends column as fallback).
static UIViewController *nfb_findVCByClassSubstring(UIViewController *root, NSString *sub, int depth) {
    if (!root || depth > 14) return nil;
    if ([NSStringFromClass(root.class) containsString:sub]) return root;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = nfb_findVCByClassSubstring(child, sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

#if NFB_DIAG
static void nfb_dumpFactoryMethods(NSMutableString *s, id obj, NSString *label) {
    if (!obj) { [s appendFormat:@"tabFactory %@ = nil\n", label]; return; }
    Class c = [obj class];
    [s appendFormat:@"tabFactory %@ = %@\n", label, NSStringFromClass(c)];
    NSArray<NSString *> *needles = @[ @"viewcontroller", @"panel", @"guide", @"moment", @"create",
                                      @"explore", @"controllerfor", @"tabat", @"index", @"page" ];
    Class cur = c;
    for (int lvl = 0; lvl < 4 && cur && cur != [UIViewController class] && cur != [UIResponder class] && cur != [NSObject class]; lvl++) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(cur, &n);
        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            NSString *low = sel.lowercaseString;
            for (NSString *nd in needles) { if ([low containsString:nd]) { [hits addObject:sel]; break; } }
        }
        if (ms) free(ms);
        if (hits.count) [s appendFormat:@"  [%@] %@\n", NSStringFromClass(cur), [hits componentsJoinedByString:@" "]];
        cur = class_getSuperclass(cur);
    }
}

static void nfb_appendTabFactoryDiag(NSMutableString *s) {
    [s appendString:@"--- tabFactoryDiag ---\n"];
    UIViewController *root = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow && w.rootViewController) { root = w.rootViewController; break; }
    }
    if (!root) { [s appendString:@"tabFactory: no key root\n"]; return; }
    NSArray<NSString *> *targets = @[ @"TFNTabbedViewController", @"T1TabbedContainerViewController",
                                      @"T1AppSplitViewController", @"T1TabBarViewController",
                                      @"T1TabbedAppNavigationViewController" ];
    for (NSString *t in targets) {
        UIViewController *vc = nfb_findVCByClassSubstring(root, t, 0);
        nfb_dumpFactoryMethods(s, vc, t);
        if (!vc) continue;
        for (NSString *key in @[ @"dataSource", @"delegate", @"_dataSource", @"_delegate", @"tabBarController" ]) {
            id v = nil;
            @try { v = [vc valueForKey:key]; } @catch (NSException *e) { v = nil; }
            if (v && v != vc && [v isKindOfClass:NSObject.class]) {
                nfb_dumpFactoryMethods(s, v, [NSString stringWithFormat:@"%@.%@", t, key]);
            }
        }
    }
}

static void nfb_appendExploreDiscoveryDiag(NSMutableString *s) {
    [s appendString:@"--- vcTree (explore discovery) ---\n"];
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.rootViewController) continue;
        [s appendFormat:@"vcWindow key=%d hidden=%d root=%@\n",
            w.isKeyWindow ? 1 : 0, w.hidden ? 1 : 0, NSStringFromClass(w.rootViewController.class)];
        nfb_appendVCTreeDiag(s, w.rootViewController, 0, &count);
    }
    // Focused dump of the currently-transplanted search nav so we can confirm what it actually hosts.
    UIViewController *searchVC = gNFBColumnsSearchColumnController;
    if ([searchVC isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)searchVC;
        UIViewController *top = nav.topViewController;
        UIViewController *vis = nav.visibleViewController;
        [s appendFormat:@"searchNav stack=%lu top=%@ visible=%@\n",
            (unsigned long)nav.viewControllers.count,
            top ? NSStringFromClass(top.class) : @"-",
            vis ? NSStringFromClass(vis.class) : @"-"];
        for (UIViewController *child in nav.viewControllers) {
            UIScrollView *sv = [child isViewLoaded] ? nfb_mainScrollViewOf(child) : nil;
            [s appendFormat:@"searchNavVC %@ loaded=%d kids=%lu scroll=%@ content=%.0fx%.0f\n",
                NSStringFromClass(child.class), [child isViewLoaded] ? 1 : 0,
                (unsigned long)child.childViewControllers.count,
                sv ? NSStringFromClass(sv.class) : @"-",
                sv ? sv.contentSize.width : 0.0, sv ? sv.contentSize.height : 0.0];
        }
    }
}
#endif

static NSInteger nfb_countVisibleTopHomeChromeInView(UIView *view, UIView *root, int depth) {
    if (!view || !root || depth > 12 || view.hidden || view.alpha < 0.01) return 0;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (depth > 0 && CGRectGetMinY(frame) > 320.0) return 0;
    NSInteger count = 0;
    if (CGRectGetMinY(frame) <= 280.0 && frame.size.height <= 260.0 &&
        (nfb_viewLooksLikeHomeSegmentBar(view, root) || nfb_viewLooksLikeSpacesChrome(view, root))) count++;
    for (UIView *subview in view.subviews) {
        count += nfb_countVisibleTopHomeChromeInView(subview, root, depth + 1);
    }
    return count;
}

static NSInteger nfb_countVisibleTopHomeChrome(void) {
    NSInteger count = 0;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        count += nfb_countVisibleTopHomeChromeInView(w, w, 0);
    }
    return count;
}

// Compact, single-line state snapshot for the recorded log — dropped in at key events (present /
// dismiss / tab select / home appear-disappear / cleanup) so a stuck or corrupted state can be
// reconstructed from a single paste. No-op unless recording; never mutates UI; KVC guarded.
void NFBLogSnapshot(NSString *reason) {
    if (!gNFBLogRecording) return;
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ NFBLogSnapshot(reason); }); return; }
    NSMutableString *s = [NSMutableString stringWithFormat:@"snap[%@] ", reason ?: @"?"];
    @try { NSString *f = BHTColumnsLogFlags(); if (f.length) [s appendFormat:@"%@ ", f]; } @catch (NSException *e) {}
    [s appendFormat:@"inline=%d ", gInlineColumnsEnabled ? 1 : 0];
    UIWindow *kw = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) { if (!w.hidden && w.isKeyWindow) { kw = w; break; } }
    UIViewController *root = kw.rootViewController;
    UIViewController *top = root; int pd = 0;
    while (top.presentedViewController && pd < 8) { top = top.presentedViewController; pd++; }
    [s appendFormat:@"root=%@ top=%@ pres=%d ", root ? NSStringFromClass(root.class) : @"nil", top ? NSStringFromClass(top.class) : @"nil", pd];
    [s appendString:@"wins["];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        [s appendFormat:@"%@%@/%@ ", w.isKeyWindow ? @"K" : @"-", w.hidden ? @"H" : @"-", w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil"];
    }
    [s appendString:@"] "];
    UIViewController *paging = nfb_findVisibleHomePagingController();
    [s appendFormat:@"paging=%@/win%d ", paging ? NSStringFromClass(paging.class) : @"nil", (paging && [paging isViewLoaded] && paging.view.window) ? 1 : 0];
    UIScrollView *h = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    if (h) {
        CGFloat cw = nfb_columnsColumnWidth(h.bounds.size.width);
        CGFloat maxX = nfb_columnsMaxOffsetXForScroll(h);
        CGFloat snapX = nfb_columnsSnappedOffsetX(h.contentOffset.x, cw, maxX);
        [s appendFormat:@"h.off=%.0f c=%.0f b=%.0f cw=%.0f snap=%.0f max=%.0f pg=%d drag=%d edgeAllow=%d ",
            h.contentOffset.x, h.contentSize.width, h.bounds.size.width, cw, snapX, maxX,
            h.pagingEnabled ? 1 : 0, (h.isDragging || h.isTracking || h.isDecelerating) ? 1 : 0,
            nfb_columnsShouldEnableEdgeMenuForScroll(h) ? 1 : 0];
    }
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    [s appendFormat:@"cols=%lu[", (unsigned long)pages.count];
    NSUInteger i = 0;
    for (UIViewController *p in pages) {
        UIScrollView *sv = [p isViewLoaded] ? nfb_mainScrollViewOf(p) : nil;
        [s appendFormat:@"%lu:w%d/h%.0f ", (unsigned long)i, ([p isViewLoaded] && p.view.window) ? 1 : 0, sv ? sv.contentSize.height : -1.0];
        i++;
    }
    [s appendString:@"] "];
    if (gInlineColumnsEnabled || [reason containsString:@"present"]) {
        [s appendFormat:@"pageList=%@ ", nfb_columnsPageSummary(paging)];
    }
    CGRect streamFrame = gStreamButton && gStreamButton.superview ? [gStreamButton.superview convertRect:gStreamButton.frame toView:nil] : CGRectZero;
    [s appendFormat:@"allTopBtn=%d/sup%d streamBtn=%d/sup%d/h%d f=(%.0f,%.0f,%.0f,%.0f) page=%@ ",
        gColumnsAllTopButton ? 1 : 0, (gColumnsAllTopButton && gColumnsAllTopButton.superview) ? 1 : 0,
        gStreamButton ? 1 : 0, (gStreamButton && gStreamButton.superview) ? 1 : 0, (gStreamButton && gStreamButton.hidden) ? 1 : 0,
        streamFrame.origin.x, streamFrame.origin.y, streamFrame.size.width, streamFrame.size.height,
        nfb_currentSelectedTabPage() ?: @"(nil)"];
    [s appendFormat:@"edgeGestures=%ld/en%ld ", (long)nfb_countColumnsEdgeMenuGestures(), (long)nfb_countEnabledColumnsEdgeMenuGestures()];
    UIViewController *segmented = paging ? nfb_parentControllerNamed(paging, @"Segmented") : nil;
    UIViewController *container = paging ? nfb_parentControllerNamed(paging, @"HomeTimelineContainer") : nil;
    NSInteger chrome = 0;
    NSInteger collapsedChrome = 0;
    if (segmented && [segmented isViewLoaded]) chrome += nfb_countSavedColumnsChromeInView(segmented.view, 0);
    if (container && [container isViewLoaded]) chrome += nfb_countSavedColumnsChromeInView(container.view, 0);
    if (segmented && [segmented isViewLoaded]) collapsedChrome += nfb_countCollapsedColumnsChromeInView(segmented.view, 0);
    if (container && [container isViewLoaded]) collapsedChrome += nfb_countCollapsedColumnsChromeInView(container.view, 0);
    [s appendFormat:@"chromeHidden=%ld/c%ld visibleTopChrome=%ld topShift=%.0f", (long)chrome, (long)collapsedChrome, (long)nfb_countVisibleTopHomeChrome(), nfb_columnsTopShift()];
    NFBLogEvent(s);
}

#if NFB_DIAG
static void nfb_appendColumnsDiag(NSMutableString *s, UIViewController *active) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    UIScrollView *h = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    NSArray<NSDictionary *> *entries = nfb_currentColumnEntriesForPaging(paging);
    BOOL applied = h && objc_getAssociatedObject(h, &kNFBInlineColumnsAppliedKey) != nil;
    NSIndexPath *selectedIndexPath = paging ? nfb_pagingSelectedIndexPath(paging) : nil;
    NSInteger estimatedPages = paging ? nfb_estimatedHomePagingPageCount(paging) : 0;
    id dataSource = paging ? nfb_pagingDataSource(paging) : nil;
    [s appendFormat:@"columns enabled=%d paging=%@ applied=%d entries=%lu pages=%lu estimatedPages=%ld selectedIndexPath=%@ dataSource=%@\n",
        gInlineColumnsEnabled ? 1 : 0,
        paging ? NSStringFromClass(paging.class) : @"(nil)",
        applied ? 1 : 0,
        (unsigned long)entries.count,
        (unsigned long)pages.count,
        (long)estimatedPages,
        selectedIndexPath ?: @"(nil)",
        dataSource ? NSStringFromClass([dataSource class]) : @"(nil)"];
    [s appendFormat:@"columnsOverlay=%d overlayWindow=%d frame=(%.1f,%.1f,%.1f,%.1f) scrollContent=(%.1f,%.1f) scrollBounds=(%.1f,%.1f) button=%d\n",
        gColumnsOverlayView ? 1 : 0,
        (gColumnsOverlayView && gColumnsOverlayView.window) ? 1 : 0,
        gColumnsOverlayView ? gColumnsOverlayView.frame.origin.x : 0.0,
        gColumnsOverlayView ? gColumnsOverlayView.frame.origin.y : 0.0,
        gColumnsOverlayView ? gColumnsOverlayView.frame.size.width : 0.0,
        gColumnsOverlayView ? gColumnsOverlayView.frame.size.height : 0.0,
        gColumnsOverlayScrollView ? gColumnsOverlayScrollView.contentSize.width : 0.0,
        gColumnsOverlayScrollView ? gColumnsOverlayScrollView.contentSize.height : 0.0,
        gColumnsOverlayScrollView ? gColumnsOverlayScrollView.bounds.size.width : 0.0,
        gColumnsOverlayScrollView ? gColumnsOverlayScrollView.bounds.size.height : 0.0,
        gColumnsAllTopButton ? 1 : 0];
    if (h) {
        CGFloat columnWidth = nfb_columnsColumnWidth(h.bounds.size.width);
        CGFloat maxOffsetX = nfb_columnsMaxOffsetXForScroll(h);
        CGFloat snapOffsetX = nfb_columnsSnappedOffsetX(h.contentOffset.x, columnWidth, maxOffsetX);
        NSNumber *targetWidth = objc_getAssociatedObject(h, &kNFBInlineColumnsTargetContentWidthKey);
        [s appendFormat:@"nativeHScroll class=%@ frame=(%.1f,%.1f,%.1f,%.1f) offset=(%.1f,%.1f) content=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) adjusted=(%.1f,%.1f,%.1f,%.1f) paging=%d bounceH=%d columnWidth=%.1f snapOffset=%.1f maxOffset=%.1f targetContent=%.1f edgeAllow=%d topShift=%.1f\n",
            NSStringFromClass(h.class), h.frame.origin.x, h.frame.origin.y, h.frame.size.width, h.frame.size.height,
            h.contentOffset.x, h.contentOffset.y, h.contentSize.width, h.contentSize.height,
            h.bounds.size.width, h.bounds.size.height,
            h.contentInset.top, h.contentInset.left, h.contentInset.bottom, h.contentInset.right,
            h.adjustedContentInset.top, h.adjustedContentInset.left, h.adjustedContentInset.bottom, h.adjustedContentInset.right,
            h.pagingEnabled ? 1 : 0, h.alwaysBounceHorizontal ? 1 : 0,
            columnWidth, snapOffsetX, maxOffsetX, targetWidth ? targetWidth.doubleValue : 0.0,
            nfb_columnsShouldEnableEdgeMenuForScroll(h) ? 1 : 0, nfb_columnsTopShift()];
    }
    UIViewController *segmented = paging ? nfb_parentControllerNamed(paging, @"Segmented") : nil;
    UIViewController *container = paging ? nfb_parentControllerNamed(paging, @"HomeTimelineContainer") : nil;
    NSInteger hiddenChrome = 0;
    NSInteger collapsedChrome = 0;
    if (segmented && [segmented isViewLoaded]) hiddenChrome += nfb_countSavedColumnsChromeInView(segmented.view, 0);
    if (container && [container isViewLoaded]) hiddenChrome += nfb_countSavedColumnsChromeInView(container.view, 0);
    if (segmented && [segmented isViewLoaded]) collapsedChrome += nfb_countCollapsedColumnsChromeInView(segmented.view, 0);
    if (container && [container isViewLoaded]) collapsedChrome += nfb_countCollapsedColumnsChromeInView(container.view, 0);
    [s appendFormat:@"columnsChromeHidden=%ld collapsed=%ld segmented=%@ container=%@\n",
        (long)hiddenChrome,
        (long)collapsedChrome,
        segmented ? NSStringFromClass(segmented.class) : @"(nil)",
        container ? NSStringFromClass(container.class) : @"(nil)"];

    NSUInteger entryIdx = 0;
    for (NSDictionary *entry in entries) {
        NSString *identity = nfb_columnEntryIdentity(entry);
        if (identity.length > 120) identity = [[identity substringToIndex:120] stringByAppendingString:@"..."];
        UIViewController *vc = nfb_columnEntryViewController(entry);
        [s appendFormat:@"entry[%lu] kind=%@ hidden=%d title=%@ id=%@ vc=%@ win=%d\n",
            (unsigned long)entryIdx,
            entry[@"kind"] ?: @"-",
            nfb_columnEntryIsHidden(entry) ? 1 : 0,
            nfb_columnEntryTitle(entry) ?: @"-",
            identity.length ? identity : @"-",
            vc ? NSStringFromClass(vc.class) : @"-",
            (vc && [vc isViewLoaded] && vc.view.window) ? 1 : 0];
        entryIdx++;
    }
    if (gNFBColumnsAppTabReasons.count) {
        [s appendString:@"appTabColumnReasons:\n"];
        for (NSString *identity in gNFBColumnsAppTabReasons) {
            [s appendFormat:@"  %@ => %@\n", identity, gNFBColumnsAppTabReasons[identity]];
        }
    }

    NSUInteger idx = 0;
    for (UIViewController *page in pages) {
        UIScrollView *sv = [page isViewLoaded] ? nfb_mainScrollViewOf(page) : nil;
        CGRect frame = [page isViewLoaded] ? page.view.frame : CGRectZero;
        NSString *identity = nfb_columnTimelineIdentity(page);
        if (identity.length > 120) identity = [[identity substringToIndex:120] stringByAppendingString:@"..."];
        [s appendFormat:@"column[%lu] class=%@ id=%@ loaded=%d window=%d hidden=%d recommended=%d atTop=%d frame=(%.1f,%.1f,%.1f,%.1f)",
            (unsigned long)idx, NSStringFromClass(page.class), identity.length ? identity : @"-",
            [page isViewLoaded] ? 1 : 0,
            ([page isViewLoaded] && page.view.window) ? 1 : 0,
            ([page isViewLoaded] && page.view.hidden) ? 1 : 0,
            nfb_isRecommendedHomeTimeline(page) ? 1 : 0,
            nfb_isTimelineAtTop(page) ? 1 : 0,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
        if (sv) {
            CGFloat topY = -sv.adjustedContentInset.top;
            CGFloat targetTopInset = ([page isViewLoaded] && page.view.window) ? nfb_columnsTopContentInsetForPageView(page.view) : 0.0;
            CGRect svFrame = sv.superview ? [sv.superview convertRect:sv.frame toView:page.view] : sv.frame;
            [s appendFormat:@" scroll=%@ sframe=(%.1f,%.1f,%.1f,%.1f) targetTopInset=%.1f offset=(%.1f,%.1f) topY=%.1f content=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) adjusted=(%.1f,%.1f,%.1f,%.1f)",
                NSStringFromClass(sv.class), svFrame.origin.x, svFrame.origin.y, svFrame.size.width, svFrame.size.height,
                targetTopInset,
                sv.contentOffset.x, sv.contentOffset.y, topY,
                sv.contentSize.width, sv.contentSize.height, sv.bounds.size.width, sv.bounds.size.height,
                sv.contentInset.top, sv.contentInset.left, sv.contentInset.bottom, sv.contentInset.right,
                sv.adjustedContentInset.top, sv.adjustedContentInset.left, sv.adjustedContentInset.bottom, sv.adjustedContentInset.right];
        }
        [s appendString:@"\n"];
        idx++;
    }
    // b52: in-column detail nav geometry — traitH should read 1 (compact) after the b52 override and
    // the content scroll should have a ~340pt-wide frame with non-zero contentSize. If the column is
    // still black, this line tells whether it's a width/trait problem or a data-load problem.
    for (NSString *detailKey in gNFBColumnsDetailNavControllers) {
        UINavigationController *dnav = gNFBColumnsDetailNavControllers[detailKey];
        UIViewController *dtop = dnav.topViewController ?: dnav.viewControllers.firstObject;
        UIScrollView *dsv = (dtop && [dtop isViewLoaded]) ? nfb_mainScrollViewOf(dtop) : nil;
        CGRect dnavFrame = [dnav isViewLoaded] ? dnav.view.frame : CGRectZero;
        CGRect dtopFrame = (dtop && [dtop isViewLoaded]) ? dtop.view.frame : CGRectZero;
        [s appendFormat:@"columnDetail[b63] key=%@ top=%@ win=%d hidden=%d alpha=%.2f traitH=%ld navFrame=(%.1f,%.1f,%.1f,%.1f) topFrame=(%.1f,%.1f,%.1f,%.1f) scroll=%@ sframe=(%.1f,%.1f,%.1f,%.1f) content=(%.1f,%.1f)\n",
            detailKey,
            dtop ? NSStringFromClass(dtop.class) : @"-",
            ([dnav isViewLoaded] && dnav.view.window) ? 1 : 0,
            ([dnav isViewLoaded] && dnav.view.hidden) ? 1 : 0,
            [dnav isViewLoaded] ? dnav.view.alpha : 0.0,
            dtop ? (long)dtop.traitCollection.horizontalSizeClass : 0,
            dnavFrame.origin.x, dnavFrame.origin.y, dnavFrame.size.width, dnavFrame.size.height,
            dtopFrame.origin.x, dtopFrame.origin.y, dtopFrame.size.width, dtopFrame.size.height,
            dsv ? NSStringFromClass(dsv.class) : @"nil",
            dsv ? dsv.frame.origin.x : 0.0, dsv ? dsv.frame.origin.y : 0.0,
            dsv ? dsv.frame.size.width : 0.0, dsv ? dsv.frame.size.height : 0.0,
            dsv ? dsv.contentSize.width : 0.0, dsv ? dsv.contentSize.height : 0.0];
    }
    // Always surface the borrow outcome (the borrow runs once, often before recording starts, so its
    // one-time logs may be missing — this latched state shows what happened regardless).
    {
        UIViewController *gh = gNFBColumnsGuideHost;
        UIScrollView *gsv = gh ? nfb_mainScrollViewOf(gh) : nil;
        [s appendFormat:@"guideBorrowDiag failed=%d host=%@ parent=%@ ready=%d attempts=%d content=%.0fx%.0f reason=%@\n",
            gNFBColumnsGuideBorrowFailed ? 1 : 0,
            gh ? NSStringFromClass(gh.class) : @"nil",
            (gh && gh.parentViewController) ? NSStringFromClass(gh.parentViewController.class) : @"-",
            gNFBColumnsGuideContentReady ? 1 : 0, gNFBGuideBorrowAttempts,
            gsv ? gsv.contentSize.width : 0.0, gsv ? gsv.contentSize.height : 0.0,
            gNFBGuideBorrowReason ?: @"-"];
    }
    // Issue B (full-width) constraint introspection: dump the primary app-split host's width-governing
    // constraints so the exact one can be pinned if the heuristic in nfb_columnsExpandPrimaryViaConstraint
    // misses it. Read-only.
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UIViewController *fwPaging = nfb_findVisibleHomePagingController();
        UIScrollView *fwScroll = fwPaging ? nfb_horizontalPagingScrollViewOf(fwPaging) : nil;
        UIView *primaryHost = fwScroll ? nfb_enclosingAppSplitHostView((UIView *)fwScroll) : nil;
        if (primaryHost) {
            UIView *fwContainer = primaryHost.superview;
            UIViewController *split = fwPaging ? nfb_columnsAppSplitForPaging(fwPaging) : nil;
            [s appendFormat:@"nativeSplitDiag[b63] split=%@ suppressed=%d storedLive=%d crashed=%ld\n",
                split ? NSStringFromClass(split.class) : @"nil",
                gNFBNativeSplitTierSuppressed ? 1 : 0,
                (gNFBNativeSplitTierSplit && gNFBNativeSplitTierSplit.viewIfLoaded.window) ? 1 : 0,
                (long)[NSUserDefaults.standardUserDefaults integerForKey:@"NFBNativeSplitTierCrashedBuild"]];
            [s appendFormat:@"fullWidthDiag[b63] hostW=%.1f containerW=%.1f scrollW=%.1f chainLatched=%d pref=%d\n",
                primaryHost.bounds.size.width, fwContainer ? fwContainer.bounds.size.width : -1.0,
                fwScroll ? fwScroll.bounds.size.width : -1.0, gNFBFWChainLatched ? 1 : 0, nfb_columnsFullWidthPref() ? 1 : 0];
            NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
            [cs addObjectsFromArray:primaryHost.constraints];
            if (fwContainer) [cs addObjectsFromArray:fwContainer.constraints];
            int n = 0;
            for (NSLayoutConstraint *c in cs) {
                if (c.firstItem != primaryHost && c.secondItem != primaryHost) continue;
                if (!(c.firstAttribute == NSLayoutAttributeWidth || c.firstAttribute == NSLayoutAttributeTrailing ||
                      c.firstAttribute == NSLayoutAttributeRight || c.firstAttribute == NSLayoutAttributeLeading ||
                      c.firstAttribute == NSLayoutAttributeLeft ||
                      c.secondAttribute == NSLayoutAttributeWidth || c.secondAttribute == NSLayoutAttributeTrailing)) continue;
                [s appendFormat:@"  fwC[%d] %@ a1=%ld a2=%ld const=%.1f mult=%.2f rel=%ld active=%d owner=%@\n",
                    n++, [primaryHost.constraints containsObject:c] ? @"onHost" : @"onSuper",
                    (long)c.firstAttribute, (long)c.secondAttribute, c.constant, c.multiplier,
                    (long)c.relation, c.isActive ? 1 : 0,
                    c.secondItem ? NSStringFromClass([c.secondItem class]) : @"nil"];
                if (n >= 12) break;
            }
        }
    }
    UIViewController *searchVC = gNFBColumnsSearchColumnController;
    if (searchVC && [searchVC isViewLoaded]) {
        UIView *searchView = searchVC.view;
        UIScrollView *searchScroll = nfb_mainScrollViewOf(searchVC);
        CGRect searchFrame = searchView.frame;
        [s appendFormat:@"searchColumnDiag vc=%@ loaded=1 window=%d hidden=%d frame=(%.1f,%.1f,%.1f,%.1f) scroll=%@ atTop=%d text=%@\n",
            NSStringFromClass(searchVC.class),
            searchView.window ? 1 : 0,
            searchView.hidden ? 1 : 0,
            searchFrame.origin.x, searchFrame.origin.y, searchFrame.size.width, searchFrame.size.height,
            searchScroll ? NSStringFromClass(searchScroll.class) : @"nil",
            nfb_isTimelineAtTop(searchVC) ? 1 : 0,
            nfb_diagTextForView(searchView, 160) ?: @"-"];
        if (searchScroll) {
            [s appendFormat:@"searchColumnScroll offset=(%.1f,%.1f) content=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) adjusted=(%.1f,%.1f,%.1f,%.1f)\n",
                searchScroll.contentOffset.x, searchScroll.contentOffset.y,
                searchScroll.contentSize.width, searchScroll.contentSize.height,
                searchScroll.bounds.size.width, searchScroll.bounds.size.height,
                searchScroll.contentInset.top, searchScroll.contentInset.left, searchScroll.contentInset.bottom, searchScroll.contentInset.right,
                searchScroll.adjustedContentInset.top, searchScroll.adjustedContentInset.left, searchScroll.adjustedContentInset.bottom, searchScroll.adjustedContentInset.right];
        }
    }
    if (segmented && [segmented isViewLoaded] && paging && [paging isViewLoaded]) {
        nfb_appendColumnsChromeDiag(s, segmented.view, paging.view, segmented.view, 0);
    }
    if (container && [container isViewLoaded] && paging && [paging isViewLoaded] && container != segmented) {
        nfb_appendColumnsChromeDiag(s, container.view, paging.view, container.view, 0);
    }
}
#endif

// Always defined: the menu / recording-stop call sites stay unconditional, and a
// diagnostics-stripped build just returns this stub line instead of the report.
static NSString *nfb_buildDiagnosticReport(void) {
#if NFB_DIAG
    UIViewController *active = gActiveItemsVC;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"active=%@\n", active ? NSStringFromClass([active class]) : @"(nil)"];
    if (active) nfb_appendScrollDiag(s, active);
    NSString *columnsMode = nil;
    @try { columnsMode = BHTColumnsModeDiagnostic(); } @catch (NSException *e) { columnsMode = nil; }
    if (columnsMode.length) [s appendString:columnsMode];
    nfb_appendColumnsDiag(s, active);
    nfb_appendTopChromeDiag(s);
    nfb_appendSearchChromeDiag(s);
    nfb_appendSavedColumnsChromeDiag(s);
    nfb_appendCoveringViewsDiag(s);
    nfb_appendGestureDiag(s);
    nfb_appendSpacesCandidatesDiag(s);
    nfb_appendExploreDiscoveryDiag(s);
    nfb_appendGuideClassDiag(s);
    nfb_appendTabFactoryDiag(s);
    nfb_dumpTree(nfb_homeRoot(active), 0, s);
    return s;
#else
    return @"(diagnostics disabled: rebuild with NFB_DIAG=1)";
#endif
}

static void nfb_requestLayoutActiveHomePagingOnNextTurn(void) {
    if (gNFBLayoutActiveHomePagingScheduled) return;
    gNFBLayoutActiveHomePagingScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gNFBLayoutActiveHomePagingScheduled = NO;
        nfb_layoutActiveHomePaging();
    });
}

static void nfb_layoutActiveHomePaging(void) {
    if (gNFBLayoutActiveHomePagingRunning) {
        if (gNFBLogRecording) {
            static NSString *lastLayoutReentryKey = nil;
            NSString *key = @"layout[b63] activeHome reentry deferred";
            if (![key isEqualToString:lastLayoutReentryKey]) { lastLayoutReentryKey = [key copy]; NFBLogEvent(key); }
        }
        nfb_requestLayoutActiveHomePagingOnNextTurn();
        return;
    }
    gNFBLayoutActiveHomePagingRunning = YES;
    @try {
    UIViewController *paging = gInlineColumnsEnabled ? nfb_findVisibleHomePagingController() : nfb_findAnyHomePagingController();
    if (!paging || ![paging isViewLoaded]) {
        if (!gInlineColumnsEnabled) {
            nfb_removeColumnsOverlay();
            if (gNFBNativeSplitTierSuppressed) nfb_columnsApplyNativeSplitTierForPaging(nil, NO);
            // Codex: columns are off but we couldn't resolve a pager — still restore the extended-content
            // rail (the helper uses the stored split, so paging is not required).
            if (gNFBExtendedContentActuallyRemoved) { gNFBExtRemoveScheduled = NO; nfb_columnsSetExtendedContentRemoved(nil, NO); }
        }
        return;
    }
    [paging.view setNeedsLayout];
    if (!gInlineColumnsEnabled) [paging.view layoutIfNeeded];
    if (gInlineColumnsEnabled) nfb_applyInlineColumns(paging);
    else nfb_restoreInlineColumns(paging);
    } @finally {
        gNFBLayoutActiveHomePagingRunning = NO;
    }
}

static void nfb_scheduleLayoutActiveHomePagingLight(void) {
    if (gNFBColumnsLightLayoutScheduled) {
        nfb_requestLayoutActiveHomePagingOnNextTurn();
        return;
    }
    gNFBColumnsLightLayoutScheduled = YES;
    nfb_requestLayoutActiveHomePagingOnNextTurn();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gNFBColumnsLightLayoutScheduled = NO;
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
}

static void nfb_scheduleLayoutActiveHomePaging(void) {
    if (gNFBColumnsSizeTransitioning) {
        nfb_scheduleLayoutActiveHomePagingLight();
        return;
    }
    nfb_requestLayoutActiveHomePagingOnNextTurn();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_requestLayoutActiveHomePagingOnNextTurn();
    });
}

static void nfb_columnsBeginSizeTransition(void) {
    if (!gInlineColumnsEnabled) return;
    gNFBColumnsSizeTransitioning = YES;
    NSTimeInterval stamp = CACurrentMediaTime();
    gNFBColumnsSizeTransitionStamp = stamp;
    if (gNFBLogRecording) NFBLogEvent(@"columnsResize[b63] begin lightLayout");
    nfb_scheduleLayoutActiveHomePagingLight();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gNFBColumnsSizeTransitioning || fabs(gNFBColumnsSizeTransitionStamp - stamp) > 0.001) return;
        gNFBColumnsSizeTransitioning = NO;
        if (gNFBLogRecording) NFBLogEvent(@"columnsResize[b63] timeout finalLayout");
        nfb_scheduleLayoutActiveHomePaging();
    });
}

static void nfb_columnsEndSizeTransition(void) {
    if (!gInlineColumnsEnabled) {
        gNFBColumnsSizeTransitioning = NO;
        return;
    }
    gNFBColumnsSizeTransitioning = NO;
    if (gNFBLogRecording) NFBLogEvent(@"columnsResize[b63] end finalLayout");
    nfb_scheduleLayoutActiveHomePaging();
}

static void nfb_reapplyColumnsSegmentedControlHidden(void) {
    if (!gInlineColumnsEnabled) return;
    UIViewController *paging = nfb_findVisibleHomePagingController();
    if (!paging) paging = nfb_findAnyHomePagingController();
    if (paging && [paging isViewLoaded]) nfb_setColumnsSegmentedHiddenForPaging(paging, YES);
    UIViewController *segmented = paging ? nfb_parentControllerNamed(paging, @"Segmented") : nil;
    if (segmented && [segmented isViewLoaded]) {
        nfb_applyColumnsSegmentedControlHidden(segmented);
        nfb_forceColumnsSegmentedControlHeightCollapsed(segmented);
    }
}

static void nfb_scheduleColumnsSegmentedControlHiddenReapply(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
    // Late passes: a data-driven pager/segment reload (pinned lists loading at ~1-2s) can
    // re-expand the segment height after the early passes, leaving the intermittent "余白".
    // These idempotent re-asserts outlast that without touching any non-columns/non-home path.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_reapplyColumnsSegmentedControlHidden();
    });
}

BOOL NFBInlineColumnsEnabled(void) {
    return gInlineColumnsEnabled;
}

// b57: bridges for the ModernSettings layout screen (separate compilation unit).
UIViewController *NFBMakeColumnsManageViewController(void) {
    return nfb_makeColumnsSettingsViewController();
}

void NFBStreamPrefsChanged(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBStreamPrefsChanged(); });
        return;
    }
    UIViewController *vc = gActiveItemsVC;
    if (vc) nfb_streamStart(vc);   // restart the timer so a changed interval takes effect immediately
}

void NFBSetInlineColumnsEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBSetInlineColumnsEnabled(enabled); });
        return;
    }
    BOOL changed = gInlineColumnsEnabled != enabled;
    if (changed) NFBLogEvent([NSString stringWithFormat:@"NFBSetInlineColumns -> %d", enabled]);
    gInlineColumnsEnabled = enabled;
    if (!enabled) {
        nfb_columnsDismissAllDetailNavs();
        gNFBLastTouchedColumnView = nil;
        gNFBLastTouchedColumnKey = nil;
        gNFBLastTouchedColumnIndex = NSNotFound;
        gNFBLastTouchedColumnAt = 0.0;
        gInlineColumnsNeedsInitialOffsetReset = NO;
        gColumnsHiddenBarHeight = 0.0;
        gColumnsEdgeMenuStateKnown = NO;
        nfb_setColumnsEdgeMenuGesturesEnabled(YES);
        nfb_restoreAllSavedColumnsChromeSoon(@"disable");
    }
    if (enabled) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NFBNativeSplitTierInFlightBuild"];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NFBNativeSplitTierCrashedBuild"];
        [NSUserDefaults.standardUserDefaults synchronize];
        if (changed) {
            gColumnsHiddenBarHeight = 0.0;
            gInlineColumnsNeedsInitialOffsetReset = YES;
            [gNFBColumnsAppTabFailed removeAllObjects];
            [gNFBColumnsAppTabReasons removeAllObjects];
            nfb_scheduleColumnsSegmentedControlHiddenReapply();
        }
        gColumnsEdgeMenuStateKnown = NO;
        nfb_setColumnsEdgeMenuGesturesEnabled(NO);
        UIViewController *paging = nfb_findAnyHomePagingController();
        if (paging) {
            if (changed) nfb_requestColumnsPagingPreload(paging, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
    }
    nfb_scheduleLayoutActiveHomePaging();
    NFBUpdateStreamButtonVisibility();
}

#pragma mark - Hooks

%hook UIGestureRecognizer
- (void)setEnabled:(BOOL)enabled {
    if (enabled && gInlineColumnsEnabled && nfb_columnsShouldTreatGestureAsEdgeMenu(self)) {
        UIScrollView *h = nil;
        UIViewController *paging = nfb_findAnyHomePagingController();
        if (paging) h = nfb_horizontalPagingScrollViewOf(paging);
        if (!nfb_columnsShouldEnableEdgeMenuForScroll(h)) {
            %orig(NO);
            return;
        }
    }
    %orig(enabled);
}
%end

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    if (gInlineColumnsEnabled && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan || touch.phase == UITouchPhaseEnded) {
                nfb_columnsNoteTouchedView(touch.view, touch.phase == UITouchPhaseBegan ? @"began" : @"ended");
                break;
            }
        }
    }
    %orig(event);
}
%end

%hook UINavigationController
- (void)pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    if (gInlineColumnsEnabled) {
        UINavigationController *appTabNav = nfb_columnsAppTabNavForTouchedColumn();
        if (appTabNav && (UINavigationController *)self == appTabNav) {
            // The app-tab column's own nav is pushing (e.g. the Search/Explore field) -> it already
            // renders inside the 340pt column. Let it through; never re-route its own pushes.
            %orig(vc, animated);
            return;
        }
        if ((appTabNav || nfb_columnsNavSourceMatchesTouchedColumn((UINavigationController *)self)) &&
            nfb_columnsRouteControllerIntoTouchedColumn(vc, @"navPush", animated)) {
            return;
        }
    }
    %orig(vc, animated);
}
%end

%hook UIViewController
- (void)showViewController:(UIViewController *)vc sender:(id)sender {
    if (gInlineColumnsEnabled && nfb_columnsControllerSourceMatchesTouchedColumn((UIViewController *)self) &&
        nfb_columnsRouteControllerIntoTouchedColumn(vc, @"show", YES)) {
        return;
    }
    %orig(vc, sender);
}

- (void)showDetailViewController:(UIViewController *)vc sender:(id)sender {
    if (gInlineColumnsEnabled && nfb_columnsControllerSourceMatchesTouchedColumn((UIViewController *)self) &&
        nfb_columnsRouteControllerIntoTouchedColumn(vc, @"showDetail", YES)) {
        return;
    }
    %orig(vc, sender);
}

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (gInlineColumnsEnabled && nfb_columnsControllerSourceMatchesTouchedColumn((UIViewController *)self) &&
        nfb_columnsRouteControllerIntoTouchedColumn(vc, @"present", animated)) {
        if (completion) completion();
        return;
    }
    %orig(vc, animated, completion);
}
%end

// Issue C safety: a pushed detail must keep its nav bar (back button/title). If columns hid the home
// logo bar (setNavigationBarHidden:YES at root), restore it the instant anything is pushed, BEFORE the
// detail appears — so the back affordance is never missing. Popping back to root re-hides via layout.
%hook T1TimelineNavigationController
- (void)pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    if (gNFBColumnsLogoNav == self) nfb_restoreColumnsLogoBar();
    if (gInlineColumnsEnabled && !nfb_columnsNavIsColumnLocal((UINavigationController *)self) &&
        nfb_columnsRouteControllerIntoTouchedColumn(vc, @"timelinePush", animated)) {
        return;
    }
    %orig(vc, animated);
}
%end

// Issue B (b37) full-width: drive Twitter's native split tier. At the widest iPad width,
// private_splitModeForSize:displayExtendedContent:displaySideBar: normally receives
// displayExtendedContent=YES and chooses the sidebar+content+trends tier. Columns force only that
// input to NO, preserving the sidebar flag so Twitter chooses its native medium tier instead.
%hook T1AppSplitViewController
- (BOOL)displayExtendedContent {
    if (nfb_columnsShouldForceNativeSplitTierForSplit((UIViewController *)self)) return NO;
    return %orig;
}
- (void)setDisplayExtendedContent:(BOOL)displayExtendedContent {
    if (nfb_columnsShouldForceNativeSplitTierForSplit((UIViewController *)self)) {
        %orig(NO);
        return;
    }
    %orig(displayExtendedContent);
}
- (void)setDisplayExtendedContent:(BOOL)displayExtendedContent animated:(BOOL)animated {
    if (nfb_columnsShouldForceNativeSplitTierForSplit((UIViewController *)self)) {
        %orig(NO, animated);
        return;
    }
    %orig(displayExtendedContent, animated);
}
- (NSInteger)private_splitModeForSize:(CGSize)size displayExtendedContent:(BOOL)displayExtendedContent displaySideBar:(BOOL)displaySideBar {
    if (nfb_columnsShouldForceNativeSplitTierForSplit((UIViewController *)self)) {
        NSInteger mode = %orig(size, NO, displaySideBar);
        if (gNFBLogRecording) {
            static NSString *lastNativeTierKey = nil;
            NSString *key = [NSString stringWithFormat:@"nativeTier[b63] size=%.0fx%.0f ext=%d->0 side=%d mode=%ld",
                size.width, size.height, displayExtendedContent ? 1 : 0, displaySideBar ? 1 : 0, (long)mode];
            if (![key isEqualToString:lastNativeTierKey]) { lastNativeTierKey = [key copy]; NFBLogEvent(key); }
        }
        return mode;
    }
    return %orig(size, displayExtendedContent, displaySideBar);
}
%end

// Button lifecycle on the stable Home container.
%hook THFHomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated { %orig; NFBLogSnapshot(@"homeContainer.appear"); nfb_syncHomeTimelineTabIdentifierFromController(self); nfb_installButton(self.view.window); if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging(); else nfb_restoreAllSavedColumnsChrome(); }
- (void)viewDidDisappear:(BOOL)animated { %orig; NFBLogSnapshot(@"homeContainer.disappear"); nfb_removeButton(); }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig(size, coordinator);
    if (!gInlineColumnsEnabled) return;
    nfb_columnsBeginSizeTransition();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_columnsEndSizeTransition();
    }];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging();
}
- (void)selectTimelineVariant:(id)variant shouldRefresh:(BOOL)shouldRefresh {
    nfb_persistHomeTimelineTabIdentifier(nfb_identifierForTimelineVariantArgument(variant));
    %orig(variant, shouldRefresh);
}
%end

%hook THFHomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; NFBLogEvent([NSString stringWithFormat:@"homeItems viewDidAppear recommended=%d", nfb_isRecommendedHomeTimeline(self) ? 1 : 0]); nfb_syncHomeTimelineTabIdentifierFromController(nfb_parentControllerNamed(self, @"HomeTimelineContainer")); gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
// NOTE: do NOT stop the timer on disappear. Switching to a pinned list (ニコニコ/投資)
// disappears this home VC; the timer must keep running so it can refresh the list via
// the paging controller's selectedViewController. It self-cleans on dealloc / when off.
- (void)viewDidDisappear:(BOOL)animated { %orig; }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_noteActiveTimelineScroll(scrollView); nfb_visibilityForScroll(scrollView); }
%end

// Older app versions.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_noteActiveTimelineScroll(scrollView); nfb_visibilityForScroll(scrollView); }
%end

// Pinned-list timelines (ニコニコ / 投資) are hosted by T1URTViewController inside the Home paging
// surface and never reach the home items VC scroll hook, so the stream state icon kept reading
// "paused" even when the list sat at the very top. Refresh straight from the list's own scroll,
// but only when it belongs to the Home surface so unrelated URT screens are unaffected.
%hook T1URTViewController
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    if (!nfb_parentControllerNamed((UIViewController *)self, @"HomeTimelineContainer")) return;
    // Icon refresh only — do NOT run the full visibility logic here (it fades/disables the button).
    nfb_noteActiveTimelineScroll(scrollView);
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}
%end

// Twitter's paging layout keeps resetting the horizontal scroll's contentSize to pages*fullWidth
// (1808) — including mid-drag — which let the scroll run past the 340pt columns and snap back.
// Only for the columns-applied home pager, force the width to the current column target.
%hook TFNPagingScrollView
- (void)setContentOffset:(CGPoint)offset {
    %orig(offset);
    if (gInlineColumnsEnabled && objc_getAssociatedObject(self, &kNFBInlineColumnsAppliedKey)) {
        nfb_updateColumnsEdgeMenuGesturesForScroll((UIScrollView *)self);
    }
}
- (void)setContentSize:(CGSize)size {
    if (gInlineColumnsEnabled && objc_getAssociatedObject(self, &kNFBInlineColumnsAppliedKey)) {
        NSNumber *targetWidth = objc_getAssociatedObject(self, &kNFBInlineColumnsTargetContentWidthKey);
        CGFloat target = targetWidth.doubleValue;
        if (target > 1.0) { %orig(CGSizeMake(target, size.height)); return; }
    }
    %orig(size);
}
// b51: crisp horizontal/vertical split WITHOUT ever hard-rejecting the pager pan. b50 returned NO here
// for a vertical-dominant drag, but that fails the WHOLE touch sequence — a horizontal swipe that
// merely STARTS with a little vertical jitter got killed, so columns felt like they wouldn't move at
// all ("うごいてない"). directionalLockEnabled does the right thing for free: the pager only scrolls
// horizontally (its content height == bounds height), so once a drag reads as vertical-dominant the
// lock disables its horizontal axis and it stays put, while horizontal AND diagonal drags still slide
// columns. No gesture is ever rejected, so horizontal can never break.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gInlineColumnsEnabled && objc_getAssociatedObject(self, &kNFBInlineColumnsAppliedKey) &&
        [gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class] &&
        gestureRecognizer == ((UIScrollView *)self).panGestureRecognizer) {
        // b56: decide the lock PER GESTURE. The b51 always-on lock froze the axis from the first
        // ~10pt: a horizontal swipe that started with vertical jitter got locked vertical and the
        // columns ignored the rest of that touch ("横のつもりが反応がない"). Lock only when the
        // start is CLEARLY vertical (|vy| > 2|vx| → pager stays put, inner timeline scrolls); any
        // meaningful horizontal component leaves the lock off so the columns track the finger.
        // Nothing is ever rejected (the b50 lesson: returning NO kills the whole touch).
        CGPoint v = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:(UIView *)self];
        // b58: a touch that lands just to STOP a decelerating column timeline reads as a tiny,
        // mostly-vertical movement; b57 locked the axis on it and the rest of that touch could not
        // slide the columns ("縦で操作した後に横が効きにくい"). Lock only on a CLEARLY vertical start
        // with real speed; a near-still or horizontal-leaning start leaves the columns free to track.
        ((UIScrollView *)self).directionalLockEnabled = (fabs(v.y) > 2.0 * fabs(v.x) && fabs(v.y) > 60.0);
    }
    return %orig(gestureRecognizer);
}
%end

%hook TFNPagingViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gInlineColumnsEnabled) nfb_applyInlineColumns(self);
    else nfb_restoreInlineColumns(self);
}
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(CGPoint *)targetContentOffset {
    %orig(scrollView, velocity, targetContentOffset);
    nfb_columnsApplyTargetSnap(scrollView, velocity, targetContentOffset);
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    %orig(scrollView, decelerate);
    if (!decelerate) {
        nfb_columnsScheduleSnapReassert(scrollView);
        nfb_columnsMaybeRunDeferredRefresh(scrollView);
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    %orig(scrollView);
    nfb_columnsScheduleSnapReassert(scrollView);
    nfb_columnsMaybeRunDeferredRefresh(scrollView);
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (gInlineColumnsEnabled) nfb_applyInlineColumns(self);
    else nfb_restoreInlineColumns(self);
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig(size, coordinator);
    if (!gInlineColumnsEnabled) return;
    nfb_columnsBeginSizeTransition();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_columnsEndSizeTransition();
    }];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging();
}
%end

%hook TFNScrollingSegmentedViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    if (gInlineColumnsEnabled) nfb_applyColumnsSegmentedControlHidden(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (gInlineColumnsEnabled) {
        nfb_applyColumnsSegmentedControlHidden(self);
        nfb_forceColumnsSegmentedControlHeightCollapsed(self);
    }
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig(size, coordinator);
    if (!gInlineColumnsEnabled) return;
    nfb_columnsBeginSizeTransition();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_columnsEndSizeTransition();
    }];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging();
}
%end
