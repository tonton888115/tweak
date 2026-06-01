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

#pragma mark - Hooks

%hook THFHomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
%end

// Older app versions expose the T1-prefixed controller.
%hook T1HomeTimelineItemsViewController
- (void)viewDidAppear:(BOOL)animated { %orig; nfb_streamStart(self); }
- (void)viewDidDisappear:(BOOL)animated { %orig; nfb_streamStop(self); }
%end
