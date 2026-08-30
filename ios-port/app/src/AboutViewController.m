// AboutViewController.m — see AboutViewController.h for the contract.
#import "AboutViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"
#import <sys/utsname.h>

@interface AboutViewController ()
// Live status fields refreshed after a JIT attempt.
@property (nonatomic, strong) UILabel *coreValueLabel;
@property (nonatomic, strong) UILabel *statusValueLabel;
@property (nonatomic, strong) UILabel *jitValueLabel;
@property (nonatomic, strong) UIView  *jitDot;
@end

@implementation AboutViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.title.length ? self.title : @"About";
    self.view.backgroundColor = V3KBackground();

    // --- Scroll view filling the safe area ---
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:scroll];

    // --- Vertical content stack pinned inside the scroll view ---
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 18.0;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.layoutMargins = UIEdgeInsetsMake(24, 20, 40, 20);
    [scroll addSubview:stack];

    UILayoutGuide *frameG = scroll.frameLayoutGuide;
    UILayoutGuide *contentG = scroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:contentG.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:contentG.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:contentG.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:contentG.bottomAnchor],
        // Keep the content one screen wide so it never scrolls horizontally.
        [stack.widthAnchor constraintEqualToAnchor:frameG.widthAnchor],
    ]];

    [stack addArrangedSubview:[self buildHeader]];
    [stack addArrangedSubview:[self buildStatusCard]];
    [stack addArrangedSubview:[self buildJITButton]];
    [stack addArrangedSubview:[self buildAboutCard]];
    [stack addArrangedSubview:[self buildFooter]];

    [self refreshStatus];
}

#pragma mark - Header

- (UIView *)buildHeader {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.alignment = UIStackViewAlignmentLeading;
    v.spacing = 4.0;

    UILabel *wordmark = [[UILabel alloc] init];
    wordmark.text = @"VITA3K";
    wordmark.textColor = V3KGold();
    wordmark.font = [UIFont systemFontOfSize:44 weight:UIFontWeightHeavy];
    wordmark.adjustsFontSizeToFitWidth = YES;
    wordmark.minimumScaleFactor = 0.6;
    wordmark.numberOfLines = 1;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"PlayStation Vita Emulator — iOS";
    subtitle.textColor = V3KSubtext();
    subtitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    subtitle.numberOfLines = 0;

    [v addArrangedSubview:wordmark];
    [v addArrangedSubview:subtitle];
    return v;
}

#pragma mark - Status card

- (UIView *)buildStatusCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"info.circle.fill"
                                                  title:@"Build status"]];

    Vita3KCore *core = [Vita3KCore shared];

    self.coreValueLabel = [self valueLabel:core.coreVersion];
    self.statusValueLabel = [self valueLabel:core.statusLine];

    [body addArrangedSubview:[self fieldRowNamed:@"Core" value:self.coreValueLabel]];
    [body addArrangedSubview:[self hairline]];
    [body addArrangedSubview:[self fieldRowNamed:@"Status" value:self.statusValueLabel]];
    [body addArrangedSubview:[self hairline]];
    [body addArrangedSubview:[self fieldRowNamed:@"iOS"
                                           value:[self valueLabel:NSProcessInfo.processInfo.operatingSystemVersionString]]];
    [body addArrangedSubview:[self hairline]];
    [body addArrangedSubview:[self fieldRowNamed:@"Device"
                                           value:[self valueLabel:[self deviceDescription]]]];
    [body addArrangedSubview:[self hairline]];
    [body addArrangedSubview:[self buildJITStatusRow]];

    return card;
}

// A JIT status row with a colored indicator dot on the leading edge.
- (UIView *)buildJITStatusRow {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 6.0;
    dot.backgroundColor = V3KSubtext();
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:12.0],
        [dot.heightAnchor constraintEqualToConstant:12.0],
    ]];
    self.jitDot = dot;

    UIStackView *text = [[UIStackView alloc] init];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 2.0;

    UILabel *caption = [self captionLabel:@"JIT"];
    self.jitValueLabel = [self valueLabel:@"Unknown"];
    [text addArrangedSubview:caption];
    [text addArrangedSubview:self.jitValueLabel];

    [row addArrangedSubview:dot];
    [row addArrangedSubview:text];
    return row;
}

#pragma mark - Enable JIT button

- (UIView *)buildJITButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = V3KGold();
    button.layer.cornerRadius = 14.0;
    button.tintColor = V3KBackground();
    [button setTitle:@"Enable JIT (iOS 26)" forState:UIControlStateNormal];
    [button setTitleColor:V3KBackground() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) {
        UIImage *bolt = [UIImage systemImageNamed:@"bolt.fill"];
        [button setImage:bolt forState:UIControlStateNormal];
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 8);
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, -8);
    }
    button.accessibilityLabel = @"Enable JIT";
    [button addTarget:self action:@selector(enableJITTapped:) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:56.0].active = YES;
    return button;
}

- (void)enableJITTapped:(UIButton *)sender {
    sender.enabled = NO;
    [[Vita3KCore shared] prepareJITWithCompletion:^(BOOL ok, NSError *e) {
        sender.enabled = YES;
        [self presentJITResult:ok error:e];
    }];
}

- (void)presentJITResult:(BOOL)ok error:(NSError *)e {
    NSString *title = ok ? @"JIT Ready" : @"JIT Unavailable";
    NSString *message;
    if (ok) {
        message = @"JIT ready — the recompiler can run.";
    } else {
        message = e.localizedDescription.length
            ? e.localizedDescription
            : @"Could not prepare an executable arena. JIT needs StikDebug attached on iOS 18.4+ / 26.";
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];

    // Reflect the new core state in the status card.
    [self refreshStatus];
}

