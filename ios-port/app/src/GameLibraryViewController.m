// GameLibraryViewController.m — the Library screen.
//
// Layout:
//   [ nav bar ............................ (+) ]   <- import button
//   [ thin status strip: core.statusLine      ]
//   [ collection grid of rounded title cards   ]
//   ( empty state overlay when no titles )
//
// Each card shows icon0.png (or a gold controller glyph) plus the title name.
// Tap  -> boot the title full-screen in the EmulatorViewController.
// Hold -> action sheet with Delete.
#import "GameLibraryViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"
#import "EmulatorViewController.h"
#import "GameDetailViewController.h"

#pragma mark - V3KGameCell

/// A single rounded title card: square icon on top, name label beneath.
@interface V3KGameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
- (void)configureWithTitle:(V3KTitle *)title;
@end

@implementation V3KGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = V3KCard();
        self.contentView.layer.cornerRadius = 16.0;
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.borderWidth = 1.0;
        self.contentView.layer.borderColor = [V3KGold() colorWithAlphaComponent:0.18].CGColor;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.clipsToBounds = YES;
        _iconView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.20];
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _nameLabel.textColor = V3KText();
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.numberOfLines = 2;
        [self.contentView addSubview:_nameLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat labelH = 34.0;
    CGFloat iconDim = MIN(w, MAX(0.0, h - labelH));
    self.iconView.frame = CGRectMake((w - iconDim) / 2.0, 0.0, iconDim, iconDim);
    self.nameLabel.frame = CGRectMake(6.0, h - labelH, w - 12.0, labelH);
}

- (void)configureWithTitle:(V3KTitle *)title {
    self.nameLabel.text = title.name.length ? title.name : title.titleId;

    UIImage *icon = nil;
    if (title.iconPath.length) {
        icon = [UIImage imageWithContentsOfFile:title.iconPath];
    }
    if (icon) {
        self.iconView.image = icon;
        self.iconView.contentMode = UIViewContentModeScaleAspectFill;
        self.iconView.tintColor = nil;
    } else {
        UIImage *glyph = [UIImage systemImageNamed:@"gamecontroller.fill"];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg =
                [UIImageSymbolConfiguration configurationWithPointSize:44.0
                                                                weight:UIImageSymbolWeightRegular];
            glyph = [glyph imageByApplyingSymbolConfiguration:cfg];
        }
        self.iconView.image = glyph;
        self.iconView.contentMode = UIViewContentModeCenter;
        self.iconView.tintColor = V3KGold();
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.nameLabel.text = nil;
}

@end

#pragma mark - GameLibraryViewController

@interface GameLibraryViewController () <UICollectionViewDataSource,
                                         UICollectionViewDelegate,
                                         UICollectionViewDelegateFlowLayout,
                                         UIDocumentPickerDelegate>
@property (nonatomic, strong) UIView *statusStrip;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, copy) NSArray<V3KTitle *> *titles;
@end

static NSString *const kCellId = @"V3KGameCell";

@implementation GameLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = V3KBackground();
    self.titles = @[];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(importTapped)];
    self.navigationItem.rightBarButtonItem.tintColor = V3KGold();

    [self buildStatusStrip];
    [self buildCollectionView];
    [self buildEmptyState];
    [self installConstraints];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadTitles];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        [self.collectionView.collectionViewLayout invalidateLayout];
    } completion:nil];
}

#pragma mark Build

- (void)buildStatusStrip {
    self.statusStrip = [[UIView alloc] initWithFrame:CGRectZero];
    self.statusStrip.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusStrip.backgroundColor = V3KCard();
    [self.view addSubview:self.statusStrip];

    UIImageView *dot = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle.fill"]];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.tintColor = [[Vita3KCore shared] coreLinked] ? V3KGreen() : V3KGold();
    dot.contentMode = UIViewContentModeScaleAspectFit;
    [self.statusStrip addSubview:dot];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    self.statusLabel.textColor = V3KSubtext();
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.statusStrip addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:self.statusStrip.leadingAnchor constant:16.0],
        [dot.centerYAnchor constraintEqualToAnchor:self.statusStrip.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:9.0],
        [dot.heightAnchor constraintEqualToConstant:9.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:8.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.statusStrip.trailingAnchor constant:-16.0],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.statusStrip.centerYAnchor],
    ]];
}

- (void)buildCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 14.0;
    layout.minimumLineSpacing = 16.0;
    layout.sectionInset = UIEdgeInsetsMake(16.0, 16.0, 24.0, 16.0);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                             collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[V3KGameCell class] forCellWithReuseIdentifier:kCellId];
    [self.view addSubview:self.collectionView];

    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleLongPress:)];
    hold.minimumPressDuration = 0.45;
    [self.collectionView addGestureRecognizer:hold];
}

