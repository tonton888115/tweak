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
static void nfb_appendColumnsDiag(NSMutableString *s, UIViewController *active);
static void nfb_appendTopChromeDiag(NSMutableString *s);
static void nfb_appendCoveringViewsDiag(NSMutableString *s);
static void nfb_appendGestureDiag(NSMutableString *s);
static void nfb_appendSpacesCandidatesDiag(NSMutableString *s);
static void nfb_appendExploreDiscoveryDiag(NSMutableString *s);
static void nfb_appendGuideClassDiag(NSMutableString *s);
static void nfb_appendSearchChromeDiag(NSMutableString *s);
static void nfb_appendSavedColumnsChromeDiag(NSMutableString *s);
static NSString *nfb_diagShortString(NSString *value, NSUInteger maxLen);
static NSString *nfb_diagTextForView(UIView *view, NSUInteger maxLen);
static NSString *nfb_buildDiagnosticReport(void);
void NFBLogSnapshot(NSString *reason);             // compact 1-line state snapshot (records only while recording)
extern NSString *BHTColumnsLogFlags(void);          // columns flags + tab selectedIndex, from Tweak.x
static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void);
static NSArray<UIViewController *> *nfb_currentColumnRefreshControllers(void);
static NSArray<UIViewController *> *nfb_allHomePagingTimelinePages(UIViewController *paging);
static UIScrollView *nfb_horizontalPagingScrollViewOf(UIViewController *vc);
static NSInteger nfb_estimatedHomePagingPageCount(UIViewController *paging);
static void nfb_requestColumnsPagingPreload(UIViewController *paging, BOOL aggressive);
static id nfb_pagingDataSource(UIViewController *paging);
static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging);
static UIViewController *nfb_pagingViewControllerAtIndexPath(UIViewController *paging, NSIndexPath *indexPath);
static UIViewController *nfb_findAnyHomePagingController(void);
static UIViewController *nfb_findVisibleHomePagingController(void);
static UIViewController *nfb_firstColumnTimelineAwayFromTop(void);
static UIViewController *nfb_firstColumnTimelineAwayFromTopExcept(UIViewController *allowedRevealing);
static void nfb_rememberInlineColumnsOriginals(UIScrollView *scrollView);
static void nfb_layoutActiveHomePaging(void);
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

static __weak UIViewController *gActiveItemsVC = nil;   // the visible Home timeline list
static __weak UIViewController *gPendingNewTweetsVC = nil;
static __weak UIScrollView *gActiveTimelineScrollView = nil;
static UIButton *gNewTweetsPill = nil;
static BOOL gInlineColumnsEnabled = NO;
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
static id nfb_findPullControl(UIViewController *startVC);

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

static id nfb_findHomeResponder(UIViewController *startVC, SEL sel) {
    id near = nfb_findResponder(startVC, sel, 0);
    if (near) return near;
    return nfb_findResponder(nfb_homeRoot(startVC), sel, 0);
}

static BOOL nfb_doPull(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(_t1_didPullToRefresh:));
    if (t) { ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(_t1_didPullToRefresh:), nil); return YES; }
    return NO;
}
static BOOL nfb_doLoadNewer(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(loadNewer));
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(loadNewer)); return YES; }
    return NO;
}
static BOOL nfb_doReloadTop(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(reloadTop:));
    if (t) { ((void(*)(id,SEL,BOOL))objc_msgSend)(t, @selector(reloadTop:), YES); return YES; }
    return NO;
}
static BOOL nfb_doRefreshContent(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(_refreshContent));
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(_refreshContent)); return YES; }
    return NO;
}
static BOOL nfb_doSchedulePullUpdate(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(schedulePullToRefreshUpdate));
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(schedulePullToRefreshUpdate)); return YES; }
    return NO;
}
static BOOL nfb_doLoadTop(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(loadTop:));
    if (t) {
        id sender = nfb_findPullControl(startVC);
        ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(loadTop:), sender);
        return YES;
    }
    return NO;
}
static BOOL nfb_doLoadTopNil(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(loadTop:));
    if (t) { ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(loadTop:), nil); return YES; }
    return NO;
}
static NSInteger nfb_streamLoadSourceFromSender(id sender) {
    NSInteger (*fromSender)(id) = (NSInteger(*)(id))dlsym(RTLD_DEFAULT, "TFSTwitterStreamLoadSourceFromSender");
    if (!fromSender) fromSender = (NSInteger(*)(id))dlsym(RTLD_DEFAULT, "_TFSTwitterStreamLoadSourceFromSender");
    return fromSender ? fromSender(sender) : 0;
}
static BOOL nfb_doTimelineRefreshWithSource(id startVC, NSInteger source) {
    id t = nfb_findHomeResponder(startVC, @selector(refreshWithSource:completion:));
    if (t) {
        void (^completion)(void) = ^{};
        ((void(*)(id,SEL,NSInteger,id))objc_msgSend)(t, @selector(refreshWithSource:completion:), source, completion);
        return YES;
    }
    return NO;
}
static BOOL nfb_doTimelineRefresh(id startVC) {
    return nfb_doTimelineRefreshWithSource(startVC, nfb_streamLoadSourceFromSender(nfb_findPullControl(startVC)));
}

