// Vpk.m — minimal ZIP reader for VPK packages, using the SDK's zlib for the
// DEFLATE path. Reads via a memory-mapped file so large packages don't blow up
// RAM. Handles stored (0) and deflate (8); ZIP64 is not handled (Vita VPK
// entries are well under 4 GiB).
#import "Vpk.h"
#import <zlib.h>

static uint16_t r16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t r32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

// Locate the End Of Central Directory record (scan back over any trailing comment).
static const uint8_t *find_eocd(const uint8_t *b, size_t n) {
    if (n < 22) return NULL;
    size_t maxBack = n < (22 + 65535) ? n : (22 + 65535);
    for (size_t i = 22; i <= maxBack; i++) {
        const uint8_t *p = b + n - i;
        if (r32(p) == 0x06054b50u) return p;
    }
    return NULL;
}

// Inflate `clen` bytes at `src` (raw deflate) into a buffer of `ulen` bytes.
static NSData *inflate_raw(const uint8_t *src, uint32_t clen, uint32_t ulen) {
    NSMutableData *out = [NSMutableData dataWithLength:ulen];
    z_stream s; memset(&s, 0, sizeof s);
    if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return nil;
    s.next_in = (Bytef *)src; s.avail_in = clen;
    s.next_out = out.mutableBytes; s.avail_out = ulen;
    int rc = inflate(&s, Z_FINISH);
    inflateEnd(&s);
    return (rc == Z_STREAM_END || rc == Z_OK) ? out : nil;
}

// Given a central-dir local-header offset, return (data ptr, comp size, uncomp
// size, method, name). Returns NULL data on error.
typedef struct { const uint8_t *data; uint32_t clen, ulen; uint16_t method; } LocalEntry;
static LocalEntry read_local(const uint8_t *b, size_t n, uint32_t localOff,
                             uint32_t clen, uint32_t ulen, uint16_t method) {
    LocalEntry e = {0};
    if ((size_t)localOff + 30 > n || r32(b + localOff) != 0x04034b50u) return e;
    uint16_t nameLen = r16(b + localOff + 26);
    uint16_t extraLen = r16(b + localOff + 28);
    size_t dataOff = (size_t)localOff + 30 + nameLen + extraLen;
    if (dataOff + clen > n) return e;
    e.data = b + dataOff; e.clen = clen; e.ulen = ulen; e.method = method;
    return e;
}

static NSData *decode_entry(LocalEntry e) {
    if (!e.data) return nil;
    if (e.method == 0) return [NSData dataWithBytes:e.data length:e.ulen];      // stored
    if (e.method == 8) return inflate_raw(e.data, e.clen, e.ulen);             // deflate
    return nil;
}

// Iterate central directory, invoking block(name, localOff, clen, ulen, method).
// Return NO from the block to stop early.
static BOOL iterate_cd(const uint8_t *b, size_t n,
                       BOOL (^block)(NSString *name, uint32_t localOff, uint32_t clen, uint32_t ulen, uint16_t method)) {
    const uint8_t *eocd = find_eocd(b, n);
    if (!eocd) return NO;
    uint16_t total = r16(eocd + 10);
    uint32_t cdOff = r32(eocd + 16);
    size_t p = cdOff;
    for (uint16_t i = 0; i < total; i++) {
        if (p + 46 > n || r32(b + p) != 0x02014b50u) break;
        uint16_t method  = r16(b + p + 10);
        uint32_t clen    = r32(b + p + 20);
        uint32_t ulen    = r32(b + p + 24);
        uint16_t nameLen = r16(b + p + 28);
        uint16_t extraLen= r16(b + p + 30);
        uint16_t cmtLen  = r16(b + p + 32);
        uint32_t localOff= r32(b + p + 42);
        if (p + 46 + nameLen > n) break;
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (name && !block(name, localOff, clen, ulen, method)) return YES;
        p += 46 + nameLen + extraLen + cmtLen;
    }
    return YES;
}

NSData *V3KZipReadEntry(NSString *zipPath, NSString *entryName) {
    NSData *file = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:nil];
    if (!file) return nil;
    const uint8_t *b = file.bytes; size_t n = file.length;
    __block NSData *result = nil;
    iterate_cd(b, n, ^BOOL(NSString *name, uint32_t lo, uint32_t cl, uint32_t ul, uint16_t m) {
        if ([name isEqualToString:entryName]) { result = decode_entry(read_local(b, n, lo, cl, ul, m)); return NO; }
        return YES;
    });
    return result;
}

BOOL V3KZipExtractAll(NSString *zipPath, NSString *destDir, void (^progress)(double), NSError **error) {
    NSData *file = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:error];
    if (!file) return NO;
    const uint8_t *b = file.bytes; size_t n = file.length;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

    // First pass: count entries for progress.
    __block int total = 0;
    iterate_cd(b, n, ^BOOL(NSString *name, uint32_t lo, uint32_t cl, uint32_t ul, uint16_t m) { total++; return YES; });
    if (total == 0) { if (error) *error = [NSError errorWithDomain:@"Vpk" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Not a valid VPK/zip"}]; return NO; }

    __block int done = 0; __block BOOL ok = YES;
    iterate_cd(b, n, ^BOOL(NSString *name, uint32_t lo, uint32_t cl, uint32_t ul, uint16_t m) {
        if (![name hasSuffix:@"/"]) {                              // skip directory entries
            // Prevent path traversal.
            if ([name containsString:@".."]) { ok = NO; return NO; }
            NSString *outPath = [destDir stringByAppendingPathComponent:name];
            [fm createDirectoryAtPath:outPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            NSData *content = decode_entry(read_local(b, n, lo, cl, ul, m));
            if (!content || ![content writeToFile:outPath atomically:NO]) { ok = NO; return NO; }
        }
        done++;
        if (progress) progress((double)done / (double)total);
        return YES;
    });
    if (!ok && error) *error = [NSError errorWithDomain:@"Vpk" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Failed to extract an entry"}];
    return ok;
}
