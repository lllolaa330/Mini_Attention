"""Decode pre-NBA, pre-rising-edge samples from the two controlled waveform runs."""
import argparse
import csv
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
SIGNALS=set('clk rst_n in_valid in_ready out_valid out_ready out_last qk_step pv_step v_ready wave_slot_available prob_valid pe_mac'.split())

def decode(vcd):
    ids,scope={},[]
    with vcd.open() as file:
        for line in file:
            words=line.split()
            if not words:continue
            if words[0]=='$scope':scope.append(words[2])
            elif words[0]=='$upscope':scope.pop()
            elif words[0]=='$var' and scope==['tb_matched'] and words[4] in SIGNALS:ids[words[3]]=words[4]
            elif words[0]=='$enddefinitions':break
        assert set(ids.values())==SIGNALS, (vcd,ids)
        values,old={},{}
        cycle=0
        def rising():
            return old.get('clk')=='0' and values.get('clk')=='1' and old.get('rst_n')=='1'
        def sample():
            return {name:int(bits,2) for name,bits in old.items() if not(set(bits)-{'0','1'})}
        for line in file:
            s=line.strip()
            if s.startswith('#'):
                if rising():
                    cycle+=1;yield cycle,sample()
                old=values.copy()
            elif s.startswith('b'):
                bits,key=s[1:].split()
                if key in ids:values[ids[key]]=bits
            elif s and s[1:] in ids:
                values[ids[s[1:]]]=s[0]
        if rising():
            cycle+=1;yield cycle,sample()

def analyze(work,ver,mode):
    pe=[[] for _ in range(256)]
    wave=[]
    inputs=[];outputs=[];pv=[];blocked=[];previous_group=[];returned_rows=0
    for cycle,s in decode(work/'attention.vcd'):
        if s['in_ready'] and s['in_valid']:inputs.append(cycle)
        if s['out_valid']:
            if s['out_ready']:outputs.append(cycle)
            else:
                blocked.append(cycle);previous_group.append(len(outputs))
        eligible_p = returned_rows > min(len(pv),15)
        returned_rows += s['prob_valid']
        if s['pv_step']:pv.append(cycle)
        mask=s.get('pe_mac',0)
        assert 'pe_mac' in s or not (s['qk_step'] or s['pv_step'])
        qmac=pmac=0
        while mask:
            bit=mask&-mask
            idx=bit.bit_length()-1
            if len(pe[idx])<16:qmac+=1
            else:pmac+=1
            pe[idx].append(cycle);mask^=bit
        wave.append(dict(cycle=cycle,qk_pe=qmac,pv_pe=pmac,p_row_ready=int(eligible_p),pv_step=s['pv_step'],v_ready=s['v_ready'],
                         slot=s['wave_slot_available'],out_valid=s['out_valid'],out_ready=s['out_ready']))
    assert [len(a) for a in pe]==[32]*256
    assert len(inputs)==(768 if ver=='before' else 528) and len(outputs)==31 and len(pv)==46
    assert inputs==list(range(inputs[0],inputs[-1]+1))
    assert previous_group==([5]*12 if mode=='backpressure' else [])
    assert not blocked or blocked==list(range(blocked[0],blocked[0]+12))
    first_q=min(a[0] for a in pe);last_p=max(a[-1] for a in pe)
    assert (min(a[16] for a in pe),last_p)==(pv[0],pv[-1])
    frame=outputs[-1]-inputs[0]+1;compute=last_p-first_q+1
    win=[r for r in wave if pv[0]<=r['cycle']<=pv[-1]]
    inactive=[r for r in win if not r['pv_step']]
    vwait=sum(not r['v_ready'] and r['slot'] for r in inactive)
    owait=sum(r['v_ready'] and not r['slot'] for r in inactive)
    assert returned_rows==16 and all(r['p_row_ready'] for r in win)
    assert vwait+owait==len(inactive),'Other reasons also present'
    info=dict(version=ver,mode=mode,input_beats=len(inputs),output_groups=31,golden_p_words=256,golden_y_words=256,
              per_pe_qk_fmas=16,per_pe_pv_fmas=16,clock_edges_inclusive=True,pv_enabled=len(pv),
              pv_first_to_last=len(win),pv_idle=len(inactive),pv_idle_missing_v=vwait,pv_idle_output_capacity=owait,
              external_output_blocked_cycles=len(blocked),first_qk_mac_from_input=first_q-inputs[0]+1,
              first_pv_mac_from_input=pv[0]-inputs[0]+1,first_y_transfer_from_input=outputs[0]-inputs[0]+1,
              frame_cycles=frame,compute_cycles=compute,overlap=sum(r['qk_pe']>0 and r['pv_pe']>0 for r in wave),
              per_pe_compute_util_pct=3200/compute,per_pe_frame_util_pct=3200/frame,
              per_pe_pv_window_util_pct=1600/len(win),vcd=str(work/'attention.vcd'))
    per_pe=[]
    for n,acts in enumerate(pe):
        per_pe.append(dict(version=ver,mode=mode,row=n//16,col=n%16,qk_fmas=len(acts[:16]),pv_fmas=len(acts[16:]),
                           first_qk_T=acts[0]-first_q+1,last_qk_T=acts[15]-first_q+1,
                           first_pv_T=acts[16]-first_q+1,last_pv_T=acts[-1]-first_q+1,
                           compute_cycles=compute,compute_util_pct=3200/compute,pv_cycles=len(win),
                           pv_util_pct=1600/len(win),frame_cycles=frame,frame_util_pct=3200/frame))
    return info,per_pe,[dict(version=ver,mode=mode,T=r['cycle']-first_q+1,
                             PV_T=r['cycle']-pv[0]+1,**r) for r in wave if first_q<=r['cycle']<=last_p]

def csvout(path,rows):
    with path.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=HERE/'matched')
    args=parser.parse_args()
    items=[];pes=[];waves=[]
    for ver in ('before','after'):
        for mode in ('ready','backpressure'):
            info,pp,ww=analyze(args.root/ver/mode,ver,mode)
            info['vcd']=str(Path(info['vcd']).relative_to(args.root))
            items.append(info);pes.extend(pp);waves.extend(ww)
            print(ver,mode,'PV',info['pv_first_to_last'], 'idle', info['pv_idle'], 'compute',info['compute_cycles'],'frame',info['frame_cycles'])
    m=[json.loads((args.root/v/'manifest.json').read_text()) for v in ('before','after')]
    assert m[0]['fixture_sha256']==m[1]['fixture_sha256'] and m[0]['testbench_sha256']==m[1]['testbench_sha256']
    (args.root/'comparison.json').write_text(json.dumps({'status':'PASS','fixture':'random_uniform_001','measurements':items},indent=2)+'\n')
    csvout(args.root/'per_pe.csv',pes);csvout(args.root/'cycles.csv',waves)
if __name__=='__main__':main()
