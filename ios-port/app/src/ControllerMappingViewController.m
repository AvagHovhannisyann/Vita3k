// ControllerMappingViewController.m — see the header for the contract.
#import "ControllerMappingViewController.h"
#import "Theme.h"
#import <GameController/GameController.h>

// Notification names are referenced as string literals rather than the extern
// symbols so the screen stays safe even if GameController.framework is weakly
// linked and absent at runtime (the symbols would be nil, and observing a nil
// name would silently match every notification). Their string values are the
// stable, documented constant names.
static NSString *const kV3KDidConnect    = @"GCControllerDidConnectNotification";
static NSString *const kV3KDidDisconnect = @"GCControllerDidDisconnectNotification";

// Stable identifiers for each mapped input, used as chip keys.
typedef NSString V3KInputKey;
static V3KInputKey *const kFaceA   = @"A";
static V3KInputKey *const kFaceB   = @"B";
static V3KInputKey *const kFaceX   = @"X";
static V3KInputKey *const kFaceY   = @"Y";
static V3KInputKey *const kDUp     = @"D-Up";
static V3KInputKey *const kDDown   = @"D-Down";
static V3KInputKey *const kDLeft   = @"D-Left";
static V3KInputKey *const kDRight  = @"D-Right";
static V3KInputKey *const kL1      = @"L1";
static V3KInputKey *const kR1      = @"R1";
static V3KInputKey *const kL2      = @"L2";
static V3KInputKey *const kR2      = @"R2";
static V3KInputKey *const kLStick  = @"L-Stick";
static V3KInputKey *const kRStick  = @"R-Stick";
static V3KInputKey *const kL3      = @"L3";
static V3KInputKey *const kR3      = @"R3";

@interface ControllerMappingViewController ()
// Rebuilt whenever the connected-controller set changes.
@property (nonatomic, strong) UIStackView *controllersBody;   // list-card contents
@property (nonatomic, strong) UILabel     *liveHeadingLabel;   // "watching …" caption
// key -> chip view for the live input map.
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *chips;
// The gamepad we are currently listening to (weak: owned by its controller).
@property (nonatomic, weak) GCExtendedGamepad *activeGamepad;
@end

@implementation ControllerMappingViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.title.length ? self.title : @"Controllers";
    self.view.backgroundColor = V3KBackground();
    self.chips = [NSMutableDictionary dictionary];

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
    [stack addArrangedSubview:[self buildControllersCard]];
    [stack addArrangedSubview:[self buildLiveMapCard]];
    [stack addArrangedSubview:[self buildTouchNoteCard]];

    // Observe hot-plug of controllers (guarded string-name registration).
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(controllersChanged:)
               name:kV3KDidConnect object:nil];
    [nc addObserver:self selector:@selector(controllersChanged:)
               name:kV3KDidDisconnect object:nil];

    [self refreshControllers];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Drop our handler so a lingering controller stops calling into a dead VC.
    GCExtendedGamepad *gp = self.activeGamepad;
    if (gp) { gp.valueChangedHandler = nil; }
}

#pragma mark - Header

- (UIView *)buildHeader {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.alignment = UIStackViewAlignmentLeading;
    v.spacing = 4.0;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Controllers";
    title.textColor = V3KGold();
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightHeavy];
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    title.numberOfLines = 1;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"Pair a gamepad and watch it map to the Vita buttons.";
    subtitle.textColor = V3KSubtext();
    subtitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    subtitle.numberOfLines = 0;

    [v addArrangedSubview:title];
    [v addArrangedSubview:subtitle];
    return v;
}

#pragma mark - Connected-controllers card

- (UIView *)buildControllersCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"gamecontroller.fill"
                                                  title:@"Connected controllers"]];

    // A sub-stack we can tear down and rebuild as controllers come and go.
    UIStackView *list = [[UIStackView alloc] init];
    list.axis = UILayoutConstraintAxisVertical;
    list.alignment = UIStackViewAlignmentFill;
    list.spacing = 12.0;
    self.controllersBody = list;
    [body addArrangedSubview:list];

    return card;
}

