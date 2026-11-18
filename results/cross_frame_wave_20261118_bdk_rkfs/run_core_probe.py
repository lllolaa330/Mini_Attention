"""Replay three no-stall schedules using the actual OS array and online Softmax."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SIM = HERE / 'sim'
TB = HERE / 'tb_overlap_schedule.sv'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_case(params):
    ii, delay = params
    stem = f'ii{ii}_pv{delay}'
    exe = dest / (stem+'.vvp')
    build = ['iverilog','-g2012','-s','tb_overlap_schedule',
             f'-Ptb_overlap_schedule.II={ii}',f'-Ptb_overlap_schedule.PV_OFFSET={delay}',
             '-o',str(exe),'-f','rtl/files.f',str(TB.relative_to(ROOT))]
    with (dest/(stem+'_compile.log')).open('w') as stream:
        subprocess.run(build,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,check=True)
    command = ['vvp',str(exe)]
    if ii == 52:
        command.append('+WAVE='+str(dest/(stem+'.vcd')))
    proc = subprocess.run(command,cwd=SIM,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    log = proc.stdout
    (dest/(stem+'.log')).write_text(log)
    if ii == 48 and delay == 36:
        assert proc.returncode and 'contention t=48' in log, log
        outcome = 'Expected conflict'
    else:
        assert proc.returncode == 0 and f'PASS II={ii} PV_OFFSET={delay} frames=6 P=1536 Y=1536' in log, log
        outcome = 'PASS'
    return dict(ii=ii,pv_offset=delay,outcome=outcome,compile=build,run=command,log=stem+'.log')


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('new_directory',type=Path)
    dest=parser.parse_args().new_directory.resolve()
    dest.mkdir(exist_ok=False)
    with ThreadPoolExecutor(max_workers=3) as pool:
        cases=list(pool.map(run_case,[(52,36),(48,36),(48,64)]))
    summary=dict(scope='one unchanged systolic_array and one unchanged online_softmax16, fixture-resident matrices, always-accepting result capture, no top-level input, frame-bank or backpressure controller', frames=6,
                 simulator=subprocess.check_output(['iverilog','-V'],stderr=subprocess.DEVNULL,text=True).splitlines()[0],
                 source_manifest='../sim/manifest.json',testbench_sha256=digest(TB),
                 input_hashes={f:digest(SIM/f) for f in ('input.hex','expected.hex','expected_p.hex')},cases=cases)
    (dest/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    for case in cases:
        print(case['ii'],case['pv_offset'],case['outcome'])
