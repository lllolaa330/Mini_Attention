"""Replay the nine-frame OS-SCOPE slow-source / drain / restart RTL test."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

fixture = Path(__file__).resolve().parent
root = fixture.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--outdir', type=Path)
args = parser.parse_args()
if args.outdir:
    out = args.outdir.resolve()
    out.mkdir(parents=True, exist_ok=False)
else:
    out = Path(tempfile.mkdtemp(prefix='run_', dir=fixture))
gold = root / 'results/scope_report_final_20261118/scope'
for name in ('input.hex', 'expected.hex', 'expected_p.hex'):
    shutil.copyfile(gold / name, out / name)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

filelist = root / 'rtl/os_scope_files.f'
tb = fixture / 'tb_os_scope_sparse.sv'
sources = [p for x in filelist.read_text().splitlines() if x and not x.startswith(('+','-','#')) for p in [root/x.strip()] if p.is_file()]
manifest = {
    'status':'RUNNING', 'purpose':'Delayed first V tail; idle drain and restart w/o reset; long partial frame gaps; held output payload, P/Y bit-exact.',
    'source_sha256':{str(p.relative_to(root)):sha(p) for p in [filelist,*sources,root/'rtl/scope_exp_coeffs.svh',tb]},
    'vectors_sha256':{f:sha(out/f) for f in ('input.hex','expected.hex','expected_p.hex')},
    'simulator':subprocess.check_output(['iverilog','-V'], stderr=subprocess.DEVNULL,text=True).splitlines()[0],
    'commands':[],
}
def call(cmd,cwd,name):
    manifest['commands'].append({'cwd':str(cwd),'command':[str(x) for x in cmd]})
    with (out/name).open('w') as fd:
        subprocess.run(cmd, cwd=cwd, stdout=fd, stderr=subprocess.STDOUT, check=True,timeout=180)
try:
    call(['iverilog','-g2012','-s','tb_os_scope_sparse','-o',out/'tb.vvp','-f',filelist,tb],root,'compile.log')
    call(['vvp',out/'tb.vvp'],out,'simulation.log')
    lines=(out/'simulation.log').read_text().splitlines()
    summary=next(line for line in lines if line.startswith('PASS '))
    assert 'Y=2304 P=2304' in summary
    assert sum(s.startswith('GAP_START') for s in lines)==6
    manifest.update(status='PASS',summary=summary, directed_gaps=[s for s in lines if s.startswith('GAP_')])
except BaseException:
    manifest['status']='FAIL'
    raise
finally:
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(out,summary)
