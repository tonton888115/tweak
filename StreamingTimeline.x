//
//  StreamingTimeline.x
//  NeoFreeBird
//
//  Native Home-timeline auto-refresh ("streaming" / 垂れ流し) mode, inspired by
//  the old Feather client and OldTweetDeck's live columns.
//
//  When enabled, the visible Home timeline is refreshed on a repeating timer.
//  A refresh only fires while the user is parked near the very top and is not
//  actively scrolling, so reading further down is never interrupted — new
//  Tweets simply flow in from the top, exactly like a streaming column. When
//  the user has scrolled down, the native "new Tweets" pill still appears, so
//  nothing is lost.
//
//  Pairs nicely with the existing "Always show Following" option, since the
//  Following (chronological) tab is where streaming feels most natural.
//

#import "TWHeaders.h"
#import "BHTManager.h"
#import <objc/runtime.h>

// --- Minimal private declarations (confirmed against Twitter 11.35) ---
// Verify the exact selectors at runtime with the bundled FLEX if a future
// Twitter build changes them.
@interface TFNTwitterHomeTimeline : NSObject
- (void)loadNewerWithSource:(NSUInteger)source completion:(void (^)(void))completion;
@end

@interface THFHomeTimelineItemsViewController : UIViewController
@property (nonatomic, readonly) UIScrollView *scrollView;
@property (nonatomic, readonly) TFNTwitterHomeTimeline *timeline;
- (void)_t1_didPullToRefresh:(id)arg1;
@end

// Older app versions. The shared helpers reach its accessors via -respondsToSelector:,
// so only the UIViewController base needs to be known here.
@interface T1HomeTimelineItemsViewController : UIViewController
@end

// Associated-object key for the per-controller refresh timer.
static char kNFBStreamTimerKey;

// How close to the top (in points) still counts as "parked at the top".
static const CGFloat kNFBStreamTopThreshold = 90.0;

#pragma mark - Core logic (shared by every Home-timeline controller class)

static BOOL nfb_streamShouldFire(UIViewController *vc) {
    if (![BHTManager autoStreamTimeline]) return NO;

    // Only stream the timeline the user is actually looking at. The Home
    // container keeps both "For you" and "Following" item controllers alive,
    // so this stops the off-screen tab from burning requests.
    if (![vc isViewLoaded] || vc.view.window == nil) return NO;

    if (![vc respondsToSelector:@selector(scrollView)]) return YES; // can't inspect, allow
    UIScrollView *sv = [(id)vc scrollView];
    if (!sv) return YES;

    // Never refresh while the user is touching / flinging the list.
    if (sv.isDragging || sv.isDecelerating || sv.isTracking) return NO;

    // Only "stream" while parked near the very top.
    CGFloat topY = -sv.adjustedContentInset.top;
    return (sv.contentOffset.y <= topY + kNFBStreamTopThreshold);
}

static void nfb_streamTrigger(UIViewController *vc) {
    // Preferred: replay the exact pull-to-refresh path. It is guaranteed to
    // fetch + prepend newer Tweets and gives the same subtle spinner feedback
    // as a manual pull (the classic Feather auto-refresh feel). Because we only
    // ever call it while parked at the top, it is non-disruptive.
    if ([vc respondsToSelector:@selector(_t1_didPullToRefresh:)]) {
        [(id)vc _t1_didPullToRefresh:nil];
        return;
    }

    // Fallback: ask the timeline model to load newer items directly. The source
    // enum value may differ per app version — confirm with FLEX if needed.
    if ([vc respondsToSelector:@selector(timeline)]) {
        TFNTwitterHomeTimeline *tl = [(id)vc timeline];
        if ([tl respondsToSelector:@selector(loadNewerWithSource:completion:)]) {
            [tl loadNewerWithSource:0 completion:nil];
        }
    }
}

