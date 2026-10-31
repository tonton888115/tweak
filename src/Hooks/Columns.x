//
//  Columns.x
//  NeoFreeBird
//
//  OldTweetDeck-style columns for the Home timelines (For You / Following / pinned lists) on
//  X 12.x. The Home pager is TFNUISwift.LegacyPagingViewController: a UICollectionView whose
//  PagingFlowLayout gives every page the full width. In columns mode we answer that layout's
//  geometry questions ourselves — fixed 340pt columns, user order, hidden columns — and snap
//  scrolling to column edges. Nothing is reparented and no Twitter view frame is written by
//  hand: UIKit lays the cells out, so window resizes follow natively.
//
//  Like the 11.35 fork, columns live on their own bottom tab: one native tab (the "host",
//  Communities by default) is relabelled "Columns". Tapping it shows the Home surface in columns;
//  Home itself always stays the normal Home, and any other tab turns columns off again.
//  While columns are shown, the Home segment strip and the Spaces bar are hidden (restored on leave).
//
//  App-tab columns: X's own tabs (Notifications, Search, Bookmarks, …) can be added as columns too.
//  Each is a second instance of that tab hosted in the Home collection view (see "app-tab columns").
//
//  Prefs: nfb_columns_enabled (the Columns tab), nfb_columns_host (page ID of the replaced tab),
//  nfb_columns_full_width (iPad: drop the right trends pane via T1AppSplitViewController's own
//  split-mode inputs), nfb_columns_order (timeline titles and "tab:<page>" keys),
//  nfb_columns_visibility (key -> BOOL; For You and every app tab default to hidden).
//

#import "HookHelpers.h"

@interface _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42416PagingFlowLayout : UICollectionViewLayout
@end
@interface _TtC10TFNUISwift26LegacyPagingViewController : UIViewController
@end
@interface _TtC10TFNUISwift29LegacySegmentedViewController : UIViewController
@end
@interface _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42420PagingCollectionView : UICollectionView
@end
@interface _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController : UIViewController
@end
@interface T1FleetLineHeaderController : NSObject
@end

void NFBLogEvent(NSString *msg);
void NFBStreamPrefsChanged(void);
void NFBColumnsRevealAllTops(void);   // Streaming.x

static NSString * const kNFBColsEnabledKey = @"nfb_columns_enabled";
static NSString * const kNFBColsFullWidthKey = @"nfb_columns_full_width";
static NSString * const kNFBColsOrderKey = @"nfb_columns_order";
static NSString * const kNFBColsVisibilityKey = @"nfb_columns_visibility";
static NSString * const kNFBColsTabInFlightKey = @"nfb_columns_tab_inflight";   // app-tab columns being opened
static NSString * const kNFBColsTabFailedKey = @"nfb_columns_tab_failed";       // ... that the app died opening

static BOOL gNFBColsEnabled = NO;          // Columns tab feature (pref), cached
static BOOL gNFBColsEnabledLoaded = NO;
static BOOL gNFBColsActive = NO;           // runtime: the Columns tab is the selected tab
static BOOL gNFBColsSelectingHome = NO;    // re-entrancy guard while we select Home ourselves
static NSUInteger gNFBColsGen = 1;         // bumped on any pref change -> model rebuild
static __weak UIViewController *gNFBColsPager = nil;
static __weak UICollectionView *gNFBColsCollectionView = nil;

static char kNFBColsIsHomeKey;             // NSNumber on the layout / pager
static char kNFBColsModelKey;              // NFBColumnsModel on the layout
static char kNFBColsSavedPagingKey;        // NSNumber(pagingEnabled) on the collection view
static char kNFBColsSavedScrollKey;        // NSNumber(scrollEnabled): iPad may disable swipe paging
static char kNFBColsDesiredOffsetKey;      // NSNumber(x) on the collection view
static char kNFBColsKickedKey;             // one empty-content load kick per page
static BOOL gNFBColsRawTabTitle = NO;      // read a T1TabView's own title (no "Columns" relabel)
static BOOL gNFBColsSettingScroll = NO;          // our own scrollEnabled write, not X's wish
static NSUInteger gNFBColsScrollOffBlocked = 0;  // times X tried to turn the columns' swipe off

// Horizontal scroll stats (diagnostics; see nfb_colsScrollStatsFlush).
static struct {
    NSUInteger frames, slow, invalidations, prepares, selects;
    NSUInteger rejectVertical, rejectEdge, stockVetoes;
    double lastT, maxGap, startX;
} gNFBColsScroll;

static void nfb_colsScheduleKick(void);
static NSArray<NSDictionary *> *nfb_colsTabCandidates(void);
static NSSet<NSString *> *nfb_colsTabFailed(void);
static BOOL nfb_colsTabSkippedNow(NSString *identity);
static void nfb_colsScheduleTabLayout(void);
static UICollectionView *nfb_colsCollectionViewOfPager(UIViewController *pager);

static NSString *nfb_colsLoc(NSString *key, NSString *fallback) {
    NSString *value = [[BHTBundle sharedBundle] localizedStringForKey:key];
    return (value.length && ![value isEqualToString:key]) ? value : fallback;
}

static BOOL nfb_colsEnabled(void) {
    if (!gNFBColsEnabledLoaded) {
        gNFBColsEnabled = [BHTSettings boolForKey:kNFBColsEnabledKey];
        gNFBColsEnabledLoaded = YES;
    }
    return gNFBColsEnabled;
}

// Columns are shown only while the Columns tab is selected.
static BOOL nfb_colsActiveNow(void) {
    return gNFBColsActive && nfb_colsEnabled();
}

NSString *NFBColumnsHostPageID(void) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *page = [defs stringForKey:@"nfb_columns_host"];
    if (page.length) return page;
    // Carry over the host chosen in the 11.35 builds once this X version is known to have that tab.
    NSString *old = [defs stringForKey:@"columns_host_page"];
    if (old.length && ![old isEqualToString:CustomTabBarHomePageID] && [CustomTabBarUtility metadataForPage:old]) {
        [defs setObject:old forKey:@"nfb_columns_host"];
        return old;
    }
    return @"communities";
}

static CGFloat nfb_colsColumnWidth(CGFloat viewportWidth) {
    // Fixed 340pt columns; never wider than the viewport so one column always fits.
    return MIN(340.0, MAX(200.0, viewportWidth));
}

static BOOL nfb_colsTitleLooksRecommended(NSString *text) {
    NSString *low = text.lowercaseString;
    return [text containsString:@"おすすめ"] || [low containsString:@"for you"] ||
           [low containsString:@"foryou"] || [low containsString:@"recommended"];
}

#pragma mark - model (titles, order, visibility)

@interface NFBColumnsModel : NSObject
@property (nonatomic) NSUInteger gen;
@property (nonatomic) NSInteger itemCount;
@property (nonatomic, copy) NSArray<NSString *> *titles;        // per item index
@property (nonatomic, copy) NSArray<NSNumber *> *slots;         // visible item indices in display order
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *slotOfItem;   // item -> column number
@property (nonatomic, copy) NSArray<NSDictionary *> *tabColumns;  // visible app tabs: id, page, title, entry, slot
@property (nonatomic) NSInteger columnCount;                     // timeline + app-tab columns
@end
@implementation NFBColumnsModel
@end

static NSString *nfb_colsTabDiag(NFBColumnsModel *model);

static UIViewController *nfb_colsViewControllerOfView(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        UIResponder *n = v.nextResponder;
        if ([n isKindOfClass:UIViewController.class]) return (UIViewController *)n;
    }
    return nil;
}

static UIViewController *nfb_colsParentNamed(UIViewController *vc, NSString *needle) {
    UIViewController *current = vc;
    for (int i = 0; current && i < 10; i++, current = current.parentViewController) {
        if ([NSStringFromClass(current.class) containsString:needle]) return current;
    }
    return nil;
}

static UIViewController *nfb_colsPagerOfCollectionView(UICollectionView *cv) {
    UIViewController *vc = nfb_colsViewControllerOfView(cv);
    return nfb_colsParentNamed(vc, @"LegacyPagingViewController");
}

static BOOL nfb_colsPagerIsHome(UIViewController *pager) {
    if (!pager) return NO;
    NSNumber *cached = objc_getAssociatedObject(pager, &kNFBColsIsHomeKey);
    if (cached) return cached.boolValue;
    BOOL home = nfb_colsParentNamed(pager, @"HomeTimelineContainer") != nil;
    // Only cache once the pager is attached; an early answer can be a false negative.
    if (pager.parentViewController) objc_setAssociatedObject(pager, &kNFBColsIsHomeKey, @(home), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return home;
}

// Layout -> is this the Home pager's layout? Cached on the layout once known.
static BOOL nfb_colsLayoutIsHome(UICollectionViewLayout *layout) {
    NSNumber *cached = objc_getAssociatedObject(layout, &kNFBColsIsHomeKey);
    if (cached) return cached.boolValue;
    UICollectionView *cv = layout.collectionView;
    if (!cv || !cv.window) return NO;
    UIViewController *pager = nfb_colsPagerOfCollectionView(cv);
    if (!pager || !pager.parentViewController) return NO;
    BOOL home = nfb_colsPagerIsHome(pager);
    objc_setAssociatedObject(layout, &kNFBColsIsHomeKey, @(home), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (home) {
        gNFBColsPager = pager;
        gNFBColsCollectionView = cv;
    }
    return home;
}

static UIViewController *nfb_colsSegmentedOfPager(UIViewController *pager) {
    return nfb_colsParentNamed(pager, @"LegacySegmentedViewController");
}

static NSArray<NSString *> *nfb_colsTitlesForPager(UIViewController *pager, NSInteger count) {
    UIViewController *segmented = nfb_colsSegmentedOfPager(pager);
    id dataSource = [segmented respondsToSelector:@selector(dataSource)] ? ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(dataSource)) : nil;
    SEL descSel = @selector(segmentedViewController:descriptorAtIndex:);
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSCountedSet *seen = [NSCountedSet set];
    for (NSInteger i = 0; i < count; i++) {
        NSString *title = nil;
        if (segmented && [dataSource respondsToSelector:descSel]) {
            id descriptor = nil;
            @try {
                descriptor = ((id(*)(id, SEL, id, NSInteger))objc_msgSend)(dataSource, descSel, segmented, i);
            } @catch (NSException *e) {
                descriptor = nil;
            }
            for (NSString *getter in @[@"firstLabelText", @"tabAccessibilityLabel"]) {
                SEL sel = NSSelectorFromString(getter);
                if (!title.length && [descriptor respondsToSelector:sel]) {
                    id value = ((id(*)(id, SEL))objc_msgSend)(descriptor, sel);
                    if ([value isKindOfClass:NSString.class]) title = value;
                    else if ([value isKindOfClass:NSAttributedString.class]) title = [(NSAttributedString *)value string];
                }
            }
        }
        if (!title.length) title = [NSString stringWithFormat:@"Tab %ld", (long)(i + 1)];
        [seen addObject:title];
        NSUInteger n = [seen countForObject:title];
        [titles addObject:(n > 1 ? [NSString stringWithFormat:@"%@ #%lu", title, (unsigned long)n] : title)];
    }
    return titles;
}

static BOOL nfb_colsTitleVisible(NSString *title, NSDictionary *visibility) {
    id value = visibility[title];
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return !nfb_colsTitleLooksRecommended(title);   // For You is opt-in (never auto-refreshed)
}

static NFBColumnsModel *nfb_colsBuildModel(UIViewController *pager, NSInteger count) {
    NFBColumnsModel *model = [NFBColumnsModel new];
    model.gen = gNFBColsGen;
    model.itemCount = count;
    model.titles = nfb_colsTitlesForPager(pager, count);
    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:kNFBColsOrderKey] ?: @[];
    NSDictionary *visibility = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kNFBColsVisibilityKey] ?: @{};
    NSArray<NSDictionary *> *candidates = nfb_colsTabCandidates();
    NSMutableDictionary<NSString *, NSDictionary *> *tabs = [NSMutableDictionary dictionary];
    for (NSDictionary *tab in candidates) tabs[tab[@"id"]] = tab;
    // Display order of every column key: timelines by title, app tabs by "tab:<page>".
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in savedOrder) {
        if (![key isKindOfClass:NSString.class] || [keys containsObject:key]) continue;
        if ([model.titles containsObject:key] || tabs[key]) [keys addObject:key];
    }
    for (NSString *title in model.titles) if (![keys containsObject:title]) [keys addObject:title];
    for (NSDictionary *tab in candidates) if (![keys containsObject:tab[@"id"]]) [keys addObject:tab[@"id"]];
    NSSet<NSString *> *failed = nfb_colsTabFailed();
    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];   // every timeline, display order
    NSMutableArray *columns = [NSMutableArray array];               // NSNumber item / NSDictionary tab
    BOOL anyTimeline = NO;
    for (NSString *key in keys) {
        NSUInteger item = [model.titles indexOfObject:key];
        if (item != NSNotFound) {
            [ordered addObject:@(item)];
            if (nfb_colsTitleVisible(key, visibility)) {
                [columns addObject:@(item)];
                anyTimeline = YES;
            }
        } else if (tabs[key] && [visibility[key] boolValue] && ![failed containsObject:key] && !nfb_colsTabSkippedNow(key)) {
            [columns addObject:tabs[key]];
        }
    }
    if (!anyTimeline) {   // never hide every timeline
        NSArray *tabColumns = [columns copy];
        [columns setArray:ordered];
        [columns addObjectsFromArray:tabColumns];
    }
    NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *tabColumns = [NSMutableArray array];
    NSMutableDictionary *slotOfItem = [NSMutableDictionary dictionary];
    [columns enumerateObjectsUsingBlock:^(id column, NSUInteger idx, BOOL *stop) {
        if ([column isKindOfClass:NSNumber.class]) {
            [slots addObject:column];
            slotOfItem[column] = @(idx);
        } else {
            NSMutableDictionary *tab = [column mutableCopy];
            tab[@"slot"] = @(idx);
            [tabColumns addObject:tab];
        }
    }];
    model.slots = slots;
    model.slotOfItem = slotOfItem;
    model.tabColumns = tabColumns;
    model.columnCount = (NSInteger)columns.count;
    return model;
}

