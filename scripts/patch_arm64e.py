#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
arm64e PAC 后处理（clang19 / ld64 956 构建的 iOS 二进制）。

clang19 生成的 arm64e 切片里有两类指针缺少 PAC 认证，加载即崩：

1. __DATA_CONST,__cfstring 的 isa
   -> 普通 bind，objc_msgSend 遇到常量字符串接收者时 SIGBUS。
   需要改写为 auth bind24：diversity=0x6AE1, addrDiv=1, key=2。

2. __DATA,__objc_data 中每个 class_t 的
      isa       (结构体偏移 0x00)
      superclass(结构体偏移 0x08)
   同 Xcode 产物对比，isa 需要 auth(div=0x6AE1)，superclass 需要
   auth(div=0xB5AB)，addrDiv=1, key=2。缺失时 objc readClass()
   在 map_images 阶段做指针认证会 SIGBUS（设置面板点击即闪退）。

3. __DATA_CONST,__const 中的 __NSConcreteGlobalBlock isa 使用对象 isa 认证。

改编自 LSTimeSeconds iOS 17 port；许可见 patch_arm64e.LICENSE。

用法：python3 patch_arm64e.py <macho>
arm64 切片不需要处理（无 PAC 语义）；非 FAT/无 arm64e 时直接跳过。
"""
import struct
import sys

CHAINED = 0x80000034
SEGMENT64 = 0x19

ISA_DIV = 0x6AE1
SUPERCLASS_DIV = 0xB5AB
AUTH_KEY = 2          # IA key


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def encode_auth_bind24(ordinal, diversity, next_delta):
    return ((ordinal & 0xFFFFFF)
            | (0 << 24)
            | ((diversity & 0xFFFF) << 32)
            | (1 << 48)          # addrDiv
            | (AUTH_KEY << 49)
            | ((next_delta & 0x7FF) << 51)
            | (1 << 62)          # bind
            | (1 << 63))         # auth


def encode_auth_rebase24(target, diversity, next_delta):
    return ((target & 0xFFFFFFFF)
            | ((diversity & 0xFFFF) << 32)
            | (1 << 48)
            | (AUTH_KEY << 49)
            | ((next_delta & 0x7FF) << 51)
            | (0 << 62)
            | (1 << 63))


def patch_slice(d, off):
    ncmds = u32(d, off + 16)
    q = off + 32
    segs = []
    fixups = None
    for _ in range(ncmds):
        cmd, csz = u32(d, q), u32(d, q + 4)
        if cmd == SEGMENT64:
            name = bytes(d[q + 8:q + 24]).rstrip(b"\0").decode()
            vmaddr = u64(d, q + 24)
            vmsize = u64(d, q + 32)
            fileoff = u64(d, q + 40)
            filesize = u64(d, q + 48)
            nsects = u32(d, q + 64)
            secs = []
            for j in range(nsects):
                b = q + 72 + j * 80
                sname = bytes(d[b:b + 16]).rstrip(b"\0").decode()
                addr = u64(d, b + 32)
                size = u64(d, b + 40)
                soff = u32(d, b + 48)          # slice 内绝对文件偏移
                secs.append((sname, addr, size, off + soff))
            segs.append((name, vmaddr, vmsize, fileoff, filesize, secs))
        elif cmd == CHAINED:
            fixups = u32(d, q + 8)
        q += csz

    if fixups is None:
        raise ValueError("arm64e slice has no chained fixups")

    text_base = next((vmaddr for name, vmaddr, _vmsize, _fo, _fs, _secs in segs
                      if name == "__TEXT"), None)
    if text_base is None:
        raise ValueError("arm64e slice has no __TEXT segment")

    def section_at(file_offset):
        for name, _vmaddr, _vmsize, _fo, _fs, secs in segs:
            for sname, _addr, size, soff in secs:
                if soff <= file_offset < soff + size:
                    return "%s,%s" % (name, sname), soff
        return None, None

    def vm_to_file(vm_offset):
        vm_offset += text_base
        for name, vmaddr, vmsize, fo, fs, secs in segs:
            if vmaddr <= vm_offset < vmaddr + vmsize:
                return off + fo + (vm_offset - vmaddr)
        return None

    base = off + fixups
    starts_off = u32(d, base + 4)
    imports_off = u32(d, base + 8)
    symbols_off = u32(d, base + 12)
    imports_count = u32(d, base + 16)
    imports_format = u32(d, base + 20)
    if imports_format not in (1, 2, 3):
        raise ValueError("unsupported chained import format: %d" % imports_format)

    def import_name(ordinal):
        if ordinal >= imports_count:
            raise ValueError("chained import ordinal is out of range")
        stride = {1: 4, 2: 8, 3: 16}[imports_format]
        entry_offset = base + imports_off + ordinal * stride
        name_offset = (u64(d, entry_offset) >> 32) if imports_format == 3 \
            else (u32(d, entry_offset) >> 9)
        begin = base + symbols_off + name_offset
        return bytes(d[begin:d.index(0, begin)]).decode("utf-8")

    seg_count = u32(d, base + starts_off)

    cf_patched = 0
    objc_patched = 0
    block_patched = 0

    for si in range(seg_count):
        so = u32(d, base + starts_off + 4 + si * 4)
        if so == 0:
            continue
        sbase = base + starts_off + so
        _size, page_size, pointer_format, seg_vmoff, _mv, page_count = \
            struct.unpack_from("<IHHQIH", d, sbase)
        if pointer_format != 12:          # 仅 arm64e (USERLAND24)
            raise ValueError("unsupported chained pointer format: %d" % pointer_format)
        for p in range(page_count):
            ps = u16(d, sbase + 22 + p * 2)
            if ps == 0xFFFF:
                continue
            if ps & 0x8000:
                raise ValueError("unsupported multi-start page: %d %d" % (si, p))
            page_file = vm_to_file(seg_vmoff + p * page_size)
            if page_file is None:
                raise ValueError("chained fixup page is outside file-backed segments")
            cur = page_file + ps
            while True:
                raw = u64(d, cur)
                bind = (raw >> 62) & 1
                auth = (raw >> 63) & 1
                nxt = (raw >> 51) & 0x7FF
                secname, sec_off = section_at(cur)

                def patch_bind(diversity):
                    if ((raw >> 32) & 0x7FFFF) != 0:
                        raise ValueError("cannot authenticate a bind with an addend")
                    d[cur:cur + 8] = struct.pack(
                        "<Q", encode_auth_bind24(raw & 0xFFFFFF, diversity, nxt))

                if secname and secname.endswith("__cfstring"):
                    if bind and not auth and (cur - sec_off) % 32 == 0:
                        patch_bind(ISA_DIV)
                        cf_patched += 1
                elif secname == "__DATA_CONST,__const" and bind and not auth and \
                        import_name(raw & 0xFFFFFF) == "__NSConcreteGlobalBlock":
                    patch_bind(ISA_DIV)
                    block_patched += 1
                elif secname and secname.endswith("__objc_data"):
                    rel = cur - sec_off
                    if rel % 0x28 == 0:            # class/metaclass isa
                        diversity = ISA_DIV
                    elif rel % 0x28 == 8:          # class/metaclass superclass
                        diversity = SUPERCLASS_DIV
                    else:
                        diversity = None
                    if diversity is not None and not auth:
                        if bind:
                            patch_bind(diversity)
                        else:
                            if (raw & ((1 << 43) - 1)) > 0xFFFFFFFF or ((raw >> 43) & 0xFF):
                                raise ValueError("class rebase target cannot be represented safely")
                            newv = encode_auth_rebase24(raw & 0xFFFFFFFF, diversity, nxt)
                            d[cur:cur + 8] = struct.pack("<Q", newv)
                        objc_patched += 1
                    elif diversity is not None and auth:
                        if ((raw >> 32) & 0xFFFF) != diversity or \
                                ((raw >> 48) & 1) != 1 or ((raw >> 49) & 3) != AUTH_KEY:
                            raise ValueError("class pointer has unexpected authentication")

                if nxt == 0:
                    break
                cur += 8 * nxt
    return cf_patched, objc_patched, block_patched


def main(path):
    d = bytearray(open(path, "rb").read())
    total_cf = total_objc = total_block = 0
    arm64e_found = False
    if u32(d, 0) == 0xFEEDFACF:
        slices = [(u32(d, 4), u32(d, 8), 0)]
    elif struct.unpack_from(">I", d, 0)[0] == 0xCAFEBABE:
        nfat = struct.unpack_from(">I", d, 4)[0]
        slices = [struct.unpack_from(">III", d, 8 + i * 20) for i in range(nfat)]
    else:
        raise ValueError("unsupported Mach-O format")
    for ct, sub, off in slices:
        if ct != 0x0100000C or (sub & 0x00FFFFFF) != 2:
            continue
        arm64e_found = True
        cf, objc, block = patch_slice(d, off)
        total_cf += cf
        total_objc += objc
        total_block += block
        print("  arm64e: cfstring=%d objc=%d global-block=%d" % (cf, objc, block))

    if not arm64e_found:
        print("  arm64e slice is absent; no patch needed")
        return 0

    open(path, "wb").write(bytes(d))
    print("  %s: complete (cfstring=%d, objc=%d, global-block=%d)"
          % (path.split("/")[-1], total_cf, total_objc, total_block))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_arm64e.py <macho>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
