#import <UIKit/UIKit.h>
#import <objc/message.h>

extern void BHTDismissColumnsMode(void);

@interface NFBColumnsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *widthConstraints;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *columnControllers;
@property (nonatomic, strong) UIButton *tweetsNoticeButton;
@property (nonatomic, strong) id sourceAccount;
@property (nonatomic, weak) UIViewController *sourceHomeContainer;
@property (nonatomic, weak) UIViewController *sourceTabBarController;
@property (nonatomic, copy) NSArray *sourceTabViews;
@property (nonatomic, copy) NSDictionary<NSString *, id> *availableTabs;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *availableTitles;
@property (nonatomic, strong) NSMutableArray<NSString *> *selectedPages;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, copy) NSString *lastNativeTabFailure;
@end

@implementation NFBColumnsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"カラム";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.widthConstraints = [NSMutableArray array];
    self.columnControllers = [NSMutableArray array];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"ホーム"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(closeColumns)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(reloadColumns)];
    UIBarButtonItem *allTop = [[UIBarButtonItem alloc] initWithTitle:@"全カラム↑"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(revealAllColumns)];
    UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:@"編集"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(showColumnEditor)];
    self.navigationItem.leftBarButtonItem = done;
    self.navigationItem.rightBarButtonItems = @[edit, refresh, allTop];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.showsHorizontalScrollIndicator = YES;
    [self.view addSubview:self.scrollView];

    self.stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisHorizontal;
    self.stackView.spacing = 1.0;
    self.stackView.alignment = UIStackViewAlignmentFill;
    self.stackView.distribution = UIStackViewDistributionFill;
    [self.scrollView addSubview:self.stackView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.stackView.heightAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.heightAnchor]
    ]];

    self.tweetsNoticeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.tweetsNoticeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.tweetsNoticeButton.backgroundColor = UIColor.systemBlueColor;
    self.tweetsNoticeButton.layer.cornerRadius = 17.0;
    self.tweetsNoticeButton.layer.masksToBounds = YES;
    self.tweetsNoticeButton.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [self.tweetsNoticeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.tweetsNoticeButton setTitle:@"新しいツイートがあります" forState:UIControlStateNormal];
    [self.tweetsNoticeButton addTarget:self action:@selector(revealAllColumns) forControlEvents:UIControlEventTouchUpInside];
    self.tweetsNoticeButton.hidden = YES;
    [self.view addSubview:self.tweetsNoticeButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.tweetsNoticeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [self.tweetsNoticeButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.tweetsNoticeButton.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32.0],
        [self.tweetsNoticeButton.heightAnchor constraintEqualToConstant:34.0],
    ]];

    UIViewController *tabBarController = self.sourceTabBarController ?: [self activeTabBarController];
    self.sourceTabBarController = tabBarController;
    if (!self.sourceHomeContainer) self.sourceHomeContainer = [self homeContainerFromControllerTree:tabBarController];
    id account = self.sourceAccount ?: [self accountFromControllerTree:tabBarController];
    self.sourceAccount = account;
    self.availableTabs = [self tabViewsByPageFromTabBarController:tabBarController];
    self.availableTitles = [self titlesByPageFromTabs:self.availableTabs];
    self.selectedPages = [[self loadSelectedPages] mutableCopy];
    [self rebuildColumns];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startColumnRefreshTimer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopColumnRefreshTimer];
}

- (void)dealloc {
    [self stopColumnRefreshTimer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat columnWidth = width >= 700.0 ? 340.0 : MAX(320.0, MIN(390.0, width));
    for (NSLayoutConstraint *constraint in self.widthConstraints) {
        constraint.constant = columnWidth;
    }
}

- (UIViewController *)activeTabBarController {
    Class tabBarClass = NSClassFromString(@"T1TabBarViewController");
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *found = [self findControllerOfClass:tabBarClass fromController:window.rootViewController];
        if (found) return found;
    }
    return nil;
}

- (UIViewController *)findControllerOfClass:(Class)targetClass fromController:(UIViewController *)controller {
    if (!controller || !targetClass) return nil;
    if ([controller isKindOfClass:targetClass]) return controller;
    UIViewController *presented = [self findControllerOfClass:targetClass fromController:controller.presentedViewController];
    if (presented) return presented;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = [self findControllerOfClass:targetClass fromController:child];
        if (found) return found;
    }
    return nil;
}

