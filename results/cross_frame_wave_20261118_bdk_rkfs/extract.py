"""Extract continuous main frames from Icarus VCD and cross-check against run.py."""
import csv
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
VCD = BASE/'sim/attention.vcd'
TOP = 'tb_attention'
WANTED = {
    TOP: 'clk cycle rst_n in_valid in_ready out_valid out_ready out_last pe_mac'.split(),
    TOP+'.dut': 'input_matrix input_index state qk_age feed_step qk_step pv_step norm_issue prob_valid score_valid compute_bank write_bank bank_full'.split(),
}


def clock_edges(src):
    scope, names, values = [], {}, {}
    with src.open() as stream:
        for line in stream:
            fields = line.split()
            if not fields:
                continue
            if fields[0] == '$scope':
                scope.append(fields[2])
            elif fields[0] == '$upscope':
                scope.pop()
            elif fields[0] == '$var' and fields[4] in WANTED.get('.'.join(scope), []):
                names[fields[3]] = fields[4]
            elif fields[0] == '$enddefinitions':
                break
        assert set(names.values()) == set(sum(WANTED.values(), []))
        changes, t = {}, 0
        for line in stream:
            s = line.strip()
            if s.startswith('#'):
                if changes.get('clk') == '1' and values.get('clk') == '0' and values.get('rst_n') == '1':
                    yield t, {name:int(bits, 2) for name,bits in values.items()}
                values.update(changes)
                t, changes = int(s[1:]), {}
            elif s.startswith('b'):
                value, symbol = s[1:].split()
                if symbol in names:
                    changes[names[symbol]] = value
            elif s[:1] in ('1', '0', 'x', 'z') and s[1:] in names:
                changes[names[s[1:]]] = s[0]


def main():
    cases = json.loads((BASE/'vectors.json').read_text())
    by_frame = [{} for _ in cases]
    counts, tx, rx = [0]*256, 0, 0
    waveform = []
    for t,w in clock_edges(VCD):
        cycle = w['cycle']
        state = ['LOAD','CLEAR','COMPUTE','DRAIN'][w['state']]
        row = {'cycle':cycle, 'time_ps':t, 'state':state, 'active_frame':rx, 'input_frame':'', 'input_matrix':'', 'input_index':'',
               'input_pending':int(bool(w['in_valid'])), 'in_ready':w['in_ready'], 'out_ready':w['out_ready'],
               'write_bank':w['write_bank'], 'compute_bank':w['compute_bank'], 'bank_full':w['bank_full'],
               'qk_step':w['qk_step'], 'qk_age':w['qk_age'], 'pv_step':w['pv_step'], 'feed_step':w['feed_step'],
               'norm_issue':w['norm_issue'], 'prob_valid':w['prob_valid'], 'score_valid':w['score_valid'],
               'output_fire':int(w['out_valid'] and w['out_ready']), 'output_last':w['out_last']}
        events = []
        if w['in_valid'] and w['in_ready']:
            mat = 'QKV'[w['input_matrix']]
            row.update(input_frame=tx,input_matrix=mat,input_index=w['input_index'])
            by_frame[tx].setdefault(mat,[]).append(cycle)
            if mat=='V' and w['input_index']==15:
                tx += 1
        mask, qmask, pmask = w['pe_mac'], 0, 0
        while mask:
            bit = mask & -mask
            idx = bit.bit_length()-1
            if counts[idx] < 16:
                qmask |= bit
            else:
                pmask |= bit
            counts[idx] += 1
            assert counts[idx] <= 32
            mask ^= bit
        row.update(qk_mac_hex=format(qmask,'064x'),pv_mac_hex=format(pmask,'064x'),
                   qk_mac_count=bin(qmask).count('1'),pv_mac_count=bin(pmask).count('1'))
        if qmask: events.append('QK')
        if pmask: events.append('PV')
        if w['norm_issue']: events.append('norm_issue')
        if w['prob_valid']: events.append('prob_valid')
        if w['score_valid']: events.append('score')
        if state=='CLEAR': events.append('CLEAR')
        if row['output_fire']: events.append('out')
        for event in events:
            by_frame[rx].setdefault(event,[]).append(cycle)
        waveform.append(row)
        if row['output_fire'] and row['output_last']:
            assert counts==[32]*256
            counts, rx = [0]*256, rx+1
            if rx==len(cases): break
    assert tx==rx==len(cases)
    if (BASE/'sim/per_frame.csv').exists():
        with (BASE/'sim/per_frame.csv').open() as f:
            main_rows=[r for r in csv.DictReader(f) if r['batch']=='main']
        mapping = {'Q':('first_in_cycle',None), 'QK':('first_qk_mac','last_qk_mac'), 'PV':('first_pv_mac',None),
                   'norm_issue':('normalization_first_issue','normalization_last_issue'), 'prob_valid':('normalization_first_return','normalization_last_return'),
                   'out':('first_out_cycle','last_out_cycle')}
        for i,f in enumerate(by_frame):
            for event,(first,last) in mapping.items():
                assert f[event][0]==int(main_rows[i][first]), (i,event)
                if last:
                    assert f[event][-1]==int(main_rows[i][last]), (i,event)
    frames=[]
    for i,f in enumerate(by_frame):
        for event, cycles in f.items():
            assert cycles==list(range(cycles[0],cycles[-1]+1)), (i,event)
        assert all(len(f[group])==16 for group in ('Q','K','V','norm_issue','prob_valid'))
        assert all(len(f[group])==46 for group in ('QK','PV')) and len(f['out'])==31
        frames.append({'frame':i, 'case':cases[i]['name'], 'events':{k:[v[0],v[-1]] for k,v in f.items()}})
    with (BASE/'cycles.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(waveform[0]))
        writer.writeheader()
        writer.writerows(waveform)
    doc={'vcd':'sim/attention.vcd','sha256':hashlib.sha256(VCD.read_bytes()).hexdigest(),
         'time':'absolute testbench cycle from VCD before rising edge; intervals inclusive, t_ps = 10000 * cycle + 5000',
         'frame_ids':'zero based; contiguous main batch, source valid while data remain, ready sink',
         'physical_MAC':'local pe.step && a_valid_in && b_valid_in; each coordinate performs 16 QK MACs then 16 PV MACs between retirements; bit 16*i+j',
         'frames':frames}
    (BASE/'frames.json').write_text(json.dumps(doc,indent=2)+'\n')
    print(json.dumps(frames[2:4]))


if __name__=='__main__':
    main()
