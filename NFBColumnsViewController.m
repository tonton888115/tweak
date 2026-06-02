#import <UIKit/UIKit.h>
#import <objc/message.h>

@interface NFBColumnsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *widthConstraints;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *columnControllers;
@property (nonatomic, strong) id sourceAccount;
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
    self.title = @"Columns";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.widthConstraints = [NSMutableArray array];
    self.columnControllers = [NSMutableArray array];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:self
                                                                          action:@selector(closeColumns)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(reloadColumns)];
    self.navigationItem.leftBarButtonItems = @[done, refresh];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"編集"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(showColumnEditor)];

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

    UIViewController *tabBarController = [self activeTabBarController];
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
    CGFloat columnWidth = width >= 1000.0 ? floor((width - 2.0) / 3.0) : (width >= 700.0 ? floor((width - 1.0) / 2.0) : width);
    columnWidth = MAX(320.0, MIN(430.0, columnWidth));
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

    for (NSString *page in self.selectedPages) {
        id tabView = self.availableTabs[page];
        NSString *title = self.availableTitles[page];
        if (!tabView || !title.length) continue;
        [self addNativeColumnWithTitle:title page:page account:self.sourceAccount tabs:self.availableTabs];
    }
    if (self.stackView.arrangedSubviews.count == 0) {
        [self addPlaceholderColumnWithTitle:@"Columns" message:@"No native tabs are available."];
    }
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
        [strongSelf reloadColumns];
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.selectedPages = [[self defaultPages] mutableCopy];
        [self persistSelectedPages];
        [self rebuildColumns];
    }]];

    for (NSString *page in [self.selectedPages copy]) {
        NSString *title = self.availableTitles[page] ?: page;
        NSUInteger index = [self.selectedPages indexOfObject:page];
        if (index != NSNotFound && index > 0) {
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"← %@", title] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSUInteger i = [self.selectedPages indexOfObject:page];
                if (i != NSNotFound && i > 0) {
                    [self.selectedPages exchangeObjectAtIndex:i withObjectAtIndex:i - 1];
                    [self persistSelectedPages];
                    [self rebuildColumns];
                }
            }]];
        }
        if (index != NSNotFound && index + 1 < self.selectedPages.count) {
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ →", title] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSUInteger i = [self.selectedPages indexOfObject:page];
                if (i != NSNotFound && i + 1 < self.selectedPages.count) {
                    [self.selectedPages exchangeObjectAtIndex:i withObjectAtIndex:i + 1];
                    [self persistSelectedPages];
                    [self rebuildColumns];
                }
            }]];
        }
        if (self.selectedPages.count > 1) {
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"削除: %@", title] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                [self.selectedPages removeObject:page];
                [self persistSelectedPages];
                [self rebuildColumns];
            }]];
        }
    }

    for (NSString *page in [self preferredPageOrder]) {
        if (!self.availableTabs[page] || !self.availableTitles[page] || [self.selectedPages containsObject:page]) continue;
        NSString *title = self.availableTitles[page] ?: page;
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"追加: %@", title] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.selectedPages addObject:page];
            [self persistSelectedPages];
            [self rebuildColumns];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)closeColumns {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
