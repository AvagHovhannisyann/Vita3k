// FirstRunSetupViewController.h — friendly first-launch onboarding.
//
// A self-contained 3-step walkthrough shown the first time the app is opened:
//   1) Welcome / what Vita3K is (work-in-progress iOS port)
//   2) Enable JIT via StikDebug (with an inline "Test JIT now" probe)
//   3) Add firmware (PUP) & games (.vpk) from the Library tab / Files
//
// Talks to the emulator only through the Vita3KCore singleton. Persists the
// NSUserDefaults flag "v3k.setupDone" when finished and calls -onFinish (or
// dismisses itself if no handler was set).
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FirstRunSetupViewController : UIViewController

/// Invoked when the user finishes (or skips) setup, after the "v3k.setupDone"
/// default has been written. If nil, the controller dismisses itself instead.
@property (nonatomic, copy, nullable) void (^onFinish)(void);

@end

NS_ASSUME_NONNULL_END
