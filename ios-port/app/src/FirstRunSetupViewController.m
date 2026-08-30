// FirstRunSetupViewController.m — see the header for the contract.
#import "FirstRunSetupViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"

static NSString *const kV3KSetupDoneKey = @"v3k.setupDone";

@interface FirstRunSetupViewController () <UIScrollViewDelegate>
// Horizontal paging scroll view holding the three step pages.
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, assign) NSInteger currentPage;

// Inline JIT probe result (step 2).
@property (nonatomic, strong) UIImageView *jitResultIcon;
@property (nonatomic, strong) UILabel *jitResultLabel;
@end

@implementation FirstRunSetupViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = V3KBackground();
    self.currentPage = 0;

    // --- Top bar: small wordmark + a Skip button ---
    UILabel *wordmark = [[UILabel alloc] init];
    wordmark.translatesAutoresizingMaskIntoConstraints = NO;
    wordmark.text = @"VITA3K SETUP";
    wordmark.textColor = V3KGold();
    wordmark.font = [UIFont systemFontOfSize:14 weight:UIFontWeightHeavy];
    [self.view addSubview:wordmark];

    UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
    skip.translatesAutoresizingMaskIntoConstraints = NO;
    skip.tintColor = V3KSubtext();
    [skip setTitle:@"Skip" forState:UIControlStateNormal];
    [skip setTitleColor:V3KSubtext() forState:UIControlStateNormal];
    skip.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    skip.accessibilityLabel = @"Skip setup";
    [skip addTarget:self action:@selector(finishSetup) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:skip];

    // --- Paging scroll view ---
    UIScrollView *pager = [[UIScrollView alloc] init];
    pager.translatesAutoresizingMaskIntoConstraints = NO;
    pager.pagingEnabled = YES;
    pager.showsHorizontalScrollIndicator = NO;
    pager.showsVerticalScrollIndicator = NO;
    pager.alwaysBounceHorizontal = YES;
    pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    pager.backgroundColor = [UIColor clearColor];
    pager.delegate = self;
    [self.view addSubview:pager];
    self.pager = pager;

    // --- Page dots ---
    UIPageControl *dots = [[UIPageControl alloc] init];
    dots.translatesAutoresizingMaskIntoConstraints = NO;
    dots.numberOfPages = 3;
    dots.currentPage = 0;
    dots.currentPageIndicatorTintColor = V3KGold();
    dots.pageIndicatorTintColor = [V3KSubtext() colorWithAlphaComponent:0.4];
    dots.userInteractionEnabled = NO;
    [self.view addSubview:dots];
    self.pageControl = dots;

    // --- The three pages laid out edge-to-edge inside the pager ---
    UIStackView *track = [[UIStackView alloc] init];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.axis = UILayoutConstraintAxisHorizontal;
    track.alignment = UIStackViewAlignmentFill;
    track.distribution = UIStackViewDistributionFill;
    track.spacing = 0.0;
    [pager addSubview:track];

    UIView *page1 = [self buildWelcomePage];
    UIView *page2 = [self buildJITPage];
    UIView *page3 = [self buildContentPage];
    for (UIView *p in @[ page1, page2, page3 ]) {
        [track addArrangedSubview:p];
        [p.widthAnchor constraintEqualToAnchor:pager.frameLayoutGuide.widthAnchor].active = YES;
        [p.heightAnchor constraintEqualToAnchor:pager.frameLayoutGuide.heightAnchor].active = YES;
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = pager.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [wordmark.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [wordmark.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20.0],

        [skip.centerYAnchor constraintEqualToAnchor:wordmark.centerYAnchor],
        [skip.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [skip.heightAnchor constraintEqualToConstant:44.0],

        [pager.topAnchor constraintEqualToAnchor:wordmark.bottomAnchor constant:8.0],
        [pager.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [pager.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [dots.topAnchor constraintEqualToAnchor:pager.bottomAnchor constant:4.0],
        [dots.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [dots.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [dots.heightAnchor constraintEqualToConstant:24.0],

        [track.topAnchor constraintEqualToAnchor:content.topAnchor],
        [track.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [track.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [track.heightAnchor constraintEqualToAnchor:pager.frameLayoutGuide.heightAnchor],
    ]];
}

// Keep the visible page aligned across rotation / size changes.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.pager.bounds.size.width;
    if (w <= 0.0) return;
    CGFloat expected = self.currentPage * w;
    if (!self.pager.isDragging && !self.pager.isDecelerating &&
        fabs(self.pager.contentOffset.x - expected) > 0.5) {
        self.pager.contentOffset = CGPointMake(expected, 0.0);
    }
}

#pragma mark - Pages

- (UIView *)buildWelcomePage {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [self addToBody:body
            symbol:@"gamecontroller.fill"
              step:@"Step 1 of 3"
             title:@"Welcome to Vita3K"
        paragraphs:@[
            @"Vita3K is an experimental PlayStation Vita emulator. This is a work-in-progress native iOS port — most titles will not boot yet, and features are still being wired in.",
            @"This quick setup gets the two things the emulator needs in place: a JIT recompiler, and some firmware plus games to run.",
        ]];

    [body addArrangedSubview:[self primaryButtonTitle:@"Continue"
                                               symbol:@"arrow.right"
                                               action:@selector(continueTapped)]];

    return [self pageHostingCard:card];
}

- (UIView *)buildJITPage {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [self addToBody:body
            symbol:@"bolt.fill"
              step:@"Step 2 of 3"
             title:@"Enable JIT"
        paragraphs:@[
            @"iOS 26 will not let an app recompile code on its own. Vita3K uses StikDebug to attach a debugger so the JIT can allocate an executable arena.",
            @"To enable it: launch this app, open StikDebug, choose \"Enable JIT\" for Vita3K, then come back here and test.",
        ]];

    // Inline JIT probe result row.
    UIStackView *resultRow = [[UIStackView alloc] init];
    resultRow.axis = UILayoutConstraintAxisHorizontal;
    resultRow.alignment = UIStackViewAlignmentCenter;
    resultRow.spacing = 10.0;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = V3KSubtext();
    if (@available(iOS 13.0, *)) {
        icon.image = [UIImage systemImageNamed:@"questionmark.circle"];
    }
    [icon.widthAnchor constraintEqualToConstant:22.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:22.0].active = YES;
    self.jitResultIcon = icon;

    UILabel *result = [[UILabel alloc] init];
    result.text = @"Not tested yet";
    result.textColor = V3KSubtext();
    result.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    result.numberOfLines = 0;
    self.jitResultLabel = result;

    [resultRow addArrangedSubview:icon];
    [resultRow addArrangedSubview:result];
    [body addArrangedSubview:resultRow];

    [body addArrangedSubview:[self secondaryButtonTitle:@"Test JIT now"
                                                 symbol:@"bolt.badge.a.fill"
                                                 action:@selector(testJITTapped)]];
    [body addArrangedSubview:[self primaryButtonTitle:@"Continue"
                                               symbol:@"arrow.right"
                                               action:@selector(continueTapped)]];

    return [self pageHostingCard:card];
}

- (UIView *)buildContentPage {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [self addToBody:body
            symbol:@"square.and.arrow.down.fill"
              step:@"Step 3 of 3"
             title:@"Add firmware & games"
        paragraphs:@[
            @"Vita3K needs the official PS Vita firmware (a PUP file) before games will run. You supply your own firmware and games — none are bundled.",
            @"Import a PUP and your games (.vpk) from the Library tab, using the Files picker. Everything is installed into the emulator's data folder on this device.",
        ]];

    [body addArrangedSubview:[self primaryButtonTitle:@"Done"
                                               symbol:@"checkmark"
                                               action:@selector(finishSetup)]];

    return [self pageHostingCard:card];
}

#pragma mark - Actions

- (void)continueTapped {
    NSInteger next = MIN(self.currentPage + 1, 2);
    [self scrollToPage:next animated:YES];
}

- (void)testJITTapped {
    self.jitResultLabel.text = @"Asking StikDebug for executable memory\u2026";
    [[Vita3KCore shared] prepareJITWithCompletion:^(BOOL ok, NSError *err) {
        [self showJITResult:ok error:err];
    }];
}

- (void)showJITResult:(BOOL)ok error:(NSError *)err {
    NSString *symbol;
    UIColor *color;
    NSString *text;
    if (ok) {
        symbol = @"checkmark.circle.fill";
        color = V3KGreen();
        text = @"JIT ready — the recompiler can run.";
    } else {
        symbol = @"xmark.circle.fill";
        color = V3KMagenta();
        text = err.localizedDescription.length
            ? err.localizedDescription
            : @"JIT unavailable — attach StikDebug and try again.";
    }

    if (@available(iOS 13.0, *)) {
        self.jitResultIcon.image = [UIImage systemImageNamed:symbol];
    }
    self.jitResultIcon.tintColor = color;
    self.jitResultLabel.text = text;
    self.jitResultLabel.textColor = color;
}

- (void)finishSetup {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kV3KSetupDoneKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (self.onFinish) {
        self.onFinish();
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)scrollToPage:(NSInteger)page animated:(BOOL)animated {
    self.currentPage = page;
    CGFloat w = self.pager.bounds.size.width;
    [self.pager setContentOffset:CGPointMake(page * w, 0.0) animated:animated];
    self.pageControl.currentPage = page;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat w = scrollView.bounds.size.width;
    if (w <= 0.0) return;
    NSInteger page = (NSInteger)lround(scrollView.contentOffset.x / w);
    page = MAX(0, MIN(page, 2));
    if (page != self.currentPage) {
        self.currentPage = page;
        self.pageControl.currentPage = page;
    }
}

#pragma mark - Building blocks

// Wrap a card in a vertically-scrollable page so tall content still fits on
// small screens; the card is pinned near the top with comfortable margins.
- (UIView *)pageHostingCard:(UIView *)card {
    UIScrollView *page = [[UIScrollView alloc] init];
    page.showsVerticalScrollIndicator = NO;
    page.alwaysBounceVertical = YES;
    page.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    page.backgroundColor = [UIColor clearColor];

    card.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:card];

    UILayoutGuide *content = page.contentLayoutGuide;
    UILayoutGuide *frame = page.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:content.topAnchor constant:24.0],
        [card.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24.0],
        [card.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor constant:20.0],
        [card.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor constant:-20.0],
        // Cap the card width on iPad so it reads as a centered column.
        [card.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [card.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
    ]];
    return page;
}

- (void)addToBody:(UIStackView *)body
           symbol:(NSString *)symbol
             step:(NSString *)step
            title:(NSString *)title
       paragraphs:(NSArray<NSString *> *)paragraphs {
    // Circular gold-tinted glyph badge.
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [V3KGold() colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 36.0;
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:72.0],
        [badge.heightAnchor constraintEqualToConstant:72.0],
    ]];
    if (@available(iOS 13.0, *)) {
        UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = V3KGold();
        [badge addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
            [glyph.widthAnchor constraintEqualToConstant:38.0],
            [glyph.heightAnchor constraintEqualToConstant:38.0],
        ]];
    }
    [body addArrangedSubview:badge];
    [body setCustomSpacing:18.0 afterView:badge];

    UILabel *stepLabel = [[UILabel alloc] init];
    stepLabel.text = [step uppercaseString];
    stepLabel.textColor = V3KSubtext();
    stepLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [body addArrangedSubview:stepLabel];
    [body setCustomSpacing:4.0 afterView:stepLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.textColor = V3KText();
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightHeavy];
    titleLabel.numberOfLines = 0;
    [body addArrangedSubview:titleLabel];
    [body setCustomSpacing:14.0 afterView:titleLabel];

    UILabel *last = nil;
    for (NSString *p in paragraphs) {
        UILabel *l = [[UILabel alloc] init];
        l.text = p;
        l.textColor = V3KSubtext();
        l.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        l.numberOfLines = 0;
        [body addArrangedSubview:l];
        last = l;
    }
    if (last) [body setCustomSpacing:22.0 afterView:last];
}

- (UIView *)makeCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = V3KCard();
    card.layer.cornerRadius = 20.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.14].CGColor;
    return card;
}

- (UIStackView *)cardBodyIn:(UIView *)card {
    UIStackView *body = [[UIStackView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.alignment = UIStackViewAlignmentFill;
    body.spacing = 10.0;
    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:28.0],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24.0],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24.0],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-28.0],
    ]];
    return body;
}

- (UIButton *)primaryButtonTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [self baseButtonTitle:title symbol:symbol action:action];
    b.backgroundColor = V3KGold();
    b.tintColor = V3KBackground();
    [b setTitleColor:V3KBackground() forState:UIControlStateNormal];
    return b;
}

- (UIButton *)secondaryButtonTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [self baseButtonTitle:title symbol:symbol action:action];
    b.backgroundColor = [V3KGold() colorWithAlphaComponent:0.14];
    b.tintColor = V3KGold();
    [b setTitleColor:V3KGold() forState:UIControlStateNormal];
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [V3KGold() colorWithAlphaComponent:0.5].CGColor;
    return b;
}

- (UIButton *)baseButtonTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.layer.cornerRadius = 14.0;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    b.accessibilityLabel = title;
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:symbol];
        [b setImage:img forState:UIControlStateNormal];
        b.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, -8);
    }
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:56.0].active = YES;
    return b;
}

@end
