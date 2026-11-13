#!/usr/bin/env python3
"""Compile arm64e Objective-C through an IR pass for Procursus clang 16."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from sign_stack_block_ir import sign_stack_blocks


def argument_value(arguments: list[str], option: str) -> str | None:
    for index, value in enumerate(arguments[:-1]):
        if value == option:
            return arguments[index + 1]
    return None


def main(arguments: list[str]) -> int:
    compiler = os.environ.get('VC_REAL_CLANG', 'clang')
    architecture = argument_value(arguments, '-arch')
    language = argument_value(arguments, '-x')
    output = argument_value(arguments, '-o')
    if '-c' not in arguments or architecture != 'arm64e' or \
            language not in ('objective-c', 'objective-c++') or not output:
        return subprocess.call([compiler, *arguments])

    output_path = Path(output)
    raw_ir = output_path.with_name(output_path.name + '.vcam-raw.ll')
    signed_ir = output_path.with_name(output_path.name + '.vcam-signed.ll')
    ir_arguments = list(arguments)
    index = ir_arguments.index('-c')
    ir_arguments[index:index + 1] = ['-S', '-emit-llvm']
    ir_arguments[ir_arguments.index('-o') + 1] = str(raw_ir)
    try:
        result = subprocess.call([compiler, *ir_arguments])
        if result:
            return result
        transformed, count = sign_stack_blocks(raw_ir.read_text(encoding='utf-8'))
        signed_ir.write_text(transformed, encoding='utf-8')
        print(f'arm64e stack-block isa stores signed: {count} ({output_path.name})', file=sys.stderr)

        backend = [compiler]
        for option in ('-target', '-arch', '-isysroot', '-resource-dir'):
            value = argument_value(arguments, option)
            if value:
                backend.extend((option, value))
        backend.extend(('-O2', '-x', 'ir', '-c', str(signed_ir), '-o', output))
        return subprocess.call(backend)
    finally:
        raw_ir.unlink(missing_ok=True)
        signed_ir.unlink(missing_ok=True)


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
