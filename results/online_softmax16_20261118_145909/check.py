from pathlib import Path
import random, hashlib, sys
import shutil, subprocess, json
dest=Path(__file__).resolve().parent
root=dest.parent.parent
sys.path.insert(0,str(root))
from model.attention import encode, decode, exp16
from model.softfloat import ops
op=ops(); rng=random.Random(20261118)
values=[]; expected=[]
for ci in range(8):
    for i in range(16):
        if ci==0: row=[0]*16
        elif ci==1: row=[encode((j-8)*8.0) for j in range(16)]
        elif ci==2: row=[encode((7-j)*8.0) for j in range(16)]
        elif ci==3: row=[encode((-1.0)**j*(i+j)*2) for j in range(16)]
        elif ci==4: row=[(0x8000 if j%2 else 0) | rng.randrange(0x400) for j in range(16)]
        else: row=[encode(rng.uniform(-64,64)) for j in range(16)]
        values.extend(row)
        score=[op['mul'](a,0x3400) for a in row]; m=score[0]; ell=0x3c00
        for x in score[1:]:
            m2=max([m,x],key=decode)
            ell=op['add'](op['mul'](ell,exp16(op['sub'](m,m2))),exp16(op['sub'](x,m2)))
            m=m2
        expected.extend(op['div'](exp16(op['sub'](x,m)),ell) for x in score)
for name,words in [('raw',values),('expected',expected)]:
    (dest/(name+'.hex')).write_text(''.join(f'{x:04x}\n' for x in words))
shutil.copyfile(root/'rtl/exp_fp16.hex',dest/'exp_fp16.hex')
commands=[
('strict_lint.log',root,['verilator','--lint-only','--Wall','--top-module','online_softmax16','scripts/verilator_lint.vlt','-f',str(dest/'files.f')]),
('compile.log',root,['iverilog','-g2012','-s','tb','-o',str(dest/'test.vvp'),'-f',str(dest/'files.f'),str(dest/'tb.sv')]),
('simulation.log',dest,['vvp',str(dest/'test.vvp')])]
result={'status':'RUNNING','tool_version':[subprocess.check_output(['verilator','--version'],text=True).strip(),subprocess.check_output(['iverilog','-V'],stderr=subprocess.DEVNULL,text=True).splitlines()[0]],'sources_sha256':{
str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*(root/f for f in (dest/'files.f').read_text().splitlines() if not f.startswith('+')),root/'rtl/exp_fp16.hex',dest/'tb.sv',dest/'check.py']}}
try:
    for log,cwd,cmd in commands:
        with (dest/log).open('w') as out:
            out.write('COMMAND: '+repr(cmd)+'\n');out.flush();subprocess.run(cmd,cwd=cwd,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=180)
    assert 'ONLINE SOFTMAX PASS' in (dest/'simulation.log').read_text()
    result.update(status='PASS', rows=128, outputs=2048, max_consecutive_rows=16, issue_to_consume_clocks=3)
finally:
    if result['status']=='RUNNING': result['status']='FAIL'
    (dest/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(dest,result['status'])
