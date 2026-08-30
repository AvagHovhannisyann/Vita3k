// SettingsViewController.m — grouped, dark-themed settings backed by
// NSUserDefaults. See SettingsViewController.h for the contract.
#import "SettingsViewController.h"
#import "Theme.h"
#import "Vita3KCore.h"
#import "FirmwareInstallViewController.h"
#import "ControllerMappingViewController.h"
#import "JitDiagnosticsViewController.h"
#import "LogViewerViewController.h"

static NSString *const kPrefix = @"v3k.";

#pragma mark - Row / section model

typedef NS_ENUM(NSInteger, V3KRowKind) {
    V3KRowValue = 0,   // fixed, non-editable value shown on the right
    V3KRowSwitch,      // UISwitch accessory (bool)
    V3KRowSegmented,   // UISegmentedControl below the title (int value)
    V3KRowSlider,      // UISlider below the title (float)
    V3KRowChoice,      // tappable, opens an action sheet; stores an index (int)
    V3KRowDisclosure,  // tappable navigation row
    V3KRowPath,        // subtitle style; long monospaced value
};

@interface V3KSettingRow : NSObject
@property (nonatomic) V3KRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *key;      // defaults key (already prefixed)
@property (nonatomic, copy, nullable) NSString *value;    // for V3KRowValue / V3KRowPath
@property (nonatomic, copy, nullable) NSArray<NSString *> *options;  // segmented / choice labels
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *segValues; // stored int per segment
@property (nonatomic) float min;   // slider
@property (nonatomic) float max;   // slider
@property (nonatomic, copy, nullable) NSString *symbol;   // SF Symbol name
+ (instancetype)row:(V3KRowKind)k title:(NSString *)t;
@end

@implementation V3KSettingRow
+ (instancetype)row:(V3KRowKind)k title:(NSString *)t {
    V3KSettingRow *r = [V3KSettingRow new];
    r.kind = k; r.title = t; r.min = 0; r.max = 1;
    return r;
}
- (NSString *)fullKey { return self.key ? [kPrefix stringByAppendingString:self.key] : nil; }
@end

@interface V3KSettingSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *footer;
@property (nonatomic, copy) NSArray<V3KSettingRow *> *rows;
@end
@implementation V3KSettingSection @end

#pragma mark - "Manage data" detail screen (self-contained)

@interface V3KManageDataViewController : UITableViewController
@end

#pragma mark - Settings

@interface SettingsViewController ()
@property (nonatomic, copy) NSArray<V3KSettingSection *> *sections;
@end

@implementation SettingsViewController

+ (NSString *)defaultsPrefix { return kPrefix; }

// Support the required default -init while forcing the grouped style.
- (instancetype)init {
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    return [self initWithStyle:style];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    return [super initWithStyle:style];
}

+ (void)registerDefaults {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            @"v3k.gfx.resolutionMultiplier" : @1,
            @"v3k.gfx.fxaa"                 : @NO,
            @"v3k.gfx.anisotropic"          : @0,
            @"v3k.gfx.asyncPipeline"        : @YES,
            @"v3k.gfx.showFPS"              : @NO,
            @"v3k.cpu.optimizations"        : @YES,
            @"v3k.sys.languageIndex"        : @1,   // English (US)
            @"v3k.sys.ngsAudio"             : @YES,
            @"v3k.sys.regionIndex"          : @2,   // Europe
            @"v3k.controls.opacity"         : @0.7f,
            @"v3k.controls.haptics"         : @YES,
        }];
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [SettingsViewController registerDefaults];

    self.title = self.title.length ? self.title : @"Settings";
    self.view.backgroundColor = V3KBackground();
    self.tableView.backgroundColor = V3KBackground();
    self.tableView.separatorColor = [V3KSubtext() colorWithAlphaComponent:0.18];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 8.0;

    [self buildModel];
}

