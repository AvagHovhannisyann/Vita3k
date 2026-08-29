// EmulatorViewController.h — the full-screen in-game screen.
//
// Boots a single Vita title into a Metal-backed surface and overlays a fully
// usable on-screen PS Vita gamepad (D-pad, face-button diamond, L/R shoulders,
// START/SELECT, and two draggable analog sticks). Prefers landscape, hides the
// status bar and home indicator. Talks to the emulator only through the
// Vita3KCore singleton.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-screen emulator host. Present modally, full screen, from the library.
@interface EmulatorViewController : UIViewController

/// Boot the title installed under ux0:/app/<titleId>.
- (instancetype)initWithTitleId:(NSString *)titleId;

@end

NS_ASSUME_NONNULL_END