static NFBColumnsModel *nfb_colsModelForLayout(UICollectionViewLayout *layout) {
    UICollectionView *cv = layout.collectionView;
    NSInteger count = (cv && cv.numberOfSections > 0) ? [cv numberOfItemsInSection:0] : 0;
    NFBColumnsModel *model = objc_getAssociatedObject(layout, &kNFBColsModelKey);
    if (model && model.gen == gNFBColsGen && model.itemCount == count) return model;
    model = nfb_colsBuildModel(nfb_colsPagerOfCollectionView(cv), count);
    objc_setAssociatedObject(layout, &kNFBColsModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return model;
}

static BOOL nfb_colsActiveForLayout(UICollectionViewLayout *layout) {
    return nfb_colsActiveNow() && nfb_colsLayoutIsHome(layout);
}

static CGFloat nfb_colsSnap(UICollectionView *cv, CGFloat proposedX, CGFloat velocityX, CGFloat currentX) {
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    CGFloat maxX = MAX(0.0, cv.contentSize.width - cv.bounds.size.width);
    CGFloat x = MIN(MAX(proposedX, 0.0), maxX);
    CGFloat snapped = round(x / cw) * cw;
    // A deliberate flick always moves at least one column in its direction.
    if (velocityX > 0.3) snapped = MAX(snapped, (floor(currentX / cw) + 1.0) * cw);
    else if (velocityX < -0.3) snapped = MIN(snapped, (ceil(currentX / cw) - 1.0) * cw);
    // The last column may not start on a column edge when the content is not a multiple of cw.
    if (maxX - snapped < cw * 0.5 && x > maxX - cw * 0.5) snapped = maxX;
    return MIN(MAX(snapped, 0.0), maxX);
}

#pragma mark - pages / diagnostics exports (used by Streaming.x)

static UIViewController *nfb_colsPageForCell(UICollectionViewCell *cell, UIViewController *pager) {
    for (UIView *sub in cell.contentView.subviews) {
        UIViewController *vc = nfb_colsViewControllerOfView(sub);
        if (!vc || vc == pager) continue;
        UIViewController *page = vc;
        while (page.parentViewController && page.parentViewController != pager) page = page.parentViewController;
        return (page.parentViewController == pager) ? page : vc;
    }
    return nil;
}

// Read-only peek at a Swift stored property through its ObjC-visible ivar (diagnostics only).
static const uint8_t *nfb_colsIvarPtr(id obj, const char *name) {
    if (!obj) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    ptrdiff_t offset = ivar ? ivar_getOffset(ivar) : 0;
    return offset > 0 ? (const uint8_t *)(__bridge void *)obj + offset : NULL;
}

static NSString *nfb_colsIntIvarText(id obj, const char *name, BOOL optional) {
    const uint8_t *p = nfb_colsIvarPtr(obj, name);
    if (!p) return @"?";
    if (optional && p[8]) return @"nil";   // Swift Int?: 8-byte payload + 1-byte "is nil" tag
    return [NSString stringWithFormat:@"%ld", (long)*(const NSInteger *)p];
}

// Strong object-typed Swift stored property (e.g. barContainerView); never use for weak ones.
static id nfb_colsObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static NSHashTable *gNFBColsFleetHeaders = nil;   // T1FleetLineHeaderController (Spaces bar), weak

// The vertical timeline scroll view of a column page (first table/collection view, breadth first).
static UIScrollView *nfb_colsContentScrollViewOf(UIViewController *page) {
    if (![page isViewLoaded]) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:page.view];
    NSUInteger hops = 0;
    while (queue.count && hops++ < 200) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:UITableView.class] || [v isKindOfClass:UICollectionView.class]) return (UIScrollView *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

BOOL NFBColumnsTabEnabled(void) {
    return nfb_colsEnabled();
}

BOOL NFBColumnsActive(void) {
    UICollectionView *cv = gNFBColsCollectionView;
    return nfb_colsActiveNow() && cv && cv.window;
}

// Visible column pages in display order, with their titles.
NSArray<NSDictionary *> *NFBColumnsVisibleEntries(void) {
    UICollectionView *cv = gNFBColsCollectionView;
    UIViewController *pager = gNFBColsPager;
    if (!NFBColumnsActive() || !pager) return @[];
    NFBColumnsModel *model = objc_getAssociatedObject(cv.collectionViewLayout, &kNFBColsModelKey);
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (UICollectionViewCell *cell in cv.visibleCells) {
        NSIndexPath *ip = [cv indexPathForCell:cell];
        if (!ip || cell.hidden) continue;
        if (!CGRectIntersectsRect(cell.frame, cv.bounds)) continue;
        UIViewController *page = nfb_colsPageForCell(cell, pager);
        if (!page) continue;
        NSString *title = (model && ip.item < (NSInteger)model.titles.count) ? model.titles[ip.item] : @"";
        NSNumber *slot = model.slotOfItem[@(ip.item)] ?: @(NSIntegerMax);
        [entries addObject:@{ @"vc": page, @"title": title, @"slot": slot, @"item": @(ip.item),
                              @"recommended": @(nfb_colsTitleLooksRecommended(title)) }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"slot"] compare:b[@"slot"]];
    }];
    return entries;
}

// Every column the user shows (on screen or not), in display order.
NSArray<NSDictionary *> *NFBColumnsAllEntries(void) {
    UICollectionView *cv = gNFBColsCollectionView;
    UIViewController *pager = gNFBColsPager;
    if (!NFBColumnsActive() || !pager) return @[];
    NFBColumnsModel *model = objc_getAssociatedObject(cv.collectionViewLayout, &kNFBColsModelKey);
    UIViewController *segmented = nfb_colsSegmentedOfPager(pager);
    if (!model || ![segmented respondsToSelector:@selector(viewControllerAtTabIndex:)]) return NFBColumnsVisibleEntries();
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    [model.slots enumerateObjectsUsingBlock:^(NSNumber *item, NSUInteger slot, BOOL *stop) {
        id vc = nil;
        @try {
            vc = ((id(*)(id, SEL, NSInteger))objc_msgSend)(segmented, @selector(viewControllerAtTabIndex:), item.integerValue);
        } @catch (NSException *e) {
            vc = nil;
        }
        if (![vc isKindOfClass:UIViewController.class]) return;
        NSString *title = item.integerValue < (NSInteger)model.titles.count ? model.titles[item.integerValue] : @"";
        [entries addObject:@{ @"vc": vc, @"title": title, @"slot": @(slot), @"item": item,
                              @"recommended": @(nfb_colsTitleLooksRecommended(title)) }];
    }];
    return entries;
}

// The pager only tells its *current* page that it appeared; a timeline that never "appeared" does
// not load (why a list first opened on Home showed fine in columns, and others stayed stale).
// While columns are shown every column page gets an appearance transition; leaving undoes it for
// all but the pager's current page, so appearance stays balanced.
static NSHashTable<UIViewController *> *gNFBColsAppeared = nil;

static void nfb_colsSyncPageAppearance(BOOL columns) {
    UIViewController *segmented = nfb_colsSegmentedOfPager(gNFBColsPager);
    id current = [segmented respondsToSelector:@selector(selectedViewController)] ?
        ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(selectedViewController)) : nil;
    NSUInteger changed = 0;
    if (columns) {
        if (!gNFBColsAppeared) gNFBColsAppeared = [NSHashTable weakObjectsHashTable];
        for (NSDictionary *entry in NFBColumnsAllEntries()) {
            UIViewController *page = entry[@"vc"];
            if (page == current || ![page isViewLoaded] || [gNFBColsAppeared containsObject:page]) continue;
            [page beginAppearanceTransition:YES animated:NO];
            [page endAppearanceTransition];
            [gNFBColsAppeared addObject:page];
            changed++;
        }
    } else {
        for (UIViewController *page in gNFBColsAppeared.allObjects) {
            if (page == current) continue;
            [page beginAppearanceTransition:NO animated:NO];
            [page endAppearanceTransition];
            changed++;
        }
        [gNFBColsAppeared removeAllObjects];
    }
    if (changed) {
        NFBLogEvent([NSString stringWithFormat:@"columns pagesAppear on=%d changed=%lu current=%@", columns ? 1 : 0,
            (unsigned long)changed, current ? NSStringFromClass([current class]) : @"nil"]);
    }
}

// Column timelines keep X's top inset minus the space of the rows we hide (segment strip, Spaces
// bar): their first post starts right under the navigation bar. X sets the inset itself (also
// later, e.g. when the Spaces bar changes), so TFNTableView's setContentInset: applies the fit and
// remembers X's value to restore on leave. Insets are read/written with UIScrollView's own
// accessors (TFNTableView overrides the getter).
static char kNFBColsFittedTableKey;        // NSNumber(YES) on a column timeline while fitted
static char kNFBColsTableStockTopKey;      // NSNumber: the top inset X asked for
static NSHashTable<UIScrollView *> *gNFBColsFittedTables = nil;
static BOOL gNFBColsSettingInset = NO;

static UIEdgeInsets nfb_colsStoredInset(UIScrollView *sv) {
    static UIEdgeInsets (*getter)(id, SEL) = NULL;
    if (!getter) getter = (UIEdgeInsets(*)(id, SEL))class_getMethodImplementation(UIScrollView.class, @selector(contentInset));
    return getter(sv, @selector(contentInset));
}

static CGFloat nfb_colsFittedTop(UIScrollView *sv, CGFloat stockTop) {
    UINavigationBar *bar = nfb_colsSegmentedOfPager(gNFBColsPager).navigationController.navigationBar;
    if (!bar.window || bar.hidden || !sv.window) return stockTop;
    CGFloat navBottom = CGRectGetMaxY([bar convertRect:bar.bounds toView:nil]);
    CGFloat tableTop = [sv.superview convertPoint:sv.frame.origin toView:nil].y;
    return MIN(stockTop, MAX(0.0, navBottom - tableTop));   // only ever removes space
}

static void nfb_colsFitTable(UIScrollView *sv, BOOL columns) {
    if (!sv) return;
    UIEdgeInsets inset = nfb_colsStoredInset(sv);
    BOOL atTop = sv.contentOffset.y <= -sv.adjustedContentInset.top + 1.0;
    if (columns) {
        if (!objc_getAssociatedObject(sv, &kNFBColsFittedTableKey)) {
            objc_setAssociatedObject(sv, &kNFBColsFittedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(sv, &kNFBColsTableStockTopKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!gNFBColsFittedTables) gNFBColsFittedTables = [NSHashTable weakObjectsHashTable];
            [gNFBColsFittedTables addObject:sv];
        }
        NSNumber *stock = objc_getAssociatedObject(sv, &kNFBColsTableStockTopKey);
        inset.top = nfb_colsFittedTop(sv, stock.doubleValue);
    } else {
        NSNumber *stock = objc_getAssociatedObject(sv, &kNFBColsTableStockTopKey);
        objc_setAssociatedObject(sv, &kNFBColsFittedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sv, &kNFBColsTableStockTopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!stock) return;
        inset.top = stock.doubleValue;
    }
    if (fabs(inset.top - nfb_colsStoredInset(sv).top) < 0.5) return;
    gNFBColsSettingInset = YES;
    sv.contentInset = inset;
    gNFBColsSettingInset = NO;
    if (atTop && !sv.isDragging && !sv.isDecelerating) {
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, -sv.adjustedContentInset.top) animated:NO];
    }
}

static void nfb_colsFitColumnTables(BOOL columns) {
    if (columns) {
        for (NSDictionary *entry in NFBColumnsAllEntries()) nfb_colsFitTable(nfb_colsContentScrollViewOf(entry[@"vc"]), YES);
    } else {
        for (UIScrollView *sv in gNFBColsFittedTables.allObjects) nfb_colsFitTable(sv, NO);
        [gNFBColsFittedTables removeAllObjects];
    }
}

// 1 = For You, 0 = not, -1 = not a visible column page.
NSInteger NFBColumnsPageRecommended(UIViewController *vc) {
    if (!vc) return -1;
    for (NSDictionary *entry in NFBColumnsVisibleEntries()) {
        UIViewController *page = entry[@"vc"];
        for (UIViewController *c = vc; c; c = c.parentViewController) {
            if (c == page) return [entry[@"recommended"] boolValue] ? 1 : 0;
        }
    }
    return -1;
}

