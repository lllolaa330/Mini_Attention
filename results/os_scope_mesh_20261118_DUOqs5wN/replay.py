"""Replay PE-level OS-SCOPE structural and bit checks; takes a fresh output directory."""
import collections
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import decode, encode
from model.scope_attention import bit_model_with_probabilities, dot16, scna_exp16
from model.softfloat import ops

FRAMES = 6
SEED = 20261118
N = 16
II = 52
PV = 120
RTL = ['rtl/os_scope_left_pe.sv', 'rtl/os_scope_right_pe.sv', 'rtl/os_scope_array.sv']
BENCH = SOURCE / 'tb_mesh.sv'
if len(sys.argv) != 2:
    raise SystemExit('python3 replay.py NEW_OUTPUT_DIRECTORY')
RUN = Path(sys.argv[1]).resolve()
RUN.mkdir(exist_ok=False, parents=True)
COMMANDS = []

def command(args, cwd, file):
    COMMANDS.append([str(v) for v in args])
    with (RUN / file).open('w') as f:
        print('COMMAND', args, file=f, flush=True)
        subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, check=True)

def bus(words):
    return ''.join(f'{h:04x}' for h in reversed(words))

rng = random.Random(SEED)
op = ops()
frames = []
for f in range(FRAMES):
    q,k,v = [[encode(rng.uniform(-2,2)) for _ in range(256)] for _ in range(3)]
    q[:4] = [0, 0x8000, 0x0001, 0x8001]
    _,p = bit_model_with_probabilities(q+k+v)
    score = [op['mul'](dot16(q[i*16:(i+1)*16], k[j*16:(j+1)*16],op['fma']),0x3400)
             for i in range(16) for j in range(16)]
    x=[]
    for i in range(16):
        row=score[i*16:(i+1)*16]
        largest=max(row,key=decode)
        x.extend(op['sub'](s,largest) for s in row)
    e=[scna_exp16(value,op) for value in x]
    frames.append((q,k,v,p,x,e))

counts=collections.Counter()
edge=0
def drive(file, stop, stalls):
    global edge
    acc=[0]*256; ex=[0]*16
    print(edge,0,0,0,0,0,0,0,0,0,0,file=file);edge+=1
    for t in range(stop):
        west=[0]*16; north=[0]*16; x_in=[0]*16; dg=first=ds=0
        if stalls and (t%9==5 or t in range(136,146)):
            for _ in range(2):
                # Deliberately perturb the buses and enables while step is low.
                print(edge,1,0,f'{rng.getrandbits(256):x}',f'{rng.getrandbits(256):x}',
                      f'{rng.getrandbits(256):x}', '7fffffff', '7fffffff', '7fffffff',
                      bus(acc),bus(ex),file=file); edge+=1; counts['stall_edges']+=1
        for f,(q,k,v,p,x,e) in enumerate(frames):
            age=t-f*II
            for lane in range(16):
                term=age-lane
                if 0<=term<16:
                    west[lane]=q[lane*16+term]; north[lane]=k[lane*16+term]
                term=age-PV-lane
                if 0<=term<16:
                    west[lane]=p[lane*16+term]; north[lane]=v[term*16+lane]
                origin=32+8*(lane//8)+2*(lane%8)
                i=age-origin
                if 0<=i<16: x_in[lane]=x[16*i+lane]
                i=age-origin-8
                if 0<=i<16: ex[lane]=e[16*i+lane];counts['exp_results']+=1
            for d in range(31):
                if 0<=age-d-32<16: ds|=1<<d
                for name,start,a,b in [('QK',0,q,k),('PV',PV,p,v)]:
                    term=age-start-d
                    if not 0<=term<16: continue
                    dg|=1<<d
                    if term==0: first|=1<<d
                    for i in range(max(0,d-15), min(d,15)+1):
                        j=d-i; ix=i*16+j
                        lhs=a[16*i+term]
                        rhs=b[16*j+term] if name=='QK' else b[16*term+j]
                        acc[ix]=op['fma'](lhs,rhs,acc[ix] if term else 0)
                        counts[name+'_MAC']+=1
        assert not dg & ds
        print(edge,1,1,bus(west),bus(north),bus(x_in),f'{dg:x}',f'{first:x}',f'{ds:x}',bus(acc),bus(ex),file=file)
        edge+=1; counts['logical_edges']+=1

with (RUN/'stimulus.txt').open('w') as stim:
    # Reset the mesh with two frames' QK and SCNA already in flight.
    drive(stim, 82, False)
    drive(stim, (FRAMES-1)*II+PV+46, True)
command(['verilator','--lint-only','--Wall','--top-module','os_scope_array','scripts/verilator_lint.vlt',
         '-f','rtl/scope_files.f',*RTL],ROOT,'strict.log')
command(['iverilog','-g2012','-s','tb_mesh','-o',str(RUN/'test.vvp'),'-f','rtl/scope_files.f',
         *RTL,str(BENCH)],ROOT,'compile.log')
modules=collections.Counter()
for line in (RUN/'test.vvp').open():
    mat=re.search(r'\.scope module, "[^"]+" "([^"]+)"',line)
    if mat: modules[mat[1]]+=1
physical={k:modules[k] for k in ('os_scope_left_pe','os_scope_right_pe','fp16_fma','mulAddRecFN')}
assert list(physical.values())==[128,128,256,256],physical
command(['vvp',str(RUN/'test.vvp')],RUN,'simulation.log')
assert 'PASS all physical OS accumulators and 16 strip outputs' in (RUN/'simulation.log').read_text()
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
files=RTL+['rtl/scope_exp_coeffs.svh','rtl/fp16_ops.sv','model/scope_attention.py']
report={'status':'PASS','design':'one dual-strip 16x16 OS-SCOPE mesh','frames_after_reset':FRAMES,'seed':SEED,
        'physical_elaborated':physical,'coverage':dict(counts),'checked_clock_edges':edge,
        'value_checks':{'accumulator':edge*256,'strip_exp':edge*16},'commands':COMMANDS,
        'iverilog':subprocess.check_output(['iverilog','-V'],text=True,stderr=subprocess.DEVNULL).splitlines()[0],
        'verilator':subprocess.check_output(['verilator','--version'],text=True).strip(),
        'sources_sha256':{p:sha(ROOT/p) for p in files},'stimulus_sha256':sha(RUN/'stimulus.txt'),
        'bench_sha256':sha(BENCH),'script_sha256':sha(Path(__file__))}
(RUN/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ('status','physical_elaborated','coverage','checked_clock_edges')},indent=2))