- (UIViewController *)homeContainerFromControllerTree:(UIViewController *)controller {
    if (!controller) return nil;
    if ([NSStringFromClass(controller.class) containsString:@"HomeTimelineContainer"]) return controller;
    UIViewController *presented = [self homeContainerFromControllerTree:controller.presentedViewController];
    if (presented) return presented;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = [self homeContainerFromControllerTree:child];
        if (found) return found;
    }
    return nil;
}

- (id)accountFromControllerTree:(UIViewController *)controller {
    if (!controller) return nil;
    @try {
        id account = [controller valueForKey:@"account"];
        if (account) return account;
    } @catch (NSException *e) {
    }
    for (UIViewController *child in controller.childViewControllers) {
        id account = [self accountFromControllerTree:child];
        if (account) return account;
    }
    return nil;
}

- (NSDictionary<NSString *, id> *)tabViewsByPageFromTabBarController:(UIViewController *)tabBarController {
    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    NSArray *tabViews = self.sourceTabViews;
    @try {
        if (!tabViews) tabViews = [tabBarController valueForKey:@"tabViews"];
    } @catch (NSException *e) {
        tabViews = nil;
    }
    for (id tabView in tabViews) {
        NSString *page = nil;
        @try {
            page = [tabView valueForKey:@"scribePage"];
        } @catch (NSException *e) {
            page = nil;
        }
        if (page.length && !result[page]) result[page] = tabView;
    }
    return result;
}

- (NSDictionary<NSString *, NSString *> *)titlesByPageFromTabs:(NSDictionary<NSString *, id> *)tabs {
    NSDictionary<NSString *, NSString *> *defaults = @{
        @"home": @"Home",
        @"guide": @"Search",
        @"ntab": @"Notifications",
        @"messages": @"Messages",
        @"grok": @"Grok",
        @"profile": @"Profile",
        @"audiospace": @"Spaces",
        @"media": @"Video",
        @"lists": @"Lists"
    };
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionary];
    for (NSString *page in tabs) {
        if ([page isEqualToString:@"communities"]) continue;
        NSString *title = defaults[page] ?: page;
        id tabView = tabs[page];
        @try {
            UILabel *label = [tabView valueForKey:@"titleLabel"];
            if (label.text.length && ![label.text isEqualToString:@"カラム"] && ![label.text isEqualToString:@"Columns"]) title = label.text;
        } @catch (NSException *e) {
        }
        titles[page] = title;
    }
    return titles;
}

- (NSArray<NSString *> *)preferredPageOrder {
    NSMutableArray<NSString *> *order = [@[@"home", @"guide", @"ntab", @"messages", @"grok", @"profile", @"audiospace", @"media", @"lists"] mutableCopy];
    NSArray *extra = [[self.availableTitles allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *page in extra) {
        if (![order containsObject:page]) [order addObject:page];
    }
    return order;
}

- (NSArray<NSString *> *)defaultPages {
    NSArray *preferred = @[@"home", @"guide", @"ntab", @"messages"];
    NSMutableArray<NSString *> *pages = [NSMutableArray array];
    for (NSString *page in preferred) {
        if (self.availableTabs[page] && self.availableTitles[page]) [pages addObject:page];
    }
    if (pages.count == 0) {
        for (NSString *page in [self preferredPageOrder]) {
            if (self.availableTabs[page] && self.availableTitles[page]) {
                [pages addObject:page];
                break;
            }
        }
    }
    return pages;
}

- (NSArray<NSString *> *)loadSelectedPages {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"nfb_columns_pages"];
    NSMutableArray<NSString *> *pages = [NSMutableArray array];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id value in saved) {
            if ([value isKindOfClass:NSString.class] && self.availableTabs[value] && self.availableTitles[value] && ![pages containsObject:value]) {
                [pages addObject:value];
            }
        }
    }
    return pages.count ? pages : [self defaultPages];
}

