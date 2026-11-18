"""Recompile frozen source and replay identical input/golden bits in both ready profiles."""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE = ROOT/'results/20261118_150420_os_iverilog_seed20261117_21541'
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(cmd,dest,log):
    with log.open('w') as f:
        print('Command:',cmd,file=f,flush=True)
        subprocess.run(cmd,cwd=dest,stdout=f,stderr=subprocess.STDOUT,check=True,timeout=600)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--version',choices=['before','after'],required=True)
    p.add_argument('--out-root',default=HERE/'matched',type=Path)
    a=p.parse_args()
    dut=HERE/a.version
    dest=(a.out_root/a.version).resolve()
    dest.mkdir(parents=True,exist_ok=False)
    fl=dut/'rtl/files.f'
    source={}
    compile_list=[]
    for entry in fl.read_text().splitlines():
        if entry.startswith('+incdir+'):
            compile_list.append('+incdir+'+str(ROOT/entry[8:]))
        else:
            path=(dut if entry.startswith('rtl/') else ROOT)/entry
            source[entry]=digest(path)
            compile_list.append(str(path))
    for path in (ROOT/'third_party/HardFloat-1/source').rglob('*.vi'):
        source[str(path.relative_to(ROOT))]=digest(path)
    (dest/'files.f').write_text('\n'.join(compile_list)+'\n')
    cmd=['iverilog','-g2012','-s','tb_matched','-o','sim.vvp','-f','files.f']
    if a.version=='after':cmd+=['-DCOLUMN_INPUT']
    run(cmd+[str(HERE/'tb_matched.sv')],dest,dest/'compile.log')
    for mode,hold in [('ready',0),('backpressure',12)]:
        work=dest/mode;work.mkdir()
        for filename in ['input.hex','expected.hex','expected_p.hex','exp_fp16.hex']:
            shutil.copyfile(FIXTURE/filename,work/filename)
        run(['vvp',str(dest/'sim.vvp'),f'+HOLD={hold}'],work,work/'sim.log')
        if 'PASS ' not in (work/'sim.log').read_text():raise ValueError('Missing scoreboard result')
    manifest={'status':'PASS','version':a.version,'testbench_sha256':digest(HERE/'tb_matched.sv'),
              'files_f_sha256':digest(fl),'source_sha256':source,'fixture_source':str(FIXTURE.relative_to(ROOT)),
              'fixture_sha256':{n:digest(FIXTURE/n) for n in ['input.hex','expected.hex','expected_p.hex','exp_fp16.hex']},
              'commands':sys.argv,'iverilog':subprocess.check_output(['iverilog','-V'],stderr=subprocess.DEVNULL,text=True).splitlines()[0]}
    (dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(a.version,'PASS',dest)
if __name__=='__main__':main()