NSString *NFBColumnsDiagnostic(void) {
    UICollectionView *cv = gNFBColsCollectionView;
    UIViewController *pager = gNFBColsPager;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"columns tab=%d host=%@ selected=%d active=%d fullWidth=%d pager=%@ cv=%@\n", nfb_colsEnabled() ? 1 : 0,
        NFBColumnsHostPageID(), gNFBColsActive ? 1 : 0, NFBColumnsActive() ? 1 : 0, [BHTSettings boolForKey:kNFBColsFullWidthKey] ? 1 : 0,
        pager ? NSStringFromClass(pager.class) : @"nil", cv ? NSStringFromClass(cv.class) : @"nil"];
    if (cv) {
        NFBColumnsModel *model = objc_getAssociatedObject(cv.collectionViewLayout, &kNFBColsModelKey);
        [s appendFormat:@"columns layout=%@ paging=%d bounds=(%.0f,%.0f) content=(%.0f,%.0f) off=%.0f desired=%@ items=%ld slots=%@\n",
            NSStringFromClass(cv.collectionViewLayout.class), cv.pagingEnabled ? 1 : 0, cv.bounds.size.width, cv.bounds.size.height,
            cv.contentSize.width, cv.contentSize.height, cv.contentOffset.x,
            objc_getAssociatedObject(cv, &kNFBColsDesiredOffsetKey) ?: @"-", (long)model.itemCount,
            [model.slots componentsJoinedByString:@","] ?: @"-"];
        [s appendFormat:@"columns titles=%@\n", [model.titles componentsJoinedByString:@" | "] ?: @"-"];
        [s appendFormat:@"columns swipe scroll=%d xScrollOff=%lu pending rejectV=%lu rejectEdge=%lu xVeto=%lu\n", cv.scrollEnabled ? 1 : 0,
            (unsigned long)gNFBColsScrollOffBlocked, (unsigned long)gNFBColsScroll.rejectVertical,
            (unsigned long)gNFBColsScroll.rejectEdge, (unsigned long)gNFBColsScroll.stockVetoes];
        [s appendString:nfb_colsTabDiag(model)];
        for (NSDictionary *entry in NFBColumnsVisibleEntries()) {
            UIViewController *page = entry[@"vc"];
            [s appendFormat:@"columns visible slot=%@ item=%@ title=%@ rec=%@ page=%@ loaded=%d\n", entry[@"slot"], entry[@"item"],
                entry[@"title"], entry[@"recommended"], NSStringFromClass(page.class), [page isViewLoaded] ? 1 : 0];
        }
        for (UICollectionViewCell *cell in cv.visibleCells) {
            NSIndexPath *ip = [cv indexPathForCell:cell];
            UIViewController *page = nfb_colsPageForCell(cell, pager);
            UIView *firstContent = cell.contentView.subviews.firstObject;
            [s appendFormat:@"probe cell item=%ld f=(%.0f,%.0f,%.0f,%.0f) hidden=%d contentSubviews=%lu cellSubviews=%lu first=%@ page=%@\n",
                (long)ip.item, cell.frame.origin.x, cell.frame.origin.y, cell.frame.size.width, cell.frame.size.height, cell.hidden ? 1 : 0,
                (unsigned long)cell.contentView.subviews.count, (unsigned long)cell.subviews.count,
                firstContent ? NSStringFromClass(firstContent.class) : @"-", page ? NSStringFromClass(page.class) : @"nil"];
        }
    }
    if (pager) {
        const uint8_t *spacing = nfb_colsIvarPtr(pager, "pageSpacing");
        const uint8_t *hPagingIvar = nfb_colsIvarPtr(pager, "horizontalPagingEnabled");
        [s appendFormat:@"probe pager currentIndex=%@ pageCount=%@ destinationIndex=%@ pageSpacing=%.1f hPaging=%d children=%lu\n",
            nfb_colsIntIvarText(pager, "currentIndex", NO), nfb_colsIntIvarText(pager, "pageCount", NO),
            nfb_colsIntIvarText(pager, "destinationIndex", YES), spacing ? *(const double *)spacing : -1.0,
            hPagingIvar ? (int)hPagingIvar[0] : -1, (unsigned long)pager.childViewControllers.count];
        for (UIViewController *child in pager.childViewControllers) {
            UIView *sup = [child isViewLoaded] ? child.view.superview : nil;
            UIView *cellAncestor = sup;
            while (cellAncestor && ![cellAncestor isKindOfClass:UICollectionViewCell.class]) cellAncestor = cellAncestor.superview;
            NSIndexPath *ip = [cellAncestor isKindOfClass:UICollectionViewCell.class] ? [cv indexPathForCell:(UICollectionViewCell *)cellAncestor] : nil;
            [s appendFormat:@"probe pagerChild %@ superview=%@ inCellItem=%@ window=%d\n", NSStringFromClass(child.class),
                sup ? NSStringFromClass(sup.class) : @"nil", ip ? @(ip.item) : @"-", ([child isViewLoaded] && child.view.window) ? 1 : 0];
        }
        UIViewController *segmented = nfb_colsSegmentedOfPager(pager);
        if (segmented) {
            NSInteger tabs = [segmented respondsToSelector:@selector(numberOfTabs)] ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(numberOfTabs)) : -1;
            NSInteger selected = [segmented respondsToSelector:@selector(selectedIndex)] ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(selectedIndex)) : -1;
            NSInteger hideMode = [segmented respondsToSelector:@selector(tabBarHideMode)] ? ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(tabBarHideMode)) : -1;
            BOOL hPaging = [segmented respondsToSelector:@selector(isHorizontalPagingEnabled)] ? ((BOOL(*)(id, SEL))objc_msgSend)(segmented, @selector(isHorizontalPagingEnabled)) : NO;
            id tabBar = [segmented respondsToSelector:@selector(tabBarView)] ? ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(tabBarView)) : nil;
            CGRect tf = [tabBar isKindOfClass:UIView.class] ? [(UIView *)tabBar convertRect:((UIView *)tabBar).bounds toView:nil] : CGRectZero;
            [s appendFormat:@"probe segmented tabs=%ld selected=%ld tabBarHideMode=%ld hPaging=%d tabBar=%@ window=(%.0f,%.0f,%.0f,%.0f) hidden=%d\n",
                (long)tabs, (long)selected, (long)hideMode, hPaging ? 1 : 0, tabBar ? NSStringFromClass([tabBar class]) : @"nil",
                tf.origin.x, tf.origin.y, tf.size.width, tf.size.height, [tabBar isKindOfClass:UIView.class] ? (((UIView *)tabBar).hidden ? 1 : 0) : -1];
            // Top strip: container view, its height constraint, the bar inset the segmented adds to pages.
            UIView *bar = nfb_colsObjectIvar(segmented, "barContainerView");
            NSLayoutConstraint *height = nfb_colsObjectIvar(segmented, "barContainerHeightConstraint");
            const uint8_t *adj = nfb_colsIvarPtr(segmented, "cachedBarInsetAdjustment");
            CGRect bf = [bar isKindOfClass:UIView.class] ? [bar convertRect:bar.bounds toView:nil] : CGRectZero;
            double barH = [segmented respondsToSelector:@selector(barHeight)] ? ((double(*)(id, SEL))objc_msgSend)(segmented, @selector(barHeight)) : -1.0;
            double maxBarH = [segmented respondsToSelector:@selector(maximumBarHeight)] ? ((double(*)(id, SEL))objc_msgSend)(segmented, @selector(maximumBarHeight)) : -1.0;
            id pagingScroll = [tabBar respondsToSelector:@selector(pagingScrollView)] ? ((id(*)(id, SEL))objc_msgSend)(tabBar, @selector(pagingScrollView)) : nil;
            [s appendFormat:@"probe bar container=%@ super=%@ window=(%.0f,%.0f,%.0f,%.0f) hidden=%d heightConst=%@ barHeight=%.1f maxBarHeight=%.1f insetAdj=%.1f tabBarScroll=%@\n",
                [bar isKindOfClass:UIView.class] ? NSStringFromClass(bar.class) : @"nil",
                [bar isKindOfClass:UIView.class] && bar.superview ? NSStringFromClass(bar.superview.class) : @"nil",
                bf.origin.x, bf.origin.y, bf.size.width, bf.size.height, [bar isKindOfClass:UIView.class] ? (bar.hidden ? 1 : 0) : -1,
                [height isKindOfClass:NSLayoutConstraint.class] ? [NSString stringWithFormat:@"%.1f", height.constant] : @"nil",
                barH, maxBarH, adj ? *(const double *)adj : -1.0, pagingScroll ? NSStringFromClass([pagingScroll class]) : @"nil"];
            UINavigationController *nav = segmented.navigationController;
            if (nav) {
                UINavigationBar *navBar = nav.navigationBar;
                CGRect nf = [navBar convertRect:navBar.bounds toView:nil];
                [s appendFormat:@"probe nav %@ bar=%@ window=(%.0f,%.0f,%.0f,%.0f) hidden=%d navHidden=%d\n", NSStringFromClass(nav.class),
                    NSStringFromClass(navBar.class), nf.origin.x, nf.origin.y, nf.size.width, nf.size.height, navBar.hidden ? 1 : 0,
                    nav.navigationBarHidden ? 1 : 0];
                // Everything drawn in the top band of the navigation controller's view (depth <= 3).
                NSMutableArray<NSArray *> *queue = [NSMutableArray arrayWithObject:@[nav.view, @0]];
                NSUInteger lines = 0;
                while (queue.count && lines < 24) {
                    UIView *v = queue.firstObject[0];
                    NSInteger depth = [queue.firstObject[1] integerValue];
                    [queue removeObjectAtIndex:0];
                    CGRect wf = [v convertRect:v.bounds toView:nil];
                    if (v != nav.view && CGRectGetMinY(wf) < 260.0 && wf.size.height > 0.5 && wf.size.height <= 260.0 && !v.hidden && v.alpha > 0.01) {
                        [s appendFormat:@"probe top d=%ld %@ window=(%.0f,%.0f,%.0f,%.0f) alpha=%.2f\n", (long)depth, NSStringFromClass(v.class),
                            wf.origin.x, wf.origin.y, wf.size.width, wf.size.height, v.alpha];
                        lines++;
                    }
                    if (depth < 3 && !v.hidden && ![v isKindOfClass:UIScrollView.class]) {
                        for (UIView *sub in v.subviews) [queue addObject:@[sub, @(depth + 1)]];
                    }
                }
            }
        }
        for (NSDictionary *entry in NFBColumnsVisibleEntries()) {
            UIScrollView *sv = nfb_colsContentScrollViewOf(entry[@"vc"]);
            if (!sv) continue;
            CGRect wf = [sv convertRect:sv.bounds toView:nil];
            [s appendFormat:@"probe pageScroll item=%@ %@ window=(%.0f,%.0f,%.0f,%.0f) inset=%.0f adjusted=%.0f offY=%.0f\n", entry[@"item"],
                NSStringFromClass(sv.class), wf.origin.x, wf.origin.y, wf.size.width, wf.size.height, sv.contentInset.top,
                sv.adjustedContentInset.top, sv.contentOffset.y];
        }
    }
    for (id header in gNFBColsFleetHeaders) {
        BOOL (^b)(NSString *) = ^BOOL(NSString *name) {
            SEL sel = NSSelectorFromString(name);
            return [header respondsToSelector:sel] ? ((BOOL(*)(id, SEL))objc_msgSend)(header, sel) : NO;
        };
        double inset = [header respondsToSelector:@selector(fleetLineInset)] ? ((double(*)(id, SEL))objc_msgSend)(header, @selector(fleetLineInset)) : -1.0;
        id parent = [header respondsToSelector:@selector(parentViewController)] ? ((id(*)(id, SEL))objc_msgSend)(header, @selector(parentViewController)) : nil;
        [s appendFormat:@"probe spacesBar hidden=%d shouldBeHidden=%d inset=%.0f parent=%@\n", b(@"isHidden") ? 1 : 0,
            b(@"shouldBeHidden") ? 1 : 0, inset, parent ? NSStringFromClass([parent class]) : @"nil"];
    }
    return s;
}

#pragma mark - top chrome (segment strip, Spaces bar)

// The Home segment strip (For You / Following / lists) sits in the segmented controller's
// barContainerView, and the segmented adds its height to every page's top inset. In columns mode
// the strip is useless (all pages are on screen) and its tab bar tracks the pager's scroll offset,
// so: height 0 (barHeight / maximumBarHeight hooks + the container constraint), hidden, and
// detached from the pager scroll view. Everything is saved once and restored on leave.
static char kNFBColsSavedHiddenKey;        // NSNumber(hidden) on bar / tab bar / shadow view
static char kNFBColsSavedConstantKey;      // NSNumber(constant) on the bar height constraint
static char kNFBColsSavedPagingScrollKey;  // the tab bar's original pagingScrollView
static char kNFBColsChromeAppliedKey;      // NSNumber(YES) on the segmented while applied

static BOOL nfb_colsSegmentedIsHome(UIViewController *segmented) {
    return segmented && nfb_colsParentNamed(segmented, @"HomeTimelineContainer") != nil;
}

