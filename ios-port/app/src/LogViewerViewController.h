// LogViewerViewController.h — read the emulator's own log and the last crash
// report on the device, and share them. Without this, a boot failure on iOS is
// invisible: the app simply vanishes and takes the reason with it.
#import <UIKit/UIKit.h>
@interface LogViewerViewController : UIViewController
@end
