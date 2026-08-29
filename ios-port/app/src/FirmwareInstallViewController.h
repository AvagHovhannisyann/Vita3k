// FirmwareInstallViewController.h — the "Install firmware" screen.
//
// Shows whether the PS Vita system firmware is present and lets the user import
// their own PSP2UPDAT.PUP. The PS Vita firmware is required to run most games
// and is NOT bundled with Vita3K — the user provides it themselves, legally,
// from their own console / Sony. This screen never links to or ships firmware.
//
// Pure front-end: it reaches the emulator only through the Vita3KCore.h façade
// (firmwareInstalled / importFirmwareAtURL:error:) and never touches the native
// core directly. Constructed with the default -init and pushed / presented from
// the setup flow, the library, or Settings.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Scrollable dark-themed firmware screen. Default -init.
@interface FirmwareInstallViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
