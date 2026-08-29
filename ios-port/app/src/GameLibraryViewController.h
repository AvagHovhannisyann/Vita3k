// GameLibraryViewController.h — the Library tab root: a grid of installed Vita
// titles scanned from ux0:/app, with import (.vpk / .pkg), delete, and launch.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Grid of installed titles from [[Vita3KCore shared] installedTitles].
/// Tapping a title boots it full-screen in the EmulatorViewController.
@interface GameLibraryViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
