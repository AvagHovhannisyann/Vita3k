// AppDelegate.m — Vita3K iOS front-end entry. Tabbed shell: Library / Settings /
// About. The emulator screen is presented full-screen from the Library.
#import <UIKit/UIKit.h>
#import "Theme.h"
#import "Vita3KCore.h"
#import "CrashReporter.h"
#import "GameLibraryViewController.h"
#import "SettingsViewController.h"
#import "AboutViewController.h"
#import "FirstRunSetupViewController.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Vita3KCore.shared self];   // spin up the bridge + data tree early
    // Install this before anything else can fault: on a device we cannot attach
    // a debugger to, an unreported crash teaches us nothing.
    V3KInstallCrashReporter(Vita3KCore.shared.dataRoot);

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    UITabBarController *tabs = [UITabBarController new];
    tabs.tabBar.barTintColor = V3KCard();
    tabs.tabBar.tintColor = V3KGold();
    tabs.tabBar.unselectedItemTintColor = V3KSubtext();

    UIViewController *library  = [GameLibraryViewController new];
    library.title = @"Library";
    UIViewController *settings = [SettingsViewController new];
    settings.title = @"Settings";
    UIViewController *about    = [AboutViewController new];
    about.title = @"About";

    UINavigationController *(^wrap)(UIViewController *, NSString *) =
        ^(UIViewController *vc, NSString *sys) {
            UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:vc];
            nc.navigationBar.barTintColor = V3KCard();
            nc.navigationBar.titleTextAttributes = @{ NSForegroundColorAttributeName: V3KText() };
            nc.tabBarItem = [[UITabBarItem alloc] initWithTitle:vc.title
                                                          image:[UIImage systemImageNamed:sys] tag:0];
            return nc;
        };

    tabs.viewControllers = @[ wrap(library, @"square.grid.2x2.fill"),
                              wrap(settings, @"gearshape.fill"),
                              wrap(about, @"info.circle.fill") ];

    self.window.rootViewController = tabs;
    self.window.backgroundColor = V3KBackground();
    [self.window makeKeyAndVisible];

    // First launch: show the setup/onboarding (JIT + firmware + games guide).
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"v3k.setupDone"]) {
        FirstRunSetupViewController *setup = [FirstRunSetupViewController new];
        setup.modalPresentationStyle = UIModalPresentationFullScreen;
        __weak UITabBarController *wtabs = tabs;
        setup.onFinish = ^{ [wtabs dismissViewControllerAnimated:YES completion:nil]; };
        dispatch_async(dispatch_get_main_queue(), ^{ [tabs presentViewController:setup animated:NO completion:nil]; });
    }
    return YES;
}

// The moment we come back from StikDebug is the ONLY moment the executable
// arena can be reserved: the JIT26 handshake works exactly once per attach, and
// only while the debugger is still there. So grab it here, automatically,
// instead of relying on the user to remember a button. Idempotent and safe when
// no debugger is attached (it just reports JIT unavailable).
- (void)applicationDidBecomeActive:(UIApplication *)application {
    Vita3KCore *core = Vita3KCore.shared;
    if (core.jitArenaReady) return;               // already have it — never re-handshake
    if (!core.processIsDebugged) return;          // nothing to talk to
    [core prepareJITWithCompletion:^(BOOL ok, NSError *error) {
        NSLog(@"[Vita3K] auto JIT arena: %@ (%@)", ok ? @"ready" : @"failed",
              ok ? core.jitArenaStatus : (error.localizedDescription ?: @"unknown"));
    }];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
