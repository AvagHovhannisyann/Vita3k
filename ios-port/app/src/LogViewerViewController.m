#import "LogViewerViewController.h"
#import "Vita3KCore.h"
#import "CrashReporter.h"
#import "JitArena.h"
#import "Theme.h"

@implementation LogViewerViewController {
    UISegmentedControl *_picker;
    UITextView *_text;
    NSArray<NSString *> *_paths;      // nil entry = synthesised, not a file
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = V3KBackground();
    self.title = self.title ?: @"Logs";

    _picker = [[UISegmentedControl alloc] initWithItems:@[@"Emulator", @"Crash", @"Environment"]];
    _picker.selectedSegmentIndex = V3KLastCrashReport().length ? 1 : 0;
    _picker.tintColor = V3KGold();
    if (@available(iOS 13.0, *)) _picker.selectedSegmentTintColor = V3KGold();
    [_picker addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _picker.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_picker];

    _text = [UITextView new];
    _text.editable = NO;
    _text.backgroundColor = V3KCard();
    _text.textColor = V3KText();
    _text.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    _text.alwaysBounceVertical = YES;
    [self.view addSubview:_text];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_picker.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [_picker.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [_picker.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_text.topAnchor constraintEqualToAnchor:_picker.bottomAnchor constant:12],
        [_text.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_text.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [_text.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(share:)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)],
    ];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }

- (NSString *)emulatorLogPath {
    // logging::init() writes vita3k.log under the data root's log path; older
    // trees put it at the root. Take whichever exists.
    NSString *root = Vita3KCore.shared.dataRoot;
    for (NSString *rel in @[@"vita3k.log", @"logs/vita3k.log", @"log/vita3k.log"]) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    }
    return [root stringByAppendingPathComponent:@"vita3k.log"];
}

// Read at most the last `maxBytes` so a multi-megabyte log cannot wedge the UI.
static NSString *tailOfFile(NSString *path, unsigned long long maxBytes) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    unsigned long long size = [fh seekToEndOfFile];
    unsigned long long from = size > maxBytes ? size - maxBytes : 0;
    [fh seekToFileOffset:from];
    NSData *d = [fh readDataToEndOfFile];
    [fh closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (from > 0) s = [NSString stringWithFormat:@"… (showing the last %llu KB of %llu KB)\n\n%@",
                       maxBytes >> 10, size >> 10, s ?: @""];
    return s;
}

- (NSString *)environmentReport {
    Vita3KCore *c = Vita3KCore.shared;
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"iOS %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    [s appendFormat:@"device: %@\n", UIDevice.currentDevice.model];
    [s appendFormat:@"core:   %@\n", c.coreVersion];
    [s appendFormat:@"linked: %@\n", c.coreLinked ? @"yes" : @"no (UI preview)"];
    [s appendFormat:@"CS:     %@\n", [c codeSigningFlagsDescription]];
    [s appendFormat:@"debugged: %@\n", c.processIsDebugged ? @"yes" : @"no"];
    [s appendFormat:@"arena:  %@\n", c.jitArenaStatus];
    [s appendFormat:@"  ready=%@ rx=%p rw=%p size=%lu MB used=%lu MB\n",
        c.jitArenaReady ? @"yes" : @"no", v3k_ios_jit_rx(), v3k_ios_jit_rw(),
        v3k_ios_jit_size() >> 20, v3k_ios_jit_used() >> 20];
    [s appendFormat:@"data:   %@\n", c.dataRoot];
    [s appendFormat:@"titles: %lu installed\n", (unsigned long)c.installedTitles.count];
    [s appendFormat:@"firmware: %@\n", c.firmwareInstalled ? @"installed" : @"missing"];
    [s appendString:@"\n--- JIT routes ---\n"];
    [s appendString:[c jitDiagnosticsReport]];
    return s;
}

- (void)reload {
    NSString *body;
    switch (_picker.selectedSegmentIndex) {
        case 1:
            body = V3KLastCrashReport();
            if (!body.length) body = @"No crash report.\n\nIf the app closes by itself while a game is loading, "
                                      "come back here afterwards — the reason is written before the process dies.";
            break;
        case 2:
            body = [self environmentReport];
            break;
        default: {
            NSString *p = [self emulatorLogPath];
            body = tailOfFile(p, 512 * 1024);
            if (!body.length) body = [NSString stringWithFormat:
                @"No emulator log yet at\n%@\n\nThe core writes this once a title starts booting.", p];
            break;
        }
    }
    _text.text = body;
    // Show the newest lines first-hand: scroll to the end for logs.
    if (_picker.selectedSegmentIndex == 0 && body.length > 1)
        [_text scrollRangeToVisible:NSMakeRange(body.length - 1, 1)];
    else
        [_text setContentOffset:CGPointZero animated:NO];
}

- (void)share:(UIBarButtonItem *)sender {
    NSString *body = _text.text ?: @"";
    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[body] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:av animated:YES completion:nil];
}

@end
