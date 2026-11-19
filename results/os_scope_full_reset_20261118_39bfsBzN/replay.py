"""Replay queued/blocked frame reset from the three-way benchmark's pinned SCOPE goldens."""
import hashlib,json,re,subprocess,sys
from pathlib import Path
SRC=Path(__file__).resolve().parent
ROOT=SRC.parents[1]
if len(sys.argv)!=2: raise SystemExit('usage: replay.py NEW_OUTPUT_DIRECTORY')
OUT=Path(sys.argv[1]).resolve()
OUT.mkdir(exist_ok=False,parents=True)
BENCH=SRC/'tb_reset_queued.sv'
fixture=ROOT/'results/scope_report_final_20261118/scope'
sha=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def execute(cmd,cwd,name):
    with (OUT/name).open('w') as log:
        print('COMMAND',cmd,file=log,flush=True)
        subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,cwd=cwd,check=True,timeout=200)
for name in ('input.hex','expected_p.hex','expected.hex'):
    (OUT/name).write_bytes((fixture/name).read_bytes())
filelist=ROOT/'rtl/os_scope_files.f'
sources={ROOT/l for l in filelist.read_text().splitlines() if l and not l.startswith('+')}
sources.update([filelist,ROOT/'rtl/scope_exp_coeffs.svh',BENCH,Path(__file__)])
compile_cmd=['iverilog','-g2012','-s','tb_reset_queued','-o',str(OUT/'tb.vvp'),'-f','rtl/os_scope_files.f',str(BENCH)]
execute(compile_cmd,ROOT,'compile.log')
sim_cmd=['vvp',str(OUT/'tb.vvp')]
execute(sim_cmd,OUT,'simulation.log')
simlog=(OUT/'simulation.log').read_text().splitlines()
checks=[x for x in simlog if x.startswith('PRE_RESET') or x.startswith('PASS')]
assert len(checks)==2 and checks[-1].startswith('PASS')
def counters(line): return {k:int(v,2 if k.endswith('full') else 10) for k,v in re.findall(r'(\w+)=(\d+)',line)}
data={'status':'PASS','coverage':{'before_reset':counters(checks[0]), 'after_reset':counters(checks[1])},
      'commands':[compile_cmd,sim_cmd],'played_case_ids_after_reset':[5,4,11,9,5],
      'reference_fixture':str(fixture.relative_to(ROOT)), 'tool':subprocess.check_output(['iverilog','-V'],stderr=subprocess.DEVNULL,text=True).splitlines()[0],
      'fixture_sha256':{n:sha(OUT/n) for n in ('input.hex','expected_p.hex','expected.hex')},
      'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted(sources)}}
(OUT/'manifest.json').write_text(json.dumps(data,indent=2)+'\n')
print(*checks,sep='\n')
