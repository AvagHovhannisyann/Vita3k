// GameDetailViewController.m — see GameDetailViewController.h for the contract.
//
// Layout (inside a vertical scroll view so it fits iPhone and iPad):
//   [ rounded icon0.png ]  name (bold)
//                          [ TITLE ID | VERSION | REGION | SIZE ] chips
//   [ ▶  PLAY .............................................. ]   <- gold
//   ┌ SAVE DATA ─────────────────────────────────────────────┐
//   │  folder name ......................... 1.2 MB          │
//   │  ( "No save data" when empty )                         │
//   └────────────────────────────────────────────────────────┘
//   [ 🗑  Delete game ] -> confirm -> deleteTitle -> pop back
#import "GameDetailViewController.h"
#import "Vita3KCore.h"
#import "EmulatorViewController.h"
#import "Theme.h"

@interface GameDetailViewController ()
@property (nonatomic, strong) V3KTitle *title_;
@property (nonatomic, strong) UIStackView *saveDataBody;  // rows re-filled on appear
@end

@implementation GameDetailViewController

#pragma mark - Lifecycle

- (instancetype)initWithTitle:(V3KTitle *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _title_ = title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = V3KBackground();
    self.title = self.title_.name.length ? self.title_.name : self.title_.titleId;

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
    stack.spacing = 20.0;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.layoutMargins = UIEdgeInsetsMake(24.0, 20.0, 40.0, 20.0);
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
    [stack addArrangedSubview:[self buildPlayButton]];
    [stack addArrangedSubview:[self buildSaveDataCard]];
    [stack addArrangedSubview:[self buildDeleteButton]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Save data can change between visits (a session may have written some).
    [self reloadSaveData];
}

#pragma mark - Header (icon + name + metadata chips)

- (UIView *)buildHeader {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 16.0;

    // Large rounded icon0.png (or a gold controller glyph if missing).
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.clipsToBounds = YES;
    iconView.layer.cornerRadius = 22.0;
    iconView.backgroundColor = V3KCard();
    iconView.layer.borderWidth = 1.0;
    iconView.layer.borderColor = [V3KGold() colorWithAlphaComponent:0.24].CGColor;

    UIImage *icon = nil;
    if (self.title_.iconPath.length) {
        icon = [UIImage imageWithContentsOfFile:self.title_.iconPath];
    }
    if (icon) {
        iconView.image = icon;
        iconView.contentMode = UIViewContentModeScaleAspectFill;
    } else {
        UIImage *glyph = [UIImage systemImageNamed:@"gamecontroller.fill"];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:48.0
                                                                weight:UIImageSymbolWeightRegular];
            glyph = [glyph imageByApplyingSymbolConfiguration:cfg];
        }
        iconView.image = glyph;
        iconView.contentMode = UIViewContentModeCenter;
        iconView.tintColor = V3KGold();
    }
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:120.0],
        [iconView.heightAnchor constraintEqualToConstant:120.0],
    ]];

    // Name + metadata chips column.
    UIStackView *col = [[UIStackView alloc] init];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentFill;
    col.spacing = 12.0;

    UILabel *name = [[UILabel alloc] init];
    name.text = self.title_.name.length ? self.title_.name : self.title_.titleId;
    name.textColor = V3KText();
    name.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    name.numberOfLines = 3;
    [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                          forAxis:UILayoutConstraintAxisHorizontal];
    [col addArrangedSubview:name];
    [col addArrangedSubview:[self buildMetadataChips]];

    [row addArrangedSubview:iconView];
    [row addArrangedSubview:col];
    return row;
}

- (UIView *)buildMetadataChips {
    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;
    NSString *sizeText = [fmt stringFromByteCount:(long long)self.title_.sizeBytes];

    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.alignment = UIStackViewAlignmentFill;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 8.0;

    [grid addArrangedSubview:[self chipWithCaption:@"Title ID"
                                             value:self.title_.titleId.length ? self.title_.titleId : @"—"]];
    [grid addArrangedSubview:[self chipWithCaption:@"Version"
                                             value:self.title_.version.length ? self.title_.version : @"—"]];
    [grid addArrangedSubview:[self chipWithCaption:@"Region"
                                             value:self.title_.region.length ? self.title_.region : @"—"]];
    [grid addArrangedSubview:[self chipWithCaption:@"Size" value:sizeText]];
    return grid;
}