static void nfb_colsHideView(UIView *view, BOOL hide) {
    if (![view isKindOfClass:UIView.class]) return;
    NSNumber *saved = objc_getAssociatedObject(view, &kNFBColsSavedHiddenKey);
    if (hide) {
        if (!saved) objc_setAssociatedObject(view, &kNFBColsSavedHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = YES;
    } else if (saved) {
        view.hidden = saved.boolValue;
        objc_setAssociatedObject(view, &kNFBColsSavedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL nfb_colsFleetHeaderIsHome(id header) {
    id parent = [header respondsToSelector:@selector(parentViewController)] ?
        ((id(*)(id, SEL))objc_msgSend)(header, @selector(parentViewController)) : nil;
    return [parent isKindOfClass:UIViewController.class] && nfb_colsParentNamed(parent, @"HomeTimelineContainer") != nil;
}

static UIView *nfb_colsFleetContainer(id header) {
    id view = [header respondsToSelector:@selector(fleetLineContainerView)] ?
        ((id(*)(id, SEL))objc_msgSend)(header, @selector(fleetLineContainerView)) : nil;
    return [view isKindOfClass:UIView.class] ? view : nil;
}

// Spaces bar (fleet line, a row in the same stack view as the segment strip). X re-shows it when
// live Spaces arrive, so while columns are shown its container stays hidden (see the hooks below).
static void nfb_colsUpdateFleetLines(BOOL columns) {
    for (id header in gNFBColsFleetHeaders.allObjects) {
        if (!nfb_colsFleetHeaderIsHome(header)) continue;
        @try {
            if (columns) {
                nfb_colsHideView(nfb_colsFleetContainer(header), YES);
            } else {
                nfb_colsHideView(nfb_colsFleetContainer(header), NO);
                if ([header respondsToSelector:@selector(_t1_updateFleetLineVisibility)]) {
                    ((void(*)(id, SEL))objc_msgSend)(header, @selector(_t1_updateFleetLineVisibility));
                }
            }
        } @catch (NSException *e) {
            NFBLogEvent([NSString stringWithFormat:@"columns spacesBar update threw %@", e.name]);
        }
    }
}

static void nfb_colsSetTopChrome(UIViewController *pager, BOOL columns) {
    UIViewController *segmented = nfb_colsSegmentedOfPager(pager);
    if (!nfb_colsSegmentedIsHome(segmented) || ![segmented isViewLoaded]) return;
    BOOL applied = objc_getAssociatedObject(segmented, &kNFBColsChromeAppliedKey) != nil;
    if (!columns && !applied) return;   // never touch the stock Home that we did not change
    UIView *bar = nfb_colsObjectIvar(segmented, "barContainerView");
    UIView *shadow = nfb_colsObjectIvar(segmented, "shadowView");
    if (columns && applied) {
        nfb_colsHideView(bar, YES);
        nfb_colsHideView(shadow, YES);
        nfb_colsUpdateFleetLines(YES);
        return;
    }
    NSLayoutConstraint *height = nfb_colsObjectIvar(segmented, "barContainerHeightConstraint");
    if (![height isKindOfClass:NSLayoutConstraint.class]) height = nil;
    id tabBar = [segmented respondsToSelector:@selector(tabBarView)] ? ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(tabBarView)) : nil;
    BOOL canDetach = [tabBar respondsToSelector:@selector(setPagingScrollView:)] && [tabBar respondsToSelector:@selector(pagingScrollView)];
    if (columns) {
        nfb_colsHideView(bar, YES);
        nfb_colsHideView(shadow, YES);
        nfb_colsHideView(tabBar, YES);
        if (height && !objc_getAssociatedObject(height, &kNFBColsSavedConstantKey)) {
            objc_setAssociatedObject(height, &kNFBColsSavedConstantKey, @(height.constant), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        height.constant = 0.0;
        if (canDetach) {
            id current = ((id(*)(id, SEL))objc_msgSend)(tabBar, @selector(pagingScrollView));
            if (current && !objc_getAssociatedObject(tabBar, &kNFBColsSavedPagingScrollKey)) {
                objc_setAssociatedObject(tabBar, &kNFBColsSavedPagingScrollKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            ((void(*)(id, SEL, id))objc_msgSend)(tabBar, @selector(setPagingScrollView:), nil);
        }
        objc_setAssociatedObject(segmented, &kNFBColsChromeAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        nfb_colsHideView(bar, NO);
        nfb_colsHideView(shadow, NO);
        nfb_colsHideView(tabBar, NO);
        NSNumber *constant = height ? objc_getAssociatedObject(height, &kNFBColsSavedConstantKey) : nil;
        if (constant) {
            height.constant = constant.doubleValue;
            objc_setAssociatedObject(height, &kNFBColsSavedConstantKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        id savedScroll = canDetach ? objc_getAssociatedObject(tabBar, &kNFBColsSavedPagingScrollKey) : nil;
        if (savedScroll) {
            ((void(*)(id, SEL, id))objc_msgSend)(tabBar, @selector(setPagingScrollView:), savedScroll);
            objc_setAssociatedObject(tabBar, &kNFBColsSavedPagingScrollKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(segmented, &kNFBColsChromeAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Let the segmented re-measure its bar and re-apply the page insets.
    [segmented viewSafeAreaInsetsDidChange];
    [segmented.view setNeedsLayout];
    [segmented.view layoutIfNeeded];
    nfb_colsUpdateFleetLines(columns);
    NFBLogEvent([NSString stringWithFormat:@"columns topChrome on=%d bar=%@ const=%@ detach=%d", columns ? 1 : 0,
        bar ? NSStringFromClass(bar.class) : @"nil", height ? [NSString stringWithFormat:@"%.0f", height.constant] : @"nil",
        canDetach ? 1 : 0]);
}

#pragma mark - apply / restore

static UIViewController *nfb_colsFindChildNamed(UIViewController *root, NSString *needle, int depth) {
    if (!root || depth > 6) return nil;
    if ([NSStringFromClass(root.class) containsString:needle]) return root;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = nfb_colsFindChildNamed(child, needle, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIViewController *nfb_colsFindHomeContainer(void) {
    NSMutableArray *queue = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.rootViewController) [queue addObject:window.rootViewController];
    }
    NSUInteger hops = 0;
    while (queue.count && hops++ < 600) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(vc.class) containsString:@"HomeTimelineContainer"]) return vc;
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    return nil;
}

static UICollectionView *nfb_colsCollectionViewOfPager(UIViewController *pager) {
    if (![pager isViewLoaded]) return nil;
    if ([pager.view isKindOfClass:UICollectionView.class]) return (UICollectionView *)pager.view;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:pager.view];
    NSUInteger hops = 0;
    while (queue.count && hops++ < 64) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:UICollectionView.class] && [NSStringFromClass(v.class) containsString:@"Paging"]) return (UICollectionView *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// iPad full width: force the split's "display extended content" input to NO while columns are on,
// so Twitter chooses its own sidebar+content tier (the trends pane goes away natively).
static BOOL nfb_colsWantNativeSplitTier(UIViewController *split) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return NO;
    return nfb_colsActiveNow() && [BHTSettings boolForKey:kNFBColsFullWidthKey] &&
           [NSStringFromClass(split.class) containsString:@"AppSplitViewController"];
}

static void nfb_colsRefreshSplit(UIViewController *container) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    UIViewController *split = nfb_colsParentNamed(container, @"AppSplitViewController");
    if (!split) return;
    BOOL displayExtended = !nfb_colsWantNativeSplitTier(split);
    @try {
        if ([split respondsToSelector:@selector(setDisplayExtendedContent:animated:)]) {
            ((void(*)(id, SEL, BOOL, BOOL))objc_msgSend)(split, @selector(setDisplayExtendedContent:animated:), displayExtended, NO);
        }
        if ([split respondsToSelector:@selector(private_updateSplitModeAnimated:)]) {
            ((void(*)(id, SEL, BOOL))objc_msgSend)(split, @selector(private_updateSplitModeAnimated:), NO);
        }
        [split.viewIfLoaded setNeedsLayout];
    } @catch (NSException *e) {
        NFBLogEvent([NSString stringWithFormat:@"columns split refresh threw %@", e.name]);
    }
}

// The pager sets its scrolling to `horizontalPagingEnabled && no page transition` after every
// programmatic page change (X 12.38.1), which turns the columns' swipe off where swipe paging is
// off. While columns are shown it stays on (setScrollEnabled: hook); X's last value is kept in
// kNFBColsSavedScrollKey for leaving columns.
static void nfb_colsForceScrollable(UICollectionView *cv) {
    if (cv.scrollEnabled) return;
    gNFBColsSettingScroll = YES;
    cv.scrollEnabled = YES;
    gNFBColsSettingScroll = NO;
}

static void nfb_colsApplyToPager(UIViewController *pager) {
    UICollectionView *cv = nfb_colsCollectionViewOfPager(pager);
    if (!cv) return;
    gNFBColsPager = pager;
    gNFBColsCollectionView = cv;
    BOOL on = nfb_colsActiveNow();
    if (on) {
        if (!objc_getAssociatedObject(cv, &kNFBColsSavedPagingKey)) {
            objc_setAssociatedObject(cv, &kNFBColsSavedPagingKey, @(cv.pagingEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!objc_getAssociatedObject(cv, &kNFBColsSavedScrollKey)) {
            objc_setAssociatedObject(cv, &kNFBColsSavedScrollKey, @(cv.scrollEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (cv.pagingEnabled) cv.pagingEnabled = NO;
        nfb_colsForceScrollable(cv);
        // Normal deceleration: a strong flick crosses several columns (snapped at the landing point).
        cv.decelerationRate = UIScrollViewDecelerationRateNormal;
        objc_setAssociatedObject(cv, &kNFBColsDesiredOffsetKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        NSNumber *saved = objc_getAssociatedObject(cv, &kNFBColsSavedPagingKey);
        if (saved) cv.pagingEnabled = saved.boolValue;
        NSNumber *savedScroll = objc_getAssociatedObject(cv, &kNFBColsSavedScrollKey);
        if (savedScroll) cv.scrollEnabled = savedScroll.boolValue;
        objc_setAssociatedObject(cv, &kNFBColsSavedScrollKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cv.decelerationRate = UIScrollViewDecelerationRateNormal;
        objc_setAssociatedObject(cv, &kNFBColsSavedPagingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cv, &kNFBColsDesiredOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [cv.collectionViewLayout invalidateLayout];
    [cv layoutIfNeeded];
    if (on) {
        [cv setContentOffset:CGPointMake(0.0, cv.contentOffset.y) animated:NO];
    } else {
        // Re-align on the selected page with the stock full-width geometry.
        UIViewController *segmented = nfb_colsSegmentedOfPager(pager);
        NSInteger selected = [segmented respondsToSelector:@selector(selectedIndex)] ?
            ((NSInteger(*)(id, SEL))objc_msgSend)(segmented, @selector(selectedIndex)) : 0;
        if ([segmented respondsToSelector:@selector(setSelectedIndexWithoutAnimation:)]) {
            ((void(*)(id, SEL, NSInteger))objc_msgSend)(segmented, @selector(setSelectedIndexWithoutAnimation:), selected);
        }
        CGFloat pageWidth = cv.bounds.size.width;
        if (pageWidth > 1.0) [cv setContentOffset:CGPointMake(pageWidth * MAX(selected, 0), cv.contentOffset.y) animated:NO];
    }
    nfb_colsRefreshSplit(nfb_colsParentNamed(pager, @"HomeTimelineContainer"));
    nfb_colsSetTopChrome(pager, on);
    NFBLogEvent([NSString stringWithFormat:@"columns apply on=%d cv=%@ items=%ld", on ? 1 : 0, NSStringFromClass(cv.class),
        (long)(cv.numberOfSections > 0 ? [cv numberOfItemsInSection:0] : -1)]);
}

static void nfb_colsApplyToHome(void) {
    UIViewController *pager = gNFBColsPager;
    if (!pager) {
        UIViewController *container = nfb_colsFindHomeContainer();
        UIViewController *segmented = nfb_colsFindChildNamed(container, @"LegacySegmentedViewController", 0);
        id candidate = [segmented respondsToSelector:@selector(pagingViewController)] ?
            ((id(*)(id, SEL))objc_msgSend)(segmented, @selector(pagingViewController)) : nil;
        pager = [candidate isKindOfClass:UIViewController.class] ? candidate : nil;
    }
    if (pager) nfb_colsApplyToPager(pager);
}

#pragma mark - Columns tab (host tab takeover)

void NFBNoteTabSelectionChanged(void);

static UIViewController *nfb_colsFindControllerOfClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    NSMutableArray *queue = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.rootViewController) [queue addObject:window.rootViewController];
    }
    NSUInteger hops = 0;
    while (queue.count && hops++ < 800) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:cls]) return vc;
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    return nil;
}

static NSArray *nfb_colsTabViews(UIViewController *tabBarController) {
    id views = [tabBarController respondsToSelector:@selector(tabViews)] ?
        ((id(*)(id, SEL))objc_msgSend)(tabBarController, @selector(tabViews)) : nil;
    return [views isKindOfClass:NSArray.class] ? views : @[];
}

static NSInteger nfb_colsIndexOfPage(NSArray *tabViews, NSString *page) {
    for (NSUInteger i = 0; i < tabViews.count; i++) {
        T1TabView *tabView = tabViews[i];
        if ([tabView isKindOfClass:NSClassFromString(@"T1TabView")] && [tabView.scribePage isEqualToString:page]) return (NSInteger)i;
    }
    return NSNotFound;
}

static NSString *nfb_colsTabTitle(void) {
    return nfb_colsLoc(@"NFB_COLUMNS_TAB_TITLE", @"Columns");
}

// Re-apply label + selection highlight on every tab view (our hooks do the actual forcing).
// Re-applies each tab's highlight: while columns are shown the setSelected: hook marks the host;
// otherwise the tab the navigation controller really has selected (leaving columns used to keep
// Home un-highlighted, which also hid the stream button on Home).
static void nfb_colsRefreshTabViews(UIViewController *nav, UIViewController *tabBarController) {
    NSInteger selected = [nav respondsToSelector:@selector(selectedIndex)] ?
        ((NSInteger(*)(id, SEL))objc_msgSend)(nav, @selector(selectedIndex)) : NSNotFound;
    [nfb_colsTabViews(tabBarController) enumerateObjectsUsingBlock:^(T1TabView *tabView, NSUInteger idx, BOOL *stop) {
        if (![tabView isKindOfClass:NSClassFromString(@"T1TabView")]) return;
        if ([tabView respondsToSelector:@selector(_t1_updateTitleLabel)]) {
            ((void(*)(id, SEL))objc_msgSend)(tabView, @selector(_t1_updateTitleLabel));
        }
        BOOL isSelected = selected != NSNotFound ? (NSInteger)idx == selected : tabView.isSelected;
        ((void(*)(id, SEL, BOOL))objc_msgSend)(tabView, @selector(setSelected:), isSelected);
    }];
}

// The host tab has to be in the tab bar: add it to the custom tab selection if it is missing.
static void nfb_colsEnsureHostVisible(UIViewController *nav) {
    if (!nfb_colsEnabled() || !nav) return;
    NSString *host = NFBColumnsHostPageID();
    NSArray<NSString *> *visible = [CustomTabBarUtility visiblePageIDsInOrder];
    if ([visible containsObject:host]) return;
    NSMutableArray<NSString *> *list = [(visible ?: [CustomTabBarUtility defaultVisiblePageIDs]) mutableCopy];
    NSUInteger homeIndex = [list indexOfObject:@"home"];
    [list insertObject:host atIndex:(homeIndex == NSNotFound ? 0 : homeIndex + 1)];
    [CustomTabBarUtility setVisiblePageIDs:list];
    if ([nav respondsToSelector:@selector(recalculateVisiblePanels)]) [(T1TabbedAppNavigationViewController *)nav recalculateVisiblePanels];
    NFBLogEvent([NSString stringWithFormat:@"columns host %@ added to the tab bar", host]);
}

#pragma mark - app-tab columns (X's own tabs next to the timelines)

// Notifications, Search, Bookmarks, Lists, … as columns (the 11.35 fork's app-tab columns). Each
// column is a second instance of the tab, built the way X 12.38.1 opens one
// (-[T1TabbedAppNavigationViewController tabbedViewController:viewControllerAtIndex:]: the entry's
// contentControllerFactory -> createContentController = a new tab navigation controller,
// rootTabViewController = a new root page), never the live tab. It is hosted view-only in the Home
// collection view at its column's x (11.35 b39: adopting tab controllers as children crashed while
// they loaded) and gets its appearance calls by hand, without which it never loads. Every app tab
// is off until turned on in Manage columns; its order / on-off live with the timelines' ("tab:<page>").

static NSArray *gNFBColsTabEntries = nil;   // every tab entry X built (Theme.x's setVisibleTabEntries: hook)
static NSArray<NSDictionary *> *gNFBColsTabCandidatesCache = nil;
static NSArray *gNFBColsTabCandidatesFor = nil;
static NSMutableDictionary<NSString *, UINavigationController *> *gNFBColsTabNavs = nil;   // id -> our instance
static NSMutableSet<NSString *> *gNFBColsTabShown = nil;     // ids whose view is in the columns now
static NSMutableSet<NSString *> *gNFBColsTabSkipped = nil;   // could not be built this session
static NSString *gNFBColsTabFailedAtLaunch = nil;
static NSUInteger gNFBColsTabInvalidatedGen = 0;
static BOOL gNFBColsTabLayoutPending = NO;
static __weak UIViewController *gNFBColsTabBarController = nil;
static char kNFBColsTabEntryKey;             // the entry an instance was built from
static char kNFBColsTabPagerLockedKey;       // NSNumber(original scrollEnabled) on a locked inner pager
static char kNFBColsTabLockCheckKey;         // NSNumber(time) of the last inner-pager walk

void NFBColumnsNoteTabEntries(NSArray *entries) {
    if (![entries isKindOfClass:NSArray.class]) return;
    BOOL same = gNFBColsTabEntries.count == entries.count;
    for (NSUInteger i = 0; same && i < entries.count; i++) same = gNFBColsTabEntries[i] == entries[i];
    if (same) return;
    gNFBColsTabEntries = [entries copy];
    gNFBColsGen++;
    nfb_colsScheduleTabLayout();
}

static id nfb_colsTabFactory(id entry) {
    id factory = [entry respondsToSelector:@selector(contentControllerFactory)] ?
        ((id(*)(id, SEL))objc_msgSend)(entry, @selector(contentControllerFactory)) : nil;
    for (id candidate in @[ factory ?: entry, entry ]) {
        if ([candidate respondsToSelector:@selector(createContentController)] &&
            [candidate respondsToSelector:@selector(rootTabViewController)]) return candidate;
    }
    return nil;
}

// Every tab X can build except Home (its timelines are the columns already) and the More drawer.
static NSArray<NSDictionary *> *nfb_colsTabCandidates(void) {
    NSArray *entries = gNFBColsTabEntries;
    if (!entries) {
        UIViewController *tabbed = nfb_colsFindControllerOfClass(@"T1TabbedAppNavigationViewController");
        id visible = [tabbed respondsToSelector:@selector(visibleTabEntries)] ?
            ((id(*)(id, SEL))objc_msgSend)(tabbed, @selector(visibleTabEntries)) : nil;
        entries = [visible isKindOfClass:NSArray.class] ? visible : @[];
    }
    if (gNFBColsTabCandidatesCache && gNFBColsTabCandidatesFor == entries) return gNFBColsTabCandidatesCache;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *pages = [NSMutableSet set];
    for (id entry in entries) {
        T1TabView *tabView = [entry respondsToSelector:@selector(tabView)] ? ((id(*)(id, SEL))objc_msgSend)(entry, @selector(tabView)) : nil;
        NSString *page = [tabView respondsToSelector:@selector(scribePage)] ? tabView.scribePage : nil;
        if (!page.length || [page isEqualToString:CustomTabBarHomePageID] || [pages containsObject:page]) continue;
        if ([NSStringFromClass([entry class]) containsString:@"HomeTimeline"] || !nfb_colsTabFactory(entry)) continue;
        long long panelID = [entry respondsToSelector:@selector(panelID)] ?
            ((long long(*)(id, SEL))objc_msgSend)(entry, @selector(panelID)) : -1;
        if (panelID >= 0 && !panelIsGenuinelyAvailable(panelID)) continue;
        gNFBColsRawTabTitle = YES;
        NSString *title = [tabView respondsToSelector:@selector(title)] ? tabView.title : nil;
        gNFBColsRawTabTitle = NO;
        [pages addObject:page];
        [out addObject:@{ @"id": [@"tab:" stringByAppendingString:page], @"page": page,
                          @"title": title.length ? title : page, @"entry": entry }];
    }
    gNFBColsTabCandidatesCache = [out copy];
    gNFBColsTabCandidatesFor = entries;
    return gNFBColsTabCandidatesCache;
}

static NSSet<NSString *> *nfb_colsTabFailed(void) {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kNFBColsTabFailedKey];
    return list.count ? [NSSet setWithArray:list] : [NSSet set];
}

static BOOL nfb_colsTabSkippedNow(NSString *identity) {
    return [gNFBColsTabSkipped containsObject:identity];
}

static void nfb_colsTabClearFailed(NSString *identity) {
    [gNFBColsTabSkipped removeObject:identity];
    NSMutableArray *list = [[NSUserDefaults.standardUserDefaults arrayForKey:kNFBColsTabFailedKey] ?: @[] mutableCopy];
    if (![list containsObject:identity]) return;
    [list removeObject:identity];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kNFBColsTabFailedKey];
}

// Columns being opened: if the app dies before one has been on screen for a few seconds, it is
// stopped at the next launch (nfb_colsLaunchGuard). Written through at once, the app may die next.
static void nfb_colsTabMarkInFlight(NSString *identity, BOOL inFlight) {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    NSMutableArray *list = [[defs arrayForKey:kNFBColsTabInFlightKey] ?: @[] mutableCopy];
    if (inFlight == [list containsObject:identity]) return;
    if (inFlight) [list addObject:identity];
    else [list removeObject:identity];
    if (list.count) [defs setObject:list forKey:kNFBColsTabInFlightKey];
    else [defs removeObjectForKey:kNFBColsTabInFlightKey];
    [defs synchronize];
}

// iPad: a column is phone-width, so lay the tab out like on a phone (Compact width, iOS 17+).
static void nfb_colsTabCompactWidth(UIViewController *nav) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    SEL getter = NSSelectorFromString(@"traitOverrides");
    id overrides = [nav respondsToSelector:getter] ? ((id(*)(id, SEL))objc_msgSend)(nav, getter) : nil;
    SEL setter = NSSelectorFromString(@"setHorizontalSizeClass:");
    if ([overrides respondsToSelector:setter]) {
        ((void(*)(id, SEL, NSInteger))objc_msgSend)(overrides, setter, UIUserInterfaceSizeClassCompact);
    }
}

static void nfb_colsTabHide(NSString *identity, UINavigationController *nav);

static UINavigationController *nfb_colsTabNav(NSDictionary *column) {
    NSString *identity = column[@"id"];
    id entry = column[@"entry"];
    UINavigationController *nav = gNFBColsTabNavs[identity];
    if (nav && objc_getAssociatedObject(nav, &kNFBColsTabEntryKey) == entry) return nav;
    if (nav) {   // X rebuilt its tabs (e.g. account switch): start over from the new entry
        nfb_colsTabHide(identity, nav);
        [gNFBColsTabNavs removeObjectForKey:identity];
    }
    if ([gNFBColsTabSkipped containsObject:identity]) return nil;
    id factory = nfb_colsTabFactory(entry);
    if (!factory) return nil;
    nfb_colsTabMarkInFlight(identity, YES);
    CFTimeInterval t0 = CACurrentMediaTime();
    id created = nil;
    id root = nil;
    NSString *problem = nil;
    @try {
        created = ((id(*)(id, SEL))objc_msgSend)(factory, @selector(createContentController));
        root = ((id(*)(id, SEL))objc_msgSend)(factory, @selector(rootTabViewController));
    } @catch (NSException *e) {
        problem = [NSString stringWithFormat:@"threw %@", e.name];
    }
    if (!problem && (![created isKindOfClass:UINavigationController.class] || ![root isKindOfClass:UIViewController.class])) {
        problem = [NSString stringWithFormat:@"got nav=%@ root=%@", created ? NSStringFromClass([created class]) : @"nil",
            root ? NSStringFromClass([root class]) : @"nil"];
    }
    // Never a screen someone else shows: one that already has a parent or presenter is not ours.
    if (!problem && ([(UIViewController *)created parentViewController] || [(UIViewController *)root parentViewController] ||
                     [(UIViewController *)created presentingViewController])) {
        problem = @"already in use";
    }
    if (problem) {
        nfb_colsTabMarkInFlight(identity, NO);
        if (!gNFBColsTabSkipped) gNFBColsTabSkipped = [NSMutableSet set];
        [gNFBColsTabSkipped addObject:identity];
        NFBLogEvent([NSString stringWithFormat:@"columns tabCol %@ not created: %@", identity, problem]);
        gNFBColsGen++;   // no empty slot for it
        [gNFBColsCollectionView.collectionViewLayout invalidateLayout];
        return nil;
    }
    nav = created;
    nav.viewControllers = @[ root ];
    // The rest of what X does when it opens a tab: the avatar (side menu) button and nav items.
    UIViewController *tabbed = nfb_colsFindControllerOfClass(@"T1TabbedAppNavigationViewController");
    id live = [tabbed respondsToSelector:@selector(currentTabNavigationController)] ?
        ((id(*)(id, SEL))objc_msgSend)(tabbed, @selector(currentTabNavigationController)) : nil;
    id dash = [live respondsToSelector:@selector(dashPresenter)] ? ((id(*)(id, SEL))objc_msgSend)(live, @selector(dashPresenter)) : nil;
    if (dash && [nav respondsToSelector:@selector(setDashPresenter:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(nav, @selector(setDashPresenter:), dash);
    }
    if ([tabbed respondsToSelector:@selector(_t1_updateDashBarButtonItemForTabNavigationController:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(tabbed, @selector(_t1_updateDashBarButtonItemForTabNavigationController:), nav);
    }
    if ([nav respondsToSelector:@selector(updateNavigationItemForViewController:)]) {
        ((void(*)(id, SEL, id))objc_msgSend)(nav, @selector(updateNavigationItemForViewController:), root);
    }
    nfb_colsTabCompactWidth(nav);
    objc_setAssociatedObject(nav, &kNFBColsTabEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gNFBColsTabNavs) gNFBColsTabNavs = [NSMutableDictionary dictionary];
    gNFBColsTabNavs[identity] = nav;
    NFBLogEvent([NSString stringWithFormat:@"columns tabCol created id=%@ nav=%@ root=%@ %.0fms", identity,
        NSStringFromClass(nav.class), NSStringFromClass([root class]), (CACurrentMediaTime() - t0) * 1000.0]);
    return nav;
}

// Inside a column a horizontal swipe moves the columns: the tab's own horizontal pagers (the
// Notifications / Explore top tabs) stop scrolling sideways while hosted; their tab strip still
// switches pages. Vertical lists are not walked into.
static void nfb_colsLockTabPagers(UIViewController *nav, BOOL lock) {
    if (![nav isViewLoaded]) return;
    if (lock) {
        NSNumber *last = objc_getAssociatedObject(nav, &kNFBColsTabLockCheckKey);
        CFTimeInterval now = CACurrentMediaTime();
        if (last && now - last.doubleValue < 1.0) return;
        objc_setAssociatedObject(nav, &kNFBColsTabLockCheckKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:nav.view];
    NSUInteger hops = 0, locked = 0;
    while (queue.count && hops++ < 300) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:UIScrollView.class]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (!sv.pagingEnabled && ![NSStringFromClass(sv.class) containsString:@"PagingCollectionView"]) continue;
            NSNumber *saved = objc_getAssociatedObject(sv, &kNFBColsTabPagerLockedKey);
            if (lock && sv.contentSize.width > sv.bounds.size.width + 1.0) {
                if (!saved) objc_setAssociatedObject(sv, &kNFBColsTabPagerLockedKey, @(sv.scrollEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (sv.scrollEnabled) {
                    sv.scrollEnabled = NO;
                    locked++;
                }
            } else if (!lock && saved) {
                sv.scrollEnabled = saved.boolValue;
                objc_setAssociatedObject(sv, &kNFBColsTabPagerLockedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    if (locked) NFBLogEvent([NSString stringWithFormat:@"columns tabCol lockedPagers=%lu nav=%@", (unsigned long)locked, NSStringFromClass(nav.class)]);
}

static void nfb_colsTabHide(NSString *identity, UINavigationController *nav) {
    if (![gNFBColsTabShown containsObject:identity]) return;
    [gNFBColsTabShown removeObject:identity];
    [nav beginAppearanceTransition:NO animated:NO];
    [nav.viewIfLoaded removeFromSuperview];
    [nav endAppearanceTransition];
    nfb_colsLockTabPagers(nav, NO);
    NFBLogEvent([NSString stringWithFormat:@"columns tabCol removed id=%@", identity]);
}

// A tab column spans from under Home's navigation bar to above the bottom tab bar (the iPad sidebar
// is beside the content, not below it); returned in collection view coordinates.
static void nfb_colsTabBand(UICollectionView *cv, CGFloat *y, CGFloat *height) {
    CGRect cvRect = [cv convertRect:cv.bounds toView:nil];
    CGFloat top = CGRectGetMinY(cvRect), bottom = CGRectGetMaxY(cvRect);
    UINavigationBar *bar = nfb_colsSegmentedOfPager(gNFBColsPager).navigationController.navigationBar;
    if (bar.window && !bar.hidden && bar.alpha > 0.01) top = MAX(top, CGRectGetMaxY([bar convertRect:bar.bounds toView:nil]));
    UIViewController *tabBarController = gNFBColsTabBarController;
    if (!tabBarController.viewIfLoaded.window) {
        tabBarController = nfb_colsFindControllerOfClass(@"T1TabBarViewController");
        gNFBColsTabBarController = tabBarController;
    }
    for (UIView *tabView in nfb_colsTabViews(tabBarController)) {
        if (![tabView isKindOfClass:UIView.class] || !tabView.window || tabView.hidden) continue;
        // The bar holding the tab buttons: the first ancestor at least half as wide as the columns.
        UIView *barView = tabView;
        while (barView.superview && barView.bounds.size.width < cvRect.size.width * 0.5) barView = barView.superview;
        CGRect barRect = [barView convertRect:barView.bounds toView:nil];
        if (barRect.size.height < 160.0 && CGRectGetMinY(barRect) > top + 200.0) bottom = MIN(bottom, CGRectGetMinY(barRect));
        break;
    }
    *y = [cv convertPoint:CGPointMake(0.0, top) fromView:nil].y;
    *height = MAX(200.0, bottom - top);
}

static void nfb_colsLayoutTabColumns(void) {
    UICollectionView *cv = gNFBColsCollectionView;
    BOOL on = nfb_colsActiveNow() && cv.window != nil;
    NFBColumnsModel *model = on ? nfb_colsModelForLayout(cv.collectionViewLayout) : nil;
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    if (model.tabColumns.count) {
        CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
        // The model changed outside a pref change (X rebuilt its tabs): the content size follows.
        if (model.gen != gNFBColsTabInvalidatedGen && fabs(cv.contentSize.width - MAX(cw * model.columnCount, cv.bounds.size.width)) > 1.0) {
            gNFBColsTabInvalidatedGen = model.gen;
            [cv.collectionViewLayout invalidateLayout];
        }
        CGFloat y = 0.0, height = 0.0;
        nfb_colsTabBand(cv, &y, &height);
        for (NSDictionary *column in model.tabColumns) {
            NSString *identity = column[@"id"];
            UINavigationController *nav = nfb_colsTabNav(column);
            if (!nav) continue;
            [placed addObject:identity];
            UIView *view = nav.view;
            CGRect frame = CGRectMake(cw * [column[@"slot"] doubleValue], y, cw, height);
            if (view.superview != cv) {
                view.clipsToBounds = YES;
                [cv addSubview:view];
            }
            if (!CGRectEqualToRect(view.frame, frame)) view.frame = frame;
            if (![gNFBColsTabShown containsObject:identity]) {
                if (!gNFBColsTabShown) gNFBColsTabShown = [NSMutableSet set];
                [gNFBColsTabShown addObject:identity];
                [nav beginAppearanceTransition:YES animated:NO];
                [nav endAppearanceTransition];
                NFBLogEvent([NSString stringWithFormat:@"columns tabCol shown id=%@ slot=%@ f=(%.0f,%.0f,%.0f,%.0f)", identity,
                    column[@"slot"], frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
                // Once it has loaded a little: lock the pagers it built meanwhile; after 4s it is no
                // longer a suspect for a crash.
                for (NSNumber *delay in @[ @1.5, @4.0 ]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (delay.doubleValue > 3.0) nfb_colsTabMarkInFlight(identity, NO);
                        nfb_colsScheduleTabLayout();
                    });
                }
            }
            nfb_colsLockTabPagers(nav, YES);
        }
    }
    for (NSString *identity in gNFBColsTabShown.allObjects) {
        if (![placed containsObject:identity]) nfb_colsTabHide(identity, gNFBColsTabNavs[identity]);
    }
    // Tabs that are no longer columns let go of their screen; the rest stay for the next visit.
    if (gNFBColsTabNavs.count && (on || !nfb_colsEnabled())) {
        NSMutableSet<NSString *> *keep = [NSMutableSet set];
        for (NSDictionary *column in model.tabColumns) [keep addObject:column[@"id"]];
        for (NSString *identity in gNFBColsTabNavs.allKeys) {
            if (![keep containsObject:identity]) [gNFBColsTabNavs removeObjectForKey:identity];
        }
    }
}

static void nfb_colsScheduleTabLayout(void) {
    if (gNFBColsTabLayoutPending) return;
    gNFBColsTabLayoutPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gNFBColsTabLayoutPending = NO;
        nfb_colsLayoutTabColumns();
    });
}

static NSString *nfb_colsTabDiag(NFBColumnsModel *model) {
    NSMutableString *s = [NSMutableString string];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSDictionary *tab in nfb_colsTabCandidates()) [candidates addObject:[NSString stringWithFormat:@"%@=%@", tab[@"page"], tab[@"title"]]];
    [s appendFormat:@"columns tabs entries=%lu candidates=%@ cols=%ld shown=%@ cached=%@ failed=%@ inflight=%@ skipped=%@ stoppedAtLaunch=%@\n",
        (unsigned long)gNFBColsTabEntries.count, [candidates componentsJoinedByString:@","] ?: @"-", (long)model.columnCount,
        [gNFBColsTabShown.allObjects componentsJoinedByString:@","] ?: @"-", [gNFBColsTabNavs.allKeys componentsJoinedByString:@","] ?: @"-",
        [nfb_colsTabFailed().allObjects componentsJoinedByString:@","] ?: @"-",
        [[NSUserDefaults.standardUserDefaults arrayForKey:kNFBColsTabInFlightKey] componentsJoinedByString:@","] ?: @"-",
        [gNFBColsTabSkipped.allObjects componentsJoinedByString:@","] ?: @"-", gNFBColsTabFailedAtLaunch ?: @"-"];
    for (NSDictionary *column in model.tabColumns) {
        UINavigationController *nav = gNFBColsTabNavs[column[@"id"]];
        UIView *view = nav.viewIfLoaded;
        UIScrollView *list = nil;   // the first vertical list: did the tab load anything?
        NSMutableArray<UIView *> *queue = view ? [NSMutableArray arrayWithObject:view] : [NSMutableArray array];
        NSUInteger hops = 0;
        while (queue.count && hops++ < 300 && !list) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:UIScrollView.class] && !((UIScrollView *)v).pagingEnabled && v.bounds.size.height > 150.0) list = (UIScrollView *)v;
            [queue addObjectsFromArray:v.subviews];
        }
        CGRect f = view.frame;
        [s appendFormat:@"columns tabCol id=%@ slot=%@ nav=%@ top=%@ stack=%lu super=%@ f=(%.0f,%.0f,%.0f,%.0f) window=%d list=%@ content=%.0f\n",
            column[@"id"], column[@"slot"], nav ? NSStringFromClass(nav.class) : @"nil",
            nav.topViewController ? NSStringFromClass(nav.topViewController.class) : @"-", (unsigned long)nav.viewControllers.count,
            view.superview ? NSStringFromClass(view.superview.class) : @"nil", f.origin.x, f.origin.y, f.size.width, f.size.height,
            view.window ? 1 : 0, list ? NSStringFromClass(list.class) : @"-", list ? list.contentSize.height : -1.0];
    }
    return s;
}

static void nfb_colsSetActiveOnNav(BOOL active, UIViewController *nav, UIViewController *tabBarController) {
    if (active && !nfb_colsEnabled()) return;
    if (!nav) nav = nfb_colsFindControllerOfClass(@"T1TabbedAppNavigationViewController");
    if (!tabBarController) tabBarController = nfb_colsFindControllerOfClass(@"T1TabBarViewController");
    if (active) {
        // Columns reuse the Home surface: make sure Home is the real selected tab first.
        NSArray *tabViews = nfb_colsTabViews(tabBarController);
        NSInteger homeIndex = nfb_colsIndexOfPage(tabViews, @"home");
        NSInteger selected = [nav respondsToSelector:@selector(selectedIndex)] ?
            ((NSInteger(*)(id, SEL))objc_msgSend)(nav, @selector(selectedIndex)) : NSNotFound;
        if (homeIndex != NSNotFound && selected != homeIndex &&
            [nav respondsToSelector:@selector(tabBarViewController:selectTabAtIndex:withView:)]) {
            gNFBColsSelectingHome = YES;
            ((void(*)(id, SEL, id, NSInteger, id))objc_msgSend)(nav, @selector(tabBarViewController:selectTabAtIndex:withView:),
                tabBarController, homeIndex, tabViews[(NSUInteger)homeIndex]);
            gNFBColsSelectingHome = NO;
        }
    }
    BOOL changed = gNFBColsActive != active;
    if (!active && changed) {
        nfb_colsSyncPageAppearance(NO);
        nfb_colsFitColumnTables(NO);
    }
    gNFBColsActive = active;
    if (!active && changed) nfb_colsLayoutTabColumns();   // the app-tab columns leave with the Columns tab
    [NSUserDefaults.standardUserDefaults setBool:active forKey:@"nfb_columns_session"];
    nfb_colsApplyToHome();
    if (active) {
        // The Home pager may only now be laid out for the first time.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!nfb_colsActiveNow()) return;
            nfb_colsApplyToHome();
            nfb_colsSyncPageAppearance(YES);
            nfb_colsFitColumnTables(YES);
            nfb_colsScheduleTabLayout();
        });
        nfb_colsScheduleKick();
    } else if ([nav respondsToSelector:@selector(_t1_syncTabBarSelectionWithSelectedController)]) {
        ((void(*)(id, SEL))objc_msgSend)(nav, @selector(_t1_syncTabBarSelectionWithSelectedController));
    }
    nfb_colsRefreshTabViews(nav, tabBarController);
    NFBNoteTabSelectionChanged();
    NFBStreamPrefsChanged();
    if (changed) NFBLogEvent([NSString stringWithFormat:@"columns tab active=%d", active ? 1 : 0]);
}

void NFBColumnsPrefsChanged(void) {
    gNFBColsGen++;
    gNFBColsEnabled = [BHTSettings boolForKey:kNFBColsEnabledKey];
    gNFBColsEnabledLoaded = YES;
    UIViewController *nav = nfb_colsFindControllerOfClass(@"T1TabbedAppNavigationViewController");
    UIViewController *tabBarController = nfb_colsFindControllerOfClass(@"T1TabBarViewController");
    if (!gNFBColsEnabled && gNFBColsActive) nfb_colsSetActiveOnNav(NO, nav, tabBarController);
    nfb_colsEnsureHostVisible(nav);
    nfb_colsApplyToHome();
    nfb_colsRefreshTabViews(nav, tabBarController);
    NFBNoteTabSelectionChanged();
    NFBStreamPrefsChanged();
    nfb_colsScheduleTabLayout();
}

// Empty columns: pages that were never "current" may not have fetched yet. Nudge each once.
static void nfb_colsKickEmptyPages(void) {
    if (nfb_colsActiveNow()) nfb_colsFitColumnTables(YES);
    for (NSDictionary *entry in NFBColumnsVisibleEntries()) {
        UIViewController *page = entry[@"vc"];
        if (![page isViewLoaded] || objc_getAssociatedObject(page, &kNFBColsKickedKey)) continue;
        UIScrollView *best = nil;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:page.view];
        NSUInteger hops = 0;
        while (queue.count && hops++ < 200) {
            UIView *v = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:UIScrollView.class] && v.bounds.size.height > 200.0) { best = (UIScrollView *)v; break; }
            [queue addObjectsFromArray:v.subviews];
        }
        if (!best || best.contentSize.height > 60.0) continue;
        objc_setAssociatedObject(page, &kNFBColsKickedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIViewController *target = page;
        NSMutableArray<UIViewController *> *vcs = [NSMutableArray arrayWithObject:page];
        while (vcs.count) {
            UIViewController *vc = vcs.lastObject;
            [vcs removeLastObject];
            if ([vc respondsToSelector:@selector(loadTop:)]) { target = vc; break; }
            [vcs addObjectsFromArray:vc.childViewControllers];
        }
        if ([target respondsToSelector:@selector(loadTop:)]) {
            @try { ((void(*)(id, SEL, id))objc_msgSend)(target, @selector(loadTop:), nil); } @catch (NSException *e) {}
            NFBLogEvent([NSString stringWithFormat:@"columns kickLoad %@ (%@)", entry[@"title"], NSStringFromClass(target.class)]);
        }
    }
}

static void nfb_colsScheduleKick(void) {
    for (NSNumber *delay in @[@0.8, @2.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NFBColumnsActive()) nfb_colsKickEmptyPages();
        });
    }
}

#pragma mark - crash guard (never let columns crash-loop the app)

static void nfb_colsPresentAlert(NSString *message) {
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { key = w; break; }
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:ac animated:YES completion:nil];
}

static BOOL gNFBColsPendingAutoDisableAlert = NO;

// Runs from %ctor: if the app died twice in a row while the Columns tab was active (crash /
// watchdog kill, i.e. without reaching the background), turn the Columns tab off.
static void nfb_colsLaunchGuard(void) {
    NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
    if ([defs boolForKey:@"nfb_columns_session"]) {
        NSInteger unclean = [defs integerForKey:@"nfb_columns_unclean"];
        unclean += 1;
        if (unclean >= 2) {
            [defs setBool:NO forKey:kNFBColsEnabledKey];
            unclean = 0;
            gNFBColsPendingAutoDisableAlert = YES;
        }
        [defs setInteger:unclean forKey:@"nfb_columns_unclean"];
    } else {
        [defs setInteger:0 forKey:@"nfb_columns_unclean"];
    }
    // An app-tab column that was being opened when the app died stays off until turned on again.
    NSArray *inFlight = [defs arrayForKey:kNFBColsTabInFlightKey];
    if (inFlight.count) {
        NSMutableArray *failed = [[defs arrayForKey:kNFBColsTabFailedKey] ?: @[] mutableCopy];
        for (id identity in inFlight) if (![failed containsObject:identity]) [failed addObject:identity];
        [defs setObject:failed forKey:kNFBColsTabFailedKey];
        [defs removeObjectForKey:kNFBColsTabInFlightKey];
        gNFBColsTabFailedAtLaunch = [inFlight componentsJoinedByString:@","];
    }
    gNFBColsEnabled = [BHTSettings boolForKey:kNFBColsEnabledKey];
    gNFBColsEnabledLoaded = YES;
    [defs setBool:NO forKey:@"nfb_columns_session"];   // columns start inactive (Home is Home)
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"nfb_columns_session"];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsTabInFlightKey];   // they opened fine
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            NSUInteger released = 0;
            for (NSString *identity in gNFBColsTabNavs.allKeys) {
                if ([gNFBColsTabShown containsObject:identity]) continue;
                [gNFBColsTabNavs removeObjectForKey:identity];
                released++;
            }
            if (released) NFBLogEvent([NSString stringWithFormat:@"columns tabCol memoryWarning released=%lu", (unsigned long)released]);
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [NSUserDefaults.standardUserDefaults setBool:nfb_colsActiveNow() forKey:@"nfb_columns_session"];
        }];
}

static void nfb_colsHomeAppearedOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (gNFBColsTabFailedAtLaunch) {
            NFBLogEvent([NSString stringWithFormat:@"columns tabCol stopped after the app quit while opening: %@", gNFBColsTabFailedAtLaunch]);
        }
        if (gNFBColsPendingAutoDisableAlert) {
            gNFBColsPendingAutoDisableAlert = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                nfb_colsPresentAlert(nfb_colsLoc(@"NFB_COLUMNS_AUTO_DISABLED", @"The Columns tab was turned off because the app quit unexpectedly twice while it was open."));
            });
        }
    });
}

