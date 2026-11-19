"""From repository root: python3 <run_dir>/audit.py <new_output.json>."""
import hashlib, json, math, struct, sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root))
from model.attention import decode, errors, reference
from model.scope_attention import EXP_COEFFICIENTS, bit_model_with_probabilities, scna_exp16
from model.softfloat import ops
from model.vectors import make_cases
from scripts.gen_scope_exp import CHECKPOINT_SHA256
op=ops()
errors_exp=[]
previous=-1
for mag in range(0x5000,-1,-1):
    x=0x8000|mag
    val=decode(scna_exp16(x,op))
    assert val>=previous and val>=0
    previous=val
    errors_exp.append((abs(val-math.exp(decode(x))),decode(x)))
max_exp_error,x_at_max=max(errors_exp)
cases=make_cases(seed=20261118,random_count=96)
inputs=hashlib.sha256()
frames=[]
for case in cases:
    words=case['words']
    inputs.update(struct.pack('<768H',*words))
    y,p=bit_model_with_probabilities(words)
    rmse,max_abs=errors(y,reference(words))
    assert rmse<=0.06 and max_abs<=0.20
    assert all(0<=decode(v)<=1 for v in p)
    frames.append(dict(name=case['name'],rmse=rmse,max_abs_error=max_abs))
sources=['model/scope_attention.py','scripts/gen_scope_exp.py','rtl/scope_exp_coeffs.svh','tests/test_scope_model.py']
summary=dict(status='PASS',scope='CPU SoftFloat and independent float64. Exhaustive SCNA exp for negative inputs from -32 to zero.',seed=20261118,frames=len(frames),scalar_P_words=256*len(frames),scalar_Y_words=256*len(frames),inputs_sha256=inputs.hexdigest(),max_frame_rmse=max(f['rmse'] for f in frames),max_abs_error=max(f['max_abs_error'] for f in frames),exp_count=len(errors_exp),exp_monotone=True,exp_at_zero=decode(scna_exp16(0,op)),exp_max_error=max_exp_error,x_at_exp_max_error=x_at_max,coefficient_checkpoint_sha256=CHECKPOINT_SHA256,source_sha256={f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in sources},python=sys.version,per_frame=frames)
target=Path(sys.argv[1])
with target.open('x') as f:
    json.dump(summary,f,indent=2)
    f.write('\n')
print({k:v for k,v in summary.items() if k not in ('per_frame','source_sha256','python')})