- (void)buildModel {
    NSMutableArray<V3KSettingSection *> *out = [NSMutableArray array];

    // ---- GRAPHICS ----
    V3KSettingSection *gfx = [V3KSettingSection new];
    gfx.title = @"Graphics";
    gfx.footer = @"Vulkan runs through MoltenVK on Apple GPUs.";
    {
        V3KSettingRow *renderer = [V3KSettingRow row:V3KRowValue title:@"Renderer"];
        renderer.value = @"Vulkan (MoltenVK)";
        renderer.symbol = @"cpu";

        V3KSettingRow *res = [V3KSettingRow row:V3KRowSegmented title:@"Resolution multiplier"];
        res.key = @"gfx.resolutionMultiplier";
        res.options = @[@"1x", @"2x", @"3x"];
        res.segValues = @[@1, @2, @3];
        res.symbol = @"square.resize.up";

        V3KSettingRow *fxaa = [V3KSettingRow row:V3KRowSwitch title:@"Enable FXAA"];
        fxaa.key = @"gfx.fxaa";
        fxaa.symbol = @"wand.and.stars";

        V3KSettingRow *aniso = [V3KSettingRow row:V3KRowSegmented title:@"Anisotropic filtering"];
        aniso.key = @"gfx.anisotropic";
        aniso.options = @[@"Off", @"2x", @"4x", @"8x", @"16x"];
        aniso.segValues = @[@0, @2, @4, @8, @16];
        aniso.symbol = @"square.stack.3d.up";

        V3KSettingRow *async = [V3KSettingRow row:V3KRowSwitch title:@"Async pipeline compilation"];
        async.key = @"gfx.asyncPipeline";
        async.symbol = @"arrow.triangle.2.circlepath";

        V3KSettingRow *fps = [V3KSettingRow row:V3KRowSwitch title:@"Show FPS"];
        fps.key = @"gfx.showFPS";
        fps.symbol = @"speedometer";

        gfx.rows = @[renderer, res, fxaa, aniso, async, fps];
    }
    [out addObject:gfx];

    // ---- CPU ----
    V3KSettingSection *cpu = [V3KSettingSection new];
    cpu.title = @"CPU";
    cpu.footer = @"ARM code is translated by the Dynarmic recompiler.";
    {
        V3KSettingRow *backend = [V3KSettingRow row:V3KRowValue title:@"CPU backend"];
        backend.value = @"Dynarmic";
        backend.symbol = @"memorychip";

        V3KSettingRow *opt = [V3KSettingRow row:V3KRowSwitch title:@"Enable optimizations"];
        opt.key = @"cpu.optimizations";
        opt.symbol = @"bolt.fill";

        cpu.rows = @[backend, opt];
    }
    [out addObject:cpu];

    // ---- SYSTEM ----
    V3KSettingSection *sys = [V3KSettingSection new];
    sys.title = @"System";
    {
        V3KSettingRow *lang = [V3KSettingRow row:V3KRowChoice title:@"Console language"];
        lang.key = @"sys.languageIndex";
        lang.options = [SettingsViewController languageNames];
        lang.symbol = @"globe";

        V3KSettingRow *ngs = [V3KSettingRow row:V3KRowSwitch title:@"Enable NGS audio"];
        ngs.key = @"sys.ngsAudio";
        ngs.symbol = @"speaker.wave.2.fill";

        V3KSettingRow *region = [V3KSettingRow row:V3KRowChoice title:@"Emulated console region"];
        region.key = @"sys.regionIndex";
        region.options = @[@"Japan", @"America", @"Europe", @"Asia"];
        region.symbol = @"flag.fill";

        sys.rows = @[lang, ngs, region];
    }
    [out addObject:sys];

    // ---- CONTROLS ----
    V3KSettingSection *ctl = [V3KSettingSection new];
    ctl.title = @"Controls";
    {
        V3KSettingRow *opacity = [V3KSettingRow row:V3KRowSlider title:@"On-screen controls opacity"];
        opacity.key = @"controls.opacity";
        opacity.min = 0.2f; opacity.max = 1.0f;
        opacity.symbol = @"slider.horizontal.3";

        V3KSettingRow *haptics = [V3KSettingRow row:V3KRowSwitch title:@"Enable haptics"];
        haptics.key = @"controls.haptics";
        haptics.symbol = @"iphone.radiowaves.left.and.right";

        ctl.rows = @[opacity, haptics];
    }
    [out addObject:ctl];

    // ---- SETUP & DEVICES ----
    V3KSettingSection *devs = [V3KSettingSection new];
    devs.title = @"Setup & Devices";
    {
        V3KSettingRow *fw = [V3KSettingRow row:V3KRowDisclosure title:@"Firmware"];
        fw.symbol = @"arrow.down.doc.fill";
        V3KSettingRow *ctrl = [V3KSettingRow row:V3KRowDisclosure title:@"Controllers"];
        ctrl.symbol = @"gamecontroller.fill";
        V3KSettingRow *jit = [V3KSettingRow row:V3KRowDisclosure title:@"JIT Diagnostics"];
        jit.symbol = @"bolt.fill";
        // The device is the only place this port can be tested, so the log and
        // the last crash report have to be readable without a debugger.
        V3KSettingRow *logs = [V3KSettingRow row:V3KRowDisclosure title:@"Logs & Crash Reports"];
        logs.symbol = @"doc.text.magnifyingglass";
        devs.rows = @[jit, logs, fw, ctrl];
    }
    [out addObject:devs];

    // ---- STORAGE ----
    V3KSettingSection *store = [V3KSettingSection new];
    store.title = @"Storage";
    store.footer = @"ux0:/ and vs0:/ live under this folder.";
    {
        V3KSettingRow *root = [V3KSettingRow row:V3KRowPath title:@"Data root"];
        root.value = [Vita3KCore.shared dataRoot];
        root.symbol = @"folder.fill";

        V3KSettingRow *manage = [V3KSettingRow row:V3KRowDisclosure title:@"Manage data"];
        manage.symbol = @"externaldrive.fill";

        store.rows = @[root, manage];
    }
    [out addObject:store];

    self.sections = out;
    [self.tableView reloadData];
}