// (Re)build the list card and the live map from the current controller set.
- (void)refreshControllers {
    UIStackView *list = self.controllersBody;
    for (UIView *sub in [list.arrangedSubviews copy]) {
        [list removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSArray<GCController *> *controllers = [self connectedControllers];

    if (controllers.count == 0) {
        [list addArrangedSubview:[self emptyStateView]];
        [self bindGamepad:nil];
        [self setLiveMapEnabled:NO controllerName:nil];
        return;
    }

    NSInteger index = 1;
    for (GCController *c in controllers) {
        [list addArrangedSubview:[self rowForController:c index:index]];
        if (c != controllers.lastObject) {
            [list addArrangedSubview:[self hairline]];
        }
        index++;
    }

    // Drive the live map from the first controller that exposes an
    // extendedGamepad profile.
    GCController *mapped = nil;
    for (GCController *c in controllers) {
        if (c.extendedGamepad) { mapped = c; break; }
    }
    if (mapped) {
        [self bindGamepad:mapped.extendedGamepad];
        [self setLiveMapEnabled:YES controllerName:[self displayNameFor:mapped]];
    } else {
        [self bindGamepad:nil];
        [self setLiveMapEnabled:NO controllerName:nil];
    }
}

// Safely query GCController.controllers even if the framework is missing.
- (NSArray<GCController *> *)connectedControllers {
    // Guard against the framework being absent at runtime (weak-linked): if the
    // class is missing we never touch the API. When present, the class message
    // is a normal call.
    if (!NSClassFromString(@"GCController")) { return @[]; }
    NSArray<GCController *> *list = [GCController controllers];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

- (NSString *)displayNameFor:(GCController *)c {
    NSString *vendor = c.vendorName.length ? c.vendorName : @"Game Controller";
    return vendor;
}

- (UIView *)rowForController:(GCController *)c index:(NSInteger)index {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 6.0;
    dot.backgroundColor = V3KGreen();
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:12.0],
        [dot.heightAnchor constraintEqualToConstant:12.0],
    ]];

    UIStackView *text = [[UIStackView alloc] init];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 2.0;

    UILabel *name = [[UILabel alloc] init];
    name.text = [self displayNameFor:c];
    name.textColor = V3KText();
    name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    name.numberOfLines = 0;

    NSString *category = c.productCategory.length ? c.productCategory : @"Controller";
    NSString *profile = c.extendedGamepad ? @"Extended gamepad" : @"Basic gamepad";
    UILabel *detail = [[UILabel alloc] init];
    detail.text = [NSString stringWithFormat:@"%@ · %@", category, profile];
    detail.textColor = V3KSubtext();
    detail.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    detail.numberOfLines = 0;

    [text addArrangedSubview:name];
    [text addArrangedSubview:detail];

    [row addArrangedSubview:dot];
    [row addArrangedSubview:text];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                              forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:spacer];
    return row;
}

- (UIView *)emptyStateView {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisHorizontal;
    v.alignment = UIStackViewAlignmentTop;
    v.spacing = 12.0;

    if (@available(iOS 13.0, *)) {
        UIImageView *icon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"]];
        icon.tintColor = V3KMagenta();
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [icon.widthAnchor constraintEqualToConstant:24.0],
            [icon.heightAnchor constraintEqualToConstant:24.0],
        ]];
        [v addArrangedSubview:icon];
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = @"No controller connected — pair a PlayStation/Xbox/MFi "
                 @"controller in iOS Settings > Bluetooth.";
    label.textColor = V3KText();
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    label.numberOfLines = 0;
    [v addArrangedSubview:label];
    return v;
}

#pragma mark - Live input-map card

