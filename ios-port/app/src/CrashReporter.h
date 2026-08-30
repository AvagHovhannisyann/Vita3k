// CrashReporter.h — capture why the emulator died, on the device, where we
// cannot attach a debugger.
//
// This is not a nicety. The only test rig for this port is the user's iPad: if
// the core faults during boot the app just disappears, and without this we
// learn nothing from that. So a fatal signal is written to a file BEFORE the
// process dies, including whether the faulting address was inside the JIT
// arena — which is the single most useful bit of information when the
// recompiler is involved.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Install fatal-signal and uncaught-exception handlers. Call once at launch.
/// `directory` is where crash.log is written (the emulator data root).
void V3KInstallCrashReporter(NSString *directory);

/// Contents of the crash report from a previous run, or nil if the last run
/// exited cleanly.
NSString *_Nullable V3KLastCrashReport(void);

/// Path of the crash report file (whether or not it exists).
NSString *V3KCrashReportPath(void);

/// Delete the stored report (after the user has seen it).
void V3KClearLastCrashReport(void);

NS_ASSUME_NONNULL_END
