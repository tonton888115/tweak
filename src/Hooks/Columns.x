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
//
//  Prefs: nfb_columns_enabled (the Columns tab), nfb_columns_host (page ID of the replaced tab),
//  nfb_columns_full_width (iPad: drop the right trends pane via T1AppSplitViewController's own
//  split-mode inputs), nfb_columns_order (titles), nfb_columns_visibility (title -> BOOL; For You
//  defaults to hidden).
//

#import "HookHelpers.h"

@interface _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42416PagingFlowLayout : UICollectionViewLayout
@end
@interface _TtC10TFNUISwift26LegacyPagingViewController : UIViewController
@end
@interface _TtC10TFNUISwift29LegacySegmentedViewController : UIViewController
@end
@interface T1AppSplitViewController : UIViewController
@end
@interface _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42420PagingCollectionView : UICollectionView
@end

void NFBLogEvent(NSString *msg);
void NFBStreamPrefsChanged(void);

static NSString * const kNFBColsEnabledKey = @"nfb_columns_enabled";
static NSString * const kNFBColsFullWidthKey = @"nfb_columns_full_width";
static NSString * const kNFBColsOrderKey = @"nfb_columns_order";
static NSString * const kNFBColsVisibilityKey = @"nfb_columns_visibility";

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

static void nfb_colsScheduleKick(void);

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
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *slotOfItem;
@end
@implementation NFBColumnsModel
@end

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
    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];
    for (NSString *title in savedOrder) {
        NSUInteger idx = [model.titles indexOfObject:title];
        if (idx != NSNotFound && ![ordered containsObject:@(idx)]) [ordered addObject:@(idx)];
    }
    for (NSInteger i = 0; i < count; i++) {
        if (![ordered containsObject:@(i)]) [ordered addObject:@(i)];
    }
    NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
    for (NSNumber *item in ordered) {
        if (nfb_colsTitleVisible(model.titles[item.unsignedIntegerValue], visibility)) [slots addObject:item];
    }
    if (!slots.count) [slots addObjectsFromArray:ordered];   // never hide everything
    NSMutableDictionary *slotOfItem = [NSMutableDictionary dictionary];
    [slots enumerateObjectsUsingBlock:^(NSNumber *item, NSUInteger idx, BOOL *stop) { slotOfItem[item] = @(idx); }];
    model.slots = slots;
    model.slotOfItem = slotOfItem;
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
        }
    }
    return s;
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
        if (!cv.scrollEnabled) cv.scrollEnabled = YES;
        cv.decelerationRate = UIScrollViewDecelerationRateFast;
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
static void nfb_colsRefreshTabViews(UIViewController *tabBarController) {
    for (T1TabView *tabView in nfb_colsTabViews(tabBarController)) {
        if (![tabView isKindOfClass:NSClassFromString(@"T1TabView")]) continue;
        if ([tabView respondsToSelector:@selector(_t1_updateTitleLabel)]) [tabView _t1_updateTitleLabel];
        ((void(*)(id, SEL, BOOL))objc_msgSend)(tabView, @selector(setSelected:), tabView.isSelected);
    }
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
    gNFBColsActive = active;
    [NSUserDefaults.standardUserDefaults setBool:active forKey:@"nfb_columns_session"];
    nfb_colsApplyToHome();
    if (active) {
        // The Home pager may only now be laid out for the first time.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (nfb_colsActiveNow()) nfb_colsApplyToHome();
        });
        nfb_colsScheduleKick();
    } else if ([nav respondsToSelector:@selector(_t1_syncTabBarSelectionWithSelectedController)]) {
        ((void(*)(id, SEL))objc_msgSend)(nav, @selector(_t1_syncTabBarSelectionWithSelectedController));
    }
    nfb_colsRefreshTabViews(tabBarController);
    NFBNoteTabSelectionChanged();
    NFBStreamPrefsChanged();
    if (changed) NFBLogEvent([NSString stringWithFormat:@"columns tab active=%d", active ? 1 : 0]);
}

void NFBColumnsSetActive(BOOL active) {
    nfb_colsSetActiveOnNav(active, nil, nil);
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
    nfb_colsRefreshTabViews(tabBarController);
    NFBNoteTabSelectionChanged();
    NFBStreamPrefsChanged();
}

// Empty columns: pages that were never "current" may not have fetched yet. Nudge each once.
static void nfb_colsKickEmptyPages(void) {
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
    gNFBColsEnabled = [BHTSettings boolForKey:kNFBColsEnabledKey];
    gNFBColsEnabledLoaded = YES;
    [defs setBool:NO forKey:@"nfb_columns_session"];   // columns start inactive (Home is Home)
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"nfb_columns_session"];
        }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [NSUserDefaults.standardUserDefaults setBool:nfb_colsActiveNow() forKey:@"nfb_columns_session"];
        }];
}

