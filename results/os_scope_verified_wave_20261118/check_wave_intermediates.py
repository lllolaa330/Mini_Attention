"""Check real OS accumulator and SCNA lane values on rising edges of the saved VCD."""
import hashlib
import json
from pathlib import Path
import sys

RUN = Path(__file__).resolve().parent
ROOT = RUN.parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import decode
from model.scope_attention import dot16, scna_exp16
from model.softfloat import ops


def reference_matrices(words):
    op = ops()
    q, k = words[:256], words[256:512]
    qk = [dot16(q[i:i+16], k[j:j+16], op['fma'])
          for i in range(0,256,16) for j in range(0,256,16)]
    exps=[]
    for i in range(0,256,16):
        s=[op['mul'](v,0x3400) for v in qk[i:i+16]]
        m=max(s,key=decode)
        exps.extend(scna_exp16(op['sub'](v,m),op) for v in s)
    return qk,exps


def preclock_values(path):
    scopes, ids, values, updates = [], {}, {}, {}
    with path.open() as f:
        for line in f:
            fields=line.split()
            if not fields:
                continue
            if fields[0]=='$scope':
                scopes.append(fields[2])
            elif fields[0]=='$upscope':
                scopes.pop()
            elif fields[0]=='$var':
                name=fields[4]; scope='.'.join(scopes)
                if ((scope=='tb_scope_compare.dut' and name in ('accum','exp_out','step','launch','clk'))
                    or (scope=='tb_scope_compare' and name=='cycle')):
                    ids[fields[3]]=name
            elif fields[0]=='$enddefinitions':
                break
        assert set(ids.values())=={'accum','exp_out','step','launch','clk','cycle'}
        def edge():
            if updates.get('clk')=='1' and values.get('clk')=='0' and 'cycle' in values:
                return int(values['cycle'],2),values.copy()
            return None
        for line in f:
            line=line.strip()
            if not line: continue
            if line[0]=='#':
                result=edge()
                if result: yield result
                values.update(updates); updates.clear()
            elif line[0]=='b':
                binary,key=line[1:].split()
                if key in ids: updates[ids[key]]=binary
            elif line[0] in '01xz':
                if line[1:] in ids: updates[ids[line[1:]]]=line[0]
        result=edge()
        if result: yield result


def main():
    data=RUN/'os-scope'
    cases=json.loads((RUN/'cases.json').read_text())
    matrices=[reference_matrices(case['words']) for case in cases]
    groups={}
    for line in (data/'mesh_activity.txt').read_text().splitlines():
        group,cycle,step,launch,*_=line.split()
        groups[int(cycle)]=(int(group),step,launch)
    age=[0,0]; launches=[[],[]]; seen=[set(),set()]
    vcd=data/'attention.vcd'
    for cycle, signals in preclock_values(vcd):
        event=groups.pop(cycle,None)
        if event is None:
            continue
        group,step,launch=event
        assert (signals['step'],signals['launch'])==(step,launch)
        if step=='0':
            continue
        if launch=='1':
            frame=len(launches[group]); cid=frame if group else frame%6
            launches[group].append((age[group],frame,cid))
        for start,frame,cid in launches[group][-4:]:
            t=age[group]-start
            for col in range(16):
                # Raw QK at physical PE[row,col] is consumed by score capture at 16+row+col.
                # Exp is consumed one edge after S+1 stages in the corresponding strip.
                for kind, row, bus in ((0,t-16-col,'accum'),
                                       (1,t-(32+8*(col//8)+2*(col%8)+9),'exp_out')):
                    if not 0<=row<16: continue
                    index=16*row+col
                    offset=index if kind==0 else col
                    actual=(int(signals[bus],2)>>(16*offset))&0xffff
                    gold=matrices[cid][kind][index]
                    if actual!=gold:
                        raise ValueError(f'{bus} mismatch group={group}, frame={frame}, [{row},{col}], '
                                         f'cycle={cycle}, age={t}, got={actual:04x}, expected={gold:04x}')
                    key=(group,frame,index)
                    assert key not in seen[kind]
                    seen[kind].add(key)
        age[group]+=1
    assert not groups and all(len(obs)==256*(12+len(cases)) for obs in seen)
    report=dict(status='PASS',frames=12+len(cases),raw_qk_words=len(seen[0]),scna_e_words=len(seen[1]),
                source='pre-rising-edge snapshots of dut.accum and dut.exp_out in final Icarus VCD',
                vcd_sha256=hashlib.sha256(vcd.read_bytes()).hexdigest(),
                command='python3 '+str(Path(__file__).relative_to(ROOT)))
    (data/'wave_intermediates.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
if __name__=='__main__':
    main()
