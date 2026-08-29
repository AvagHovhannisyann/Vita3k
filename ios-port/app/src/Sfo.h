// Sfo.h — parser for the PS Vita param.sfo metadata format.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Parse a param.sfo file. Returns a dict of key -> (NSString for UTF8/UTF8S
/// entries, NSNumber for integer entries). nil on malformed input.
/// Common keys: TITLE, TITLE_ID, STITLE, APP_VER, CATEGORY, PSP2_DISP_VER,
/// PARENTAL_LEVEL, CONTENT_ID.
NSDictionary<NSString *, id> *_Nullable V3KParseSfoAtPath(NSString *path);
NSDictionary<NSString *, id> *_Nullable V3KParseSfoData(NSData *data);

NS_ASSUME_NONNULL_END