- (void)persistSelectedPages {
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedPages ?: @[] forKey:@"nfb_columns_pages"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)rebuildColumns {
    for (UIViewController *controller in [self.columnControllers copy]) {
        [controller willMoveToParentViewController:nil];
        [controller.view removeFromSuperview];
        [controller removeFromParentViewController];
    }
    [self.columnControllers removeAllObjects];
    [self.widthConstraints removeAllObjects];

    for (UIView *view in [self.stackView.arrangedSubviews copy]) {
        [self.stackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    [self addTimelineColumnsFromHomeContainer];
    if (self.stackView.arrangedSubviews.count == 0) {
        NSString *message = self.lastNativeTabFailure.length ? self.lastNativeTabFailure : @"Home timelines are not available.";
        [self addPlaceholderColumnWithTitle:@"Columns" message:message];
    }
}

- (id)valueForKeySafely:(NSString *)key object:(id)object {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

- (id)performObjectSelector:(SEL)selector object:(id)object {
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *e) {
        return nil;
    }
}

- (id)timelineFromController:(UIViewController *)controller {
    id timeline = [self performObjectSelector:@selector(timeline) object:controller];
    if (timeline) return timeline;
    return [self valueForKeySafely:@"timeline" object:controller];
}

- (UIViewController *)latestTimelineControllerFromHomeContainer:(UIViewController *)container {
    UIViewController *vc = [self performObjectSelector:@selector(latestTimelineViewController) object:container];
    if (vc) return vc;
    vc = [self valueForKeySafely:@"latestTimelineViewController" object:container];
    if (vc) return vc;
    vc = [self valueForKeySafely:@"_latestTimelineViewController" object:container];
    return vc;
}

- (NSArray *)pinnedTimelineModelsFromHomeContainer:(UIViewController *)container {
    id models = [self valueForKeySafely:@"pinnedTimelineModels" object:container];
    if (!models) models = [self valueForKeySafely:@"_pinnedTimelineModels" object:container];
    return [models isKindOfClass:NSArray.class] ? models : @[];
}

- (NSString *)titleForPinnedTimelineModel:(id)model index:(NSUInteger)index {
    for (NSString *key in @[@"displayName", @"title", @"name", @"identifier"]) {
        id value = [self valueForKeySafely:key object:model];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return [NSString stringWithFormat:@"List %lu", (unsigned long)(index + 1)];
}

- (id)homeFeatureFactoryCandidateFromHomeContainer:(UIViewController *)container {
    SEL homeSel = @selector(homeTimelineItemsViewControllerWithAccount:timeline:);
    SEL pinnedSel = @selector(pinnedTimelineViewControllerWithAccount:pinnedTimeline:);
    NSMutableArray *candidates = [NSMutableArray array];
    if (container) [candidates addObject:container];
    NSArray<NSString *> *factoryKeys = @[
        @"homeFeatures", @"homeFeature", @"twitterHomeFeature", @"feature",
        @"featureImplementation", @"implementation", @"homeFeatureObjC", @"twitterHomeFeatureObjC"
    ];
    for (NSString *key in factoryKeys) {
        id value = [self valueForKeySafely:key object:container];
        if (value) [candidates addObject:value];
    }
    for (id object in [candidates copy]) {
        for (NSString *key in factoryKeys) {
            id value = [self valueForKeySafely:key object:object];
            if (value && ![candidates containsObject:value]) [candidates addObject:value];
        }
    }
    for (NSString *className in @[
        @"TFNTwitterHomeFeature",
        @"TwitterHomeFeatureImplementation.TwitterHomeFeatureImplementation",
        @"_TtC32TwitterHomeFeatureImplementation32TwitterHomeFeatureImplementation"
    ]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        [candidates addObject:cls];
    }
    for (id candidate in candidates) {
        if ([candidate respondsToSelector:homeSel] || [candidate respondsToSelector:pinnedSel]) return candidate;
    }
    return nil;
}

- (UIViewController *)newFollowingTimelineControllerWithAccount:(id)account timeline:(id)timeline factory:(id)factory {
    if (!account || !timeline) return nil;
    SEL factorySel = @selector(homeTimelineItemsViewControllerWithAccount:timeline:);
    if (factory && [factory respondsToSelector:factorySel]) {
        @try {
            UIViewController *vc = ((id (*)(id, SEL, id, id))objc_msgSend)(factory, factorySel, account, timeline);
            if (vc) return vc;
        } @catch (NSException *e) {
            self.lastNativeTabFailure = [NSString stringWithFormat:@"Following factory failed: %@", e.reason ?: e.name];
        }
    }
    Class cls = NSClassFromString(@"THFHomeTimelineItemsViewController");
    SEL initSel = @selector(initWithAccount:timeline:);
    if (cls && [cls instancesRespondToSelector:initSel]) {
        @try {
            UIViewController *vc = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initSel, account, timeline);
            if (vc) return vc;
        } @catch (NSException *e) {
            self.lastNativeTabFailure = [NSString stringWithFormat:@"Following init failed: %@", e.reason ?: e.name];
        }
    }
    if (!self.lastNativeTabFailure.length) self.lastNativeTabFailure = @"Unable to create Following timeline controller.";
    return nil;
}

- (UIViewController *)newPinnedTimelineControllerWithAccount:(id)account model:(id)model factory:(id)factory {
    if (!account || !model) return nil;
    SEL sel = @selector(pinnedTimelineViewControllerWithAccount:pinnedTimeline:);
    if (factory && [factory respondsToSelector:sel]) {
        @try {
            return ((id (*)(id, SEL, id, id))objc_msgSend)(factory, sel, account, model);
        } @catch (NSException *e) {
            self.lastNativeTabFailure = [NSString stringWithFormat:@"Pinned factory failed: %@", e.reason ?: e.name];
        }
    }
    if (!self.lastNativeTabFailure.length) self.lastNativeTabFailure = @"Unable to create pinned list timeline controllers.";
    return nil;
}

- (void)addTimelineColumnsFromHomeContainer {
    self.lastNativeTabFailure = nil;
    UIViewController *container = self.sourceHomeContainer ?: [self homeContainerFromControllerTree:self.sourceTabBarController ?: [self activeTabBarController]];
    self.sourceHomeContainer = container;
    id account = self.sourceAccount ?: [self accountFromControllerTree:self.sourceTabBarController ?: container];
    self.sourceAccount = account;
    id factory = [self homeFeatureFactoryCandidateFromHomeContainer:container];

    UIViewController *latestVC = [self latestTimelineControllerFromHomeContainer:container];
    id latestTimeline = [self timelineFromController:latestVC];
    UIViewController *following = [self newFollowingTimelineControllerWithAccount:account timeline:latestTimeline factory:factory];
    if (following) [self addTimelineColumnWithTitle:@"フォロー中" controller:following];

    NSArray *models = [self pinnedTimelineModelsFromHomeContainer:container];
    NSUInteger index = 0;
    for (id model in models) {
        UIViewController *pinned = [self newPinnedTimelineControllerWithAccount:account model:model factory:factory];
        if (pinned) [self addTimelineColumnWithTitle:[self titleForPinnedTimelineModel:model index:index] controller:pinned];
        index++;
    }

    if (self.stackView.arrangedSubviews.count == 0 && !self.lastNativeTabFailure.length) {
        self.lastNativeTabFailure = [NSString stringWithFormat:@"No timeline columns. container=%@ account=%@ latest=%@ pinned=%lu factory=%@",
            container ? NSStringFromClass(container.class) : @"(nil)",
            account ? NSStringFromClass([account class]) : @"(nil)",
            latestTimeline ? NSStringFromClass([latestTimeline class]) : @"(nil)",
            (unsigned long)models.count,
            factory ? NSStringFromClass([factory class]) : @"(nil)"];
    }
}

- (void)addTimelineColumnWithTitle:(NSString *)title controller:(UIViewController *)controller {
    UIView *column = [[UIView alloc] initWithFrame:CGRectZero];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.backgroundColor = UIColor.systemBackgroundColor;
    [self.stackView addArrangedSubview:column];

    NSLayoutConstraint *width = [column.widthAnchor constraintEqualToConstant:360.0];
    width.active = YES;
    [self.widthConstraints addObject:width];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title.length ? title : @"Timeline";
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    [column addSubview:label];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = UIColor.separatorColor;
    [column addSubview:separator];

    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:column.topAnchor],
        [label.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-1.0],
        [label.heightAnchor constraintEqualToConstant:28.0],
        [separator.topAnchor constraintEqualToAnchor:column.topAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:column.bottomAnchor],
        [separator.widthAnchor constraintEqualToConstant:1.0],
        [content.topAnchor constraintEqualToAnchor:label.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-1.0],
        [content.bottomAnchor constraintEqualToAnchor:column.bottomAnchor]
    ]];

    [self addChildViewController:controller];
    controller.view.translatesAutoresizingMaskIntoConstraints = NO;
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    [content addSubview:controller.view];
    [NSLayoutConstraint activateConstraints:@[
        [controller.view.topAnchor constraintEqualToAnchor:content.topAnchor],
        [controller.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [controller.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [controller.view.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [controller loadViewIfNeeded];
    [controller didMoveToParentViewController:self];
    [self.columnControllers addObject:controller];
}

- (void)addNativeColumnWithTitle:(NSString *)title page:(NSString *)page account:(id)account tabs:(NSDictionary<NSString *, id> *)tabs {
    UIView *column = [[UIView alloc] initWithFrame:CGRectZero];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.backgroundColor = UIColor.systemBackgroundColor;
    [self.stackView addArrangedSubview:column];

    NSLayoutConstraint *width = [column.widthAnchor constraintEqualToConstant:360.0];
    width.active = YES;
    [self.widthConstraints addObject:width];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = UIColor.separatorColor;
    [column addSubview:separator];

    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [separator.topAnchor constraintEqualToAnchor:column.topAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:column.bottomAnchor],
        [separator.widthAnchor constraintEqualToConstant:1.0],
        [content.topAnchor constraintEqualToAnchor:column.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-1.0],
        [content.bottomAnchor constraintEqualToAnchor:column.bottomAnchor]
    ]];

    UIViewController *controller = [self newTabNavigationControllerForPage:page account:account tabs:tabs];
    if (!controller) {
        NSString *reason = self.lastNativeTabFailure.length ? self.lastNativeTabFailure : @"Unable to load native tab";
        [self addPlaceholderInView:content message:[NSString stringWithFormat:@"%@\n%@", title ?: page, reason]];
        return;
    }

    [self addChildViewController:controller];
    controller.view.translatesAutoresizingMaskIntoConstraints = NO;
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    [content addSubview:controller.view];
    [NSLayoutConstraint activateConstraints:@[
        [controller.view.topAnchor constraintEqualToAnchor:content.topAnchor],
        [controller.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [controller.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [controller.view.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [controller loadViewIfNeeded];
    [controller didMoveToParentViewController:self];
    [self.columnControllers addObject:controller];
}

- (void)addPlaceholderColumnWithTitle:(NSString *)title message:(NSString *)message {
    UIView *column = [[UIView alloc] initWithFrame:CGRectZero];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.backgroundColor = UIColor.systemBackgroundColor;
    [self.stackView addArrangedSubview:column];
    NSLayoutConstraint *width = [column.widthAnchor constraintEqualToConstant:360.0];
    width.active = YES;
    [self.widthConstraints addObject:width];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    [column addSubview:label];
    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:column.topAnchor constant:8.0],
        [label.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [label.heightAnchor constraintEqualToConstant:24.0],
        [content.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6.0],
        [content.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:column.bottomAnchor]
    ]];
    [self addPlaceholderInView:content message:message];
}

- (void)addPlaceholderInView:(UIView *)view message:(NSString *)message {
    UILabel *fallback = [[UILabel alloc] initWithFrame:CGRectZero];
    fallback.translatesAutoresizingMaskIntoConstraints = NO;
    fallback.text = message;
    fallback.textColor = UIColor.secondaryLabelColor;
    fallback.textAlignment = NSTextAlignmentCenter;
    fallback.numberOfLines = 0;
    [view addSubview:fallback];
    [NSLayoutConstraint activateConstraints:@[
        [fallback.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16.0],
        [fallback.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16.0],
        [fallback.centerYAnchor constraintEqualToAnchor:view.centerYAnchor]
    ]];
}

- (UIViewController *)newTabNavigationControllerForPage:(NSString *)page account:(id)account tabs:(NSDictionary<NSString *, id> *)tabs {
    self.lastNativeTabFailure = nil;
    id tabView = tabs[page];
    Class cls = NSClassFromString(@"T1TabNavigationController");
    SEL initSel = @selector(initWithAccount:tabView:);
    if (!cls) {
        self.lastNativeTabFailure = @"Missing T1TabNavigationController";
        return nil;
    }
    if (!account) {
        self.lastNativeTabFailure = @"Missing account";
        return nil;
    }
    if (!tabView) {
        self.lastNativeTabFailure = [NSString stringWithFormat:@"Missing tabView for %@", page ?: @"(nil)"];
        return nil;
    }
    if (![cls instancesRespondToSelector:initSel]) {
        self.lastNativeTabFailure = @"Missing initWithAccount:tabView:";
        return nil;
    }

    UIViewController *controller = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initSel, account, tabView);
    if (!controller) {
        self.lastNativeTabFailure = @"Native tab init returned nil";
        return nil;
    }
    if ([controller respondsToSelector:@selector(setupForTabBarPresentation)]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(setupForTabBarPresentation));
    }
    return controller;
}

- (void)reloadColumns {
    for (UIViewController *controller in self.columnControllers) {
        [self reloadControllerTree:controller];
    }
}

- (CGFloat)scrollViewScore:(UIScrollView *)scrollView {
    if (!scrollView || scrollView.hidden || scrollView.alpha < 0.01 || scrollView.bounds.size.width < 80.0 || scrollView.bounds.size.height < 120.0) return 0;
    CGFloat score = scrollView.bounds.size.width * scrollView.bounds.size.height;
    BOOL vertical = scrollView.alwaysBounceVertical || scrollView.contentSize.height > scrollView.bounds.size.height + 80.0;
    BOOL horizontalOnly = scrollView.contentSize.width > scrollView.bounds.size.width * 1.4 && scrollView.contentSize.height <= scrollView.bounds.size.height + 80.0;
    if (vertical) score *= 3.0;
    if (horizontalOnly) score *= 0.15;
    return score;
}

- (UIScrollView *)mainScrollViewInView:(UIView *)view bestScore:(CGFloat *)bestScore {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    UIScrollView *best = nil;
    if ([view isKindOfClass:UIScrollView.class]) {
        CGFloat score = [self scrollViewScore:(UIScrollView *)view];
        if (score > *bestScore) {
            *bestScore = score;
            best = (UIScrollView *)view;
        }
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *candidate = [self mainScrollViewInView:subview bestScore:bestScore];
        if (candidate) best = candidate;
    }
    return best;
}

- (UIScrollView *)mainScrollViewForController:(UIViewController *)controller {
    if (!controller || ![controller isViewLoaded]) return nil;
    CGFloat bestScore = 0;
    return [self mainScrollViewInView:controller.view bestScore:&bestScore];
}

- (BOOL)controllerTreeIsInteracting:(UIViewController *)controller {
    UIScrollView *scrollView = [self mainScrollViewForController:controller];
    if (scrollView && (scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking)) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if ([self controllerTreeIsInteracting:child]) return YES;
    }
    return NO;
}

- (BOOL)controllerTreeIsAtTop:(UIViewController *)controller {
    UIScrollView *scrollView = [self mainScrollViewForController:controller];
    if (scrollView) {
        CGFloat topY = -scrollView.adjustedContentInset.top;
        return scrollView.contentOffset.y <= topY + 4.0;
    }
    for (UIViewController *child in controller.childViewControllers) {
        if ([self controllerTreeIsAtTop:child]) return YES;
    }
    return YES;
}

- (void)scrollControllerTreeToTop:(UIViewController *)controller animated:(BOOL)animated {
    UIScrollView *scrollView = [self mainScrollViewForController:controller];
    if (scrollView) {
        CGPoint offset = scrollView.contentOffset;
        offset.y = -scrollView.adjustedContentInset.top;
        [scrollView setContentOffset:offset animated:animated];
    }
    for (UIViewController *child in controller.childViewControllers) {
        [self scrollControllerTreeToTop:child animated:animated];
    }
}

- (void)revealAllColumns {
    self.tweetsNoticeButton.hidden = YES;
    for (UIViewController *controller in self.columnControllers) {
        [self scrollControllerTreeToTop:controller animated:NO];
        [self reloadControllerTree:controller];
    }
}

- (void)streamColumns {
    BOOL hasAwayColumn = NO;
    for (UIViewController *controller in self.columnControllers) {
        if ([self controllerTreeIsInteracting:controller]) {
            hasAwayColumn = YES;
            continue;
        }
        if ([self controllerTreeIsAtTop:controller]) {
            [self reloadControllerTree:controller];
            [self scrollControllerTreeToTop:controller animated:NO];
        } else {
            hasAwayColumn = YES;
        }
    }
    self.tweetsNoticeButton.hidden = !hasAwayColumn;
}

- (void)reloadControllerTree:(UIViewController *)controller {
    if (!controller) return;
    id timeline = nil;
    @try {
        if ([controller respondsToSelector:@selector(timeline)]) timeline = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(timeline));
    } @catch (NSException *e) {
        timeline = nil;
    }
    id refreshTarget = timeline ?: controller;
    if ([refreshTarget respondsToSelector:@selector(refreshWithSource:completion:)]) {
        void (^completion)(void) = ^{};
        ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(refreshTarget, @selector(refreshWithSource:completion:), 0, completion);
    }
    SEL selectors[] = {
        @selector(reloadViewControllerData),
        @selector(_tfn_reloadViewControllerDataIfNeeded),
        @selector(reloadVisibleViewControllers),
        @selector(reloadDataIfNeeded)
    };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(SEL); i++) {
        SEL sel = selectors[i];
        if ([controller respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, sel);
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        [self reloadControllerTree:child];
    }
}

- (BOOL)columnsAutoRefreshEnabled {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"auto_stream_timeline"]) return NO;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (NSTimeInterval)columnsRefreshInterval {
    NSInteger seconds = [[NSUserDefaults standardUserDefaults] integerForKey:@"auto_stream_interval"];
    return (NSTimeInterval)(seconds >= 5 ? seconds : 20);
}

