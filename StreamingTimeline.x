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

static void nfb_streamTrigger(UIViewController *vc) {
    BOOL readingAway = nfb_isReadingAwayFromTop(vc);
    if (!readingAway) {
        nfb_hideNewTweetsPill();
        nfb_scrollToTop(vc, NO);
    }

    BOOL did = nfb_doTimelineRefresh(vc);
    if (nfb_doLoadTop(vc)) {
        nfb_doSchedulePullUpdate(vc);
        did = YES;
    }
    if (!did) {
        if (nfb_doSchedulePullUpdate(vc))   did = YES;
        else if (nfb_doDynamicPullToLoadTop(vc)) did = YES;
        else if (nfb_doPullWithControl(vc))      did = YES;
        else if (nfb_doPull(vc))                 did = YES;
        else if (nfb_doLoadNewer(vc))            did = YES;
        else if (nfb_doReloadTop(vc))            did = YES;
        else if (nfb_doRefreshContent(vc))       did = YES;
    }
    if (did) nfb_afterRefresh(vc);
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
    if (!sv) { [s appendString:@"scroll=(nil)\n"]; return; }
    [s appendFormat:@"scroll=%@ offset=(%.1f,%.1f) size=(%.1f,%.1f) bounds=(%.1f,%.1f) inset=(%.1f,%.1f,%.1f,%.1f) bounceV=%d\n",
        NSStringFromClass([sv class]), sv.contentOffset.x, sv.contentOffset.y,
        sv.contentSize.width, sv.contentSize.height, sv.bounds.size.width, sv.bounds.size.height,
        sv.adjustedContentInset.top, sv.adjustedContentInset.left, sv.adjustedContentInset.bottom, sv.adjustedContentInset.right,
        sv.alwaysBounceVertical ? 1 : 0];
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

#pragma mark - streaming timer

static char kNFBStreamTimerKey;

static BOOL nfb_streamShouldFire(UIViewController *vc) {
    if (![BHTManager autoStreamTimeline]) return NO;
    if (vc != gActiveItemsVC) return NO;                        // only the visible list
    if (![vc isViewLoaded] || vc.view.window == nil) return NO;
    UIScrollView *sv = nfb_mainScrollViewOf(vc);
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
        if (nfb_streamShouldFire(s)) nfb_streamTrigger(s);
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

// Button lifecycle on the stable Home container.
%hook THFHomeTimelineContainerViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_installButton(self.view.window); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_removeButton(); }
%end

%hook THFHomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_visibilityForScroll(scrollView); }
%end

// Older app versions.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; gActiveItemsVC = self; nfb_installButton(self.view.window); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { %orig; gActiveItemsVC = self; nfb_visibilityForScroll(scrollView); }
%end