#pragma mark - management screen

@interface NFBColumnsManagerViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *titles;   // display order, all columns (keys)
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *tabTitles;   // app-tab key -> its name
@end

@implementation NFBColumnsManagerViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = nfb_colsLoc(@"NFB_COLUMNS_MANAGE_TITLE", @"Manage columns");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:nfb_colsLoc(@"NFB_RESET", @"Reset") style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    [self reloadTitles];
    [self setEditing:YES animated:NO];
}

- (void)reloadTitles {
    UICollectionView *cv = gNFBColsCollectionView;
    UIViewController *pager = gNFBColsPager;
    NSInteger count = (cv && cv.numberOfSections > 0) ? [cv numberOfItemsInSection:0] : 0;
    NSArray<NSString *> *native = pager ? nfb_colsTitlesForPager(pager, count) : @[];
    NSArray<NSDictionary *> *tabs = nfb_colsTabCandidates();
    NSMutableDictionary<NSString *, NSString *> *tabTitles = [NSMutableDictionary dictionary];
    for (NSDictionary *tab in tabs) tabTitles[tab[@"id"]] = tab[@"title"];
    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:kNFBColsOrderKey] ?: @[];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *t in savedOrder) {
        if (![t isKindOfClass:NSString.class] || [titles containsObject:t]) continue;
        if ([native containsObject:t] || tabTitles[t]) [titles addObject:t];
    }
    for (NSString *t in native) if (![titles containsObject:t]) [titles addObject:t];
    for (NSDictionary *tab in tabs) if (![titles containsObject:tab[@"id"]]) [titles addObject:tab[@"id"]];
    self.titles = titles;
    self.tabTitles = tabTitles;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reset {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsOrderKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsVisibilityKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsTabFailedKey];
    [gNFBColsTabSkipped removeAllObjects];
    NFBColumnsPrefsChanged();
    [self reloadTitles];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.titles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.titles.count) return nfb_colsLoc(@"NFB_COLUMNS_MANAGE_EMPTY", @"Open Home once with columns mode on to list its timelines here.");
    return self.tabTitles.count ? nfb_colsLoc(@"NFB_COLUMNS_MANAGE_TABS_NOTE",
        @"App tabs (Notifications, Search, ...) become columns when turned on. Each opens a second copy of that screen, so every one you turn on uses memory. App-tab columns are not auto-refreshed.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"col2"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"col2"];
    NSString *title = self.titles[indexPath.row];
    NSString *tabTitle = self.tabTitles[title];
    BOOL stopped = tabTitle && [nfb_colsTabFailed() containsObject:title];
    cell.textLabel.text = tabTitle ?: title;
    cell.detailTextLabel.text = !tabTitle ? nil : (stopped ?
        nfb_colsLoc(@"NFB_COLUMNS_TAB_STOPPED", @"App tab - stopped: the app quit right after this column opened last time (turn on to retry)") :
        nfb_colsLoc(@"NFB_COLUMNS_KIND_TAB", @"App tab"));
    cell.detailTextLabel.textColor = stopped ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsReorderControl = YES;
    UISwitch *sw = [UISwitch new];
    NSDictionary *visibility = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kNFBColsVisibilityKey] ?: @{};
    sw.on = tabTitle ? ([visibility[title] boolValue] && !stopped) : nfb_colsTitleVisible(title, visibility);
    sw.accessibilityIdentifier = title;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.editingAccessoryView = sw;
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    BOOL isTab = self.tabTitles[key] != nil;
    NSMutableDictionary *visibility = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kNFBColsVisibilityKey] ?: @{} mutableCopy];
    if (!sender.on && !isTab) {
        NSUInteger visibleCount = 0;
        for (NSString *t in self.titles) if (!self.tabTitles[t] && nfb_colsTitleVisible(t, visibility)) visibleCount++;
        if (visibleCount <= 1) { sender.on = YES; return; }   // keep at least one timeline column
    }
    if (isTab && sender.on) nfb_colsTabClearFailed(key);   // turning a stopped tab on again = retry
    visibility[key] = @(sender.on);
    [[NSUserDefaults standardUserDefaults] setObject:visibility forKey:kNFBColsVisibilityKey];
    NFBColumnsPrefsChanged();
    NSUInteger row = [self.titles indexOfObject:key];
    if (isTab && row != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)row inSection:0] ] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *title = self.titles[from.row];
    [self.titles removeObjectAtIndex:from.row];
    [self.titles insertObject:title atIndex:to.row];
    [[NSUserDefaults standardUserDefaults] setObject:[self.titles copy] forKey:kNFBColsOrderKey];
    NFBColumnsPrefsChanged();
}

