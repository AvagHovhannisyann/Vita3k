// FirmwareInstallViewController.m — see the header for the contract.
#import "FirmwareInstallViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"

@interface FirmwareInstallViewController () <UIDocumentPickerDelegate>
// Status pill contents, refreshed whenever the screen appears or a PUP lands.
@property (nonatomic, strong) UIView *statusPill;
@property (nonatomic, strong) UIImageView *statusIcon;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation FirmwareInstallViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Firmware";
    self.view.backgroundColor = V3KBackground();

    // --- Scroll host so tall content still fits on small screens ---
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    scroll.backgroundColor = [UIColor clearColor];
    [self.view addSubview:scroll];

    // A single centered column, capped in width so it reads well on iPad.
    UIStackView *column = [[UIStackView alloc] init];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentFill;
    column.spacing = 18.0;
    [scroll addSubview:column];

    UILayoutGuide *frame = scroll.frameLayoutGuide;
    UILayoutGuide *content = scroll.contentLayoutGuide;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [column.topAnchor constraintEqualToAnchor:content.topAnchor constant:24.0],
        [column.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-32.0],
        [column.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor constant:20.0],
        [column.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor constant:-20.0],
        [column.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [column.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
    ]];

    [column addArrangedSubview:[self buildHeader]];
    [column addArrangedSubview:[self buildStatusCard]];
    [column addArrangedSubview:[self buildImportCard]];
    [column addArrangedSubview:[self buildInfoCard]];

    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // A PUP may have been imported elsewhere (or installed on a prior boot).
    [self refreshStatus];
}

#pragma mark - Sections

- (UIView *)buildHeader {
    UIStackView *head = [[UIStackView alloc] init];
    head.axis = UILayoutConstraintAxisVertical;
    head.alignment = UIStackViewAlignmentLeading;
    head.spacing = 6.0;

    // Circular gold-tinted glyph badge.
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [V3KGold() colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 34.0;
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:68.0],
        [badge.heightAnchor constraintEqualToConstant:68.0],
    ]];
    if (@available(iOS 13.0, *)) {
        UIImageView *glyph =
            [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cpu.fill"]];
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = V3KGold();
        [badge addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
            [glyph.widthAnchor constraintEqualToConstant:36.0],
            [glyph.heightAnchor constraintEqualToConstant:36.0],
        ]];
    }
    [head addArrangedSubview:badge];
    [head setCustomSpacing:16.0 afterView:badge];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"PS Vita Firmware";
    title.textColor = V3KText();
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightHeavy];
    title.numberOfLines = 0;
    [head addArrangedSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"Required to run most games. You provide it yourself.";
    sub.textColor = V3KSubtext();
    sub.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    sub.numberOfLines = 0;
    [head addArrangedSubview:sub];

    return head;
}

- (UIView *)buildStatusCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card padding:20.0];

    UILabel *heading = [self sectionHeading:@"Status"];
    [body addArrangedSubview:heading];
    [body setCustomSpacing:14.0 afterView:heading];

    // The status pill: an icon + label whose colour and text are filled in by
    // -refreshStatus (green "Installed" / gold "Not installed").
    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.layer.cornerRadius = 14.0;
    self.statusPill = pill;

    UIStackView *pillRow = [[UIStackView alloc] init];
    pillRow.translatesAutoresizingMaskIntoConstraints = NO;
    pillRow.axis = UILayoutConstraintAxisHorizontal;
    pillRow.alignment = UIStackViewAlignmentCenter;
    pillRow.spacing = 10.0;
    [pill addSubview:pillRow];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24.0].active = YES;
    self.statusIcon = icon;

    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    label.numberOfLines = 0;
    self.statusLabel = label;

    [pillRow addArrangedSubview:icon];
    [pillRow addArrangedSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [pillRow.topAnchor constraintEqualToAnchor:pill.topAnchor constant:14.0],
        [pillRow.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-14.0],
        [pillRow.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:16.0],
        [pillRow.trailingAnchor constraintLessThanOrEqualToAnchor:pill.trailingAnchor constant:-16.0],
    ]];

    [body addArrangedSubview:pill];
    return card;
}

- (UIView *)buildImportCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card padding:20.0];

    UILabel *heading = [self sectionHeading:@"Import"];
    [body addArrangedSubview:heading];
    [body setCustomSpacing:8.0 afterView:heading];

    UILabel *blurb = [[UILabel alloc] init];
    blurb.text = @"Choose your PS Vita firmware update file (PSP2UPDAT.PUP). "
                 @"It is copied into the emulator's data folder on this device.";
    blurb.textColor = V3KSubtext();
    blurb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    blurb.numberOfLines = 0;
    [body addArrangedSubview:blurb];
    [body setCustomSpacing:16.0 afterView:blurb];

    UIButton *importBtn = [self primaryButtonTitle:@"Import firmware (.PUP)"
                                            symbol:@"square.and.arrow.down.fill"
                                            action:@selector(importTapped)];
    [body addArrangedSubview:importBtn];

    return card;
}