+ (NSArray<NSString *> *)languageNames {
    return @[@"Japanese", @"English (US)", @"French", @"Spanish", @"German",
             @"Italian", @"Dutch", @"Portuguese (PT)", @"Russian", @"Korean",
             @"Chinese (Traditional)", @"Chinese (Simplified)", @"Finnish",
             @"Swedish", @"Danish", @"Norwegian", @"Polish", @"Portuguese (BR)",
             @"English (UK)", @"Turkish"];
}

#pragma mark - Defaults helpers

- (NSUserDefaults *)ud { return NSUserDefaults.standardUserDefaults; }

- (V3KSettingRow *)rowForTag:(NSInteger)tag {
    NSInteger t = tag - 1000;
    NSInteger s = t / 100, r = t % 100;
    if (s < 0 || s >= (NSInteger)self.sections.count) return nil;
    V3KSettingSection *sec = self.sections[s];
    if (r < 0 || r >= (NSInteger)sec.rows.count) return nil;
    return sec.rows[r];
}

static NSInteger V3KTagFor(NSInteger section, NSInteger row) {
    return 1000 + section * 100 + row;
}

#pragma mark - Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].rows.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section].title;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.sections[section].footer;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
        h.textLabel.textColor = V3KGold();
        h.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *f = (UITableViewHeaderFooterView *)view;
        f.textLabel.textColor = V3KSubtext();
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    V3KSettingRow *row = self.sections[indexPath.section].rows[indexPath.row];
    switch (row.kind) {
        case V3KRowSegmented: return 84.0;
        case V3KRowSlider:    return 84.0;
        case V3KRowPath:      return UITableViewAutomaticDimension;
        default:              return 52.0;
    }
}
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56.0;
}

#pragma mark - Cell styling

