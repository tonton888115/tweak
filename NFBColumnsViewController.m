#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface NFBColumnsViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<WKWebView *> *webViews;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *widthConstraints;
@end

@implementation NFBColumnsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Columns";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.webViews = [NSMutableArray array];
    self.widthConstraints = [NSMutableArray array];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reloadColumns)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(closeColumns)];

    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceHorizontal = YES;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisHorizontal;
    self.stackView.spacing = 10.0;
    self.stackView.alignment = UIStackViewAlignmentFill;
    self.stackView.distribution = UIStackViewDistributionFill;
    [self.scrollView addSubview:self.stackView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:8.0],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:8.0],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-8.0],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-8.0],
        [self.stackView.heightAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.heightAnchor constant:-16.0]
    ]];

    [self addColumnWithTitle:@"Home" URL:@"https://x.com/home"];
    [self addColumnWithTitle:@"Notifications" URL:@"https://x.com/notifications"];
    [self addColumnWithTitle:@"Search" URL:@"https://x.com/explore"];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat columnWidth = width >= 900.0 ? 360.0 : MAX(300.0, width - 36.0);
    for (NSLayoutConstraint *constraint in self.widthConstraints) {
        constraint.constant = columnWidth;
    }
}

- (void)addColumnWithTitle:(NSString *)title URL:(NSString *)URLString {
    UIView *column = [[UIView alloc] initWithFrame:CGRectZero];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.backgroundColor = UIColor.secondarySystemBackgroundColor;
    column.layer.cornerRadius = 8.0;
    column.layer.masksToBounds = YES;
    [self.stackView addArrangedSubview:column];

    NSLayoutConstraint *width = [column.widthAnchor constraintEqualToConstant:340.0];
    width.active = YES;
    [self.widthConstraints addObject:width];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.labelColor;
    [column addSubview:label];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.allowsInlineMediaPlayback = YES;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.navigationDelegate = self;
    webView.backgroundColor = UIColor.systemBackgroundColor;
    webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    [column addSubview:webView];
    [self.webViews addObject:webView];

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:column.topAnchor constant:10.0],
        [label.leadingAnchor constraintEqualToAnchor:column.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:column.trailingAnchor constant:-12.0],
        [webView.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8.0],
        [webView.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:column.bottomAnchor]
    ]];

    NSURL *url = [NSURL URLWithString:URLString];
    if (url) [webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)reloadColumns {
    for (WKWebView *webView in self.webViews) {
        [webView reload];
    }
}

- (void)closeColumns {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
