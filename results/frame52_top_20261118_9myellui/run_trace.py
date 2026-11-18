"""Run the six archived matrices through the current top or the archived old top."""
import argparse
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OLD=ROOT/'results/cross_frame_wave_20261118_bdk_rkfs'
GOLD=OLD/'sim'
OLD_TOP=ROOT/'results/qkv_row16_20261118_m8jjyw1p/after/rtl/attention_fp16.sv'
parser=argparse.ArgumentParser()
parser.add_argument('dest',type=Path,help='New run directory')
parser.add_argument('--old',action='store_true')
parser.add_argument('--hold-output',action='store_true',help='Force 23-cycle holds on diagonals 0/15/30')
args=parser.parse_args()
dest=args.dest.resolve()
dest.mkdir(exist_ok=False)
sha=lambda file:hashlib.sha256(file.read_bytes()).hexdigest()
inputs=['input.hex','expected.hex','expected_p.hex','exp_fp16.hex']
for name in inputs: shutil.copy2(GOLD/name,dest/name)
source_text=(ROOT/'rtl/files.f').read_text()
filelist=ROOT/'rtl/files.f'
if args.old:
    filelist=dest/'old.f'
    filelist.write_text(source_text.replace('rtl/attention_fp16.sv',str(OLD_TOP)))
cmd=['iverilog','-g2012','-s','tb_frame52_trace','-f',str(filelist),'-o',str(dest/'trace.vvp'),str(HERE/'tb_frame52_trace.sv')]
if args.hold_output:
    cmd[1:1] = ['-s','tb_forced_output']
    cmd.append(str(HERE/'tb_forced_output.sv'))
run=['vvp','trace.vvp']
manifest=dict(status='RUNNING',source_sha256={},fixture_sha256={f:sha(dest/f) for f in inputs},
              shared_with_old_run=str(GOLD.relative_to(ROOT)),compile=cmd,run=run,
              compile_cwd=str(ROOT),run_cwd=str(dest),seed=20261117,testbench_sha256=sha(HERE/'tb_frame52_trace.sv'),
              git=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              iverilog=subprocess.check_output(['iverilog','-V'],text=True,stderr=subprocess.DEVNULL).splitlines()[0])
for line in source_text.splitlines():
    loc=line.strip()
    path=ROOT/loc
    if path.is_file():
        if args.old and loc=='rtl/attention_fp16.sv': path=OLD_TOP
        manifest['source_sha256'][loc]=sha(path)
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
try:
    with (dest/'compile.log').open('w') as f:
        subprocess.run(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,check=True)
    with (dest/'simulation.log').open('w') as f:
        subprocess.run(run,cwd=dest,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=160)
    assert 'PASS frames=6' in (dest/'simulation.log').read_text()
    if args.hold_output:
        log=(dest/'simulation.log').read_text()
        assert 'HELD groups=18 stalled_valid_clocks=414' in log and 'ERROR' not in log
        manifest['stall_driver_sha256']=sha(HERE/'tb_forced_output.sv')
    manifest['status']='PASS'
    manifest['vcd_sha256']=sha(dest/'attention.vcd')
except Exception:
    manifest['status']='FAIL'
    raise
finally:
    (dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
