#!/usr/bin/env python3
"""Sign arm64e stack-block isa fields in LLVM IR emitted by Procursus clang 16."""
from __future__ import annotations

import re
import sys
from pathlib import Path

STORE = re.compile(
    r'^(?P<indent>[ \t]*)store ptr @(?P<symbol>_NSConcrete(?:Stack|Global)Block), '
    r'ptr (?P<slot>%[-a-zA-Z$._0-9]+|%"[^"]+")(?P<suffix>,.*)$',
    re.MULTILINE,
)


def sign_stack_blocks(ir: str) -> tuple[str, int]:
    count = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal count
        number = count
        count += 1
        indent, symbol, slot, suffix = (match.group(k) for k in ('indent', 'symbol', 'slot', 'suffix'))
        prefix = f'%vcam_block_isa_{number}'
        return '\n'.join((
            f'{indent}{prefix}_slot = ptrtoint ptr {slot} to i64',
            f'{indent}{prefix}_disc = call i64 @llvm.ptrauth.blend(i64 {prefix}_slot, i64 27361)',
            f'{indent}{prefix}_signed = call i64 @llvm.ptrauth.sign(i64 ptrtoint (ptr @{symbol} to i64), i32 2, i64 {prefix}_disc)',
            f'{indent}{prefix}_ptr = inttoptr i64 {prefix}_signed to ptr',
            f'{indent}store ptr {prefix}_ptr, ptr {slot}{suffix}',
        ))

    ir = STORE.sub(replace, ir)
    if re.search(r'^\s*store\b[^\n]*@_NSConcrete(?:Stack|Global)Block', ir, re.MULTILINE):
        raise ValueError('unsupported stack block isa store in LLVM IR')
    if not count:
        return ir, 0
    declarations = []
    if not re.search(r'^declare\s+i64\s+@llvm\.ptrauth\.blend\(', ir, re.MULTILINE):
        declarations.append('declare i64 @llvm.ptrauth.blend(i64, i64)')
    if not re.search(r'^declare\s+i64\s+@llvm\.ptrauth\.sign\(', ir, re.MULTILINE):
        declarations.append('declare i64 @llvm.ptrauth.sign(i64, i32 immarg, i64)')
    if declarations:
        anchor = re.search(r'^attributes #\d+ =', ir, re.MULTILINE)
        position = anchor.start() if anchor else len(ir)
        ir = ir[:position] + '\n'.join(declarations) + '\n\n' + ir[position:]
    return ir, count


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: sign_stack_block_ir.py input.ll output.ll')
    source = Path(sys.argv[1]).read_text(encoding='utf-8')
    output, count = sign_stack_blocks(source)
    Path(sys.argv[2]).write_text(output, encoding='utf-8')
    print('signed stack block isa stores:', count, file=sys.stderr)
