// AppDelegate.m — Vita3K iOS front-end entry. Tabbed shell: Library / Settings /
// About. The emulator screen is presented full-screen from the Library.
#import <UIKit/UIKit.h>
#import "Theme.h"
#import "Vita3KCore.h"
#import "GameLibraryViewController.h"
#import "SettingsViewController.h"
#import "AboutViewController.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Vita3KCore.shared self];   // spin up the bridge + data tree early

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
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