@end

void NFBColumnsShowManager(UIViewController *presenter) {
    if (!presenter) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[NFBColumnsManagerViewController new]];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

// Which bottom tab becomes the Columns tab. Offers every tab the app has built (as recorded by
// the custom tab bar), except Home and the "more" dash. Used by the Timelines settings row and
// the stream button's long-press menu.
void NFBColumnsShowHostPicker(UIViewController *presenter, void (^changed)(void)) {
    if (!presenter) return;
    BHTBundle *bundle = [BHTBundle sharedBundle];
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"nfb_columns_host"] ?: @"communities";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"NFB_COLUMNS_HOST_PICKER_TITLE"]
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    for (NSDictionary *tab in [CustomTabBarUtility availableTabs]) {
        NSString *page = tab[TabPageKey];
        if (!page.length || [page isEqualToString:CustomTabBarHomePageID] || [page isEqualToString:@"dash"]) continue;
        NSString *title = [tab[TabTitleKey] length] ? tab[TabTitleKey] : page;
        if ([page isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
                                                    [[NSUserDefaults standardUserDefaults] setObject:page forKey:@"nfb_columns_host"];
                                                    NFBColumnsPrefsChanged();
                                                    if (changed) changed();
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static BOOL nfb_colsOwnsScroll(UIScrollView *scrollView) {
    return scrollView && scrollView == gNFBColsCollectionView && nfb_colsActiveNow();
}

#pragma mark - horizontal scroll stats (diagnostics)

// One summary line per horizontal drag in columns mode: frame gaps (hitches), time spent in the
// pager's own scrollViewDidScroll, layout invalidations/prepares and Home tab selections it caused,
// where it went, and the swipe-start decisions since the previous line (refused as vertical / at an
// end, and starts X's own rule would have refused). The counters are declared at the top.
static void nfb_colsScrollStatsFlush(NSString *why) {
    if (gNFBColsScroll.frames) {
        NFBLogEvent([NSString stringWithFormat:@"columns scroll[%@] frames=%lu maxGapMs=%.0f slow(>25ms)=%lu suppressedInvalidations=%lu prepares=%lu selects=%lu x=%.0f->%.0f rejectV=%lu rejectEdge=%lu xVeto=%lu xScrollOff=%lu",
            why, (unsigned long)gNFBColsScroll.frames, gNFBColsScroll.maxGap * 1000.0, (unsigned long)gNFBColsScroll.slow,
            (unsigned long)gNFBColsScroll.invalidations, (unsigned long)gNFBColsScroll.prepares, (unsigned long)gNFBColsScroll.selects,
            gNFBColsScroll.startX, gNFBColsCollectionView.contentOffset.x, (unsigned long)gNFBColsScroll.rejectVertical,
            (unsigned long)gNFBColsScroll.rejectEdge, (unsigned long)gNFBColsScroll.stockVetoes, (unsigned long)gNFBColsScrollOffBlocked]);
    }
    memset(&gNFBColsScroll, 0, sizeof(gNFBColsScroll));
}

#pragma mark - Hooks

// Geometry: only for the Home pager's layout while columns mode is on; %orig otherwise.
%hook _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42416PagingFlowLayout

- (CGSize)collectionViewContentSize {
    CGSize size = %orig;
    if (!nfb_colsActiveForLayout(self)) return size;
    UICollectionView *cv = self.collectionView;
    NFBColumnsModel *model = nfb_colsModelForLayout(self);
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    size.width = MAX(cw * (CGFloat)model.columnCount, cv.bounds.size.width);
    return size;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *orig = %orig;
    if (!nfb_colsActiveForLayout(self) || !indexPath) return orig;
    UICollectionView *cv = self.collectionView;
    NFBColumnsModel *model = nfb_colsModelForLayout(self);
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    UICollectionViewLayoutAttributes *attrs = orig ? [orig copy] :
        [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
    CGRect frame = orig ? orig.frame : CGRectMake(0.0, 0.0, cw, cv.bounds.size.height);
    NSNumber *slot = model.slotOfItem[@(indexPath.item)];
    if (slot) {
        attrs.frame = CGRectMake(cw * slot.doubleValue, frame.origin.y, cw, frame.size.height);
        attrs.hidden = NO;
    } else {
        attrs.frame = CGRectMake(-cw * 4.0, frame.origin.y, cw, frame.size.height);
        attrs.hidden = YES;
    }
    return attrs;
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    if (!nfb_colsActiveForLayout(self)) return %orig;
    NFBColumnsModel *model = nfb_colsModelForLayout(self);
    NSMutableArray<UICollectionViewLayoutAttributes *> *out = [NSMutableArray array];
    // Every column, not only those in `rect`: keeping all column cells alive means a page is never
    // taken out of / put back into a cell while swiping (each re-embed re-lays out a whole timeline).
    [model.slots enumerateObjectsUsingBlock:^(NSNumber *item, NSUInteger slot, BOOL *stop) {
        UICollectionViewLayoutAttributes *attrs = [self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:item.integerValue inSection:0]];
        if (attrs) [out addObject:attrs];
    }];
    return out;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    if (!nfb_colsActiveForLayout(self)) return %orig;
    // Column geometry depends only on the size; the stock paging layout also invalidates on every
    // scroll step (origin change), which re-lays out all columns while swiping.
    CGSize old = self.collectionView.bounds.size;
    BOOL resized = fabs(old.width - newBounds.size.width) > 0.5 || fabs(old.height - newBounds.size.height) > 0.5;
    BOOL stock = %orig;
    if (stock && !resized) gNFBColsScroll.invalidations++;   // stock invalidations we suppressed
    return resized;
}

- (void)prepareLayout {
    %orig;
    if (nfb_colsActiveForLayout(self)) {
        gNFBColsScroll.prepares++;
        NFBHeatCount(NFBHeatColumnsLayout);
        nfb_colsScheduleTabLayout();   // app-tab columns follow a resize / a changed column set
    }
}

- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposed withScrollingVelocity:(CGPoint)velocity {
    CGPoint target = %orig;
    if (!nfb_colsActiveForLayout(self)) return target;
    UICollectionView *cv = self.collectionView;
    target.x = nfb_colsSnap(cv, proposed.x, velocity.x, cv.contentOffset.x);
    return target;
}

- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposed {
    CGPoint target = %orig;
    if (!nfb_colsActiveForLayout(self)) return target;
    UICollectionView *cv = self.collectionView;
    NSNumber *desired = objc_getAssociatedObject(cv, &kNFBColsDesiredOffsetKey);
    target.x = nfb_colsSnap(cv, desired ? desired.doubleValue : proposed.x, 0.0, cv.contentOffset.x);
    return target;
}

%end

%hook _TtC10TFNUISwift26LegacyPagingViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!nfb_colsPagerIsHome(self)) return;
    nfb_colsHomeAppearedOnce();
    if (nfb_colsActiveNow()) {
        nfb_colsApplyToPager(self);
        nfb_colsScheduleKick();
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!nfb_colsActiveNow() || !nfb_colsPagerIsHome(self)) return;
    UICollectionView *cv = (gNFBColsPager == self) ? gNFBColsCollectionView : nil;
    if (!cv) cv = nfb_colsCollectionViewOfPager(self);
    if (!cv) return;
    gNFBColsPager = self;
    gNFBColsCollectionView = cv;
    if (cv.pagingEnabled) cv.pagingEnabled = NO;
    nfb_colsForceScrollable(cv);
    // The pager re-centres on its "current page" after layout changes; keep our column instead.
    NSNumber *desired = objc_getAssociatedObject(cv, &kNFBColsDesiredOffsetKey);
    if (desired && !cv.isDragging && !cv.isDecelerating && !cv.isTracking) {
        CGFloat maxX = MAX(0.0, cv.contentSize.width - cv.bounds.size.width);
        CGFloat x = MIN(MAX(desired.doubleValue, 0.0), maxX);
        if (fabs(cv.contentOffset.x - x) > 1.0) [cv setContentOffset:CGPointMake(x, cv.contentOffset.y) animated:NO];
    }
    if (!cv.isDragging && !cv.isDecelerating && !cv.isTracking) nfb_colsScheduleTabLayout();
}

// Columns mode owns the Home collection view's horizontal scrolling. The pager's own handling
// (page transitions, appearance forwarding, selecting the Home tab under the finger) is skipped:
// columns are not pages, and every one of those transitions re-laid out a whole timeline mid-swipe.
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (nfb_colsOwnsScroll(scrollView)) return;
    %orig;
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
    if (nfb_colsOwnsScroll(scrollView)) return;
    %orig;
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (nfb_colsOwnsScroll(scrollView)) return;
    %orig;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(CGPoint *)targetContentOffset {
    if (!targetContentOffset || !nfb_colsOwnsScroll(scrollView) || ![scrollView isKindOfClass:UICollectionView.class]) {
        %orig;
        return;
    }
    CGFloat snapped = nfb_colsSnap((UICollectionView *)scrollView, targetContentOffset->x, velocity.x, scrollView.contentOffset.x);
    targetContentOffset->x = snapped;
    objc_setAssociatedObject(scrollView, &kNFBColsDesiredOffsetKey, @(snapped), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!nfb_colsOwnsScroll(scrollView)) {
        %orig;
        return;
    }
    if (!(scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking)) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!gNFBColsScroll.frames) gNFBColsScroll.startX = scrollView.contentOffset.x;
    if (gNFBColsScroll.lastT > 0.0) {
        double gap = now - gNFBColsScroll.lastT;
        if (gap < 1.0) {
            if (gap > gNFBColsScroll.maxGap) gNFBColsScroll.maxGap = gap;
            if (gap > 0.025) gNFBColsScroll.slow++;
        }
    }
    gNFBColsScroll.frames++;
    gNFBColsScroll.lastT = now;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (!nfb_colsOwnsScroll(scrollView)) {
        %orig;
        return;
    }
    nfb_colsScrollStatsFlush(@"decel");
    NSNumber *desired = objc_getAssociatedObject(scrollView, &kNFBColsDesiredOffsetKey);
    if (desired && fabs(scrollView.contentOffset.x - desired.doubleValue) > 1.0) {
        [scrollView setContentOffset:CGPointMake(desired.doubleValue, scrollView.contentOffset.y) animated:YES];
    }
    nfb_colsKickEmptyPages();
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!nfb_colsOwnsScroll(scrollView)) {
        %orig;
        return;
    }
    if (decelerate) return;
    nfb_colsScrollStatsFlush(@"drag");
    NSNumber *desired = objc_getAssociatedObject(scrollView, &kNFBColsDesiredOffsetKey);
    if (desired && fabs(scrollView.contentOffset.x - desired.doubleValue) > 1.0) {
        [scrollView setContentOffset:CGPointMake(desired.doubleValue, scrollView.contentOffset.y) animated:YES];
    }
    nfb_colsKickEmptyPages();
}

