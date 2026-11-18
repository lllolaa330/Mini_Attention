#!/usr/bin/env python3
"""Flip one expected output bit and require the RTL scoreboard to reject it."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run',type=Path,required=True)
    p.add_argument('--outdir',type=Path,required=True)
    args=p.parse_args()
    source=args.run.resolve()
    out=args.outdir.resolve()
    out.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((source/'manifest.json').read_text())
    if manifest['status'] != 'PASS': raise ValueError('Need a passing run')
    for name in ('input.hex','exp_fp16.hex'):
        shutil.copyfile(source/name,out/name)
    if (source/'expected_p.hex').exists():
        shutil.copyfile(source/'expected_p.hex',out/'expected_p.hex')
    words=(source/'expected.hex').read_text().splitlines()
    words[0]=f'{int(words[0],16)^1:04x}'
    (out/'expected.hex').write_text('\n'.join(words)+'\n')
    if manifest['simulator']=='iverilog':
        exe=['vvp',str(source/'tb_attention.vvp')]
    else:
        exe=[str(source/'obj_tb_attention'/'tb_attention')]
    cmd=exe+['+INPUT=input.hex','+EXPECTED=expected.hex','+OUTPUT=actual.txt','+STALLS=0']
    with (out/'negative.log').open('w') as log:
        log.write('COMMAND: '+repr(cmd)+'\n');log.flush()
        result=subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT,timeout=120)
    text=(out/'negative.log').read_text()
    passed=result.returncode!=0 and 'BIT MISMATCH run=0 case=0 row=0 col=0' in text
    (out/'summary.json').write_text(json.dumps({'status':'PASS' if passed else 'FAIL',
        'source_run':str(source.relative_to(ROOT)),'mutation':'expected[0] XOR 1',
        'returncode':result.returncode,'checker_rejected_mutation':passed,
        'scope':'Negative scoreboard self-test; not a DUT numerical failure'},indent=2)+'\n')
    if not passed: raise RuntimeError('Scoreboard did not reject mutation as expected')
    print('CHECKER NEGATIVE PASS:',out)


if __name__=='__main__': main()