// A small caption-over-value chip used for a metadata cell.
- (UIView *)chipWithCaption:(NSString *)caption value:(NSString *)value {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = V3KCard();
    card.layer.cornerRadius = 10.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.14].CGColor;

    UILabel *cap = [[UILabel alloc] init];
    cap.text = [caption uppercaseString];
    cap.textColor = V3KSubtext();
    cap.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightSemibold];
    cap.numberOfLines = 1;

    UILabel *val = [[UILabel alloc] init];
    val.text = value;
    val.textColor = V3KText();
    val.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    val.numberOfLines = 1;
    val.adjustsFontSizeToFitWidth = YES;
    val.minimumScaleFactor = 0.6;

    UIStackView *body = [[UIStackView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.axis = UILayoutConstraintAxisVertical;
    body.alignment = UIStackViewAlignmentLeading;
    body.spacing = 3.0;
    [body addArrangedSubview:cap];
    [body addArrangedSubview:val];
    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];
    return card;
}

#pragma mark - Play

- (UIView *)buildPlayButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = V3KGold();
    button.layer.cornerRadius = 16.0;
    button.tintColor = V3KBackground();
    [button setTitle:@"Play" forState:UIControlStateNormal];
    [button setTitleColor:V3KBackground() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightHeavy];
    if (@available(iOS 13.0, *)) {
        UIImage *play = [UIImage systemImageNamed:@"play.fill"];
        [button setImage:play forState:UIControlStateNormal];
        button.imageEdgeInsets = UIEdgeInsetsMake(0.0, -8.0, 0.0, 8.0);
        button.titleEdgeInsets = UIEdgeInsetsMake(0.0, 8.0, 0.0, -8.0);
    }
    button.accessibilityLabel = @"Play";
    [button addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:60.0].active = YES;
    return button;
}

- (void)playTapped {
    // Boot full-screen. Allowed even when the core is not linked yet — the
    // EmulatorViewController shows its own not-ready preview state.
    EmulatorViewController *evc =
        [[EmulatorViewController alloc] initWithTitleId:self.title_.titleId];
    evc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:evc animated:YES completion:nil];
}

#pragma mark - Save data

- (UIView *)buildSaveDataCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = V3KCard();
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.14].CGColor;

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

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"externaldrive.fill"
                                                  title:@"Save data"]];

    // Rows get filled in -reloadSaveData (also called on viewWillAppear).
    self.saveDataBody = [[UIStackView alloc] init];
    self.saveDataBody.axis = UILayoutConstraintAxisVertical;
    self.saveDataBody.alignment = UIStackViewAlignmentFill;
    self.saveDataBody.spacing = 10.0;
    [body addArrangedSubview:self.saveDataBody];

    return card;
}

