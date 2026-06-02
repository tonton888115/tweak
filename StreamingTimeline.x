//
//  StreamingTimeline.x
//  NeoFreeBird
//
//  Native Home-timeline auto-refresh ("streaming" / 垂れ流し). A floating control sits
//  top-right (beside the logo row); a countdown gauge ring depletes each interval and at
//  0 the timeline reloads. TAP = refresh now. LONG-PRESS = options (on/off, interval, and
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

// Minimal bases so `self.view` resolves; everything else goes through objc_msgSend.
@interface THFHomeTimelineContainerViewController : UIViewController
@end
@interface THFHomeTimelineItemsViewController : UIViewController
@end
@interface T1HomeTimelineItemsViewController : UIViewController
@end
@class NFBStreamHandler;

static __weak UIViewController *gActiveItemsVC = nil;   // the visible Home timeline list
static __weak UIViewController *gPendingNewTweetsVC = nil;
static UIButton *gNewTweetsPill = nil;

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
    void (^reveal)(void) = ^{
        UIViewController *s = wvc;
        if (!s || s != gActiveItemsVC || ![s isViewLoaded] || s.view.window == nil) return;
        UIScrollView *sv = nfb_mainScrollViewOf(s);
        if (sv && (sv.isDragging || sv.isDecelerating || sv.isTracking)) return;
        nfb_tapHomeTabLikeUser();
        nfb_scrollToTop(s, YES);
    };
    reveal();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
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
        [gNewTweetsPill setTitle:@"新しいツイートがあります" forState:UIControlStateNormal];
        Class handlerClass = objc_getClass("NFBStreamHandler");
        id handler = (handlerClass && [handlerClass respondsToSelector:@selector(shared)]) ? ((id(*)(Class,SEL))objc_msgSend)(handlerClass, @selector(shared)) : nil;
        if (handler) [gNewTweetsPill addTarget:handler action:@selector(newTweetsTap) forControlEvents:UIControlEventTouchUpInside];
    }
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
    if (nfb_isReadingAwayFromTop(vc)) {
        nfb_showNewTweetsPill(vc);
    } else {
        nfb_hideNewTweetsPill();
        nfb_revealTopAfterRefresh(vc);
    }
}

