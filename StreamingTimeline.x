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
static BOOL nfb_homeTabSelectedOrUnknown(void);
static void nfb_showNewTweetsPill(UIViewController *vc);
static BOOL nfb_streamTriggerColumns(void);
static void nfb_revealAllColumnTops(void);
static void nfb_appendColumnsDiag(NSMutableString *s, UIViewController *active);
static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void);
static UIScrollView *nfb_horizontalPagingScrollViewOf(UIViewController *vc);
static NSInteger nfb_estimatedHomePagingPageCount(UIViewController *paging);
static void nfb_requestColumnsPagingPreload(UIViewController *paging);
static id nfb_pagingDataSource(UIViewController *paging);
static NSIndexPath *nfb_pagingSelectedIndexPath(UIViewController *paging);
static UIViewController *nfb_pagingViewControllerAtIndexPath(UIViewController *paging, NSIndexPath *indexPath);
static UIViewController *nfb_firstColumnTimelineAwayFromTop(void);
static UIViewController *nfb_firstColumnTimelineAwayFromTopExcept(UIViewController *allowedRevealing);
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
    gPendingNewTweetsVC = vc;
    UIWindow *win = vc.view.window;
    if (!gNewTweetsPill) {
        gNewTweetsPill = [UIButton buttonWithType:UIButtonTypeSystem];
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
    if (vc) nfb_revealTopAfterRefresh(vc);
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
- (void)showDiag {
    UIViewController *active = gActiveItemsVC;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"active=%@\n", active ? NSStringFromClass([active class]) : @"(nil)"];
    if (active) nfb_appendScrollDiag(s, active);
    NSString *columnsMode = BHTColumnsModeDiagnostic();
    if (columnsMode.length) [s appendString:columnsMode];
    nfb_appendColumnsDiag(s, active);
    nfb_dumpTree(nfb_homeRoot(active), 0, s);
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
        for (UIViewController *page in nfb_currentColumnTimelinePages()) {
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
        gStreamButton = [NFBStreamButton buttonWithType:UIButtonTypeSystem];
        gStreamButton.translatesAutoresizingMaskIntoConstraints = NO;
        gStreamButton.accessibilityLabel = @"TL自動更新";
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
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}
static void nfb_removeButton(void) {
    if (gStreamButton) { [gStreamButton.gauge removeAnimationForKey:@"deplete"]; [gStreamButton removeFromSuperview]; }
    if (gStreamStateIcon) [gStreamStateIcon removeFromSuperview];
    nfb_hideNewTweetsPill();
    gPendingNewTweetsVC = nil;
}

// Fade with the header: hide while scrolling down, show at top / scrolling up.
static void nfb_visibilityForScroll(UIScrollView *sv) {
    if (!gStreamButton || gStreamButton.window == nil) return;
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

static BOOL nfb_homeTabSelectedOrUnknown(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSString *page = nfb_selectedTabPageInView(window, 0);
        if (page.length) {
            if ([page isEqualToString:@"home"]) return YES;
            if (gInlineColumnsEnabled && [page isEqualToString:@"communities"]) return YES;
            return NO;
        }
    }
    return YES;
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
static char kNFBInlineColumnsChromeSavedKey;
static char kNFBInlineColumnsChromeHiddenKey;
static char kNFBInlineColumnsChromeAlphaKey;
static char kNFBInlineColumnsChromeInteractionKey;
static char kNFBColumnsOriginalSuperviewKey;
static char kNFBColumnsOriginalFrameKey;
static char kNFBColumnsOriginalAutoresizingKey;
static char kNFBColumnsOriginalHiddenKey;
static char kNFBColumnsOriginalAlphaKey;
static UIView *gColumnsOverlayView = nil;
static UIScrollView *gColumnsOverlayScrollView = nil;
static UIButton *gColumnsAllTopButton = nil;
static NSArray<UIViewController *> *gColumnsOverlayPages = nil;

static BOOL nfb_isHomePagingController(UIViewController *vc) {
    return nfb_parentControllerNamed(vc, @"HomeTimelineContainer") != nil;
}

static BOOL nfb_viewContainsDescendant(UIView *root, UIView *descendant) {
    if (!root || !descendant) return NO;
    if (root == descendant) return YES;
    for (UIView *subview in root.subviews) {
        if (nfb_viewContainsDescendant(subview, descendant)) return YES;
    }
    return NO;
}

static void nfb_setColumnsChromeViewHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    if (hidden) {
        if (!objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) {
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        return;
    }
    if (!objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey)) return;
    NSNumber *wasHidden = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey);
    NSNumber *alpha = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey);
    NSNumber *interactive = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey);
    view.hidden = wasHidden ? wasHidden.boolValue : NO;
    view.alpha = alpha ? alpha.doubleValue : 1.0;
    view.userInteractionEnabled = interactive ? interactive.boolValue : YES;
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBInlineColumnsChromeInteractionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    if ([cls containsString:@"Segment"] || [cls containsString:@"Tab"] || [cls containsString:@"LabelBar"]) return YES;
    if ([cls containsString:@"Bar"] && frame.size.height <= 180.0) return YES;
    return CGRectGetMaxY(frame) <= 220.0 && view.subviews.count > 0;
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