- (void)reloadSaveData {
    if (!self.saveDataBody) {
        return;
    }
    for (UIView *v in self.saveDataBody.arrangedSubviews) {
        [self.saveDataBody removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<NSString *> *paths = [[Vita3KCore shared] saveDataPathsForTitle:self.title_] ?: @[];
    if (paths.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"No save data";
        empty.textColor = V3KSubtext();
        empty.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        [self.saveDataBody addArrangedSubview:empty];
        return;
    }

    NSByteCountFormatter *fmt = [[NSByteCountFormatter alloc] init];
    fmt.countStyle = NSByteCountFormatterCountStyleFile;

    BOOL first = YES;
    for (NSString *path in paths) {
        if (!first) {
            [self.saveDataBody addArrangedSubview:[self hairline]];
        }
        first = NO;

        NSString *folder = path.lastPathComponent.length ? path.lastPathComponent : path;
        unsigned long long bytes = [self directorySizeAtPath:path];
        NSString *sizeText = [fmt stringFromByteCount:(long long)bytes];
        [self.saveDataBody addArrangedSubview:[self saveRowWithName:folder size:sizeText]];
    }
}

// One save-data row: a folder glyph, its name (fills), and its size (trailing).
- (UIView *)saveRowWithName:(NSString *)name size:(NSString *)size {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;

    if (@available(iOS 13.0, *)) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"folder.fill"]];
        icon.tintColor = V3KGold();
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [NSLayoutConstraint activateConstraints:@[
            [icon.widthAnchor constraintEqualToConstant:18.0],
            [icon.heightAnchor constraintEqualToConstant:18.0],
        ]];
        [row addArrangedSubview:icon];
    }

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = name;
    nameLabel.textColor = V3KText();
    nameLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [nameLabel setContentHuggingPriority:UILayoutPriorityDefaultLow
                                 forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:nameLabel];

    UILabel *sizeLabel = [[UILabel alloc] init];
    sizeLabel.text = size;
    sizeLabel.textColor = V3KSubtext();
    sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightRegular];
    sizeLabel.textAlignment = NSTextAlignmentRight;
    [sizeLabel setContentHuggingPriority:UILayoutPriorityRequired
                                 forAxis:UILayoutConstraintAxisHorizontal];
    [sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:sizeLabel];
    return row;
}

// Sum the sizes of every regular file under a folder (0 if unreadable).
- (unsigned long long)directorySizeAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return 0;
    }
    if (!isDir) {
        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:NULL];
        return (unsigned long long)[attrs fileSize];
    }

    unsigned long long total = 0;
    NSURL *dirURL = [NSURL fileURLWithPath:path isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *en =
        [fm enumeratorAtURL:dirURL
 includingPropertiesForKeys:@[ NSURLIsRegularFileKey, NSURLFileSizeKey ]
                    options:0
               errorHandler:nil];
    for (NSURL *fileURL in en) {
        NSNumber *isRegular = nil;
        if (![fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL]
            || !isRegular.boolValue) {
            continue;
        }
        NSNumber *fileSize = nil;
        if ([fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL] && fileSize) {
            total += fileSize.unsignedLongLongValue;
        }
    }
    return total;
}

#pragma mark - Delete

- (UIView *)buildDeleteButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [V3KMagenta() colorWithAlphaComponent:0.16];
    button.layer.cornerRadius = 14.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [V3KMagenta() colorWithAlphaComponent:0.55].CGColor;
    button.tintColor = V3KMagenta();
    [button setTitle:@"Delete game" forState:UIControlStateNormal];
    [button setTitleColor:V3KMagenta() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    if (@available(iOS 13.0, *)) {
        UIImage *trash = [UIImage systemImageNamed:@"trash.fill"];
        [button setImage:trash forState:UIControlStateNormal];
        button.imageEdgeInsets = UIEdgeInsetsMake(0.0, -8.0, 0.0, 8.0);
        button.titleEdgeInsets = UIEdgeInsetsMake(0.0, 8.0, 0.0, -8.0);
    }
    button.accessibilityLabel = @"Delete game";
    [button addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:52.0].active = YES;
    return button;
}

- (void)deleteTapped {
    NSString *name = self.title_.name.length ? self.title_.name : self.title_.titleId;
    NSString *message =
        [NSString stringWithFormat:@"Delete “%@” and its files from this device? "
                                    "This cannot be undone.", name];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Delete Game"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel"
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil];
    UIAlertAction *del = [UIAlertAction actionWithTitle:@"Delete"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
        [self performDelete];
    }];
    [alert addAction:cancel];
    [alert addAction:del];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performDelete {
    NSError *error = nil;
    BOOL ok = [[Vita3KCore shared] deleteTitle:self.title_ error:&error];
    if (!ok) {
        NSString *msg = error.localizedDescription ?: @"The title could not be deleted.";
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Delete Failed"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Gone — leave the detail screen.
    if (self.navigationController && self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Small building blocks

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
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    [row addArrangedSubview:label];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                              forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:spacer];
    return row;
}

- (UIView *)hairline {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [V3KSubtext() colorWithAlphaComponent:0.14];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return line;
}

@end