static void nfb_colsHomeAppearedOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
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
@property (nonatomic, strong) NSMutableArray<NSString *> *titles;   // display order, all columns
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
    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:kNFBColsOrderKey] ?: @[];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *t in savedOrder) if ([native containsObject:t] && ![titles containsObject:t]) [titles addObject:t];
    for (NSString *t in native) if (![titles containsObject:t]) [titles addObject:t];
    self.titles = titles;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reset {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsOrderKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNFBColsVisibilityKey];
    NFBColumnsPrefsChanged();
    [self reloadTitles];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.titles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.titles.count ? nil : nfb_colsLoc(@"NFB_COLUMNS_MANAGE_EMPTY", @"Open Home once with columns mode on to list its timelines here.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"col"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"col"];
    NSString *title = self.titles[indexPath.row];
    cell.textLabel.text = title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsReorderControl = YES;
    UISwitch *sw = [UISwitch new];
    NSDictionary *visibility = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kNFBColsVisibilityKey] ?: @{};
    sw.on = nfb_colsTitleVisible(title, visibility);
    sw.accessibilityIdentifier = title;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.editingAccessoryView = sw;
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSMutableDictionary *visibility = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kNFBColsVisibilityKey] ?: @{} mutableCopy];
    if (!sender.on) {
        NSUInteger visibleCount = 0;
        for (NSString *t in self.titles) if (nfb_colsTitleVisible(t, visibility)) visibleCount++;
        if (visibleCount <= 1) { sender.on = YES; return; }   // keep at least one column
    }
    visibility[sender.accessibilityIdentifier] = @(sender.on);
    [[NSUserDefaults standardUserDefaults] setObject:visibility forKey:kNFBColsVisibilityKey];
    NFBColumnsPrefsChanged();
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

#pragma mark - Hooks

// Geometry: only for the Home pager's layout while columns mode is on; %orig otherwise.
%hook _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42416PagingFlowLayout

- (CGSize)collectionViewContentSize {
    CGSize size = %orig;
    if (!nfb_colsActiveForLayout(self)) return size;
    UICollectionView *cv = self.collectionView;
    NFBColumnsModel *model = nfb_colsModelForLayout(self);
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    size.width = MAX(cw * (CGFloat)model.slots.count, cv.bounds.size.width);
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
    UICollectionView *cv = self.collectionView;
    NFBColumnsModel *model = nfb_colsModelForLayout(self);
    CGFloat cw = nfb_colsColumnWidth(cv.bounds.size.width);
    NSMutableArray<UICollectionViewLayoutAttributes *> *out = [NSMutableArray array];
    [model.slots enumerateObjectsUsingBlock:^(NSNumber *item, NSUInteger slot, BOOL *stop) {
        CGFloat minX = cw * (CGFloat)slot;
        if (minX + cw <= CGRectGetMinX(rect) || minX >= CGRectGetMaxX(rect)) return;
        UICollectionViewLayoutAttributes *attrs = [self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:item.integerValue inSection:0]];
        if (attrs) [out addObject:attrs];
    }];
    return out;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    BOOL orig = %orig;
    if (!nfb_colsActiveForLayout(self)) return orig;
    CGSize old = self.collectionView.bounds.size;
    return orig || fabs(old.width - newBounds.size.width) > 0.5 || fabs(old.height - newBounds.size.height) > 0.5;
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
    if (!cv.scrollEnabled) cv.scrollEnabled = YES;
    // The pager re-centres on its "current page" after layout changes; keep our column instead.
    NSNumber *desired = objc_getAssociatedObject(cv, &kNFBColsDesiredOffsetKey);
    if (desired && !cv.isDragging && !cv.isDecelerating && !cv.isTracking) {
        CGFloat maxX = MAX(0.0, cv.contentSize.width - cv.bounds.size.width);
        CGFloat x = MIN(MAX(desired.doubleValue, 0.0), maxX);
        if (fabs(cv.contentOffset.x - x) > 1.0) [cv setContentOffset:CGPointMake(x, cv.contentOffset.y) animated:NO];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(CGPoint *)targetContentOffset {
    CGFloat startX = scrollView.contentOffset.x;
    %orig;
    if (!targetContentOffset || !nfb_colsActiveNow() || !nfb_colsPagerIsHome(self) ||
        ![scrollView isKindOfClass:UICollectionView.class]) return;
    CGFloat snapped = nfb_colsSnap((UICollectionView *)scrollView, targetContentOffset->x, velocity.x, startX);
    targetContentOffset->x = snapped;
    objc_setAssociatedObject(scrollView, &kNFBColsDesiredOffsetKey, @(snapped), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    %orig;
    if (!nfb_colsActiveNow() || !nfb_colsPagerIsHome(self)) return;
    NSNumber *desired = objc_getAssociatedObject(scrollView, &kNFBColsDesiredOffsetKey);
    if (desired && fabs(scrollView.contentOffset.x - desired.doubleValue) > 1.0) {
        [scrollView setContentOffset:CGPointMake(desired.doubleValue, scrollView.contentOffset.y) animated:YES];
    }
    nfb_colsKickEmptyPages();
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    %orig;
    if (decelerate || !nfb_colsActiveNow() || !nfb_colsPagerIsHome(self)) return;
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

%hook _TtC10TFNUISwiftP33_19E25DFCBFA569FDFA3E56F314F9A42420PagingCollectionView

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
    if (nfb_colsEnabled() && [self.scribePage isEqualToString:NFBColumnsHostPageID()]) {
        self.titleLabel.text = nfb_colsTabTitle();
        self.accessibilityLabel = nfb_colsTabTitle();
    }
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

%ctor {
    %init;
    nfb_colsLaunchGuard();
}