- (UIView *)buildInfoCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card padding:20.0];

    UILabel *heading = [self sectionHeading:@"About the firmware"];
    [body addArrangedSubview:heading];
    [body setCustomSpacing:12.0 afterView:heading];

    NSString *legalText =
        @"You must provide your own firmware, legally — dump it from your own "
        @"PS Vita or download it from Sony's official update servers. Vita3K "
        @"does not bundle, host, or link to firmware.";
    NSString *gamesText =
        @"Most games will not boot until the firmware is installed. It supplies "
        @"the system modules (fonts, codecs, and services) that titles rely on.";
    NSString *bootText =
        @"An imported PUP is staged now and installed into the emulator on the "
        @"next boot. The status above updates once the firmware is in place.";

    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"exclamationmark.shield.fill", legalText ],
        @[ @"gamecontroller.fill", gamesText ],
        @[ @"arrow.triangle.2.circlepath", bootText ],
    ];

    UILabel *lastLabel = nil;
    for (NSArray<NSString *> *row in rows) {
        UIStackView *line = [[UIStackView alloc] init];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.alignment = UIStackViewAlignmentTop;
        line.spacing = 12.0;

        UIImageView *glyph = [[UIImageView alloc] init];
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = V3KGold();
        if (@available(iOS 13.0, *)) {
            glyph.image = [UIImage systemImageNamed:row[0]];
        }
        [glyph.widthAnchor constraintEqualToConstant:22.0].active = YES;
        [glyph.heightAnchor constraintEqualToConstant:22.0].active = YES;

        UILabel *text = [[UILabel alloc] init];
        text.text = row[1];
        text.textColor = V3KSubtext();
        text.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        text.numberOfLines = 0;

        [line addArrangedSubview:glyph];
        [line addArrangedSubview:text];
        [body addArrangedSubview:line];
        lastLabel = text;
        [body setCustomSpacing:14.0 afterView:line];
    }
    (void)lastLabel;

    return card;
}

#pragma mark - Status

- (void)refreshStatus {
    BOOL installed = [[Vita3KCore shared] firmwareInstalled];

    NSString *symbol = installed ? @"checkmark.seal.fill" : @"exclamationmark.triangle.fill";
    UIColor *color = installed ? V3KGreen() : V3KGold();
    NSString *text = installed ? @"Installed" : @"Not installed";

    if (@available(iOS 13.0, *)) {
        self.statusIcon.image = [UIImage systemImageNamed:symbol];
    }
    self.statusIcon.tintColor = color;
    self.statusLabel.text = text;
    self.statusLabel.textColor = color;
    self.statusPill.backgroundColor = [color colorWithAlphaComponent:0.14];
    self.statusPill.layer.borderWidth = 1.0;
    self.statusPill.layer.borderColor = [color colorWithAlphaComponent:0.45].CGColor;
    self.statusPill.accessibilityLabel =
        [NSString stringWithFormat:@"Firmware status: %@", text];
}

#pragma mark - Actions

- (void)importTapped {
    // A firmware PUP has no dedicated UTI, so accept any file (public.item) and
    // let importFirmwareAtURL: validate it. Matches the library's picker usage.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item" ]
                                                              inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }

    // Decrypting and extracting a PUP takes a while on a phone, so show a
    // non-dismissable progress alert rather than freezing the screen.
    UIAlertController *hud =
        [UIAlertController alertControllerWithTitle:@"Installing firmware"
                                            message:@"Extracting\u2026  0%"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];

    [[Vita3KCore shared] installFirmwareAtURL:url
        progress:^(double f) {
            dispatch_async(dispatch_get_main_queue(), ^{
                hud.message = [NSString stringWithFormat:@"Extracting\u2026  %d%%", (int)lround(f * 100)];
            });
        }
        completion:^(BOOL ok, NSString *version, NSError *error) {
            [self refreshStatus];
            [hud dismissViewControllerAnimated:YES completion:^{
                NSString *title = ok ? @"Firmware installed" : @"Install failed";
                NSString *message = ok
                    ? (version.length
                        ? [NSString stringWithFormat:@"PS Vita firmware %@ is installed. Games can now load "
                                                      "the system modules they need.", version]
                        : @"The firmware is installed.")
                    : (error.localizedDescription.length
                        ? error.localizedDescription
                        : @"That file could not be installed as firmware. Make sure it is a "
                           "PS Vita firmware update (PSP2UPDAT.PUP).");
                UIAlertController *alert =
                    [UIAlertController alertControllerWithTitle:title message:message
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                          style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }];
        }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // Nothing to do — keep the current status.
}

#pragma mark - Building blocks

- (UIView *)makeCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = V3KCard();
    card.layer.cornerRadius = 20.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.14].CGColor;
    return card;
}

- (UIStackView *)cardBodyIn:(UIView *)card padding:(CGFloat)pad {
    UIStackView *body = [[UIStackView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.alignment = UIStackViewAlignmentFill;
    body.spacing = 10.0;
    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:pad],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:pad],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-pad],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-pad],
    ]];
    return body;
}

- (UILabel *)sectionHeading:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = [text uppercaseString];
    l.textColor = V3KGold();
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    return l;
}

- (UIButton *)primaryButtonTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.backgroundColor = V3KGold();
    b.tintColor = V3KBackground();
    b.layer.cornerRadius = 14.0;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:V3KBackground() forState:UIControlStateNormal];
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