#pragma mark - About card

- (UIView *)buildAboutCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"hammer.fill"
                                                  title:@"About this build"]];

    NSString *p1 = @"This is a work-in-progress native port of Vita3K to iOS. It is not finished, and most titles will not boot yet.";
    NSString *p2 = @"The CPU/JIT core (dynarmic) and shader translation (SPIRV-Cross) already cross-compile for iOS. The rest of the emulator core is being wired in behind this front-end.";
    NSString *p3 = @"JIT requires StikDebug on iOS 18.4+ / 26. Without a debugger attached the recompiler cannot allocate an executable arena, so emulation stays disabled.";
    NSArray<NSString *> *paras = @[ p1, p2, p3 ];
    for (NSString *p in paras) {
        UILabel *l = [[UILabel alloc] init];
        l.text = p;
        l.textColor = V3KText();
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        l.numberOfLines = 0;
        [body addArrangedSubview:l];
    }
    return card;
}

#pragma mark - Footer

- (UIView *)buildFooter {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.alignment = UIStackViewAlignmentLeading;
    v.spacing = 10.0;

    [v addArrangedSubview:[self linkButtonTitle:@"vita3k.org"
                                         symbol:@"safari.fill"
                                         action:@selector(openWebsite)]];
    [v addArrangedSubview:[self linkButtonTitle:@"github.com/Vita3K/Vita3K"
                                         symbol:@"chevron.left.forwardslash.chevron.right"
                                         action:@selector(openGitHub)]];

    UILabel *legal = [[UILabel alloc] init];
    legal.text = @"Original Vita3K by the Vita3K team (GPLv2). iOS port in progress.";
    legal.textColor = V3KSubtext();
    legal.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    legal.numberOfLines = 0;
    [v setCustomSpacing:16.0 afterView:v.arrangedSubviews.lastObject];
    [v addArrangedSubview:legal];
    return v;
}

- (UIButton *)linkButtonTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tintColor = V3KGold();
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:V3KGold() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:symbol];
        [b setImage:img forState:UIControlStateNormal];
        b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    }
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)openWebsite { [self openURLString:@"https://vita3k.org"]; }
- (void)openGitHub  { [self openURLString:@"https://github.com/Vita3K/Vita3K"]; }

- (void)openURLString:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    if (!url) return;
    UIApplication *app = [UIApplication sharedApplication];
    if ([app canOpenURL:url]) {
        [app openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - Refresh

- (void)refreshStatus {
    Vita3KCore *core = [Vita3KCore shared];
    self.coreValueLabel.text = core.coreVersion;
    self.statusValueLabel.text = core.statusLine;

    BOOL ready = (core.jitState == V3KJITReady);
    NSString *jitText;
    UIColor *dotColor;
    switch (core.jitState) {
        case V3KJITReady:        jitText = @"Ready — executable arena prepared"; dotColor = V3KGreen();   break;
        case V3KJITFailed:       jitText = @"Failed — handshake did not complete"; dotColor = V3KMagenta(); break;
        case V3KJITUnavailable:  jitText = @"Unavailable — StikDebug not attached"; dotColor = V3KSubtext(); break;
        case V3KJITUnknown:
        default:                 jitText = @"Unknown — tap Enable JIT to probe";  dotColor = V3KSubtext(); break;
    }
    self.jitValueLabel.text = jitText;
    self.jitValueLabel.textColor = ready ? V3KGreen() : V3KText();
    self.jitDot.backgroundColor = dotColor;
}

#pragma mark - Small building blocks

// A rounded card container. Its content goes into the stack returned by
// -cardBodyIn:.
- (UIView *)makeCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = V3KCard();
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.14].CGColor;
    return card;
}

- (UIStackView *)cardBodyIn:(UIView *)card {
    UIStackView *body = [[UIStackView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.alignment = UIStackViewAlignmentFill;
    body.spacing = 12.0;
    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0],
    ]];
    return body;
}

- (UIView *)cardHeaderWithSymbol:(NSString *)symbol title:(NSString *)title {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8.0;

    if (@available(iOS 13.0, *)) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        icon.tintColor = V3KGold();
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [icon.widthAnchor constraintEqualToConstant:20.0].active = YES;
        [icon.heightAnchor constraintEqualToConstant:20.0].active = YES;
        [row addArrangedSubview:icon];
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.textColor = V3KGold();
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [row addArrangedSubview:label];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:spacer];
    return row;
}

// One labelled value: a small gold-ish caption above the value text.
- (UIView *)fieldRowNamed:(NSString *)name value:(UILabel *)valueLabel {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.alignment = UIStackViewAlignmentFill;
    v.spacing = 2.0;
    [v addArrangedSubview:[self captionLabel:name]];
    [v addArrangedSubview:valueLabel];
    return v;
}

- (UILabel *)captionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = [text uppercaseString];
    l.textColor = V3KSubtext();
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return l;
}

- (UILabel *)valueLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text ?: @"—";
    l.textColor = V3KText();
    l.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    l.numberOfLines = 0;
    return l;
}

- (UIView *)hairline {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [V3KSubtext() colorWithAlphaComponent:0.14];
    [line.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return line;
}

#pragma mark - Device info

- (NSString *)deviceDescription {
    struct utsname sysinfo;
    uname(&sysinfo);
    NSString *machine = [NSString stringWithCString:sysinfo.machine
                                           encoding:NSUTF8StringEncoding];
    UIDevice *device = [UIDevice currentDevice];
    if (machine.length) {
        return [NSString stringWithFormat:@"%@ (%@)", device.model, machine];
    }
    return device.model;
}

@end