%end

// Keep off-screen columns loaded while columns mode is on, and let the pager prewarm every page
// so each visible column has its timeline embedded (normally only the current page +-1 is kept).
%hook _TtC10TFNUISwift29LegacySegmentedViewController

- (void)unloadInvisibleViewControllers {
    if (nfb_colsActiveNow() && nfb_colsParentNamed(self, @"HomeTimelineContainer")) return;
    %orig;
}

// No segment strip in columns mode: the segmented sizes its bar (and the page top inset) from these.
- (CGFloat)barHeight {
    if (nfb_colsActiveNow() && objc_getAssociatedObject(self, &kNFBColsChromeAppliedKey)) return 0.0;
    return %orig;
}

- (CGFloat)maximumBarHeight {
    if (nfb_colsActiveNow() && objc_getAssociatedObject(self, &kNFBColsChromeAppliedKey)) return 0.0;
    return %orig;
}

- (BOOL)pagingViewController:(id)pager isPrewarmableAt:(NSInteger)index {
    if (nfb_colsActiveNow() && nfb_colsParentNamed(self, @"HomeTimelineContainer")) return YES;
    return %orig;
}

- (void)pagingViewController:(id)pager mayBeginDisplayingPageAt:(NSInteger)index viewController:(id)viewController {
    %orig;
    if (nfb_colsActiveNow() && nfb_colsParentNamed(self, @"HomeTimelineContainer")) {
        NFBLogEvent([NSString stringWithFormat:@"columns mayBeginDisplaying index=%ld vc=%@", (long)index,
            viewController ? NSStringFromClass([viewController class]) : @"nil"]);
    }
}

