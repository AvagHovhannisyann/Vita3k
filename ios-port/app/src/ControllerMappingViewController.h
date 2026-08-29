// ControllerMappingViewController.h — controller pairing + live input map.
//
// Lists MFi/Bluetooth game controllers currently connected to the device
// (PlayStation, Xbox, MFi), and — while one is connected — shows a live view
// of its extendedGamepad inputs lighting up as the user presses them, which is
// how you confirm the physical pad reaches the Vita's buttons. When no
// controller is paired it explains where to pair one, and reminds the player
// that the on-screen touch gamepad on the Emulator screen is always available.
//
// Pure front-end: uses only Apple's GameController framework. Built with the
// default -init and pushed onto a navigation stack / shown from Settings.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Scrollable dark-themed controller-mapping screen. Default -init.
@interface ControllerMappingViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
