#import "JitDiagnosticsViewController.h"
#import "Vita3KCore.h"
#import "Theme.h"

@implementation JitDiagnosticsViewController {
    UITextView *_report;
    UILabel *_headline;
    UIButton *_run;
    UIButton *_enable;
    NSTimer *_poll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"JIT Diagnostics";
    self.view.backgroundColor = V3KBackground();

    _headline = [UILabel new];
    _headline.font = [UIFont boldSystemFontOfSize:19];
    _headline.textColor = V3KGold();
    _headline.numberOfLines = 0;
    _headline.textAlignment = NSTextAlignmentCenter;
    _headline.text = @"Checking…";
    _headline.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_headline];

    _report = [UITextView new];
    _report.editable = NO;
    _report.backgroundColor = V3KCard();
    _report.textColor = V3KText();
    _report.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _report.layer.cornerRadius = 12;
    _report.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    _report.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_report];

    _run = [UIButton buttonWithType:UIButtonTypeSystem];
    [_run setTitle:@"Run JIT test" forState:UIControlStateNormal];
    [_run setTitleColor:V3KBackground() forState:UIControlStateNormal];
    _run.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    _run.backgroundColor = V3KGold();
    _run.layer.cornerRadius = 12;
    _run.translatesAutoresizingMaskIntoConstraints = NO;
    [_run addTarget:self action:@selector(runTest) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_run];

    _enable = [UIButton buttonWithType:UIButtonTypeSystem];
    [_enable setTitle:@"Enable JIT via StikDebug" forState:UIControlStateNormal];
    [_enable setTitleColor:V3KText() forState:UIControlStateNormal];
    _enable.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    _enable.backgroundColor = V3KCard();
    _enable.layer.cornerRadius = 12;
    _enable.layer.borderWidth = 1;
    _enable.layer.borderColor = V3KGold().CGColor;
    _enable.translatesAutoresizingMaskIntoConstraints = NO;
    [_enable addTarget:self action:@selector(enableViaStikDebug) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_enable];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_headline.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [_headline.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_headline.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_report.topAnchor constraintEqualToAnchor:_headline.bottomAnchor constant:14],
        [_report.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_report.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_report.bottomAnchor constraintEqualToAnchor:_enable.topAnchor constant:-14],
        [_enable.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_enable.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_enable.heightAnchor constraintEqualToConstant:52],
        [_enable.bottomAnchor constraintEqualToAnchor:_run.topAnchor constant:-10],
        [_run.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_run.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_run.heightAnchor constraintEqualToConstant:52],
        [_run.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
    ]];
    [self runTest];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Poll the debugged flag so the headline updates the moment StikDebug attaches.
    _poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        BOOL dbg = Vita3KCore.shared.processIsDebugged;
        self->_run.enabled = YES;
        if (dbg && ![self->_headline.text hasPrefix:@"JIT WORKS"]) {
            self->_headline.textColor = V3KGreen();
            self->_headline.text = @"Debugger attached — tap Run JIT test";
        }
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_poll invalidate]; _poll = nil;
}

- (void)enableViaStikDebug {
    if ([Vita3KCore.shared requestJITViaStikDebug]) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"StikDebug not found"
                         message:@"Install StikDebug 3.1.6 or newer, then in StikDebug long-press Vita3K, "
                                  "choose Attach Script and pick universal.js. Without an attached script "
                                  "StikDebug only marks the app debugged and never prepares executable memory."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runTest {
    NSString *r = [Vita3KCore.shared jitDiagnosticsReport];
    _report.text = r;
    if ([r containsString:@"JIT WORKS"]) {
        _headline.text = @"JIT WORKS ✓";
        _headline.textColor = V3KGreen();
    } else if ([r containsString:@"debugged: YES"]) {
        _headline.text = @"Debugged, but no executable memory yet";
        _headline.textColor = V3KGold();
    } else {
        _headline.text = @"Not debugged — enable JIT in StikDebug";
        _headline.textColor = V3KGold();
    }
}

@end
