//
//  StreamingTimeline.x
//  NeoFreeBird
//
//  Native Home-timeline auto-refresh ("streaming" / 垂れ流し), inspired by the old
//  Feather client and OldTweetDeck live columns. A floating control sits at the very
//  top-right (window level, beside the logo row) with a countdown gauge ring that
//  depletes each interval; at 0 the timeline reloads. Tapping it opens a native menu
//  (manual refresh, on/off, interval). Because Twitter's refresh entry points differ
//  by build, the menu also exposes method A/B/C/D so the working one can be confirmed.
//

#import "TWHeaders.h"
#import "BHTManager.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static void nfb_streamStart(UIViewController *vc);
static void nfb_streamStop(UIViewController *vc);

#pragma mark - low-level refresh callers (no signature assumptions)

static BOOL nfb_resp(id obj, SEL s) { return obj && [obj respondsToSelector:s]; }
static id   nfb_timelineOf(id vc)   { return nfb_resp(vc, @selector(timeline)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(timeline)) : nil; }
static UIScrollView *nfb_scrollOf(id vc) { return nfb_resp(vc, @selector(scrollView)) ? ((id(*)(id,SEL))objc_msgSend)(vc, @selector(scrollView)) : nil; }

// Each returns YES if it found a target that responds (regardless of visible effect).
static BOOL nfb_doPull(id vc) {
    if (nfb_resp(vc, @selector(_t1_didPullToRefresh:))) {
        ((void(*)(id,SEL,id))objc_msgSend)(vc, @selector(_t1_didPullToRefresh:), nil); return YES;
    }
    return NO;
}
static BOOL nfb_doLoadNewer(id vc) {
    if (nfb_resp(vc, @selector(loadNewer))) { ((void(*)(id,SEL))objc_msgSend)(vc, @selector(loadNewer)); return YES; }
    id tl = nfb_timelineOf(vc);
    if (nfb_resp(tl, @selector(loadNewer))) { ((void(*)(id,SEL))objc_msgSend)(tl, @selector(loadNewer)); return YES; }
    return NO;
}
static BOOL nfb_doReloadTop(id vc) {
    if (nfb_resp(vc, @selector(reloadTop:))) { ((void(*)(id,SEL,BOOL))objc_msgSend)(vc, @selector(reloadTop:), YES); return YES; }
    return NO;
}
static BOOL nfb_doRefreshContent(id vc) {
    if (nfb_resp(vc, @selector(_refreshContent))) { ((void(*)(id,SEL))objc_msgSend)(vc, @selector(_refreshContent)); return YES; }
    return NO;
}

// Auto-refresh trigger: try the data-load path first, then the gesture handler.
static void nfb_streamTrigger(UIViewController *vc) {
    if (nfb_doLoadNewer(vc)) return;
    if (nfb_doPull(vc))      return;
    if (nfb_doReloadTop(vc)) return;
    nfb_doRefreshContent(vc);
}

#pragma mark - gauge button

@interface NFBStreamButton : UIButton
@property (nonatomic, strong) CAShapeLayer *gauge;
@end
@implementation NFBStreamButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _gauge = [CAShapeLayer layer];
        _gauge.fillColor   = UIColor.clearColor.CGColor;
        _gauge.lineWidth   = 2.5;
        _gauge.lineCap     = kCALineCapRound;
        _gauge.strokeColor = UIColor.systemBlueColor.CGColor;
        _gauge.strokeEnd   = 0.0;
        [self.layer addSublayer:_gauge];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0 - 1.5;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _gauge.frame = self.bounds;
    _gauge.path  = [UIBezierPath bezierPathWithArcCenter:c radius:r
                                              startAngle:-M_PI_2 endAngle:(3.0 * M_PI_2)
                                               clockwise:YES].CGPath;
}
@end

static NFBStreamButton *gStreamButton = nil;

static void nfb_setStreamEnabled(BOOL on)   { [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"auto_stream_timeline"]; }
static void nfb_setStreamInterval(NSInteger s) { [[NSUserDefaults standardUserDefaults] setInteger:s forKey:@"auto_stream_interval"]; }

static const NSInteger kNFBIntervalChoices[] = {10, 15, 20, 30, 60};

