// Sfo.m — param.sfo (\0PSF) parser. Format is little-endian:
//   header: u32 magic(0x46535000) u32 version u32 keyTableStart u32 dataTableStart u32 count
//   index[count]: u16 keyOffset u16 dataFmt u32 dataLen u32 dataMaxLen u32 dataOffset
//   key table: NUL-terminated strings   |   data table: values
// dataFmt: 0x0004 UTF8-special(no NUL), 0x0204 UTF8 string, 0x0404 uint32.
#import "Sfo.h"

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

NSDictionary<NSString *, id> *V3KParseSfoData(NSData *data) {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    if (n < 20) return nil;
    if (rd32(b) != 0x46535000u) return nil;               // "\0PSF"
    uint32_t keyStart  = rd32(b + 8);
    uint32_t dataStart = rd32(b + 12);
    uint32_t count     = rd32(b + 16);
    if (count > 4096) return nil;                          // sanity
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (uint32_t i = 0; i < count; i++) {
        NSUInteger idx = 20 + (NSUInteger)i * 16;
        if (idx + 16 > n) break;
        const uint8_t *e = b + idx;
        uint16_t keyOff = rd16(e);
        uint16_t fmt    = rd16(e + 2);
        uint32_t dlen   = rd32(e + 4);
        uint32_t doff   = rd32(e + 12);

        NSUInteger kpos = keyStart + keyOff;
        if (kpos >= n) continue;
        NSUInteger kend = kpos;
        while (kend < n && b[kend] != 0) kend++;
        NSString *key = [[NSString alloc] initWithBytes:b + kpos length:kend - kpos encoding:NSUTF8StringEncoding];
        if (!key) continue;

        NSUInteger dpos = dataStart + doff;
        if (dpos > n) continue;
        uint32_t avail = (uint32_t)(n - dpos);
        if (dlen > avail) dlen = avail;

        if (fmt == 0x0404) {                               // uint32
            if (dlen >= 4) out[key] = @(rd32(b + dpos));
        } else {                                           // UTF8 string (0x0004 / 0x0204)
            NSUInteger slen = dlen;
            while (slen > 0 && b[dpos + slen - 1] == 0) slen--;   // trim trailing NULs
            NSString *val = [[NSString alloc] initWithBytes:b + dpos length:slen encoding:NSUTF8StringEncoding];
            if (val) out[key] = val;
        }
    }
    return out.count ? out : nil;
}

NSDictionary<NSString *, id> *V3KParseSfoAtPath(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? V3KParseSfoData(d) : nil;
}
