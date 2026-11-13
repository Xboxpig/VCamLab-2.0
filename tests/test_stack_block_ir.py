import importlib.util
from pathlib import Path

script = Path(__file__).resolve().parents[1] / 'scripts' / 'sign_stack_block_ir.py'
spec = importlib.util.spec_from_file_location('vcam_stack_block_ir', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ir = '''target triple = "arm64e-apple-ios15.0.0"
@_NSConcreteStackBlock = external global ptr
@_NSConcreteGlobalBlock = external global ptr
define void @example(ptr %slot, ptr %other) {
  store ptr @_NSConcreteStackBlock, ptr %slot, align 8
  store ptr @_NSConcreteGlobalBlock, ptr %other, align 8
  ret void
}
attributes #0 = { nounwind }
'''
patched, count = module.sign_stack_blocks(ir)
assert count == 2
assert patched.count('@llvm.ptrauth.blend(i64 %vcam_block_isa_') == 2
assert patched.count('i32 2, i64 %vcam_block_isa_') == 2
assert 'store ptr @_NSConcreteStackBlock' not in patched
assert patched.count('declare i64 @llvm.ptrauth.blend(i64, i64)') == 1
assert patched.count('declare i64 @llvm.ptrauth.sign(i64, i32 immarg, i64)') == 1
again, count = module.sign_stack_blocks(patched)
assert count == 0 and again == patched
print('arm64e stack-block IR tests passed')
