#import <UIKit/UIKit.h>
#import <objc/message.h>

@interface NFBColumnsViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *widthConstraints;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *columnControllers;
@end

@implementation NFBColumnsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Columns";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.widthConstraints = [NSMutableArray array];
    self.columnControllers = [NSMutableArray array];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(closeColumns)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reloadColumns)];

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
    id account = [self accountFromControllerTree:tabBarController];
    NSDictionary<NSString *, id> *tabs = [self tabViewsByPageFromTabBarController:tabBarController];

    NSArray<NSDictionary<NSString *, NSString *> *> *columns = @[
        @{@"title": @"Home", @"page": @"home"},
        @{@"title": @"Search", @"page": @"guide"},
        @{@"title": @"Notifications", @"page": @"ntab"},
        @{@"title": @"Messages", @"page": @"messages"}
    ];
    for (NSDictionary<NSString *, NSString *> *column in columns) {
        [self addNativeColumnWithTitle:column[@"title"]
                                  page:column[@"page"]
                               account:account
                                  tabs:tabs];
    }
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
    NSArray *tabViews = nil;
    @try {
        tabViews = [tabBarController valueForKey:@"tabViews"];
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

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    [column addSubview:label];

    UIView *content = [[UIView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [separator.topAnchor constraintEqualToAnchor:column.topAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:column.bottomAnchor],
        [separator.widthAnchor constraintEqualToConstant:1.0],
        [label.topAnchor constraintEqualToAnchor:column.topAnchor constant:8.0],
        [label.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:10.0],
        [label.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-10.0],
        [label.heightAnchor constraintEqualToConstant:24.0],
        [content.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6.0],
        [content.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-1.0],
        [content.bottomAnchor constraintEqualToAnchor:column.bottomAnchor]
    ]];

    UIViewController *controller = [self newTabNavigationControllerForPage:page account:account tabs:tabs];
    if (!controller) {
        UILabel *fallback = [[UILabel alloc] initWithFrame:CGRectZero];
        fallback.translatesAutoresizingMaskIntoConstraints = NO;
        fallback.text = @"Unable to load native tab";
        fallback.textColor = UIColor.secondaryLabelColor;
        fallback.textAlignment = NSTextAlignmentCenter;
        fallback.numberOfLines = 0;
        [content addSubview:fallback];
        [NSLayoutConstraint activateConstraints:@[
            [fallback.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
            [fallback.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
            [fallback.centerYAnchor constraintEqualToAnchor:content.centerYAnchor]
        ]];
        return;
    }

    [self addChildViewController:controller];
    controller.view.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:controller.view];
    [NSLayoutConstraint activateConstraints:@[
        [controller.view.topAnchor constraintEqualToAnchor:content.topAnchor],
        [controller.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [controller.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [controller.view.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [controller didMoveToParentViewController:self];
    [self.columnControllers addObject:controller];
}

- (UIViewController *)newTabNavigationControllerForPage:(NSString *)page account:(id)account tabs:(NSDictionary<NSString *, id> *)tabs {
    id tabView = tabs[page];
    Class cls = NSClassFromString(@"T1TabNavigationController");
    SEL initSel = @selector(initWithAccount:tabView:);
    if (!cls || !account || !tabView || ![cls instancesRespondToSelector:initSel]) return nil;

    UIViewController *controller = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initSel, account, tabView);
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

- (void)closeColumns {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
