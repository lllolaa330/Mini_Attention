"""Binary16 IEEE arithmetic via pinned Berkeley SoftFloat (not host FP emulation)."""
import ctypes
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build' / 'softfloat'
_LIB = None


def build():
    if sys.byteorder != 'little':
        raise RuntimeError('Bundled SoftFloat build currently requires little-endian host')
    BUILD.mkdir(parents=True, exist_ok=True)
    lib = BUILD / ('libhalf.dylib' if sys.platform == 'darwin' else 'libhalf.so')
    for filename in ('Makefile', 'platform.h'):
        shutil.copyfile(ROOT / 'scripts' / 'softfloat_build' / filename, BUILD / filename)
    args = ['make', '-s', '-j', '4', '-C', str(BUILD), 'SOURCE_DIR=../../third_party/softfloat_source',
            'COMPILE_C=cc -c -fPIC -Werror-implicit-function-declaration -DSOFTFLOAT_FAST_INT64 '
            '-DSOFTFLOAT_ROUND_ODD -DINLINE_LEVEL=5 -DSOFTFLOAT_FAST_DIV32TO16 '
            '-DSOFTFLOAT_FAST_DIV64TO32 -I. -I../../third_party/softfloat_source/8086-SSE '
            '-I../../third_party/softfloat_source/include -O2 -o $@']
    with (BUILD / 'build.log').open('w') as log:
        subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['cc', '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC',
                        '-I', str(ROOT/'third_party/softfloat_source/include'),
                        str(ROOT/'model/softfloat_bridge.c'), str(BUILD/'softfloat.a'), '-o', str(lib)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    return lib


def ops():
    global _LIB
    if _LIB is None:
        _LIB = ctypes.CDLL(str(build()))
        _LIB.sf_init.argtypes = []
        _LIB.sf_init.restype = None
        _LIB.sf_init()
        for name, argc in [('fma', 3), ('add', 2), ('sub', 2), ('mul', 2), ('div', 2)]:
            op = getattr(_LIB, 'sf_' + name)
            op.argtypes = [ctypes.c_uint16] * argc
            op.restype = ctypes.c_uint16
    return {name: getattr(_LIB, 'sf_' + name) for name in ('fma', 'add', 'sub', 'mul', 'div')}