- (UIView *)buildLiveMapCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"dot.circle.and.hand.point.up.left.fill"
                                                  title:@"Live input map"]];

    UILabel *heading = [[UILabel alloc] init];
    heading.textColor = V3KSubtext();
    heading.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    heading.numberOfLines = 0;
    self.liveHeadingLabel = heading;
    [body addArrangedSubview:heading];

    // Grouped rows of chips. Each label is the on-pad control; it lights up
    // gold when the matching Vita input is pressed.
    [body addArrangedSubview:[self chipRowTitle:@"Face"
                                           keys:@[ kFaceA, kFaceB, kFaceX, kFaceY ]]];
    [body addArrangedSubview:[self chipRowTitle:@"D-pad"
                                           keys:@[ kDUp, kDDown, kDLeft, kDRight ]]];
    [body addArrangedSubview:[self chipRowTitle:@"Shoulders"
                                           keys:@[ kL1, kR1, kL2, kR2 ]]];
    [body addArrangedSubview:[self chipRowTitle:@"Sticks"
                                           keys:@[ kLStick, kRStick, kL3, kR3 ]]];

    return card;
}

- (UIView *)chipRowTitle:(NSString *)title keys:(NSArray<NSString *> *)keys {
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.alignment = UIStackViewAlignmentFill;
    v.spacing = 8.0;

    [v addArrangedSubview:[self captionLabel:title]];

    UIStackView *rowChips = [[UIStackView alloc] init];
    rowChips.axis = UILayoutConstraintAxisHorizontal;
    rowChips.alignment = UIStackViewAlignmentFill;
    rowChips.distribution = UIStackViewDistributionFillEqually;
    rowChips.spacing = 8.0;
    for (NSString *key in keys) {
        UIView *chip = [self makeChipForKey:key];
        self.chips[key] = chip;
        [rowChips addArrangedSubview:chip];
    }
    [v addArrangedSubview:rowChips];
    return v;
}

// A rounded pill with the control name; `tag`-tracked label lets us recolor it.
- (UIView *)makeChipForKey:(NSString *)key {
    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [V3KBackground() colorWithAlphaComponent:0.6];
    chip.layer.cornerRadius = 12.0;
    chip.layer.borderWidth = 1.5;
    chip.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.25].CGColor;
    [chip.heightAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.tag = 7001; // retrievable via viewWithTag:
    label.text = key;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = V3KSubtext();
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    label.numberOfLines = 1;
    [chip addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:6.0],
        [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-6.0],
        [label.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
    ]];
    return chip;
}

- (void)setChipKey:(NSString *)key active:(BOOL)active {
    UIView *chip = self.chips[key];
    if (!chip) { return; }
    UILabel *label = (UILabel *)[chip viewWithTag:7001];
    if (active) {
        chip.backgroundColor = V3KGold();
        chip.layer.borderColor = V3KGold().CGColor;
        if ([label isKindOfClass:[UILabel class]]) { label.textColor = V3KBackground(); }
    } else {
        chip.backgroundColor = [V3KBackground() colorWithAlphaComponent:0.6];
        chip.layer.borderColor = [V3KSubtext() colorWithAlphaComponent:0.25].CGColor;
        if ([label isKindOfClass:[UILabel class]]) { label.textColor = V3KSubtext(); }
    }
}

- (void)setLiveMapEnabled:(BOOL)enabled controllerName:(nullable NSString *)name {
    if (enabled && name.length) {
        self.liveHeadingLabel.text =
            [NSString stringWithFormat:@"Watching %@ — press buttons to see them light up.", name];
        self.liveHeadingLabel.textColor = V3KGreen();
    } else {
        self.liveHeadingLabel.text =
            @"Connect a controller to see its inputs light up here.";
        self.liveHeadingLabel.textColor = V3KSubtext();
    }
    if (!enabled) {
        // Reset every chip to its idle look.
        for (NSString *key in self.chips) { [self setChipKey:key active:NO]; }
    }
}

#pragma mark - Live gamepad binding

- (void)bindGamepad:(nullable GCExtendedGamepad *)gamepad {
    // Detach the previous handler first.
    GCExtendedGamepad *previous = self.activeGamepad;
    if (previous && previous != gamepad) {
        previous.valueChangedHandler = nil;
    }
    self.activeGamepad = gamepad;
    if (!gamepad) { return; }

    __weak typeof(self) weakSelf = self;
    gamepad.valueChangedHandler = ^(GCExtendedGamepad *gp, GCControllerElement *element) {
        (void)element; // We refresh the whole map from current state.
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        [self syncChipsFromGamepad:gp];
    };
    // Prime the initial state.
    [self syncChipsFromGamepad:gamepad];
}

