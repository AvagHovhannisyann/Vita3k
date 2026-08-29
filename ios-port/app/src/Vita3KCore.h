// Vita3KCore.h — the bridge between the iOS front-end and the Vita3K emulator
// core. This is the iOS equivalent of the Android app's NativeLib/JNI surface.
// The UI is written entirely against THIS interface; the native core (built
// from the Vita3K C++ sources — libVita3K + dynarmic + MoltenVK) is linked in
// behind it later. Until then a stub implementation returns honest placeholders
// so the whole front-end compiles, runs, and can be navigated on device.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A Vita title installed under ux0:/app/<titleId>.
@interface V3KTitle : NSObject
@property (nonatomic, copy)   NSString *titleId;     // e.g. "PCSF00438"
@property (nonatomic, copy)   NSString *name;        // display name from param.sfo
@property (nonatomic, copy, nullable) NSString *iconPath;  // path to icon0.png
@property (nonatomic, copy, nullable) NSString *category;  // "gd" (game), "gp" (patch)...
@property (nonatomic, copy, nullable) NSString *version;   // APP_VER, e.g. "01.00"
@property (nonatomic, copy, nullable) NSString *region;    // derived from titleId prefix
@property (nonatomic, copy)   NSString *appPath;     // ux0:/app/<titleId> on disk
@property (nonatomic, assign) unsigned long long sizeBytes;
@end

typedef NS_ENUM(NSInteger, V3KJITState) {
    V3KJITUnknown = 0,
    V3KJITUnavailable,     // not debugged / StikDebug not attached
    V3KJITReady,           // JIT26 handshake done, executable arena prepared
    V3KJITFailed,
};

@interface Vita3KCore : NSObject

+ (instancetype)shared;

/// YES once the native emulator core library is actually linked in.
@property (nonatomic, readonly) BOOL coreLinked;
/// Human-readable one-liner about core + JIT readiness (shown in the UI).
@property (nonatomic, readonly) NSString *statusLine;
/// Vita3K version string of the linked core (or "not linked").
@property (nonatomic, readonly) NSString *coreVersion;

/// Root of the emulator data tree (Documents/vita3k). ux0/, vs0/, etc. live here.
@property (nonatomic, readonly) NSString *dataRoot;

// --- JIT (iOS 26 / StikDebug JIT26 protocol) ---
@property (nonatomic, readonly) V3KJITState jitState;
/// Run the JIT26 brk handshake to prepare an executable arena. Requires the
/// process to be debugged (StikDebug attached). Safe to call when not debugged
/// (returns NO, fills error). Never crashes.
- (BOOL)prepareJITWithError:(NSError **_Nullable)error;

/// YES if the process is currently marked debugged (csops CS_DEBUGGED).
@property (nonatomic, readonly) BOOL processIsDebugged;
/// Decoded code-signing flags, e.g. "0x32003005 [valid get-task-allow enforcement
/// require-LV dyld-platform DEBUGGED signed]".
- (NSString *)codeSigningFlagsDescription;
/// Open StikDebug and ask it to enable JIT for this app, binding universal.js
/// (the script that answers the brk handshake). Returns NO if StikDebug isn't
/// installed. THIS is the step most users are missing: without an attached
/// script StikDebug does a bare attach — CS_DEBUGGED gets set but no executable
/// region is ever prepared, so every execute faults.
- (BOOL)requestJITViaStikDebug;
/// YES if a StikDebug-compatible URL handler is present.
@property (nonatomic, readonly) BOOL stikDebugAvailable;

/// Run EVERY known route to executable memory and return a full multi-line
/// report (which strategy worked, or how each failed, with signal names).
/// Never crashes: all probes are fault-guarded. Safe to call repeatedly.
- (NSString *)jitDiagnosticsReport;

// --- Titles ---
/// Scan ux0:/app for installed titles.
- (NSArray<V3KTitle *> *)installedTitles;
/// Install a .vpk synchronously (real zip extraction into ux0:/app). Kept for
/// simple callers; prefer installPackageAtURL:progress:completion: for a UI.
- (BOOL)importPackageAtURL:(NSURL *)url error:(NSError **_Nullable)error;
/// Preview a .vpk before installing: returns its param.sfo fields (TITLE,
/// TITLE_ID, APP_VER, CATEGORY...) or nil if not readable.
- (nullable NSDictionary<NSString *, id> *)inspectPackageAtURL:(NSURL *)url;
/// Install a .vpk (a zip): extracts it into ux0:/app/<titleId>. `progress` is
/// called 0..1 on a background thread. The `completion` runs on the main queue.
- (void)installPackageAtURL:(NSURL *)url
                   progress:(void (^_Nullable)(double))progress
                 completion:(void (^)(BOOL ok, NSString *_Nullable titleId, NSError *_Nullable error))completion;
/// Import a firmware PUP (staged into the data tree for the core to install).
- (BOOL)importFirmwareAtURL:(NSURL *)url error:(NSError **_Nullable)error;
/// Delete an installed title.
- (BOOL)deleteTitle:(V3KTitle *)title error:(NSError **_Nullable)error;

/// Save-data folders for a title (ux0:/user/00/savedata/<id>*), by path.
- (NSArray<NSString *> *)saveDataPathsForTitle:(V3KTitle *)title;
/// Whether firmware appears installed (vs0 populated).
@property (nonatomic, readonly) BOOL firmwareInstalled;

// --- Emulation ---
/// Boot a title into the given Metal-backed layer. (Stub reports not-ready.)
- (void)bootTitleId:(NSString *)titleId inLayer:(CALayer *)layer;
/// Deliver a control event to the running core (button masks / analog).
- (void)sendButtons:(uint32_t)pressedMask;
- (void)sendLeftStickX:(float)x y:(float)y;
- (void)sendRightStickX:(float)x y:(float)y;
- (void)sendTouchFront:(CGPoint)normalizedPoint down:(BOOL)down;
/// Stop the running title.
- (void)shutdown;

@end

// PS Vita button bit masks (match SceCtrlButtons ordering).
typedef NS_OPTIONS(uint32_t, V3KButton) {
    V3KBtnSelect   = 1u << 0,
    V3KBtnStart    = 1u << 3,
    V3KBtnUp       = 1u << 4,
    V3KBtnRight    = 1u << 5,
    V3KBtnDown     = 1u << 6,
    V3KBtnLeft     = 1u << 7,
    V3KBtnLTrigger = 1u << 8,
    V3KBtnRTrigger = 1u << 9,
    V3KBtnTriangle = 1u << 12,
    V3KBtnCircle   = 1u << 13,
    V3KBtnCross    = 1u << 14,
    V3KBtnSquare   = 1u << 15,
};

NS_ASSUME_NONNULL_END
