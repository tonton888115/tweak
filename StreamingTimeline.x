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

static __weak UIViewController *gActiveItemsVC = nil;   // the visible Home timeline list

#pragma mark - refresh callers (no signature assumptions)

static BOOL nfb_resp(id o, SEL s) { return o && [o respondsToSelector:s]; }
static id   nfb_timelineOf(id vc) { return nfb_resp(vc, @selector(timeline)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(timeline)) : nil; }
static UIScrollView *nfb_scrollOf(id vc) { return nfb_resp(vc, @selector(scrollView)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(scrollView)) : nil; }

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

static BOOL nfb_doPull(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(_t1_didPullToRefresh:), 0);
    if (t) { ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(_t1_didPullToRefresh:), nil); return YES; }
    return NO;
}
static BOOL nfb_doLoadNewer(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(loadNewer), 0);
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(loadNewer)); return YES; }
    return NO;
}
static BOOL nfb_doReloadTop(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(reloadTop:), 0);
    if (t) { ((void(*)(id,SEL,BOOL))objc_msgSend)(t, @selector(reloadTop:), YES); return YES; }
    return NO;
}
static BOOL nfb_doRefreshContent(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(_refreshContent), 0);
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(_refreshContent)); return YES; }
    return NO;
}
static BOOL nfb_doSchedulePullUpdate(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(schedulePullToRefreshUpdate), 0);
    if (t) { ((void(*)(id,SEL))objc_msgSend)(t, @selector(schedulePullToRefreshUpdate)); return YES; }
    return NO;
}
static BOOL nfb_doLoadTop(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(loadTop:), 0);
    if (t) { ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(loadTop:), nil); return YES; }
    return NO;
}
static BOOL nfb_doTimelineRefresh(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(refreshWithSource:completion:), 0);
    if (t) {
        void (^completion)(void) = ^{};
        ((void(*)(id,SEL,NSInteger,id))objc_msgSend)(t, @selector(refreshWithSource:completion:), 0, completion);
        return YES;
    }
    return NO;
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
    if (!ctrl) ctrl = nfb_pullToLoadTopControlOf(nfb_findResponder(nfb_homeRoot(startVC), @selector(pullToLoadTopControl), 0));
    if (!ctrl) ctrl = nfb_ivarOfType(gActiveItemsVC, "TFNPullToRefreshControl");
    if (!ctrl) ctrl = nfb_ivarOfType(nfb_findResponder(nfb_homeRoot(startVC), @selector(_t1_didPullToRefresh:), 0), "TFNPullToRefreshControl");
    if (!ctrl) {
        UIScrollView *sv = nfb_scrollOf(gActiveItemsVC);
        Class cls = objc_getClass("TFNPullToRefreshControl");
        if (sv && cls) for (UIView *v in sv.subviews) if ([v isKindOfClass:cls]) { ctrl = v; break; }
    }
    return ctrl;
}
// The pull handler lives on the container but needs the real control as its sender.
static BOOL nfb_doPullWithControl(id startVC) {
    id cont = nfb_findResponder(nfb_homeRoot(startVC), @selector(_t1_didPullToRefresh:), 0);
    id ctrl = nfb_findPullControl(startVC);
    if (!cont || !ctrl) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(cont, @selector(_t1_didPullToRefresh:), ctrl);
    return YES;
}
// Current Twitter builds expose this on the visible items VC; it is the native
// pull-to-load-top action, with the real pull control as sender.
static BOOL nfb_doDynamicPullToLoadTop(id startVC) {
    id t = nfb_findResponder(nfb_homeRoot(startVC), @selector(_tfn_dynamic_didPullToLoadTop:), 0);
    id ctrl = nfb_findPullControl(startVC);
    if (!t || !ctrl) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(t, @selector(_tfn_dynamic_didPullToLoadTop:), ctrl);
    return YES;
}

static void nfb_streamTrigger(UIViewController *vc) {
    if (nfb_doDynamicPullToLoadTop(vc)) return;
    if (nfb_doLoadTop(vc))              return;
    if (nfb_doTimelineRefresh(vc))      return;
    if (nfb_doSchedulePullUpdate(vc))   return;
    if (nfb_doPullWithControl(vc))      return;
    if (nfb_doPull(vc))                 return;
    if (nfb_doLoadNewer(vc))            return;
    if (nfb_doReloadTop(vc))            return;
    nfb_doRefreshContent(vc);
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
    id tl = nfb_timelineOf(vc);
    if (tl) {
        NSMutableArray *tr = [NSMutableArray array];
        if ([tl respondsToSelector:@selector(refreshWithSource:completion:)]) [tr addObject:@"refreshSrc"];
        if ([tl respondsToSelector:@selector(refreshWithSource:pushToHomeTweetId:completion:)]) [tr addObject:@"refreshSrcTweet"];
        [s appendFormat:@"%@  ⮡timeline=%@%@\n", ind, NSStringFromClass([tl class]),
            tr.count ? [NSString stringWithFormat:@"  <%@>", [tr componentsJoinedByString:@","]] : @""];
        NSString *tm = nfb_refreshMethodsOf([tl class]);
        if (tm.length) [s appendFormat:@"%@   tl.m: %@\n", ind, tm];
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
    nfb_dumpTree(nfb_homeRoot(active), 0, s);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"診断情報" message:s preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"コピー" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIPasteboard.generalPasteboard.string = s; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showInterval {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更新間隔" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *n in @[@10, @15, @20, @30, @60]) {
        NSInteger sec = n.integerValue;
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%ld秒", (long)sec] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ nfb_setStreamInterval(sec); UIViewController *vc = gActiveItemsVC; if (vc) nfb_streamStart(vc); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self present:ac];
}
- (void)showTest {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"更新方式テスト"
        message:@"各ボタンでその方式の更新を1回試します。TLが更新された方式を教えてください。" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"A: dynamic pullToLoadTop" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_doDynamicPullToLoadTop(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"B: loadTop:nil" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_doLoadTop(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"C: timeline refresh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_doTimelineRefresh(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"D: schedulePullUpdate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_doSchedulePullUpdate(vc); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"E: legacy container pull" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ UIViewController *vc = gActiveItemsVC; if (vc) nfb_doPullWithControl(vc); }]];
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
    UIScrollView *sv = nfb_scrollOf(vc);
    if (sv) {
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) return NO;
        CGFloat topY = -sv.adjustedContentInset.top;
        if (sv.contentOffset.y > topY + 600.0) return NO;      // far down -> leave it to the native pill
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