static UIMenu *nfb_buildStreamMenu(UIViewController *vc) {
    BOOL on = [BHTManager autoStreamTimeline];
    NSInteger cur = [BHTManager autoStreamInterval];
    __weak UIViewController *wvc = vc;

    UIAction *(^mk)(NSString *, NSString *, void(^)(UIViewController *)) =
        ^UIAction *(NSString *title, NSString *sym, void(^act)(UIViewController *)) {
        return [UIAction actionWithTitle:title image:(sym ? [UIImage systemImageNamed:sym] : nil)
                              identifier:nil handler:^(__kindof UIAction *a) {
            UIViewController *s = wvc; if (s) act(s);
        }];
    };

    UIAction *refreshNow = mk(@"今すぐ更新", @"arrow.clockwise", ^(UIViewController *s){ nfb_streamTrigger(s); });

    // Diagnostic submenu: identify which refresh entry point actually updates the TL.
    UIMenu *test = [UIMenu menuWithTitle:@"更新方式テスト" image:[UIImage systemImageNamed:@"wrench.and.screwdriver"]
                              identifier:nil options:0 children:@[
        mk(@"A: pull", nil, ^(UIViewController *s){ nfb_doPull(s); }),
        mk(@"B: loadNewer", nil, ^(UIViewController *s){ nfb_doLoadNewer(s); }),
        mk(@"C: reloadTop", nil, ^(UIViewController *s){ nfb_doReloadTop(s); }),
        mk(@"D: refreshContent", nil, ^(UIViewController *s){ nfb_doRefreshContent(s); }),
    ]];

    UIAction *toggle = [UIAction actionWithTitle:@"TL自動更新（垂れ流し）"
                                           image:[UIImage systemImageNamed:@"bolt.fill"]
                                      identifier:nil handler:^(__kindof UIAction *a) {
        nfb_setStreamEnabled(!on);
        UIViewController *s = wvc; if (s) nfb_streamStart(s);
    }];
    toggle.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSMutableArray<UIMenuElement *> *ivals = [NSMutableArray array];
    for (int i = 0; i < (int)(sizeof(kNFBIntervalChoices)/sizeof(NSInteger)); i++) {
        NSInteger sec = kNFBIntervalChoices[i];
        UIAction *a = [UIAction actionWithTitle:[NSString stringWithFormat:@"%ld秒", (long)sec]
                                          image:nil identifier:nil handler:^(__kindof UIAction *act) {
            nfb_setStreamInterval(sec);
            UIViewController *s = wvc; if (s) nfb_streamStart(s);
        }];
        a.state = (sec == cur) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [ivals addObject:a];
    }
    UIMenu *interval = [UIMenu menuWithTitle:@"更新間隔" image:[UIImage systemImageNamed:@"timer"]
                                  identifier:nil options:0 children:ivals];

    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:0
                        children:@[refreshNow, test, toggle, interval]];
}

static void nfb_styleButton(BOOL on) {
    if (!gStreamButton) return;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    NSString *name = on ? @"arrow.clockwise.circle.fill" : @"arrow.clockwise.circle";
    [gStreamButton setImage:[[UIImage systemImageNamed:name withConfiguration:cfg]
                                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                   forState:UIControlStateNormal];
    gStreamButton.tintColor = on ? nil : [UIColor systemGrayColor];
    gStreamButton.gauge.hidden = !on;
}

// Drive the countdown ring: full -> empty over `interval`, looping.
static void nfb_updateGauge(BOOL on, NSTimeInterval interval) {
    if (!gStreamButton) return;
    CAShapeLayer *g = gStreamButton.gauge;
    [g removeAnimationForKey:@"deplete"];
    if (!on || interval <= 0) { g.strokeEnd = 0.0; return; }
    g.strokeEnd = 1.0;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    anim.fromValue = @1.0; anim.toValue = @0.0;
    anim.duration = interval;
    anim.repeatCount = HUGE_VALF;
    anim.removedOnCompletion = NO;
    anim.fillMode = kCAFillModeForwards;
    [g addAnimation:anim forKey:@"deplete"];
}

static void nfb_installButton(UIViewController *vc) {
    UIWindow *win = vc.view.window;
    if (!win) return;
    if (!gStreamButton) {
        gStreamButton = [NFBStreamButton buttonWithType:UIButtonTypeSystem];
        gStreamButton.translatesAutoresizingMaskIntoConstraints = NO;
        gStreamButton.showsMenuAsPrimaryAction = YES;
        gStreamButton.accessibilityLabel = @"TL自動更新";
    }
    gStreamButton.menu = nfb_buildStreamMenu(vc);
    if (gStreamButton.superview != win) {
        [gStreamButton removeFromSuperview];
        [win addSubview:gStreamButton];
        UILayoutGuide *safe = win.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [gStreamButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:2.0],
            [gStreamButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
            [gStreamButton.widthAnchor constraintEqualToConstant:44.0],
            [gStreamButton.heightAnchor constraintEqualToConstant:44.0],
        ]];
    }
    [win bringSubviewToFront:gStreamButton];
    nfb_styleButton([BHTManager autoStreamTimeline]);
}

static void nfb_removeButton(void) {
    if (gStreamButton) { [gStreamButton.gauge removeAnimationForKey:@"deplete"]; [gStreamButton removeFromSuperview]; }
}

#pragma mark - streaming timer

static char kNFBStreamTimerKey;

static BOOL nfb_streamShouldFire(UIViewController *vc) {
    if (![BHTManager autoStreamTimeline]) return NO;
    if (![vc isViewLoaded] || vc.view.window == nil) return NO;
    UIScrollView *sv = nfb_scrollOf(vc);
    if (sv) {
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) return NO; // don't interrupt the user
        // Stay lenient: only skip when scrolled well down (then the native pill handles it).
        CGFloat topY = -sv.adjustedContentInset.top;
        if (sv.contentOffset.y > topY + 600.0) return NO;
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
        if (![BHTManager autoStreamTimeline]) { nfb_streamStop(s); nfb_updateGauge(NO, 0); nfb_styleButton(NO); return; }
        if (nfb_streamShouldFire(s)) nfb_streamTrigger(s);
    }];
    // Keep firing while the user scrolls, too (gauge + checks still gate it).
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

%hook THFHomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_installButton(self); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); nfb_removeButton(); }
%end

// Older app versions expose the T1-prefixed controller.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_installButton(self); nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); nfb_removeButton(); }
%end