%end

// The pager re-centres on "its" page (index x page width) — not a column edge. Programmatic
// offsets that are not on a column edge are moved back to the column the user left the pager on;
// an animated jump to page N (top tab tap) goes to page N's column instead.
static char kNFBColsAnimRangeKey;   // NSArray(minX, maxX, until) of an accepted animated scroll

static CGFloat nfb_colsFixProgrammaticOffset(UICollectionView *cv, CGFloat x, BOOL animatedCall) {
    if (!nfb_colsActiveNow() || cv != gNFBColsCollectionView) return x;
    if (cv.isDragging || cv.isTracking || cv.isDecelerating) return x;
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    CGFloat maxX = MAX(0.0, cv.contentSize.width - cv.bounds.size.width);
    NSTimeInterval now = CACurrentMediaTime();
    NSNumber *desired = objc_getAssociatedObject(cv, &kNFBColsDesiredOffsetKey);
    CGFloat fixed;
    if (!animatedCall) {
        // Intermediate frames of an animated scroll we accepted.
        NSArray<NSNumber *> *range = objc_getAssociatedObject(cv, &kNFBColsAnimRangeKey);
        if (range && now < range[2].doubleValue && x >= range[0].doubleValue - 1.0 && x <= range[1].doubleValue + 1.0) return x;
        // Anything else without animation is the pager re-centring (page 0 is also a column edge,
        // so edges are not trusted here): stay on the column the user chose.
        if (!desired) return x;
        fixed = desired.doubleValue;
    } else {
        CGFloat edge = round(x / cw) * cw;
        CGFloat pageWidth = cv.bounds.size.width;
        if (fabs(x - edge) < 1.0 || fabs(x - maxX) < 1.0) {
            fixed = x;
        } else if (pageWidth > 1.0 && fabs(x / pageWidth - round(x / pageWidth)) < 0.01) {
            NFBColumnsModel *model = objc_getAssociatedObject(cv.collectionViewLayout, &kNFBColsModelKey);
            NSNumber *slot = model.slotOfItem[@((NSInteger)round(x / pageWidth))];
            fixed = slot ? cw * slot.doubleValue : (desired ? desired.doubleValue : edge);
        } else {
            fixed = desired ? desired.doubleValue : edge;
        }
    }
    fixed = MIN(MAX(fixed, 0.0), maxX);
    if (fabs(fixed - x) > 1.0) {
        static NSTimeInterval lastLog = 0.0;
        if (now - lastLog > 1.0) {
            lastLog = now;
            NFBLogEvent([NSString stringWithFormat:@"columns offsetFix from=%.0f to=%.0f animated=%d cw=%.0f max=%.0f",
                x, fixed, animatedCall ? 1 : 0, cw, maxX]);
        }
    }
    if (animatedCall) {
        // Only deliberate (animated) moves change the remembered column; a clamp while the
        // content size is still settling must not.
        objc_setAssociatedObject(cv, &kNFBColsDesiredOffsetKey, @(fixed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat from = cv.contentOffset.x;
        objc_setAssociatedObject(cv, &kNFBColsAnimRangeKey, @[ @(MIN(from, fixed)), @(MAX(from, fixed)), @(now + 0.6) ],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return fixed;
}

%hook TFNTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (gNFBColsActive && objc_getAssociatedObject(self, &kNFBColsFittedTableKey)) {
        if (!gNFBColsSettingInset) {
            objc_setAssociatedObject(self, &kNFBColsTableStockTopKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSNumber *stock = objc_getAssociatedObject(self, &kNFBColsTableStockTopKey);
        inset.top = nfb_colsFittedTop(self, stock ? stock.doubleValue : inset.top);
    }
    %orig(inset);
}

%end

%hook _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42420PagingCollectionView

// Columns: a horizontal swipe moves columns, a vertical one scrolls the timeline under the finger,
// never both at once (X lets the pager pan run together with the page's vertical pan and then
// locks the axis in its own scroll callbacks, which columns mode skips). The axis comes from the
// distance moved so far: the instantaneous velocity is noisy on a slow swipe, and a rejected
// horizontal swipe ended as a tap on the tweet under the finger (fork b70 learned the same).
// Only a clearly vertical start goes to the timeline; a diagonal one still moves columns.
// X's own answer is for page paging and is never used for columns (X 12.38.1
// -[PagingCollectionView gestureRecognizerShouldBegin:]): it wants |vx| > 2|vy| from the
// instantaneous velocity, and refuses a rightward swipe on the pager's first page and a leftward one
// on its last (so the side menu can have it). In columns mode the pager's page never moves (its
// scroll callbacks are skipped), so one direction was refused from the start and every diagonal swipe
// scrolled the timeline under the finger instead. Columns stop only at their real ends.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!nfb_colsActiveNow() || self != gNFBColsCollectionView || gesture != self.panGestureRecognizer) return %orig;
    CGPoint t = [self.panGestureRecognizer translationInView:self];
    if (fabs(t.x) < 0.5 && fabs(t.y) < 0.5) t = [self.panGestureRecognizer velocityInView:self];
    BOOL stock = %orig;   // diagnostics only (no side effects): would X have refused it?
    if (fabs(t.y) > fabs(t.x) * 1.3) {
        gNFBColsScroll.rejectVertical++;
        return NO;
    }
    CGFloat maxX = MAX(0.0, self.contentSize.width - self.bounds.size.width);
    if ((t.x > 0.0 && self.contentOffset.x <= 0.5) || (t.x < 0.0 && self.contentOffset.x >= maxX - 0.5)) {
        gNFBColsScroll.rejectEdge++;   // nothing to move toward (no bounce): the edge gestures may have it
        return NO;
    }
    if (!stock) gNFBColsScroll.stockVetoes++;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (nfb_colsActiveNow() && self == gNFBColsCollectionView && gesture == self.panGestureRecognizer &&
        [other.view isKindOfClass:UIScrollView.class] && other.view != self) return NO;
    return %orig;
}

// See nfb_colsForceScrollable: X's "off" is remembered for leaving columns, not applied.
- (void)setScrollEnabled:(BOOL)enabled {
    if (!gNFBColsSettingScroll && nfb_colsActiveNow() && self == gNFBColsCollectionView) {
        objc_setAssociatedObject(self, &kNFBColsSavedScrollKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!enabled) {
            gNFBColsScrollOffBlocked++;
            return;
        }
    }
    %orig;
}

- (void)setContentOffset:(CGPoint)offset {
    offset.x = nfb_colsFixProgrammaticOffset(self, offset.x, NO);
    %orig(offset);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    offset.x = nfb_colsFixProgrammaticOffset(self, offset.x, animated);
    %orig(offset, animated);
}

%end

// The Columns tab. All tab taps (bottom bar and iPad sidebar) arrive here.
%hook T1TabbedAppNavigationViewController

- (void)tabBarViewController:(id)tabBarController selectTabAtIndex:(NSInteger)index withView:(UIView *)tabView {
    if (gNFBColsSelectingHome || !nfb_colsEnabled()) {
        %orig;
        return;
    }
    NSString *page = [tabView isKindOfClass:NSClassFromString(@"T1TabView")] ? ((T1TabView *)tabView).scribePage : nil;
    NFBLogEvent([NSString stringWithFormat:@"columns tabTap index=%ld page=%@ active=%d", (long)index, page ?: @"-", gNFBColsActive ? 1 : 0]);
    if ([page isEqualToString:NFBColumnsHostPageID()]) {
        if (gNFBColsActive) {
            // Re-tap on the Columns tab: every column back to its newest post (like Home's re-tap).
            NFBColumnsRevealAllTops();
            return;
        }
        // Never open the host's own page: show the Home surface as columns instead.
        nfb_colsSetActiveOnNav(YES, (UIViewController *)self, tabBarController);
        return;
    }
    if (gNFBColsActive) {
        nfb_colsSetActiveOnNav(NO, (UIViewController *)self, tabBarController);
        // Home is already the selected tab underneath; tapping it just leaves columns (no re-tap
        // scroll-to-top). Any other tab switches normally.
        if ([page isEqualToString:@"home"]) return;
    }
    %orig;
}

- (void)tabbedViewController:(id)tabbedViewController didSelectViewControllerAtIndex:(NSInteger)index {
    %orig;
    // Programmatic switches (notification taps, deep links) also leave the Columns tab.
    if (gNFBColsActive && !gNFBColsSelectingHome) {
        NSArray *tabViews = nfb_colsTabViews(nfb_colsFindControllerOfClass(@"T1TabBarViewController"));
        NSInteger homeIndex = nfb_colsIndexOfPage(tabViews, @"home");
        if (homeIndex != NSNotFound && index != homeIndex) nfb_colsSetActiveOnNav(NO, (UIViewController *)self, nil);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nfb_colsEnsureHostVisible((UIViewController *)self);
    });
}

%end

// Host tab label + selection highlight while the Columns tab is active.
%hook T1TabView

- (void)_t1_updateTitleLabel {
    %orig;
    if (nfb_colsEnabled() && [self.scribePage isEqualToString:NFBColumnsHostPageID()] &&
        [self respondsToSelector:@selector(titleLabel)]) {
        UILabel *label = ((id(*)(id, SEL))objc_msgSend)(self, @selector(titleLabel));
        if ([label isKindOfClass:UILabel.class]) label.text = nfb_colsTabTitle();
    }
}

- (NSString *)title {
    if (!gNFBColsRawTabTitle && nfb_colsEnabled() && [self.scribePage isEqualToString:NFBColumnsHostPageID()]) return nfb_colsTabTitle();
    return %orig;
}

- (NSString *)accessibilityLabel {
    if (nfb_colsEnabled() && [self.scribePage isEqualToString:NFBColumnsHostPageID()]) return nfb_colsTabTitle();
    return %orig;
}

- (void)setSelected:(BOOL)selected {
    if (nfb_colsActiveNow()) {
        NSString *page = self.scribePage;
        if ([page isEqualToString:@"home"]) {
            %orig(NO);
            return;
        }
        if ([page isEqualToString:NFBColumnsHostPageID()]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}

%end

// iPad full width (see nfb_colsWantNativeSplitTier).
// Spaces bar (fleet line) above the Home timelines: hidden while columns are shown.
%hook T1FleetLineHeaderController

- (void)attachToViewController:(id)viewController {
    %orig;
    if (!gNFBColsFleetHeaders) gNFBColsFleetHeaders = [NSHashTable weakObjectsHashTable];
    [gNFBColsFleetHeaders addObject:self];
}

- (BOOL)_t1_shouldShowFleetLine {
    if (nfb_colsActiveNow() && nfb_colsFleetHeaderIsHome(self)) return NO;
    return %orig;
}

- (void)showAnimated {
    if (nfb_colsActiveNow() && nfb_colsFleetHeaderIsHome(self)) return;
    %orig;
}

- (void)_t1_updateFleetLineVisibility {
    %orig;
    if (nfb_colsActiveNow() && nfb_colsFleetHeaderIsHome(self)) nfb_colsHideView(nfb_colsFleetContainer(self), YES);
}

%end

// Which Home tab the pager reports as selected while columns are shown (diagnostics).
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController

- (void)segmentedViewController:(id)segmented didSelectViewController:(id)viewController atIndex:(NSInteger)index previousIndex:(NSInteger)previousIndex trigger:(NSInteger)trigger {
    %orig;
    if (!nfb_colsActiveNow()) return;
    gNFBColsScroll.selects++;
    NFBLogEvent([NSString stringWithFormat:@"columns homeSelect index=%ld prev=%ld trigger=%ld vc=%@", (long)index, (long)previousIndex,
        (long)trigger, viewController ? NSStringFromClass([viewController class]) : @"nil"]);
}

%end

%group NFBColsExtendedContentSplit
%hook T1AppSplitViewController

- (BOOL)displayExtendedContent {
    if (nfb_colsWantNativeSplitTier(self)) return NO;
    return %orig;
}

- (void)setDisplayExtendedContent:(BOOL)displayExtendedContent {
    if (nfb_colsWantNativeSplitTier(self)) {
        %orig(NO);
        return;
    }
    %orig;
}

- (void)setDisplayExtendedContent:(BOOL)displayExtendedContent animated:(BOOL)animated {
    if (nfb_colsWantNativeSplitTier(self)) {
        %orig(NO, animated);
        return;
    }
    %orig;
}

- (NSInteger)private_splitModeForSize:(CGSize)size displayExtendedContent:(BOOL)displayExtendedContent displaySideBar:(BOOL)displaySideBar {
    if (nfb_colsWantNativeSplitTier(self)) return %orig(size, NO, displaySideBar);
    return %orig;
}

%end
%end

%ctor {
    %init;
    Class split = objc_getClass("T1AppSplitViewController");
    if (split && class_getInstanceMethod(split, @selector(private_splitModeForSize:displayExtendedContent:displaySideBar:))) {
        %init(NFBColsExtendedContentSplit);
    }
    nfb_colsLaunchGuard();
}