// The Home container's currently-visible timeline VC: the For You items VC, the
// Following items VC, or a pinned-list PinnedTimelineViewController. The old code only
// knew about the two home items VCs, so pinned lists (ニコニコ/投資) never refreshed.
static UIViewController *nfb_selectedTimelineVC(UIViewController *vc) {
    // The PAGING controller's selected page is the on-screen timeline, including pinned
    // lists. (The home container's selectedTimelineViewController only tracks For You /
    // Following, so it was wrong for ニコニコ/投資.)
    UIViewController *paging = nfb_parentControllerNamed(vc, @"Paging");
    if (paging) {
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

static void nfb_streamTrigger(UIViewController *vc) {
    // Refresh whatever timeline is actually on screen, not just the home items VC.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;

    BOOL readingAway = nfb_isReadingAwayFromTop(target);
    if (!readingAway) {
        nfb_hideNewTweetsPill();
        nfb_scrollToTop(target, NO);
    }

    // Resolve the refresh entry point inside the TARGET's own subtree only, so a list
    // refreshes itself (loadTop:) rather than the home timeline. For You/Following find
    // refreshWithSource: on their TFNTwitterHomeTimeline; pinned lists find loadTop:.
    id ctrlVC = nfb_findResponder(target, @selector(pullToLoadTopControl), 0);
    id pullCtrl = ctrlVC ? ((id(*)(id, SEL))objc_msgSend)(ctrlVC, @selector(pullToLoadTopControl)) : nil;

    BOOL did = NO;
    id r;
    if (!did && (r = nfb_findResponder(target, @selector(refreshWithSource:completion:), 0))) {
        void (^completion)(void) = ^{};
        ((void(*)(id, SEL, NSInteger, id))objc_msgSend)(r, @selector(refreshWithSource:completion:), nfb_streamLoadSourceFromSender(pullCtrl), completion);
        did = YES;
    }
    if (!did && (r = nfb_findResponder(target, @selector(loadTop:), 0))) {
        ((void(*)(id, SEL, id))objc_msgSend)(r, @selector(loadTop:), pullCtrl);
        did = YES;
    }
    if (!did && (r = nfb_findResponder(target, @selector(_tfn_dynamic_didPullToLoadTop:), 0))) {
        ((void(*)(id, SEL, id))objc_msgSend)(r, @selector(_tfn_dynamic_didPullToLoadTop:), pullCtrl);
        did = YES;
    }
    if (!did && (r = nfb_findResponder(target, @selector(schedulePullToRefreshUpdate), 0))) {
        ((void(*)(id, SEL))objc_msgSend)(r, @selector(schedulePullToRefreshUpdate));
        did = YES;
    }
    if (did) nfb_afterRefresh(target);
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
static void nfb_setStreamEnabled(BOOL on)    { [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"auto_stream_timeline"]; }
static void nfb_setStreamInterval(NSInteger s){ [[NSUserDefaults standardUserDefaults] setInteger:s forKey:@"auto_stream_interval"]; }

#pragma mark - tap / long-press handler (reliable action sheets)

@interface NFBStreamHandler : NSObject
+ (instancetype)shared;
- (void)tap;
- (void)newTweetsTap;
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
- (void)tap { UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamTrigger(vc); }
- (void)newTweetsTap {
    UIViewController *vc = gPendingNewTweetsVC ?: gActiveItemsVC;
    gPendingNewTweetsVC = nil;
    nfb_hideNewTweetsPill();
    if (vc) nfb_revealTopAfterRefresh(vc);
}
- (void)longPress:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan) [self showMain]; }

- (void)showMain {
    BOOL on = [BHTManager autoStreamTimeline];
    NSInteger iv = [BHTManager autoStreamInterval];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"TL自動更新（垂れ流し）"
        message:[NSString stringWithFormat:@"状態: %@ ／ 間隔: %ld秒", on ? @"ON" : @"OFF", (long)iv]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"🔄 今すぐ更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamTrigger(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:(on ? @"自動更新を OFF にする" : @"自動更新を ON にする") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamEnabled(!on); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
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
    [win bringSubviewToFront:gStreamButton];
    gStreamButton.alpha = 1.0;
    gStreamButton.userInteractionEnabled = YES;
    BOOL on = [BHTManager autoStreamTimeline];
    nfb_styleButton(on);
    nfb_updateGauge(on, (NSTimeInterval)[BHTManager autoStreamInterval]);
}
static void nfb_removeButton(void) {
    if (gStreamButton) { [gStreamButton.gauge removeAnimationForKey:@"deplete"]; [gStreamButton removeFromSuperview]; }
    nfb_hideNewTweetsPill();
    gPendingNewTweetsVC = nil;
}

// Fade with the header: hide while scrolling down, show at top / scrolling up.
static void nfb_visibilityForScroll(UIScrollView *sv) {
    if (!gStreamButton || gStreamButton.window == nil) return;
    static CGFloat last = 0;
    CGFloat y = sv.contentOffset.y;
    CGFloat topY = -sv.adjustedContentInset.top;
    BOOL atTop = (y <= topY + 4.0);
    CGFloat dy = y - last; last = y;
    CGFloat target = gStreamButton.alpha;
    if (atTop || dy < -2.0) target = 1.0;          // at top or scrolling up
    else if (dy > 2.0) target = 0.0;               // scrolling down
    if (fabs(gStreamButton.alpha - target) < 0.01) return;
    [UIView animateWithDuration:0.2 animations:^{ gStreamButton.alpha = target; }
                     completion:^(BOOL f){ gStreamButton.userInteractionEnabled = (target > 0.5); }];
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
        if (page.length) return [page isEqualToString:@"home"];
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
    // Gate on whatever timeline is actually on screen (For You / Following / pinned list),
    // not on the timer's own home items VC — that's how pinned lists get refreshed.
    UIViewController *target = nfb_selectedTimelineVC(vc) ?: vc;
    if (![target isViewLoaded] || target.view.window == nil) return NO;
    if (nfb_isRecommendedHomeTimeline(target)) return NO;       // For You -> never auto-refresh
    UIScrollView *sv = nfb_mainScrollViewOf(target);
    if (sv) {
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) return NO;
    }
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
        if (![BHTManager autoStreamTimeline]) { nfb_streamStop(s); nfb_styleButton(NO); nfb_updateGauge(NO, 0); return; }
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

#pragma mark - Hooks

// Button lifecycle on the stable Home container.
%hook THFHomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_syncHomeTimelineTabIdentifierFromController(self); nfb_installButton(self.view.window); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_removeButton(); }
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
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_visibilityForScroll(scrollView); }
%end

// Older app versions.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_visibilityForScroll(scrollView); }
%end