- (void)styleCell:(UITableViewCell *)cell row:(V3KSettingRow *)row {
    cell.backgroundColor = V3KCard();
    cell.textLabel.textColor = V3KText();
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = V3KSubtext();
    cell.tintColor = V3KGold();

    UIView *sel = [UIView new];
    sel.backgroundColor = [V3KGold() colorWithAlphaComponent:0.14];
    cell.selectedBackgroundView = sel;

    if (row.symbol) {
        UIImage *img = [UIImage systemImageNamed:row.symbol];
        cell.imageView.image = img;
        cell.imageView.tintColor = V3KGold();
    } else {
        cell.imageView.image = nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    V3KSettingRow *row = self.sections[indexPath.section].rows[indexPath.row];
    NSInteger tag = V3KTagFor(indexPath.section, indexPath.row);

    switch (row.kind) {

        case V3KRowValue: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.detailTextLabel.text = row.value;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        }

        case V3KRowPath: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.detailTextLabel.text = row.value;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
            cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        case V3KRowSwitch: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = V3KGold();
            sw.tag = tag;
            sw.on = [self.ud boolForKey:row.fullKey];
            [sw addTarget:self action:@selector(switchChanged:)
                 forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            return cell;
        }

        case V3KRowSegmented: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:row.options];
            seg.translatesAutoresizingMaskIntoConstraints = NO;
            seg.tag = tag;
            seg.selectedSegmentTintColor = V3KGold();
            [seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: V3KText() }
                              forState:UIControlStateNormal];
            [seg setTitleTextAttributes:@{ NSForegroundColorAttributeName: V3KBackground(),
                                           NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold] }
                              forState:UIControlStateSelected];
            if (@available(iOS 13.0, *)) seg.backgroundColor = [V3KBackground() colorWithAlphaComponent:0.6];

            NSInteger stored = [self.ud integerForKey:row.fullKey];
            NSUInteger sel = [row.segValues indexOfObject:@(stored)];
            seg.selectedSegmentIndex = (sel == NSNotFound) ? 0 : (NSInteger)sel;
            [seg addTarget:self action:@selector(segmentChanged:)
                  forControlEvents:UIControlEventValueChanged];

            [cell.contentView addSubview:seg];
            [NSLayoutConstraint activateConstraints:@[
                [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-14],
                [seg.heightAnchor constraintEqualToConstant:32],
            ]];
            return cell;
        }

        case V3KRowSlider: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            float current = [self.ud floatForKey:row.fullKey];

            UILabel *pct = [UILabel new];
            pct.translatesAutoresizingMaskIntoConstraints = NO;
            pct.tag = 777;
            pct.textColor = V3KGold();
            pct.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
            pct.textAlignment = NSTextAlignmentRight;
            pct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(current * 100)];

            UISlider *slider = [UISlider new];
            slider.translatesAutoresizingMaskIntoConstraints = NO;
            slider.tag = tag;
            slider.minimumValue = row.min;
            slider.maximumValue = row.max;
            slider.value = current;
            slider.minimumTrackTintColor = V3KGold();
            slider.maximumTrackTintColor = [V3KSubtext() colorWithAlphaComponent:0.4];
            slider.thumbTintColor = V3KText();
            [slider addTarget:self action:@selector(sliderChanged:)
                     forControlEvents:UIControlEventValueChanged];

            [cell.contentView addSubview:slider];
            [cell.contentView addSubview:pct];
            [NSLayoutConstraint activateConstraints:@[
                [slider.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [slider.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-14],
                [pct.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:12],
                [pct.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [pct.centerYAnchor constraintEqualToAnchor:slider.centerYAnchor],
                [pct.widthAnchor constraintEqualToConstant:52],
            ]];
            return cell;
        }

        case V3KRowChoice: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            NSInteger idx = [self.ud integerForKey:row.fullKey];
            if (idx >= 0 && idx < (NSInteger)row.options.count)
                cell.detailTextLabel.text = row.options[idx];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }

        case V3KRowDisclosure: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:nil];
            [self styleCell:cell row:row];
            cell.textLabel.text = row.title;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }
    return [UITableViewCell new];
}

#pragma mark - Actions

- (void)switchChanged:(UISwitch *)sender {
    V3KSettingRow *row = [self rowForTag:sender.tag];
    if (!row.fullKey) return;
    [self.ud setBool:sender.isOn forKey:row.fullKey];
    [self haptic];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    V3KSettingRow *row = [self rowForTag:sender.tag];
    if (!row.fullKey || sender.selectedSegmentIndex < 0) return;
    NSNumber *v = row.segValues[sender.selectedSegmentIndex];
    [self.ud setInteger:v.integerValue forKey:row.fullKey];
    [self haptic];
}

- (void)sliderChanged:(UISlider *)sender {
    V3KSettingRow *row = [self rowForTag:sender.tag];
    if (!row.fullKey) return;
    [self.ud setFloat:sender.value forKey:row.fullKey];
    UILabel *pct = [sender.superview viewWithTag:777];
    if ([pct isKindOfClass:UILabel.class])
        pct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(sender.value * 100)];
}

