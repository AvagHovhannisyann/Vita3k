// Vpk.h — minimal reader/extractor for VPK packages (which are ZIP archives).
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Read a single entry (e.g. @"sce_sys/param.sfo") from a VPK/zip into memory.
NSData *_Nullable V3KZipReadEntry(NSString *zipPath, NSString *entryName);

/// Extract the whole VPK/zip into destDir (created if needed). Returns YES on
/// success. `progress` (optional) is called on an arbitrary thread with a value
/// in 0..1 as entries complete.
BOOL V3KZipExtractAll(NSString *zipPath, NSString *destDir,
                      void (^_Nullable progress)(double), NSError **_Nullable error);

NS_ASSUME_NONNULL_END
