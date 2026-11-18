"""Measure clocks at public handshakes and individual PE MAC acceptances, from two VCDs."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
from collections import defaultdict

HERE=Path(__file__).resolve().parent
OLD=HERE.parent/'cross_frame_wave_20261118_bdk_rkfs'
NFRAMES=6

def rising_edges(vcd,top):
    needed={top:set('clk rst_n in_valid in_ready in_data out_valid out_ready out_last out_lane_valid out_data pe_mac'.split()),
            top+'.dut':{'prob_valid','prob_row'}}
    scope, signal, value=[],{},{}
    with vcd.open() as f:
        for line in f:
            p=line.split()
            if not p: continue
            if p[0]=='$scope': scope.append(p[2])
            if p[0]=='$upscope': scope.pop()
            if p[0]=='$var' and p[4] in needed.get('.'.join(scope),set()):
                signal[p[3]]=p[4]
            if p[0]=='$enddefinitions': break
        assert set(signal.values())==set.union(*needed.values()), set.union(*needed.values())-set(signal.values())
        changes, t={}, 0
        for line in f:
            s=line.strip()
            if s.startswith('#'):
                if changes.get('clk')=='1' and value.get('clk')=='0' and value.get('rst_n')=='1':
                    assert t%10000==5000
                    yield t//10000,value
                value.update(changes)
                t,changes=int(s[1:]),{}
            elif s.startswith('b'):
                bits,k=s[1:].split()
                if k in signal: changes[signal[k]]=bits
            elif s[:1] in ('1','0','x','z') and s[1:] in signal:
                changes[signal[s[1:]]]=s[0]

def load_words(path):
    return [int(i,16) for i in path.read_text().splitlines()]

def extract(vcd,top):
    events=[defaultdict(list) for _ in range(NFRAMES)]
    tx,rx,p_rows=0,0,0
    count=[0]*256
    src=load_words(OLD/'sim/input.hex')
    golden=load_words(OLD/'sim/expected.hex')
    rows=[]
    first_qk=[[None]*256 for _ in range(NFRAMES)]
    for cycle,v in rising_edges(vcd,top):
        data=lambda s:int(v[s],2)
        tx_fire=int(v['in_ready']==v['in_valid']=='1')
        out_fire=int(v['out_valid']==v['out_ready']=='1')
        tx_f,rx_f='',''
        if tx_fire:
            frame,beat=divmod(tx,48)
            matrix,index=divmod(beat,16)
            word=data('in_data')
            for lane in range(16):
                loc=beat*16+lane if matrix!=2 else 512+16*lane+index
                assert (word>>(16*lane))&65535==src[frame*768+loc], ('input',frame,beat,lane)
            tx_f=frame
            events[frame]['QKV'[matrix]].append(cycle)
            tx+=1
        if out_fire:
            frame,diag=divmod(rx,31)
            rx_f=frame
            mask=0
            for j in range(16):
                i=diag-j
                if 0<=i<16:
                    mask|=1<<j
                    # Inactive output lanes may carry x bits; select valid lane only.
                    bits=v['out_data'].rjust(256,'0')
                    assert int(bits[(15-j)*16:(16-j)*16],2)==golden[frame*256+16*i+j]
            assert data('out_lane_valid')==mask and data('out_last')==int(diag==30)
            events[frame]['out'].append(cycle)
            rx+=1
        if v['prob_valid']=='1':
            frame,i=divmod(p_rows,16)
            assert data('prob_row')==i
            events[frame]['P'].append(cycle)
            p_rows+=1
        op_masks={}
        mask=data('pe_mac')
        while mask:
            bit=mask&-mask
            coord=bit.bit_length()-1
            frame,term=divmod(count[coord],32)
            op='QK' if term<16 else 'PV'
            key=(frame,op)
            op_masks[key]=op_masks.get(key,0)|bit
            if coord in (0,255): events[frame][op+str(coord)].append(cycle)
            if term==0:
                first_qk[frame][coord]=cycle
            count[coord]+=1
            mask^=bit
        for frame,op in op_masks:
            events[frame][op].append(cycle)
        rows.append(dict(cycle=cycle,input_valid=v['in_valid'],input_ready=v['in_ready'],
                         output_ready=v['out_ready'],tx_frame=tx_f,out_frame=rx_f,
                         active_pe_by_frame_and_phase=' '.join(f'F{n}{op}={hex(mask)}' for (n,op),mask in sorted(op_masks.items()))))
        if rx==31*NFRAMES: break
    assert tx==48*NFRAMES and p_rows==16*NFRAMES and rx==31*NFRAMES and count==[32*NFRAMES]*256
    frame_rows=[]
    for i,frame in enumerate(events):
        for key,seq in frame.items():
            assert seq==list(range(seq[0],seq[-1]+1)),(i,key,seq)
        for key,n in [('Q',16),('K',16),('V',16),('P',16),('QK',46),('PV',46),('out',31),
                      ('QK0',16),('PV0',16),('QK255',16),('PV255',16)]:
            assert len(frame[key])==n
        frame_rows.append({k:[s[0],s[-1]] for k,s in frame.items()})
    # Ensure the continuous-source/ready-sink experiment was exercised.
    first=frame_rows[0]['Q'][0];last=frame_rows[-1]['V'][1]
    assert all(r['input_valid']=='1' for r in rows if first<=r['cycle']<=last)
    assert all(r['output_ready']=='1' for r in rows if first<=r['cycle'])
    intervals={key:[b[key][0]-a[key][0] for a,b in zip(frame_rows,frame_rows[1:])]
               for key in ('Q','QK','PV','out')}
    overlap=[len(set(a['PV'])&set(b['QK'])) for a,b in zip(events,events[1:])]
    input_wait=[]
    for f,g in zip(frame_rows,frame_rows[1:]):
        wait=[r for r in rows if f['V'][-1]<r['cycle']<g['Q'][0]]
        assert all(r['input_valid']=='1' and r['input_ready']=='0' for r in wait)
        input_wait.append(len(wait))
    handoffs=[]
    for f in range(NFRAMES-1):
        wait=[]
        for coord in range(256):
            row,col=divmod(coord,16)
            # Acceptance of the old Y and the new QK k=0 are sampled before the same clock edge.
            old_out=events[f]['out'][row+col]
            wait.append(first_qk[f+1][coord]-old_out)
        assert min(wait)>=0
        handoffs.append({'same_edge_transfers':wait.count(0),'min_delay':min(wait),'max_delay':max(wait)})
    return dict(y_handshake_to_next_qk_first_by_pe=handoffs,vcd=str(vcd),vcd_sha256=hashlib.sha256(vcd.read_bytes()).hexdigest(),
                frames=frame_rows,intervals=intervals,consecutive_frame_overlap=overlap,input_wait=input_wait,
                matrix_words_checked=tx*16,output_words_checked=rx//31*256,
                macc_per_pe=count[0],probability_rows_seen=p_rows),rows

def write_table(path,rows):
    with path.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=rows[0])
        w.writeheader();w.writerows(rows)

def main():
    p=argparse.ArgumentParser()
    p.add_argument('current_run',type=Path)
    p.add_argument('dest',type=Path)
    p.add_argument('--expected-ii',type=int,required=True)
    args=p.parse_args()
    args.dest.mkdir(exist_ok=False)
    old,orows=extract(OLD/'sim/attention.vcd','tb_attention')
    new,nrows=extract(args.current_run/'attention.vcd','tb_frame52_trace')
    for report,ii in [(old,85),(new,args.expected_ii)]:
        assert report['intervals']['out']==[ii]*5 and report['intervals']['QK']==[ii]*5,report['intervals']
        assert all(g['out'][1]-f['out'][1]==ii for f,g in zip(report['frames'],report['frames'][1:]))
        assert report['intervals']['Q'][-2:]==[ii]*2
        assert report['consecutive_frame_overlap']==[max(0,82-ii)]*5
        for handoff in report['y_handshake_to_next_qk_first_by_pe']:
            assert handoff['min_delay']==handoff['max_delay']==ii-52
            assert handoff['same_edge_transfers']==(256 if ii==52 else 0)
    write_table(args.dest/'before_cycles.csv',orows)
    write_table(args.dest/'after_cycles.csv',nrows)
    data=dict(before=old,after=new,
              clock='Pre-rising-edge values; cycle zero at 5 ns, clock period 10 ns',
              events='Inclusive cycle ranges. Inputs/outputs are successful public handshakes. 16 MACs for QK then 16 for PV, per frame and per physical PE. Suffix 0 = PE[0,0], suffix 255 = PE[15,15].')
    (args.dest/'comparison.json').write_text(json.dumps(data,indent=2)+'\n')
    print(new['intervals'],new['consecutive_frame_overlap'],new['input_wait'])
if __name__=='__main__': main()