- (void)haptic {
    if (![self.ud boolForKey:@"v3k.controls.haptics"]) return;
    if (@available(iOS 10.0, *)) {
        UISelectionFeedbackGenerator *g = [UISelectionFeedbackGenerator new];
        [g selectionChanged];
    }
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    V3KSettingRow *row = self.sections[indexPath.section].rows[indexPath.row];

    if (row.kind == V3KRowChoice) {
        [self presentChoiceForRow:row atIndexPath:indexPath];
    } else if (row.kind == V3KRowDisclosure) {
        UIViewController *vc;
        if ([row.title isEqualToString:@"JIT Diagnostics"]) {
            vc = [JitDiagnosticsViewController new];
        } else if ([row.title isEqualToString:@"Logs & Crash Reports"]) {
            vc = [LogViewerViewController new];
        } else if ([row.title isEqualToString:@"Firmware"]) {
            vc = [FirmwareInstallViewController new];
        } else if ([row.title isEqualToString:@"Controllers"]) {
            vc = [ControllerMappingViewController new];
        } else {
            V3KManageDataViewController *m = [V3KManageDataViewController new];
            vc = m;
        }
        vc.title = row.title;
        if (self.navigationController) {
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:vc];
            [self presentViewController:nc animated:YES completion:nil];
        }
    }
}

- (void)presentChoiceForRow:(V3KSettingRow *)row atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:row.title message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger current = [self.ud integerForKey:row.fullKey];
    [row.options enumerateObjectsUsingBlock:^(NSString *opt, NSUInteger i, BOOL *stop) {
        NSString *label = (i == (NSUInteger)current) ? [@"✓  " stringByAppendingString:opt] : opt;
        UIAlertAction *a = [UIAlertAction actionWithTitle:label
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
            [self.ud setInteger:(NSInteger)i forKey:row.fullKey];
            [self haptic];
            [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
        }];
        [sheet addAction:a];
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];

    // iPad requires a popover anchor.
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Manage data implementation

@implementation V3KManageDataViewController {
    NSArray<NSString *> *_folders;   // subpaths under dataRoot
}

- (instancetype)init {
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    return [self initWithStyle:style];
}
- (instancetype)initWithStyle:(UITableViewStyle)style { return [super initWithStyle:style]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    _folders = @[@"ux0/app", @"ux0/user", @"ux0/pspemu", @"vs0", @"import"];
    self.view.backgroundColor = V3KBackground();
    self.tableView.backgroundColor = V3KBackground();
    self.tableView.separatorColor = [V3KSubtext() colorWithAlphaComponent:0.18];
}

- (NSString *)dataRoot { return [Vita3KCore.shared dataRoot]; }

- (unsigned long long)sizeOfPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir]) return 0;
    if (!dir) {
        NSNumber *sz = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
        return sz.unsignedLongLongValue;
    }
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    for (NSString *sub in e) {
        NSDictionary *attrs = e.fileAttributes;
        if ([attrs[NSFileType] isEqual:NSFileTypeRegular])
            total += [attrs[NSFileSize] unsignedLongLongValue];
        (void)sub;
    }
    return total;
}

- (NSString *)human:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_folders.count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"On-disk usage" : @"Maintenance";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? [self dataRoot] : @"Removes staged .vpk / .pkg files that have already been installed.";
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class])
        ((UITableViewHeaderFooterView *)view).textLabel.textColor = V3KGold();
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *f = (UITableViewHeaderFooterView *)view;
        f.textLabel.textColor = V3KSubtext();
        f.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        f.textLabel.numberOfLines = 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                  reuseIdentifier:nil];
    cell.backgroundColor = V3KCard();
    cell.textLabel.textColor = V3KText();
    cell.detailTextLabel.textColor = V3KSubtext();
    cell.tintColor = V3KGold();
    UIView *sel = [UIView new];
    sel.backgroundColor = [V3KGold() colorWithAlphaComponent:0.14];
    cell.selectedBackgroundView = sel;

    if (indexPath.section == 0) {
        NSString *sub = _folders[indexPath.row];
        NSString *full = [[self dataRoot] stringByAppendingPathComponent:sub];
        cell.textLabel.text = sub;
        cell.detailTextLabel.text = [self human:[self sizeOfPath:full]];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Clear import cache";
        cell.textLabel.textColor = V3KMagenta();
        cell.imageView.image = [UIImage systemImageNamed:@"trash.fill"];
        cell.imageView.tintColor = V3KMagenta();
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;

    NSString *importDir = [[self dataRoot] stringByAppendingPathComponent:@"import"];
    UIAlertController *confirm =
        [UIAlertController alertControllerWithTitle:@"Clear import cache?"
                                            message:@"Staged package files will be permanently deleted."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Clear"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *a) {
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *f in [fm contentsOfDirectoryAtPath:importDir error:nil] ?: @[]) {
            [fm removeItemAtPath:[importDir stringByAppendingPathComponent:f] error:nil];
        }
        [self.tableView reloadData];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

@end
