// AboutViewController.h — "About" screen for the Vita3K iOS front-end.
// Presents build/version/status information, a one-tap "Enable JIT (iOS 26)"
// action wired to the core's JIT26 handshake, an honest description of what
// this work-in-progress port can and cannot do yet, and project links.
//
// Pure front-end: it reads the core only through the Vita3KCore.h façade and
// never touches the native emulator directly. Constructed with the default
// -init and presented from the tab bar / a navigation stack.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Scrollable dark-themed "About" screen. Default -init.
@interface AboutViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
