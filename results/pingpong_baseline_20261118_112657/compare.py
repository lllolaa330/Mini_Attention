#!/usr/bin/env python3
"""Cross-check archived saturated-stream runs and report cycle-based changes."""
import hashlib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
runs={'baseline_os':'baseline_os_02','baseline_ws':'baseline_ws_02',
      'current_os':'current_os_02','current_ws':'current_ws_02'}
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    records={}; expected=sha(HERE/'expected.hex'); inputs=sha(HERE/'input.hex')
    for label,dirname in runs.items():
        d=HERE/dirname; manifest=json.loads((d/'manifest.json').read_text())
        assert manifest['status']=='PASS',label
        assert sha(d/'input.hex')==inputs,label
        assert sha(d/'expected.hex')==expected,label
        assert sha(d/'actual.hex')==expected,label
        r=json.loads((d/'summary.json').read_text())
        records[label]={k:v for k,v in r.items() if k!='timing'}
        records[label]['evidence']=dirname
    changes={}
    for flow in ('os','ws'):
        before=records['baseline_'+flow]; after=records['current_'+flow]
        changes[flow]={
            'mean_input_ii_speedup':before['input_ii_mean']/after['input_ii_mean'],
            'latency_reduction_cycles_min':before['latency_min']-after['latency_max'],
            'latency_reduction_cycles_max':before['latency_max']-after['latency_min'],
            'input_rate_bound_met':after['input_ii_min']==768 and after['input_ii_max']==768,
        }
    report={'same_25_input_frames':True,'same_all_6400_output_bits':True,
            'input_sha256':inputs,'output_sha256':expected,
            'condition':'source continuously valid, sink always ready, 1 FP16 input per cycle',
            'scope':'Cycle simulation only; changed output interface from scalar row-major to 16-lane diagonals, plus ping-pong/overlapped scheduling. No isolated attribution or Fmax/PPA claim.',
            'runs':records,'changes':changes}
    (HERE/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