// Find an instance variable of `obj` whose type encoding mentions `typeName`.
static id nfb_ivarOfType(id obj, const char *typeName) {
    if (!obj) return nil;
    Class c = [obj class]; int guard = 0;
    while (c && guard++ < 8) {
        unsigned int n = 0; Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (enc && strstr(enc, typeName)) { id v = object_getIvar(obj, ivars[i]); free(ivars); return v; }
        }
        free(ivars);
        c = class_getSuperclass(c);
    }
    return nil;
}
static id nfb_pullToLoadTopControlOf(id obj) {
    if (nfb_resp(obj, @selector(pullToLoadTopControl))) {
        return ((id(*)(id,SEL))objc_msgSend)(obj, @selector(pullToLoadTopControl));
    }
    return nil;
}
static id nfb_findPullControl(UIViewController *startVC) {
    id ctrl = nfb_pullToLoadTopControlOf(gActiveItemsVC);
    if (!ctrl) ctrl = nfb_pullToLoadTopControlOf(startVC);
    if (!ctrl) ctrl = nfb_pullToLoadTopControlOf(nfb_findHomeResponder(startVC, @selector(pullToLoadTopControl)));
    if (!ctrl) ctrl = nfb_ivarOfType(gActiveItemsVC, "TFNPullToRefreshControl");
    if (!ctrl) ctrl = nfb_ivarOfType(nfb_findHomeResponder(startVC, @selector(_t1_didPullToRefresh:)), "TFNPullToRefreshControl");
    if (!ctrl) {
        UIScrollView *sv = nfb_scrollOf(gActiveItemsVC);
        Class cls = objc_getClass("TFNPullToRefreshControl");
        if (sv && cls) for (UIView *v in sv.subviews) if ([v isKindOfClass:cls]) { ctrl = v; break; }
    }
    return ctrl;
}
// The pull handler lives on the container but needs the real control as its sender.
static BOOL nfb_doPullWithControl(id startVC) {
    id cont = nfb_findHomeResponder(startVC, @selector(_t1_didPullToRefresh:));
    id ctrl = nfb_findPullControl(startVC);
    if (!cont || !ctrl) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(cont, @selector(_t1_didPullToRefresh:), ctrl);
    return YES;
}
// Current Twitter builds expose this on the visible items VC; it is the native
// pull-to-load-top action, with the real pull control as sender.
static BOOL nfb_doDynamicPullToLoadTop(id startVC) {
    id t = nfb_findHomeResponder(startVC, @selector(_tfn_dynamic_didPullToLoadTop:));
    id ctrl = nfb_findPullControl(startVC);
    if (!t || !ctrl) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(_tfn_dynamic_didPullToLoadTop:), ctrl);
    return YES;
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
static BOOL nfb_isReadingAwayFromTop(UIViewController *vc) {
    UIScrollView *sv = nfb_mainScrollViewOf(vc);
    if (!sv) return NO;
    CGFloat topY = -sv.adjustedContentInset.top;
    return sv.contentOffset.y > topY + 80.0;
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
    NSString *title = gInlineColumnsEnabled ? @"新しいツイートがあります - 全カラム上へ" : @"新しいツイートがあります";
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

    // Refresh whatever timeline is actually on screen, not just the home items VC.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    nfb_streamTriggerTarget(target);
}

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
    return gNFBLog.count ? [gNFBLog componentsJoinedByString:@"\n"] : @"(ログなし)";
}
NSString *NFBLogSavedFileContents(void) {
    NSString *s = [NSString stringWithContentsOfFile:nfb_logFilePath() encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s : @"(保存ログなし)";
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"TL自動更新（垂れ流し）"
        message:[NSString stringWithFormat:@"状態: %@ ／ 間隔: %ld秒", on ? @"ON" : @"OFF", (long)iv]
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (NFBLogIsRecording()) {
        [ac addAction:[UIAlertAction actionWithTitle:@"⏹ ログ録画を停止してコピー" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ [self stopLogAndShow]; }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"⏺ ログ録画を開始（既存ログ消去）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ NFBLogStartRecording(); [self toast:@"録画開始。再現操作をしてから、もう一度長押し→「停止してコピー」。詰まって停止できない時は、起動し直して「保存済みログをコピー」。"]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"📄 保存済みログをコピー（停止不要・kill後も可）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self copySavedLog]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔄 今すぐ更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamTrigger(vc); }]];
    if (gInlineColumnsEnabled) {
        [ac addAction:[UIAlertAction actionWithTitle:@"⬆︎ 全カラムを上へ移動" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_revealAllColumnTops(); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:(on ? @"自動更新を OFF にする" : @"自動更新を ON にする") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamEnabled(!on); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:(gInlineColumnsEnabled ? @"カラムモードを OFF にする" : @"カラムモードを ON にする") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        if (gInlineColumnsEnabled) NFBSetInlineColumnsEnabled(NO);
        else BHTPresentColumnsMode();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"⏱ 更新間隔を変更…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showInterval]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔧 更新方式テスト…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showTest]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔍 診断情報（コピーして送って）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self showDiag]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"録画ログ（コピー済み）" message:log preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"再コピー" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = log; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)copySavedLog {
    NSString *log = NFBLogSavedFileContents();
    UIPasteboard.generalPasteboard.string = log;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"保存ログ（コピー済み）" message:log preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"再コピー" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = log; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showDiag {
    NSString *report = nfb_buildDiagnosticReport();
    NSMutableString *s = [report mutableCopy] ?: [NSMutableString string];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"診断情報" message:s preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"コピー" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = s; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showInterval {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更新間隔" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *n in @[@5, @10, @15, @20, @30, @60]) {
        NSInteger sec = n.integerValue;
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld秒", (long)sec] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamInterval(sec); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showTest {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更新方式テスト"
        message:@"各ボタンでその方式の更新を1回試します。TLが更新された方式を教えてください。" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"A: loadTop(sender)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doLoadTop(vc)) { nfb_doSchedulePullUpdate(vc); nfb_revealTopAfterRefresh(vc); } }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"B: loadTop:nil" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doLoadTopNil(vc)) nfb_revealTopAfterRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"C: schedulePullUpdate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doSchedulePullUpdate(vc)) nfb_revealTopAfterRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"D: dynamic pullToLoadTop" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doDynamicPullToLoadTop(vc)) nfb_revealTopAfterRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"E: legacy container pull" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doPullWithControl(vc)) nfb_revealTopAfterRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"F: timeline refresh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc && nfb_doTimelineRefresh(vc)) nfb_revealTopAfterRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
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
    anim.fromValue = @1.0; anim.toValue = @0.0; anim.duration = interval;
    anim.repeatCount = HUGE_VALF; anim.removedOnCompletion = NO; anim.fillMode = kCAFillModeForwards;
    [g addAnimation:anim forKey:@"deplete"];
}

static BOOL nfb_streamCanRunForTarget(UIViewController *target) {
    if (![BHTManager autoStreamTimeline]) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
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
    gStreamStateIcon.accessibilityLabel = active ? @"ストリーミング有効" : @"ストリーミング一時停止";
    gStreamStateIcon.hidden = NO;
}

static void nfb_installButton(UIWindow *win) {
    if (!win) return;
    if (!gStreamButton) {
        gStreamButton = [[NFBStreamButton alloc] initWithFrame:CGRectZero];
        gStreamButton.translatesAutoresizingMaskIntoConstraints = NO;
        gStreamButton.accessibilityLabel = @"TL自動更新";
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
    BOOL visible = nfb_homeTabSelectedOrUnknown();
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
    if (!nfb_homeTabSelectedOrUnknown()) return NO;
    if (gInlineColumnsEnabled) {
        BOOL hasColumns = [nfb_currentColumnTimelinePages() count] > 0;
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

static char kNFBInlineColumnsAppliedKey;
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
// User chose "remove the right pane + move search into a column": we also hide the app-split
// secondary host (the persistent iPad 587pt trends/search panel) so it is not left as an empty
// panel. Captured from the search view's ancestor chain before transplant; un-hidden on restore.
static __weak UIView *gNFBColumnsSecondaryHostView = nil;
static NSArray<UIView *> *gNFBColumnsSuppressedSplitViews = nil;
static BOOL gColumnsEdgeMenuStateKnown = NO;
static BOOL gColumnsEdgeMenuLastEnabled = YES;
static char kNFBColumnLoadKickedKey;
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
    CGFloat base = columnWidth * MAX((CGFloat)pageCount, 1.0);
    CGFloat trailing = MAX(0.0, viewportWidth - columnWidth);
    return MAX(base + trailing, viewportWidth + 1.0);
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

static BOOL nfb_searchColumnVCUsableForCurrentSplit(UIViewController *paging, UIScrollView *nativeScrollView, UIView *searchView) {
    if (!paging || !nativeScrollView || !searchView) return NO;
    if (searchView.superview == nativeScrollView) return YES;   // already transplanted; do not chase a resizing split.
    UIView *secondaryHost = nfb_enclosingAppSplitHostView(searchView);
    UIView *primarySource = nativeScrollView ? (UIView *)nativeScrollView : paging.view;
    UIView *primaryHost = nfb_enclosingAppSplitHostView(primarySource);
    if (!secondaryHost || !primaryHost || secondaryHost == primaryHost) return NO;
    if (!secondaryHost.window || secondaryHost.window != nativeScrollView.window) return NO;
    if (secondaryHost.hidden || secondaryHost.alpha < 0.01) return NO;
    CGSize hostSize = secondaryHost.bounds.size;
    // The iPad secondary search pane is removed/rebuilt at narrower widths and during live
    // resizing. Transplant only from a real, stable secondary pane; otherwise the split view and
    // our column layout fight over the same navigation view and can freeze the app.
    if (hostSize.width < 320.0 || hostSize.height < 240.0) return NO;
    return YES;
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
}

static void nfb_prepareSplitForSearchColumn(UIViewController *paging, UIScrollView *nativeScrollView, UIView *searchView) {
    if (!nfb_searchColumnVCUsableForCurrentSplit(paging, nativeScrollView, searchView)) return;
    if (searchView.superview == nativeScrollView) return;
    UIView *secondaryHost = (searchView.superview != nativeScrollView) ? nfb_enclosingAppSplitHostView(searchView) : gNFBColumnsSecondaryHostView;
    UIView *primarySource = nativeScrollView ? (UIView *)nativeScrollView : paging.view;
    UIView *primaryHost = nfb_enclosingAppSplitHostView(primarySource);
    if (!secondaryHost || !primaryHost || secondaryHost == primaryHost) return;

    nfb_rememberColumnOriginalViewState(secondaryHost);
    gNFBColumnsSecondaryHostView = secondaryHost;

    secondaryHost.hidden = YES;
    secondaryHost.alpha = 0.0;
    UIView *splitRoot = primaryHost.superview ? primaryHost.superview : primaryHost;
    nfb_suppressSplitResidueViews(splitRoot);
    [splitRoot setNeedsLayout];
    [primaryHost setNeedsLayout];
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

static void nfb_layoutColumnsOverlayForPaging(UIViewController *paging) {
    if (!nfb_inlineColumnsActiveForHomePaging(paging) || ![paging isViewLoaded]) return;
    // Twitter's own paging layout runs in %orig (before us) on every pass and snaps the pages back
    // to full-width paging positions. We must ALWAYS re-apply the column frames so that snap can't
    // win mid-drag (that was the "catch and bounce back"). Only the contentSize/contentOffset
    // mutations are skipped while dragging, since those genuinely interrupt the in-flight scroll.
    UIScrollView *activeColumnsScroll = nfb_horizontalPagingScrollViewOf(paging);
    BOOL columnsScrollDragging = activeColumnsScroll && (activeColumnsScroll.isDragging || activeColumnsScroll.isTracking || activeColumnsScroll.isDecelerating);
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    NSInteger estimatedPages = nfb_estimatedHomePagingPageCount(paging);
    NSInteger expectedColumns = MAX(1, estimatedPages - 1);
    if (!pages.count) {
        // Transient empties happen during iPad split-view resizes (the content VC is rebuilt for a
        // moment). Tearing the columns down here made them vanish on every resize. Keep whatever is
        // laid out and just retry the preload; restore only happens when columns mode is turned off.
        static NSTimeInterval lastColumnsPageRetry = 0.0;
        NSTimeInterval now = CACurrentMediaTime();
        if (!columnsScrollDragging && now - lastColumnsPageRetry > 0.75) {
            lastColumnsPageRetry = now;
            nfb_requestColumnsPagingPreload(paging, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
        return;
    }
    if ((NSInteger)pages.count < expectedColumns) {
        static NSTimeInterval lastColumnsPreload = 0.0;
        NSTimeInterval now = CACurrentMediaTime();
        if (!columnsScrollDragging && now - lastColumnsPreload > 0.75) {
            lastColumnsPreload = now;
            nfb_requestColumnsPagingPreload(paging, NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
    }
    nfb_ensureColumnsOverlayForPaging(paging);
    UIScrollView *nativeScrollView = nfb_horizontalPagingScrollViewOf(paging);
    if (!nativeScrollView) return;
    nfb_setColumnsSegmentedHiddenForPaging(paging, YES);
    UIViewController *searchColumnVC = nfb_iPadColumnsSearchSidebarVC(paging);
    if (searchColumnVC && [searchColumnVC isViewLoaded] && searchColumnVC.view) {
        if (nfb_searchColumnVCUsableForCurrentSplit(paging, nativeScrollView, searchColumnVC.view)) {
            nfb_prepareSplitForSearchColumn(paging, nativeScrollView, searchColumnVC.view);
        } else {
            searchColumnVC = nil;
        }
    }

    UIView *host = nfb_columnsHostViewForPaging(paging);
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
    nativeScrollView.directionalLockEnabled = YES;
    nfb_updateColumnsEdgeMenuGesturesForScroll(nativeScrollView);
    // Always pin OUR column contentSize. Store the target before setting it because the
    // TFNPagingScrollView hook also sees this assignment.
    NSUInteger columnCount = pages.count + (searchColumnVC ? 1 : 0);
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
        gColumnsAllTopButton.frame = CGRectMake(MAX(12.0, hostBounds.size.width - 128.0), buttonY, 116.0, 34.0);
        [host bringSubviewToFront:gColumnsAllTopButton];
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
    for (UIViewController *page in pages) {
        [page loadViewIfNeeded];
        UIView *pageView = page.view;
        nfb_rememberColumnOriginalViewState(pageView);
        if (pageView.superview != nativeScrollView) [nativeScrollView addSubview:pageView];
        if (page.parentViewController == nil) {
            [paging addChildViewController:page];
            [page didMoveToParentViewController:paging];
            objc_setAssociatedObject(page, &kNFBColumnsAddedAsChildKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pageView.hidden = NO;
        pageView.alpha = 1.0;
        pageView.frame = CGRectMake(columnWidth * idx, -topShift, columnWidth, height + topShift);
        pageView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        [pageView setNeedsLayout];
        if (!columnsScrollDragging) {
            [pageView layoutIfNeeded];
        }
        nfb_adjustColumnScrollForPage(page, pageView);
        if (!columnsScrollDragging) nfb_kickEmptyColumnLoad(page);
        idx++;
    }

    // Far-right search column (iPad): transplant the app-split trends/search sidebar's view into
    // the horizontal scroll at columnWidth*pages.count. Re-applied every layout pass so the split
    // cannot reclaim it; fully restored when columns mode turns off. Containment is untouched.
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
        searchView.frame = CGRectMake(columnWidth * pages.count, 0.0, columnWidth, height);
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
            NSString *k = [NSString stringWithFormat:@"searchColumn vc=%@ x=%.0f w=%.0f h=%.0f scroll=%@ content=%.0fx%.0f text=%@",
                NSStringFromClass(searchColumnVC.class), columnWidth * pages.count, columnWidth, height,
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
        NSMutableString *key = [NSMutableString stringWithFormat:@"pages=%lu w=%.0f top=%.0f drag=%d content=%.0f max=%.0f snap=%.0f hframe=(%.0f,%.0f,%.0f,%.0f)", (unsigned long)pages.count, columnWidth, topShift, drag ? 1 : 0, nativeScrollView.contentSize.width, maxOffsetX, snapOffsetX, nativeScrollView.frame.origin.x, nativeScrollView.frame.origin.y, nativeScrollView.frame.size.width, nativeScrollView.frame.size.height];
        NSUInteger ci = 0;
        for (UIViewController *p in pages) {
            if ([p isViewLoaded]) { CGRect f = p.view.frame; [key appendFormat:@" c%lu=(%.0f,%.0f,%.0f,%.0f)", (unsigned long)ci, f.origin.x, f.origin.y, f.size.width, f.size.height]; }
            ci++;
        }
        static NSString *lastLayoutKey = nil;
        if (![key isEqualToString:lastLayoutKey]) {
            lastLayoutKey = [key copy];
            NFBLogEvent([NSString stringWithFormat:@"layout %@ off=%.0f", key, nativeScrollView.contentOffset.x]);
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
    if (!nfb_isHomePagingController(paging) || ![paging isViewLoaded]) return;
    nfb_removeColumnsOverlay();
    nfb_setColumnsSegmentedHiddenForPaging(paging, NO);
    UIScrollView *scrollView = nfb_horizontalPagingScrollViewOf(paging);
    if (!scrollView) return;

    BOOL wasApplied = objc_getAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey) != nil;
    if (!wasApplied) return;

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
            [child willMoveToParentViewController:nil];
            [child removeFromParentViewController];
            objc_setAssociatedObject(child, &kNFBColumnsAddedAsChildKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void nfb_applyInlineColumns(UIViewController *paging) {
    if (!nfb_inlineColumnsActiveForHomePaging(paging) || ![paging isViewLoaded]) return;
    if (!nfb_homePagingControllerIsVisible(paging)) return;
    nfb_layoutColumnsOverlayForPaging(paging);
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

static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    NSMutableArray<UIViewController *> *pages = [NSMutableArray array];
    for (UIViewController *page in nfb_allHomePagingTimelinePages(paging)) {
        if (!nfb_shouldUseTimelinePageAsColumn(page)) continue;
        [pages addObject:page];
    }
    return pages;
}

static NSArray<UIViewController *> *nfb_currentColumnRefreshControllers(void) {
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray arrayWithArray:nfb_currentColumnTimelinePages()];
    UIViewController *search = gNFBColumnsSearchColumnController;
    if (search && [search isViewLoaded] && search.view.window && ![controllers containsObject:search]) {
        [controllers addObject:search];
    }
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
    for (UIViewController *page in nfb_currentColumnRefreshControllers()) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        page.view.hidden = NO;
        page.view.alpha = 1.0;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        // Don't fight a column the user is actively dragging.
        if (sv && (sv.isDragging || sv.isTracking)) continue;
        nfb_scrollToTop(page, NO);
        // Pull the latest tweets into EVERY column too, so "全カラム上へ" lands on fresh
        // content (the old path only scrolled to the top of already-loaded items).
        nfb_streamTriggerTarget(page);
    }
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
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
        page.view.hidden = NO;
        page.view.alpha = 1.0;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) {
            if (!away) away = page;
            NFBLogEvent([NSString stringWithFormat:@"streamColumns busy%lu class=%@ off=%.1f",
                (unsigned long)idx, NSStringFromClass(page.class), sv.contentOffset.y]);
            idx++;
            continue;
        }
        if (nfb_isTimelineAtTop(page)) {
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

static void nfb_appendColumnsDiag(NSMutableString *s, UIViewController *active) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
    UIScrollView *h = paging ? nfb_horizontalPagingScrollViewOf(paging) : nil;
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    BOOL applied = h && objc_getAssociatedObject(h, &kNFBInlineColumnsAppliedKey) != nil;
    NSIndexPath *selectedIndexPath = paging ? nfb_pagingSelectedIndexPath(paging) : nil;
    NSInteger estimatedPages = paging ? nfb_estimatedHomePagingPageCount(paging) : 0;
    id dataSource = paging ? nfb_pagingDataSource(paging) : nil;
    [s appendFormat:@"columns enabled=%d paging=%@ applied=%d pages=%lu estimatedPages=%ld selectedIndexPath=%@ dataSource=%@\n",
        gInlineColumnsEnabled ? 1 : 0,
        paging ? NSStringFromClass(paging.class) : @"(nil)",
        applied ? 1 : 0,
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

static NSString *nfb_buildDiagnosticReport(void) {
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
    nfb_dumpTree(nfb_homeRoot(active), 0, s);
    return s;
}

static void nfb_layoutActiveHomePaging(void) {
    UIViewController *paging = gInlineColumnsEnabled ? nfb_findVisibleHomePagingController() : nfb_findAnyHomePagingController();
    if (!paging || ![paging isViewLoaded]) {
        if (!gInlineColumnsEnabled) nfb_removeColumnsOverlay();
        return;
    }
    [paging.view setNeedsLayout];
    [paging.view layoutIfNeeded];
    if (gInlineColumnsEnabled) nfb_applyInlineColumns(paging);
    else nfb_restoreInlineColumns(paging);
}

static void nfb_scheduleLayoutActiveHomePaging(void) {
    nfb_layoutActiveHomePaging();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_layoutActiveHomePaging();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_layoutActiveHomePaging();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_layoutActiveHomePaging();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        nfb_layoutActiveHomePaging();
    });
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

void NFBSetInlineColumnsEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBSetInlineColumnsEnabled(enabled); });
        return;
    }
    BOOL changed = gInlineColumnsEnabled != enabled;
    if (changed) NFBLogEvent([NSString stringWithFormat:@"NFBSetInlineColumns -> %d", enabled]);
    gInlineColumnsEnabled = enabled;
    if (!enabled) {
        gInlineColumnsNeedsInitialOffsetReset = NO;
        gColumnsHiddenBarHeight = 0.0;
        gColumnsEdgeMenuStateKnown = NO;
        nfb_setColumnsEdgeMenuGesturesEnabled(YES);
        nfb_restoreAllSavedColumnsChromeSoon(@"disable");
    }
    if (enabled) {
        if (changed) {
            gColumnsHiddenBarHeight = 0.0;
            gInlineColumnsNeedsInitialOffsetReset = YES;
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

// Button lifecycle on the stable Home container.
%hook THFHomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated { %orig; NFBLogSnapshot(@"homeContainer.appear"); nfb_syncHomeTimelineTabIdentifierFromController(self); nfb_installButton(self.view.window); if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging(); else nfb_restoreAllSavedColumnsChrome(); }
- (void)viewDidDisappear:(BOOL)animated { %orig; NFBLogSnapshot(@"homeContainer.disappear"); nfb_removeButton(); }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig(size, coordinator);
    if (!gInlineColumnsEnabled) return;
    nfb_scheduleLayoutActiveHomePaging();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_scheduleLayoutActiveHomePaging();
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
    nfb_scheduleLayoutActiveHomePaging();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_scheduleLayoutActiveHomePaging();
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
    nfb_scheduleLayoutActiveHomePaging();
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        nfb_scheduleLayoutActiveHomePaging();
    }];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    if (gInlineColumnsEnabled) nfb_scheduleLayoutActiveHomePaging();
}
%end