- (void)syncChipsFromGamepad:(GCExtendedGamepad *)gp {
    if (!gp) { return; }

    static const float kStickDeadzone = 0.30f;

    [self setChipKey:kFaceA active:gp.buttonA.isPressed];
    [self setChipKey:kFaceB active:gp.buttonB.isPressed];
    [self setChipKey:kFaceX active:gp.buttonX.isPressed];
    [self setChipKey:kFaceY active:gp.buttonY.isPressed];

    GCControllerDirectionPad *dpad = gp.dpad;
    [self setChipKey:kDUp    active:dpad.up.isPressed];
    [self setChipKey:kDDown  active:dpad.down.isPressed];
    [self setChipKey:kDLeft  active:dpad.left.isPressed];
    [self setChipKey:kDRight active:dpad.right.isPressed];

    [self setChipKey:kL1 active:gp.leftShoulder.isPressed];
    [self setChipKey:kR1 active:gp.rightShoulder.isPressed];
    [self setChipKey:kL2 active:(gp.leftTrigger.value  > 0.05f || gp.leftTrigger.isPressed)];
    [self setChipKey:kR2 active:(gp.rightTrigger.value > 0.05f || gp.rightTrigger.isPressed)];

    GCControllerDirectionPad *ls = gp.leftThumbstick;
    GCControllerDirectionPad *rs = gp.rightThumbstick;
    BOOL lsActive = (fabsf(ls.xAxis.value) > kStickDeadzone ||
                     fabsf(ls.yAxis.value) > kStickDeadzone);
    BOOL rsActive = (fabsf(rs.xAxis.value) > kStickDeadzone ||
                     fabsf(rs.yAxis.value) > kStickDeadzone);
    [self setChipKey:kLStick active:lsActive];
    [self setChipKey:kRStick active:rsActive];

    // Thumbstick clicks (L3/R3) are optional on the profile.
    GCControllerButtonInput *l3 = gp.leftThumbstickButton;
    GCControllerButtonInput *r3 = gp.rightThumbstickButton;
    [self setChipKey:kL3 active:(l3 != nil && l3.isPressed)];
    [self setChipKey:kR3 active:(r3 != nil && r3.isPressed)];
}

#pragma mark - Touch-controls note

- (UIView *)buildTouchNoteCard {
    UIView *card = [self makeCard];
    UIStackView *body = [self cardBodyIn:card];

    [body addArrangedSubview:[self cardHeaderWithSymbol:@"hand.tap.fill"
                                                  title:@"On-screen controls"]];

    UILabel *l = [[UILabel alloc] init];
    l.text = @"No controller? The on-screen touch gamepad — D-pad, face "
             @"buttons, shoulders, START/SELECT and two analog sticks — is "
             @"always available in-game from the Emulator screen.";
    l.textColor = V3KText();
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    l.numberOfLines = 0;
    [body addArrangedSubview:l];
    return card;
}

#pragma mark - Notifications

- (void)controllersChanged:(NSNotification *)note {
    // Notifications may arrive on a background queue; bounce to main.
    if ([NSThread isMainThread]) {
        [self refreshControllers];
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf refreshControllers];
        });
    }
}

#pragma mark - Small building blocks

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
        UIImage *img = [UIImage systemImageNamed:symbol];
        if (img) {
            UIImageView *icon = [[UIImageView alloc] initWithImage:img];
            icon.tintColor = V3KGold();
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [icon.widthAnchor constraintEqualToConstant:20.0].active = YES;
            [icon.heightAnchor constraintEqualToConstant:20.0].active = YES;
            [row addArrangedSubview:icon];
        }
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.textColor = V3KGold();
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [row addArrangedSubview:label];

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow
                              forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:spacer];
    return row;
}

- (UILabel *)captionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = [text uppercaseString];
    l.textColor = V3KSubtext();
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return l;
}

- (UIView *)hairline {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [V3KSubtext() colorWithAlphaComponent:0.14];
    [line.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return line;
}

@end