- (void)buildEmptyState {
    self.emptyStateView = [[UIView alloc] initWithFrame:CGRectZero];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gamecontroller.fill"]];
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    glyph.tintColor = V3KGold();
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:72.0
                                                            weight:UIImageSymbolWeightRegular];
        glyph.image = [glyph.image imageByApplyingSymbolConfiguration:cfg];
    }
    [self.emptyStateView addSubview:glyph];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"No games yet";
    title.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    title.textColor = V3KText();
    title.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Import a .vpk or .pkg package to get started.";
    subtitle.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    subtitle.textColor = V3KSubtext();
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [self.emptyStateView addSubview:subtitle];

    UIButton *importBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    importBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [importBtn setTitle:@"  Import .vpk / .pkg  " forState:UIControlStateNormal];
    [importBtn setTitleColor:V3KBackground() forState:UIControlStateNormal];
    importBtn.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    importBtn.backgroundColor = V3KGold();
    importBtn.layer.cornerRadius = 14.0;
    if (@available(iOS 13.0, *)) {
        UIImage *plus = [UIImage systemImageNamed:@"square.and.arrow.down.fill"];
        [importBtn setImage:plus forState:UIControlStateNormal];
        importBtn.tintColor = V3KBackground();
        importBtn.imageEdgeInsets = UIEdgeInsetsMake(0.0, -6.0, 0.0, 6.0);
    }
    [importBtn addTarget:self action:@selector(importTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:importBtn];

    [NSLayoutConstraint activateConstraints:@[
        [glyph.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:self.emptyStateView.centerYAnchor constant:-96.0],
        [glyph.widthAnchor constraintEqualToConstant:96.0],
        [glyph.heightAnchor constraintEqualToConstant:96.0],

        [title.topAnchor constraintEqualToAnchor:glyph.bottomAnchor constant:20.0],
        [title.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor constant:24.0],
        [title.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor constant:-24.0],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor constant:36.0],
        [subtitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor constant:-36.0],

        [importBtn.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:28.0],
        [importBtn.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [importBtn.heightAnchor constraintEqualToConstant:54.0],
        [importBtn.widthAnchor constraintGreaterThanOrEqualToConstant:240.0],
    ]];
}

- (void)installConstraints {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusStrip.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.statusStrip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.statusStrip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.statusStrip.heightAnchor constraintEqualToConstant:30.0],

        [self.collectionView.topAnchor constraintEqualToAnchor:self.statusStrip.bottomAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyStateView.topAnchor constraintEqualToAnchor:self.statusStrip.bottomAnchor],
        [self.emptyStateView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.emptyStateView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.emptyStateView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark Data

- (void)reloadTitles {
    self.titles = [[Vita3KCore shared] installedTitles] ?: @[];
    self.statusLabel.text = [[Vita3KCore shared] statusLine];
    BOOL empty = (self.titles.count == 0);
    self.emptyStateView.hidden = !empty;
    self.collectionView.hidden = empty;
    [self.collectionView reloadData];
}

#pragma mark Actions

- (void)importTapped {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Accept .vpk and .pkg via the generic item type plus the pkg type.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item", @"com.pkg" ]
                                                               inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    if (@available(iOS 13.0, *)) {
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    CGPoint pt = [gesture locationInView:self.collectionView];
    NSIndexPath *ip = [self.collectionView indexPathForItemAtPoint:pt];
    if (!ip || ip.item >= (NSInteger)self.titles.count) {
        return;
    }
    V3KTitle *title = self.titles[(NSUInteger)ip.item];

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:title.name.length ? title.name : title.titleId
                                            message:title.titleId
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction *play = [UIAlertAction actionWithTitle:@"Play"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
        [self launchTitle:title];
    }];
    UIAlertAction *del = [UIAlertAction actionWithTitle:@"Delete"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
        [self deleteTitle:title];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel"
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil];
    [sheet addAction:play];
    [sheet addAction:del];
    [sheet addAction:cancel];

    // iPad: anchor the popover to the pressed cell.
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:ip];
    sheet.popoverPresentationController.sourceView = cell ?: self.collectionView;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(pt.x, pt.y, 1.0, 1.0);

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)deleteTitle:(V3KTitle *)title {
    NSError *error = nil;
    BOOL ok = [[Vita3KCore shared] deleteTitle:title error:&error];
    if (!ok) {
        [self presentErrorWithTitle:@"Delete Failed" error:error];
    }
    [self reloadTitles];
}

- (void)launchTitle:(V3KTitle *)title {
    GameDetailViewController *detail = [[GameDetailViewController alloc] initWithTitle:title];
    if (self.navigationController) {
        [self.navigationController pushViewController:detail animated:YES];
    } else {
        EmulatorViewController *evc = [[EmulatorViewController alloc] initWithTitleId:title.titleId];
        evc.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:evc animated:YES completion:nil];
    }
}

- (void)presentErrorWithTitle:(NSString *)title error:(NSError *)error {
    NSString *msg = error.localizedDescription ?: @"An unknown error occurred.";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSError *lastError = nil;
    NSInteger imported = 0;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error = nil;
        BOOL ok = [[Vita3KCore shared] importPackageAtURL:url error:&error];
        if (scoped) {
            [url stopAccessingSecurityScopedResource];
        }
        if (ok) {
            imported++;
        } else {
            lastError = error;
        }
    }
    [self reloadTitles];
    if (imported == 0 && lastError) {
        [self presentErrorWithTitle:@"Import Failed" error:lastError];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // Nothing to do — keep the current library.
}

#pragma mark UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.titles.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    V3KGameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCellId
                                                                 forIndexPath:indexPath];
    if (indexPath.item < (NSInteger)self.titles.count) {
        [cell configureWithTitle:self.titles[(NSUInteger)indexPath.item]];
    }
    return cell;
}

#pragma mark UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (indexPath.item >= (NSInteger)self.titles.count) {
        return;
    }
    [self launchTitle:self.titles[(NSUInteger)indexPath.item]];
}

#pragma mark UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat spacing = flow.minimumInteritemSpacing;
    CGFloat available = collectionView.bounds.size.width
        - flow.sectionInset.left - flow.sectionInset.right;

    // Aim for ~150pt cards, clamped to a sensible column count for phone/pad.
    CGFloat target = 150.0;
    NSInteger columns = (NSInteger)floor((available + spacing) / (target + spacing));
    if (columns < 2) { columns = 2; }
    if (columns > 6) { columns = 6; }

    CGFloat width = floor((available - (columns - 1) * spacing) / (CGFloat)columns);
    if (width < 80.0) { width = 80.0; }
    CGFloat labelH = 34.0;
    return CGSizeMake(width, width + labelH);
}

@end
