// SettingsViewController.h — grouped settings for the Vita3K iOS front-end.
// Every option is persisted to NSUserDefaults under the "v3k." key prefix; the
// emulator core reads these values back when a title is booted. This screen is
// pure UI + persistence — it never talks to the running core directly.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Dark-themed grouped settings table (Graphics / CPU / System / Controls /
/// Storage). Constructed with the default -init; presented from the tab bar.
@interface SettingsViewController : UITableViewController

/// Common defaults key prefix ("v3k."). Exposed so other screens / the core
/// bridge can read the same values without hard-coding the string.
@property (class, nonatomic, readonly) NSString *defaultsPrefix;

@end

NS_ASSUME_NONNULL_END
