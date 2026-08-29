// GameDetailViewController.h — the per-title detail screen.
//
// Pushed from the Library when a title is selected. Shows the title's icon,
// name and metadata, a large PLAY button that boots it full-screen in the
// EmulatorViewController, its save-data folders, and a destructive Delete
// action. Talks to the emulator core only through the Vita3KCore singleton.
#import <UIKit/UIKit.h>

@class V3KTitle;

NS_ASSUME_NONNULL_BEGIN

/// Detail view for a single installed Vita title.
@interface GameDetailViewController : UIViewController

/// Build the detail screen for an already-scanned title.
- (instancetype)initWithTitle:(V3KTitle *)title;

@end

NS_ASSUME_NONNULL_END
