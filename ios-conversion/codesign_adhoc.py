#!/usr/bin/env python3
"""
Dependency-free ad-hoc Mach-O code signer that embeds an XML entitlements blob.

It rebuilds the LC_CODE_SIGNATURE payload (already reserved by lld -adhoc_codesign)
into a proper CSMAGIC_EMBEDDED_SIGNATURE SuperBlob containing:
  - a CodeDirectory (v0x20400, SHA-256) hashing every page of the image,
  - an empty Requirements set,
  - an Entitlements blob (so get-task-allow is embedded and inspectable).

This is an ad-hoc signature: on device the real trust comes from Sideloadly
re-signing with the user's Apple ID (which, for a free account, forces
get-task-allow=true anyway). The embedded entitlements make the produced
artifact self-describing and let `codesign -d --entitlements` report them.

Usage: codesign_adhoc.py <macho> <bundle-id> <entitlements.plist> <Info.plist>
"""
import sys, struct, hashlib

LC_SEGMENT_64      = 0x19
LC_CODE_SIGNATURE  = 0x1d

CSMAGIC_EMBEDDED_SIGNATURE   = 0xfade0cc0
CSMAGIC_CODEDIRECTORY        = 0xfade0c02
CSMAGIC_REQUIREMENTS         = 0xfade0c01
CSMAGIC_EMBEDDED_ENTITLEMENTS= 0xfade7171

CSSLOT_CODEDIRECTORY = 0
CSSLOT_REQUIREMENTS  = 2
CSSLOT_ENTITLEMENTS  = 5

CS_ADHOC             = 0x0000002
CS_EXECSEG_MAIN_BINARY = 0x1
PAGE = 4096

def align(x, a):
    return (x + a - 1) & ~(a - 1)

def main():
    path, ident, ent_path, info_path = sys.argv[1:5]
    data = bytearray(open(path, "rb").read())
    ent_xml  = open(ent_path, "rb").read()
    info_xml = open(info_path, "rb").read()

    magic = struct.unpack_from("<I", data, 0)[0]
    assert magic == 0xfeedfacf, "not a 64-bit little-endian Mach-O (0x%x)" % magic
    ncmds = struct.unpack_from("<I", data, 16)[0]

    text_vmsize = None
    le_off = le_fileoff = None
    le_lc = cs_lc = None
    o = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, o)
        if cmd == LC_SEGMENT_64:
            segname = data[o+8:o+24].split(b"\x00")[0]
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, o+24)
            if segname == b"__TEXT":
                text_vmsize = vmsize
            elif segname == b"__LINKEDIT":
                le_lc = o; le_fileoff = fileoff
        elif cmd == LC_CODE_SIGNATURE:
            cs_lc = o
        o += cmdsize
    assert cs_lc is not None, "no LC_CODE_SIGNATURE (link with -adhoc_codesign first)"
    assert le_lc is not None and text_vmsize is not None

    code_limit = struct.unpack_from("<I", data, cs_lc + 8)[0]   # existing dataoff

    # ---- build the sub-blobs -------------------------------------------------
    req_blob = struct.pack(">III", CSMAGIC_REQUIREMENTS, 12, 0)                  # empty requirements set
    ent_blob = struct.pack(">II", CSMAGIC_EMBEDDED_ENTITLEMENTS, 8 + len(ent_xml)) + ent_xml

    ident_b = ident.encode() + b"\x00"
    n_special = 5
    n_code = (code_limit + PAGE - 1) // PAGE
    HDR = 88                                    # fixed CodeDirectory header, version 0x20400
    ident_off = HDR
    hash_off = HDR + len(ident_b) + n_special * 32
    cd_len = HDR + len(ident_b) + (n_special + n_code) * 32

    # SuperBlob layout: header, then CodeDirectory, Requirements, Entitlements
    sb_hdr = 12 + 3 * 8
    cd_off  = sb_hdr
    req_off = cd_off + cd_len
    ent_off = req_off + len(req_blob)
    sb_len  = ent_off + len(ent_blob)

    # ---- patch header fields BEFORE hashing (they are inside the hashed image) ----
    struct.pack_into("<I", data, cs_lc + 12, sb_len)            # LC_CODE_SIGNATURE.datasize
    new_filesize = (code_limit + sb_len) - le_fileoff
    new_vmsize = align(new_filesize, 0x4000)
    struct.pack_into("<Q", data, le_lc + 32, new_vmsize)       # __LINKEDIT vmsize
    struct.pack_into("<Q", data, le_lc + 48, new_filesize)     # __LINKEDIT filesize

    image = bytes(data[:code_limit])

    # ---- special slot hashes (stored in order slot -5 .. -1) -----------------
    def sha(b): return hashlib.sha256(b).digest()
    z = b"\x00" * 32
    h_ent  = sha(ent_blob)                 # slot 5  (index -5)
    h_app  = z                             # slot 4
    h_res  = z                             # slot 3
    h_req  = sha(req_blob)                 # slot 2
    h_info = sha(info_xml)                 # slot 1
    specials = h_ent + h_app + h_res + h_req + h_info

    code_hashes = b"".join(
        sha(image[i*PAGE:min((i+1)*PAGE, code_limit)]) for i in range(n_code)
    )

    # ---- CodeDirectory -------------------------------------------------------
    cd = struct.pack(">IIIIIIIII",
                     CSMAGIC_CODEDIRECTORY, cd_len, 0x20400, CS_ADHOC,
                     hash_off, ident_off, n_special, n_code, code_limit)
    cd += struct.pack(">BBBB", 32, 2, 0, 12)          # hashSize, hashType(SHA256), platform, pageSize log2
    cd += struct.pack(">I", 0)                        # spare2
    cd += struct.pack(">I", 0)                        # scatterOffset
    cd += struct.pack(">I", 0)                        # teamOffset
    cd += struct.pack(">I", 0)                        # spare3
    cd += struct.pack(">Q", 0)                        # codeLimit64
    cd += struct.pack(">Q", 0)                        # execSegBase (__TEXT fileoff)
    cd += struct.pack(">Q", text_vmsize)              # execSegLimit
    cd += struct.pack(">Q", CS_EXECSEG_MAIN_BINARY)   # execSegFlags
    assert len(cd) == HDR, "CD header %d != %d" % (len(cd), HDR)
    cd += ident_b + specials + code_hashes
    assert len(cd) == cd_len, "CD len %d != %d" % (len(cd), cd_len)

    # ---- SuperBlob -----------------------------------------------------------
    sb = struct.pack(">III", CSMAGIC_EMBEDDED_SIGNATURE, sb_len, 3)
    sb += struct.pack(">II", CSSLOT_CODEDIRECTORY, cd_off)
    sb += struct.pack(">II", CSSLOT_REQUIREMENTS,  req_off)
    sb += struct.pack(">II", CSSLOT_ENTITLEMENTS,  ent_off)
    sb += cd + req_blob + ent_blob
    assert len(sb) == sb_len, "SB len %d != %d" % (len(sb), sb_len)

    final = bytes(data[:code_limit]) + sb
    open(path, "wb").write(final)
    print("ad-hoc signed: %s" % path)
    print("  identifier      : %s" % ident)
    print("  codeLimit       : %d bytes (%d code pages)" % (code_limit, n_code))
    print("  signature size  : %d bytes at offset %d" % (sb_len, code_limit))
    print("  entitlements    : %d bytes embedded (slot 5)" % len(ent_xml))
    print("  file size        : %d bytes" % len(final))

if __name__ == "__main__":
    main()