static void nfb_streamStop(UIViewController *vc) {
    NSTimer *timer = objc_getAssociatedObject(vc, &kNFBStreamTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void nfb_streamStart(UIViewController *vc) {
    nfb_streamStop(vc);
    if (![BHTManager autoStreamTimeline]) return;

    NSTimeInterval interval = (NSTimeInterval)[BHTManager autoStreamInterval];
    __weak UIViewController *weakVC = vc;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        UIViewController *strongVC = weakVC;
        if (!strongVC) { [t invalidate]; return; }            // controller gone
        if (![BHTManager autoStreamTimeline]) { nfb_streamStop(strongVC); return; } // toggled off
        if (nfb_streamShouldFire(strongVC)) {
            nfb_streamTrigger(strongVC);
        }
    }];
    objc_setAssociatedObject(vc, &kNFBStreamTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Header control (top-right pull-down: on/off + interval)

static char kNFBStreamButtonKey;
static const NSInteger kNFBIntervalChoices[] = {10, 15, 20, 30, 60};

static UIMenu *nfb_buildStreamMenu(UIViewController *vc);
static void nfb_refreshStreamButton(UIViewController *vc);

static void nfb_setStreamEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"auto_stream_timeline"];
}
static void nfb_setStreamInterval(NSInteger seconds) {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:@"auto_stream_interval"];
}

static UIMenu *nfb_buildStreamMenu(UIViewController *vc) {
    BOOL on = [BHTManager autoStreamTimeline];
    NSInteger cur = [BHTManager autoStreamInterval];
    __weak UIViewController *wvc = vc;

    UIAction *toggle = [UIAction actionWithTitle:@"TL自動更新（垂れ流し）"
                                           image:[UIImage systemImageNamed:@"bolt.fill"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        nfb_setStreamEnabled(!on);
        UIViewController *s = wvc;
        if (s) { nfb_streamStart(s); nfb_refreshStreamButton(s); }
    }];
    toggle.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSMutableArray<UIMenuElement *> *choices = [NSMutableArray array];
    for (int i = 0; i < (int)(sizeof(kNFBIntervalChoices)/sizeof(NSInteger)); i++) {
        NSInteger sec = kNFBIntervalChoices[i];
        UIAction *a = [UIAction actionWithTitle:[NSString stringWithFormat:@"%ld秒", (long)sec]
                                          image:nil identifier:nil
                                        handler:^(__kindof UIAction *action) {
            nfb_setStreamInterval(sec);
            UIViewController *s = wvc;
            if (s) { nfb_streamStart(s); nfb_refreshStreamButton(s); }
        }];
        a.state = (sec == cur) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [choices addObject:a];
    }
    UIMenu *interval = [UIMenu menuWithTitle:@"更新間隔"
                                       image:[UIImage systemImageNamed:@"timer"]
                                  identifier:nil
                                     options:0
                                    children:choices];

    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:0 children:@[toggle, interval]];
}

static void nfb_styleStreamButton(UIButton *btn, BOOL on) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18
                                                                                     weight:UIImageSymbolWeightSemibold];
    NSString *name = on ? @"arrow.clockwise.circle.fill" : @"arrow.clockwise.circle";
    [btn setImage:[[UIImage systemImageNamed:name withConfiguration:cfg]
                      imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
         forState:UIControlStateNormal];
    btn.tintColor = on ? nil : [UIColor systemGrayColor]; // nil -> inherit the app's accent
}

static void nfb_refreshStreamButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, &kNFBStreamButtonKey);
    if (!btn) return;
    nfb_styleStreamButton(btn, [BHTManager autoStreamTimeline]);
    btn.menu = nfb_buildStreamMenu(vc);
}

static void nfb_addStreamButton(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, &kNFBStreamButtonKey)) { nfb_refreshStreamButton(vc); return; }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.menu = nfb_buildStreamMenu(vc);
    btn.showsMenuAsPrimaryAction = YES;                 // tap opens the menu directly
    btn.accessibilityLabel = @"TL自動更新";
    nfb_styleStreamButton(btn, [BHTManager autoStreamTimeline]);

    [vc.view addSubview:btn];
    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [btn.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6.0],
        [btn.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10.0],
        [btn.widthAnchor constraintEqualToConstant:34.0],
        [btn.heightAnchor constraintEqualToConstant:34.0],
    ]];
    objc_setAssociatedObject(vc, &kNFBStreamButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

%hook THFHomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_streamStart(self); nfb_addStreamButton(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
%end

// Older app versions expose the T1-prefixed controller.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_streamStart(self); nfb_addStreamButton(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
%end