- (void)startColumnRefreshTimer {
    [self stopColumnRefreshTimer];
    if (![self columnsAutoRefreshEnabled]) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:[self columnsRefreshInterval] repeats:YES block:^(NSTimer *t) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        if (![strongSelf columnsAutoRefreshEnabled]) return;
        [strongSelf streamColumns];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:UITrackingRunLoopMode];
    self.refreshTimer = timer;
}

- (void)stopColumnRefreshTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)showColumnEditor {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Columns" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"すべて更新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self reloadColumns];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"全カラムを上へ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self revealAllColumns];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"診断コピー" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = [self diagnosticText];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self rebuildColumns];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)closeColumns {
    BHTDismissColumnsMode();
}

- (NSString *)diagnosticText {
    NSMutableString *s = [NSMutableString string];
    UIViewController *container = self.sourceHomeContainer;
    id account = self.sourceAccount;
    id factory = [self homeFeatureFactoryCandidateFromHomeContainer:container];
    UIViewController *latest = [self latestTimelineControllerFromHomeContainer:container];
    id latestTimeline = [self timelineFromController:latest];
    NSArray *models = [self pinnedTimelineModelsFromHomeContainer:container];
    [s appendFormat:@"nfbColumns separate=1 controller=%@ window=%d columns=%lu\n",
        NSStringFromClass(self.class), self.view.window ? 1 : 0, (unsigned long)self.columnControllers.count];
    [s appendFormat:@"source container=%@ account=%@ latestVC=%@ latestTimeline=%@ pinnedModels=%lu factory=%@ failure=%@\n",
        container ? NSStringFromClass(container.class) : @"(nil)",
        account ? NSStringFromClass([account class]) : @"(nil)",
        latest ? NSStringFromClass(latest.class) : @"(nil)",
        latestTimeline ? NSStringFromClass([latestTimeline class]) : @"(nil)",
        (unsigned long)models.count,
        factory ? NSStringFromClass([factory class]) : @"(nil)",
        self.lastNativeTabFailure ?: @"(nil)"];
    NSUInteger idx = 0;
    for (UIViewController *controller in self.columnControllers) {
        UIScrollView *scrollView = [self mainScrollViewForController:controller];
        CGFloat topY = scrollView ? -scrollView.adjustedContentInset.top : 0.0;
        [s appendFormat:@"column[%lu] class=%@ loaded=%d window=%d atTop=%d frame=(%.1f,%.1f,%.1f,%.1f)",
            (unsigned long)idx,
            NSStringFromClass(controller.class),
            [controller isViewLoaded] ? 1 : 0,
            ([controller isViewLoaded] && controller.view.window) ? 1 : 0,
            [self controllerTreeIsAtTop:controller] ? 1 : 0,
            controller.view.frame.origin.x, controller.view.frame.origin.y,
            controller.view.frame.size.width, controller.view.frame.size.height];
        if (scrollView) {
            [s appendFormat:@" scroll=%@ offset=(%.1f,%.1f) topY=%.1f content=(%.1f,%.1f) bounds=(%.1f,%.1f)",
                NSStringFromClass(scrollView.class),
                scrollView.contentOffset.x, scrollView.contentOffset.y, topY,
                scrollView.contentSize.width, scrollView.contentSize.height,
                scrollView.bounds.size.width, scrollView.bounds.size.height];
        }
        [s appendString:@"\n"];
        idx++;
    }
    return s;
}

@end