static BOOL nfb_viewContainsColumnsPagingSurface(UIView *view, int depth) {
    if (!view || depth > 8) return NO;
    if (nfb_columnsPagingSurface(view)) return YES;
    for (UIView *subview in view.subviews) {
        if (nfb_viewContainsColumnsPagingSurface(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL nfb_hideColumnsChromeInView(UIView *view, UIView *pagingView, UIView *root, int depth) {
    if (!view || !root || depth > 8) return NO;
    if (nfb_columnsProtectedView(view)) return NO;
    BOOL containsPaging = nfb_viewContainsDescendant(view, pagingView);
    BOOL pagingSurface = nfb_columnsPagingSurface(view);
    BOOL containsPagingSurface = nfb_viewContainsColumnsPagingSurface(view, 0);
    if (pagingSurface) return NO;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    BOOL fullScreenChromeLayer = view != root && view != pagingView && !containsPaging &&
        !pagingSurface && !containsPagingSurface &&
        CGRectGetMinY(frame) <= 280.0 && frame.size.width >= root.bounds.size.width * 0.6 &&
        frame.size.height > 260.0 && frame.size.height <= root.bounds.size.height + 80.0 && depth <= 4;
    if (view != pagingView && !containsPaging && !pagingSurface && !containsPagingSurface && (nfb_columnsChromeCandidate(view, root) || fullScreenChromeLayer)) {
        nfb_setColumnsChromeViewHidden(view, YES);
        return YES;
    }
    BOOL did = NO;
    for (UIView *subview in view.subviews) {
        did = nfb_hideColumnsChromeInView(subview, pagingView, root, depth + 1) || did;
    }
    return did;
}

static void nfb_restoreColumnsChromeInView(UIView *view, int depth) {
    if (!view || depth > 10) return;
    nfb_setColumnsChromeViewHidden(view, NO);
    for (UIView *subview in view.subviews) {
        nfb_restoreColumnsChromeInView(subview, depth + 1);
    }
}

static BOOL nfb_globalTopColumnsChromeCandidate(UIView *view, UIView *root) {
    if (!view || !root || view == root || view.hidden || view.alpha < 0.01 || nfb_columnsProtectedView(view)) return NO;
    if (nfb_columnsPagingSurface(view)) return NO;
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (CGRectGetMinY(frame) > 240.0 || frame.size.width < 24.0 || frame.size.height < 4.0 || frame.size.height > 220.0) return NO;
    NSString *cls = NSStringFromClass(view.class);
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
    if (!view || !root || depth > 12) return 0;
    if (hidden && nfb_columnsPagingSurface(view)) return 0;
    NSInteger count = 0;
    if (hidden && nfb_globalTopColumnsChromeCandidate(view, root)) {
        nfb_setColumnsChromeViewHidden(view, YES);
        return 1;
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
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        nfb_setColumnsGlobalTopChromeHiddenInView(window, window, hidden, 0);
    }
}

static void nfb_setColumnsSegmentedHiddenForPaging(UIViewController *paging, BOOL hidden) {
    UIViewController *segmented = nfb_parentControllerNamed(paging, @"Segmented");
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (![paging isViewLoaded]) return;
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

static UIView *nfb_columnsHostViewForPaging(UIViewController *paging) {
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (container && [container isViewLoaded]) return container.view;
    return [paging isViewLoaded] ? paging.view : nil;
}

static CGFloat nfb_columnsColumnWidth(CGFloat viewportWidth) {
    CGFloat columnWidth = viewportWidth >= 700.0 ? 340.0 : MIN(viewportWidth, 390.0);
    return MAX(320.0, MIN(390.0, columnWidth));
}

static void nfb_rememberColumnOriginalViewState(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey)) return;
    objc_setAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey, view.superview, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalFrameKey, [NSValue valueWithCGRect:view.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey, @(view.autoresizingMask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_restoreColumnOriginalViewState(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey)) return;
    UIView *superview = objc_getAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey);
    NSValue *frame = objc_getAssociatedObject(view, &kNFBColumnsOriginalFrameKey);
    NSNumber *autoresizing = objc_getAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey);
    NSNumber *hidden = objc_getAssociatedObject(view, &kNFBColumnsOriginalHiddenKey);
    NSNumber *alpha = objc_getAssociatedObject(view, &kNFBColumnsOriginalAlphaKey);
    if (superview && view.superview != superview) [superview addSubview:view];
    if (frame) view.frame = frame.CGRectValue;
    if (autoresizing) view.autoresizingMask = autoresizing.unsignedIntegerValue;
    view.hidden = hidden ? hidden.boolValue : NO;
    view.alpha = alpha ? alpha.doubleValue : 1.0;
    objc_setAssociatedObject(view, &kNFBColumnsOriginalSuperviewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAutoresizingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kNFBColumnsOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_removeColumnsOverlay(void) {
    NSArray<UIViewController *> *pages = gColumnsOverlayPages ?: @[];
    for (UIViewController *page in pages) {
        if ([page isViewLoaded]) nfb_restoreColumnOriginalViewState(page.view);
    }
    for (UIViewController *page in nfb_currentColumnTimelinePages()) {
        if ([page isViewLoaded]) nfb_restoreColumnOriginalViewState(page.view);
    }
    [gColumnsOverlayView removeFromSuperview];
    [gColumnsAllTopButton removeFromSuperview];
    gColumnsOverlayView = nil;
    gColumnsOverlayScrollView = nil;
    gColumnsAllTopButton = nil;
    gColumnsOverlayPages = nil;
    gPendingNewTweetsVC = nil;
    nfb_setColumnsGlobalTopChromeHidden(NO);
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
    if (!gColumnsAllTopButton) {
        gColumnsAllTopButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gColumnsAllTopButton.frame = CGRectMake(0.0, 0.0, 116.0, 34.0);
        gColumnsAllTopButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        gColumnsAllTopButton.backgroundColor = UIColor.systemBlueColor;
        gColumnsAllTopButton.layer.cornerRadius = 17.0;
        gColumnsAllTopButton.layer.masksToBounds = YES;
        gColumnsAllTopButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [gColumnsAllTopButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [gColumnsAllTopButton setTitle:@"全カラム↑" forState:UIControlStateNormal];
        [gColumnsAllTopButton addTarget:[NFBStreamHandler shared] action:@selector(revealAllColumnsTap) forControlEvents:UIControlEventTouchUpInside];
    }
    if (gColumnsAllTopButton.superview != host) {
        [gColumnsAllTopButton removeFromSuperview];
        [host addSubview:gColumnsAllTopButton];
    }
    [host bringSubviewToFront:gColumnsAllTopButton];
}

static void nfb_layoutColumnsOverlayForPaging(UIViewController *paging) {
    if (!gInlineColumnsEnabled || !nfb_isHomePagingController(paging) || ![paging isViewLoaded]) return;
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    NSInteger estimatedPages = nfb_estimatedHomePagingPageCount(paging);
    NSInteger expectedColumns = MAX(1, estimatedPages - 1);
    if (!pages.count) {
        static NSTimeInterval lastColumnsPageRetry = 0.0;
        nfb_removeColumnsOverlay();
        NSTimeInterval now = CACurrentMediaTime();
        if (now - lastColumnsPageRetry > 0.75) {
            lastColumnsPageRetry = now;
            nfb_requestColumnsPagingPreload(paging);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
        return;
    }
    if ((NSInteger)pages.count < expectedColumns) {
        static NSTimeInterval lastColumnsPreload = 0.0;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - lastColumnsPreload > 0.75) {
            lastColumnsPreload = now;
            nfb_requestColumnsPagingPreload(paging);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_layoutActiveHomePaging();
            });
        }
    }
    nfb_ensureColumnsOverlayForPaging(paging);
    UIScrollView *nativeScrollView = nfb_horizontalPagingScrollViewOf(paging);
    if (!nativeScrollView) return;

    UIView *host = nfb_columnsHostViewForPaging(paging);
    CGRect bounds = nativeScrollView.bounds;
    if (bounds.size.width < 120.0 || bounds.size.height < 240.0) return;
    CGFloat columnWidth = nfb_columnsColumnWidth(bounds.size.width);
    CGFloat height = bounds.size.height;

    gColumnsOverlayPages = [pages copy];
    nfb_rememberInlineColumnsOriginals(nativeScrollView);
    nativeScrollView.pagingEnabled = NO;
    nativeScrollView.alwaysBounceHorizontal = YES;
    nativeScrollView.showsHorizontalScrollIndicator = YES;
    nativeScrollView.clipsToBounds = YES;
    nativeScrollView.directionalLockEnabled = YES;
    nativeScrollView.contentSize = CGSizeMake(MAX(columnWidth * pages.count, bounds.size.width + 1.0), height);
    CGFloat maxOffsetX = MAX(0.0, nativeScrollView.contentSize.width - bounds.size.width);
    if (nativeScrollView.contentOffset.x > maxOffsetX) {
        [nativeScrollView setContentOffset:CGPointMake(maxOffsetX, nativeScrollView.contentOffset.y) animated:NO];
    }
    if (host && gColumnsAllTopButton) {
        CGRect hostBounds = host.bounds;
        gColumnsAllTopButton.frame = CGRectMake(MAX(12.0, hostBounds.size.width - 128.0), 10.0, 116.0, 34.0);
        [host bringSubviewToFront:gColumnsAllTopButton];
    }

    NSSet<UIViewController *> *pageSet = [NSSet setWithArray:pages];
    for (UIViewController *child in paging.childViewControllers) {
        if (![child isViewLoaded] || !nfb_isTimelinePageController(child)) continue;
        if (![pageSet containsObject:child]) {
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
        pageView.hidden = NO;
        pageView.alpha = 1.0;
        pageView.frame = CGRectMake(columnWidth * idx, 0.0, columnWidth, height);
        pageView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        [pageView setNeedsLayout];
        [pageView layoutIfNeeded];
        idx++;
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

static void nfb_requestColumnsPagingPreload(UIViewController *paging) {
    if (!paging) return;
    UIViewController *segmented = nfb_parentControllerNamed(paging, @"Segmented");
    UIViewController *container = nfb_parentControllerNamed(paging, @"HomeTimelineContainer");
    if (container && [container respondsToSelector:@selector(loadInitialPinnedTimelines)]) {
        ((void(*)(id, SEL))objc_msgSend)(container, @selector(loadInitialPinnedTimelines));
    }
    if (segmented && [segmented respondsToSelector:@selector(setPreloadContent:)]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(segmented, @selector(setPreloadContent:), YES);
    }
    if (segmented && [segmented respondsToSelector:@selector(reloadVisibleTabs)]) {
        ((void(*)(id, SEL))objc_msgSend)(segmented, @selector(reloadVisibleTabs));
    }
    for (NSString *name in @[@"reloadInvisibleViewControllers", @"reloadVisibleViewControllers", @"reloadViewControllers"]) {
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

static UIViewController *nfb_findVisibleHomePagingController(void) {
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
    if (!scrollView || !objc_getAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey)) return;

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
    for (UIViewController *child in paging.childViewControllers) {
        if ([child isViewLoaded]) {
            child.view.hidden = NO;
            child.view.alpha = 1.0;
        }
    }

    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsPagingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsBounceHKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsIndicatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsClipsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsDirectionalLockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scrollView, &kNFBInlineColumnsContentSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_applyInlineColumns(UIViewController *paging) {
    if (!gInlineColumnsEnabled || !nfb_isHomePagingController(paging) || ![paging isViewLoaded]) return;
    nfb_layoutColumnsOverlayForPaging(paging);
}

static NSArray<UIViewController *> *nfb_currentColumnTimelinePages(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
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
                if (!nfb_isTimelinePageController(page) || nfb_isRecommendedHomeTimeline(page) || [pages containsObject:page]) continue;
                [pages addObject:page];
            }
        }
    }
    for (UIViewController *child in paging.childViewControllers) {
        if (!nfb_isTimelinePageController(child) || nfb_isRecommendedHomeTimeline(child)) continue;
        if (![pages containsObject:child]) [pages addObject:child];
    }
    return pages;
}

static UIViewController *nfb_firstColumnTimelineAwayFromTopExcept(UIViewController *allowedRevealing) {
    for (UIViewController *page in nfb_currentColumnTimelinePages()) {
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
    for (UIViewController *page in nfb_currentColumnTimelinePages()) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        page.view.hidden = NO;
        page.view.alpha = 1.0;
        nfb_scrollToTop(page, NO);
    }
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    nfb_updateStreamStateIconForVC(gActiveItemsVC);
}

static BOOL nfb_streamTriggerColumns(void) {
    nfb_layoutActiveHomePaging();
    NSArray<UIViewController *> *pages = nfb_currentColumnTimelinePages();
    if (!pages.count) return NO;

    BOOL did = NO;
    UIViewController *away = nil;
    for (UIViewController *page in pages) {
        if (![page isViewLoaded] || page.view.window == nil) continue;
        page.view.hidden = NO;
        page.view.alpha = 1.0;
        UIScrollView *sv = nfb_mainScrollViewOf(page);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) {
            if (!away) away = page;
            continue;
        }
        if (nfb_isTimelineAtTop(page)) {
            did = nfb_streamTriggerTarget(page) || did;
        } else if (!away) {
            away = page;
        }
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

static void nfb_appendColumnsChromeDiag(NSMutableString *s, UIView *view, UIView *pagingView, UIView *root, int depth) {
    if (!view || !root || depth > 3) return;
    BOOL saved = objc_getAssociatedObject(view, &kNFBInlineColumnsChromeSavedKey) != nil;
    BOOL containsPaging = nfb_viewContainsDescendant(view, pagingView);
    CGRect frame = view.superview ? [view.superview convertRect:view.frame toView:root] : view.frame;
    if (saved || (!containsPaging && CGRectGetMinY(frame) <= 280.0 && frame.size.height >= 4.0)) {
        NSString *text = nfb_textOfView(view);
        [s appendFormat:@"columnsChrome d=%d saved=%d containsPaging=%d hidden=%d alpha=%.2f frame=(%.1f,%.1f,%.1f,%.1f) class=%@ text=%@\n",
            depth, saved ? 1 : 0, containsPaging ? 1 : 0, view.hidden ? 1 : 0, view.alpha,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            NSStringFromClass(view.class), text ?: @"(nil)"];
    }
    for (UIView *subview in view.subviews) {
        nfb_appendColumnsChromeDiag(s, subview, pagingView, root, depth + 1);
    }
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
        CGFloat inferredWidth = pages.count ? (h.contentSize.width / MAX((CGFloat)pages.count, 1.0)) : 0.0;
        [s appendFormat:@"nativeHScroll class=%@ offset=(%.1f,%.1f) content=(%.1f,%.1f) bounds=(%.1f,%.1f) paging=%d bounceH=%d inferredColumnWidth=%.1f\n",
            NSStringFromClass(h.class), h.contentOffset.x, h.contentOffset.y, h.contentSize.width, h.contentSize.height,
            h.bounds.size.width, h.bounds.size.height, h.pagingEnabled ? 1 : 0, h.alwaysBounceHorizontal ? 1 : 0, inferredWidth];
    }
    UIViewController *segmented = paging ? nfb_parentControllerNamed(paging, @"Segmented") : nil;
    UIViewController *container = paging ? nfb_parentControllerNamed(paging, @"HomeTimelineContainer") : nil;
    NSInteger hiddenChrome = 0;
    if (segmented && [segmented isViewLoaded]) hiddenChrome += nfb_countSavedColumnsChromeInView(segmented.view, 0);
    if (container && [container isViewLoaded]) hiddenChrome += nfb_countSavedColumnsChromeInView(container.view, 0);
    [s appendFormat:@"columnsChromeHidden=%ld segmented=%@ container=%@\n",
        (long)hiddenChrome,
        segmented ? NSStringFromClass(segmented.class) : @"(nil)",
        container ? NSStringFromClass(container.class) : @"(nil)"];

    NSUInteger idx = 0;
    for (UIViewController *page in pages) {
        UIScrollView *sv = [page isViewLoaded] ? nfb_mainScrollViewOf(page) : nil;
        CGRect frame = [page isViewLoaded] ? page.view.frame : CGRectZero;
        [s appendFormat:@"column[%lu] class=%@ loaded=%d window=%d hidden=%d recommended=%d atTop=%d frame=(%.1f,%.1f,%.1f,%.1f)",
            (unsigned long)idx, NSStringFromClass(page.class), [page isViewLoaded] ? 1 : 0,
            ([page isViewLoaded] && page.view.window) ? 1 : 0,
            ([page isViewLoaded] && page.view.hidden) ? 1 : 0,
            nfb_isRecommendedHomeTimeline(page) ? 1 : 0,
            nfb_isTimelineAtTop(page) ? 1 : 0,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
        if (sv) {
            CGFloat topY = -sv.adjustedContentInset.top;
            [s appendFormat:@" scroll=%@ offset=(%.1f,%.1f) topY=%.1f content=(%.1f,%.1f) bounds=(%.1f,%.1f)",
                NSStringFromClass(sv.class), sv.contentOffset.x, sv.contentOffset.y, topY,
                sv.contentSize.width, sv.contentSize.height, sv.bounds.size.width, sv.bounds.size.height];
        }
        [s appendString:@"\n"];
        idx++;
    }
    if (segmented && [segmented isViewLoaded] && paging && [paging isViewLoaded]) {
        nfb_appendColumnsChromeDiag(s, segmented.view, paging.view, segmented.view, 0);
    }
}

static void nfb_layoutActiveHomePaging(void) {
    UIViewController *paging = nfb_findVisibleHomePagingController();
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

BOOL NFBInlineColumnsEnabled(void) {
    return gInlineColumnsEnabled;
}

void NFBSetInlineColumnsEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ NFBSetInlineColumnsEnabled(enabled); });
        return;
    }
    gInlineColumnsEnabled = enabled;
    nfb_scheduleLayoutActiveHomePaging();
}

#pragma mark - Hooks

// Button lifecycle on the stable Home container.
%hook THFHomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_syncHomeTimelineTabIdentifierFromController(self); nfb_installButton(self.view.window); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_removeButton(); }
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
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_syncHomeTimelineTabIdentifierFromController(nfb_parentControllerNamed(self, @"HomeTimelineContainer")); gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
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

%hook TFNPagingViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (gInlineColumnsEnabled) nfb_applyInlineColumns(self);
    else nfb_restoreInlineColumns(self);
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
