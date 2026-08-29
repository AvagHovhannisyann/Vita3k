#import "JitDiagnosticsViewController.h"
#import "Vita3KCore.h"
#import "Theme.h"

@implementation JitDiagnosticsViewController {
    UITextView *_report;
    UILabel *_headline;
    UIButton *_run;
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

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_headline.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [_headline.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_headline.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_report.topAnchor constraintEqualToAnchor:_headline.bottomAnchor constant:14],
        [_report.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_report.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_report.bottomAnchor constraintEqualToAnchor:_run.topAnchor constant:-14],
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
