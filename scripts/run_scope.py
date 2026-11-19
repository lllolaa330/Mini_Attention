#!/usr/bin/env python3
"""Bit-check and time native public-port Attention implementations (Icarus or Verilator)."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import errors, reference
from model.vectors import make_cases
from scripts.run import command, write_json

PINS = {'baseline': '34559ae', 'stream': '7ea651a'}
FILELISTS = {'baseline': 'rtl/files.f', 'stream': 'rtl/files.f',
             'scope': 'rtl/scope_files.f', 'os-scope': 'rtl/os_scope_files.f'}
TESTBENCH = ROOT / 'tb/tb_scope_compare.sv'
PERF_FRAMES = 12
PERIOD_NS = 10


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def historical_checkout(design, dest):
    commit = subprocess.check_output(['git', 'rev-parse', PINS[design]+'^{commit}'], cwd=ROOT, text=True).strip()
    archive = dest / 'source.tar'
    dest.mkdir(exist_ok=False)
    subprocess.run(['git', 'archive', '--output', str(archive), commit, 'rtl', 'model',
                    'third_party/HardFloat-1', 'third_party/softfloat_source', 'scripts/softfloat_build'],
                   cwd=ROOT, check=True)
    subprocess.run(['tar', '-xf', str(archive)], cwd=dest, check=True)
    return commit


# Import each implementation's own numerical model from the checkout used to
# build its RTL. The first release exposes only final Y; newer versions also P.
MODEL_PROGRAM = '''
import json, sys
from pathlib import Path
from importlib import import_module
design, cases_path, run_path = sys.argv[1:]
run = Path(run_path)
mod = import_module('model.scope_attention' if design in ('scope','os-scope') else 'model.attention')
y_words, p_words = [], []
for case in json.loads(Path(cases_path).read_text()):
    if design=='baseline':
        y = mod.bit_model(case['words'])
    else:
        y, p = mod.bit_model_with_probabilities(case['words'])
        if len(p)!=256: raise ValueError('invalid P gold length')
        p_words.extend(p)
    if len(y)!=256: raise ValueError('invalid Y gold length')
    y_words.extend(y)
for name, words in [('expected.hex',y_words),('expected_p.hex',p_words)]:
    if words:
        (run/name).write_text(''.join(f'{w:04x}\\n' for w in words))
'''


def check_capture(run, cases, refs):
    rows = []
    for line in (run/'simulation.log').read_text().splitlines():
        if line.startswith('FRAME '):
            stress, frame, cid, first, last_in, first_out, last = map(int, line.split()[1:])
            rows.append(dict(stress=stress, frame=frame, case_id=cid, first_in=first, last_in=last_in,
                             first_out=first_out, last_out=last, first_result_cycles=first_out-first+1,
                             latency_cycles=last-first+1))
    plan = [(0, i, i%(PERF_FRAMES//2)) for i in range(PERF_FRAMES)]
    plan += [(1, i, i) for i in range(len(cases))]
    if [(r['stress'],r['frame'],r['case_id']) for r in rows] != plan:
        raise ValueError('Unexpected frame count, order or fixture ID')
    golden = [int(s,16) for s in (run/'expected.hex').read_text().splitlines()]
    captures = {}
    for line in (run/'actual.txt').read_text().splitlines():
        group, frame, index, value = line.split()
        key = (int(group), int(frame), int(index))
        if key in captures:
            raise ValueError(f'Duplicate Y at {key}')
        captures[key] = int(value,16)
    for r in rows:
        cid = r['case_id']
        measured = [captures.pop((r['stress'],r['frame'],i)) for i in range(256)]
        if measured != golden[cid*256:(cid+1)*256]:
            raise ValueError('Python raw output bit check failed')
        rmse, max_abs = errors(measured, refs[cid])
        if rmse>0.06 or max_abs>0.20:
            raise ValueError(f"case {cases[cid]['name']} failed independent accuracy: {rmse} {max_abs}")
        r.update(rmse=rmse, max_abs=max_abs)
    if captures:
        raise ValueError('Extra output words')
    with (run/'frames.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    # Second traversal of the six fixed nonzero inputs; include the transition
    # into the first measured frame. All intervals are output retire-to-retire.
    warm = PERF_FRAMES//2
    intervals = [rows[i]['last_out']-rows[i-1]['last_out'] for i in range(warm,PERF_FRAMES)]
    mean_ii = statistics.mean(intervals)
    return dict(frames=len(rows), y_words=len(rows)*256, max_rmse=max(r['rmse'] for r in rows),
                max_abs=max(r['max_abs'] for r in rows), steady_ii_samples=intervals,
                steady_ii_cycles=mean_ii, frames_per_cycle=1/mean_ii,
                simulated_frames_per_s=1e9/(mean_ii*PERIOD_NS),
                first_result_cycles=rows[0]['first_result_cycles'],
                first_frame_cycles=rows[0]['latency_cycles'],
                first_frame_us=rows[0]['latency_cycles']*PERIOD_NS/1000,
                batch_cycles=rows[PERF_FRAMES-1]['last_out']-rows[0]['first_in']+1)


def check_os_mesh(run, case_count):
    """Compare every actual enabled diagonal and P commit to an independent edge schedule."""
    traces = [[], []]
    for line in (run/'mesh_activity.txt').read_text().splitlines():
        group, *fields = line.split()
        traces[int(group)].append(fields)
    batches = []
    for stress, (trace, frame_count) in enumerate(zip(traces, (PERF_FRAMES, case_count))):
        launches, launch_cycles = [], []
        counts = dict.fromkeys(('qk','pv','exp'),0)
        logical_edge = triple = stalled = longest_hold = hold = p_commits = 0
        for cycle, step, launch, qk, pv, exp, first, p_valid, row, blocked in trace:
            cycle = int(cycle)
            hold = hold+1 if blocked=='1' else 0
            longest_hold = max(longest_hold,hold)
            if step=='0':
                if p_valid!='0':
                    raise ValueError(f'P committed while mesh stopped at cycle {cycle}')
                stalled += int(blocked=='1')
                continue
            if step!='1' or launch not in ('0','1'):
                raise ValueError(f'Unknown mesh step or launch at cycle {cycle}')
            if launch=='1':
                launches.append(logical_edge)
                launch_cycles.append(cycle)
            qk, pv, exp, first = (int(value,16) for value in (qk,pv,exp,first))
            ages = [logical_edge - start for start in reversed(launches[-4:])]
            expected_p = [age-69 for age in ages if 69<=age<=84]
            if p_valid!=str(len(expected_p)) or (expected_p and int(row,16)!=expected_p[0]):
                raise ValueError(f'P commit row/timing mismatch at cycle {cycle}, frame ages {ages}')
            p_commits += len(expected_p)
            expected = [0,0,0]
            expected_first = 0
            for age in ages:
                for index, offset in enumerate((0,120,32)):
                    local = age-offset
                    lo, hi = max(0,local-15), min(30,local)
                    if lo<=hi:
                        expected[index] |= ((1<<(hi-lo+1))-1)<<lo
                    if index<2 and 0<=local<=30:
                        expected_first |= 1<<local
            if [qk,pv,exp]!=expected or (first & (qk|pv))!=expected_first or (qk&pv)|(qk&exp)|(pv&exp):
                raise ValueError(f'Mesh operation clash or timing mismatch at cycle {cycle}: '
                                 f'actual={[qk,pv,exp,first]}, expected={expected+[expected_first]}, ages={ages}')
            for op, mask in zip(counts,(qk,pv,exp)):
                counts[op] += sum(min(diag+1,31-diag) for diag in range(31) if mask & (1<<diag))
            triple += int(bool(qk and pv and exp))
            logical_edge += 1
        if (len(launches)!=frame_count or p_commits!=16*frame_count or not triple or
            any(count!=4096*frame_count for count in counts.values())):
            raise ValueError(f'Incomplete mesh activity for stress={stress}: {counts}, launches={launches}')
        intervals = [b-a for a,b in zip(launch_cycles,launch_cycles[1:])]
        if not stress and intervals!=[52]*(frame_count-1):
            raise ValueError(f'No-stall launch intervals: {intervals}')
        if stress and (longest_hold<320 or stalled<318):
            raise ValueError('Directed backpressure did not freeze the active array')
        batches.append(dict(stress=bool(stress), frames=frame_count, fma_events=counts,
                            launch_cycles=launch_cycles, launch_intervals=intervals,
                            row_p_commits=p_commits, simultaneous_qk_exp_pv_cycles=triple,
                            output_blocked_mesh_frozen_cycles=stalled, longest_output_hold=longest_hold))
    write_json(run/'mesh_checks.json',dict(status='PASS',batches=batches,
               first_p_write_logical_age=69,first_pv_mac_logical_age=120))


def benchmark(design, target, cases, refs, args, temp):
    run = target/design
    run.mkdir()
    source = temp/design if design in PINS else ROOT
    revision = (historical_checkout(design,source) if design in PINS else
                subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
    filelist = FILELISTS[design]
    src_files = {p for d in ('model','third_party/HardFloat-1/source','third_party/scope')
                 for p in (source/d).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    src_files.add(source/filelist)
    for line in (source/filelist).read_text().splitlines():
        if line.startswith('rtl/'):
            src_files.add(source/line)
    src_files.add(source/'rtl'/('exp_fp16.hex' if design in PINS else 'scope_exp_coeffs.svh'))
    manifest = dict(design=design, base_commit=revision, filelist=filelist,
                    source_sha256={str(p.relative_to(source)):sha(p) for p in sorted(src_files)},
                    bench_sha256=sha(TESTBENCH), runner_sha256=sha(Path(__file__)),
                    cases_sha256=sha(target/'cases.json'), status='RUNNING')
    write_json(run/'manifest.json', manifest)
    try:
        shutil.copyfile(target/'input.hex',run/'input.hex')
        if design in PINS:
            shutil.copyfile(source/'rtl/exp_fp16.hex',run/'exp_fp16.hex')
        command([sys.executable,'-c',MODEL_PROGRAM,design,target/'cases.json',run],
                run/'model.log', args.timeout, cwd=source)
        parameters = {'CASES':len(cases),'PERF_FRAMES':PERF_FRAMES}
        if design=='scope':
            parameters['SCOPE_STRIPS']=args.strips
        defines = [] if design=='scope' else ['-D'+design.upper().replace('-','_')]
        if args.sim=='iverilog':
            exe=run/'tb.vvp'
            build=['iverilog','-g2012','-s','tb_scope_compare','-o',exe]
            build += [f'-Ptb_scope_compare.{k}={v}' for k,v in parameters.items()]
            simulate=['vvp',exe]
        else:
            obj=run/'obj_scope_compare'
            build=['verilator','--binary','--timing','--assert','-j','2','-Wno-fatal',
                   '--top-module','tb_scope_compare','--Mdir',obj]
            build += [f'-G{k}={v}' for k,v in parameters.items()]
            if args.waves: build.append('--trace')
            simulate=[obj/'Vtb_scope_compare']
        command(build+defines+['-f',filelist,TESTBENCH],run/'compile.log',args.timeout,cwd=source)
        command(simulate+(['+WAVES'] if args.waves else []),run/'simulation.log',args.timeout,cwd=run)
        readout = [line for line in (run/'simulation.log').read_text().splitlines() if line.startswith('PASS ')]
        if len(readout)!=1: raise ValueError('Missing testbench PASS')
        counters = {k:int(v) for k,v in (entry.split('=') for entry in readout[0].split()[1:])}
        metrics = check_capture(run,cases,refs)
        if design=='os-scope':
            check_os_mesh(run,len(cases))
            if metrics['steady_ii_samples']!=[52]*6:
                raise ValueError('OS-SCOPE public output II did not reach 52')
        if counters['Y']!=metrics['y_words'] or counters['P']!=(0 if design=='baseline' else counters['Y']):
            raise ValueError('Missing P/Y observations')
        metrics.update(design=design, coverage=counters, status='PASS')
        write_json(run/'metrics.json',metrics)
        manifest.update(status='PASS')
        return metrics
    except BaseException as err:
        manifest.update(status='FAIL', error=repr(err))
        raise
    finally:
        write_json(run/'manifest.json',manifest)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--designs',choices=FILELISTS,nargs='+',default=['scope'])
    p.add_argument('--outdir',type=Path)
    p.add_argument('--seed',type=int,default=20261118)
    p.add_argument('--timeout',type=int,default=600)
    p.add_argument('--random',type=int,default=6,help='Seeded random cases; first six time the controlled batch.')
    p.add_argument('--waves',action='store_true')
    p.add_argument('--sim',choices=('iverilog','verilator'),default='iverilog')
    p.add_argument('--strips',type=int,choices=(1,2),default=2,help='Number of SCOPE SCNA strips in the 16x16 array.')
    args=p.parse_args()
    if len(set(args.designs))!=len(args.designs) or args.random<6: p.error('Use distinct designs and --random >= 6')
    if args.outdir:
        target=args.outdir.resolve(); target.mkdir(parents=True,exist_ok=False)
    else:
        target=Path(tempfile.mkdtemp(prefix='scope_attention_',dir=ROOT/'results')).resolve()
    print('Evidence:',target,flush=True)
    suite=make_cases(args.seed,args.random)
    cases=[c for c in suite if c['category']=='random']+[c for c in suite if c['category']!='random']
    write_json(target/'cases.json',cases)
    (target/'input.hex').write_text(''.join(f'{w:04x}\n' for c in cases for w in c['words']))
    refs=[reference(c['words']) for c in cases]
    meta=dict(status='RUNNING',args=vars(args).copy(),seed=args.seed,period_ns=PERIOD_NS,
              simulator=subprocess.check_output([args.sim,'-V' if args.sim=='iverilog' else '--version'],stderr=subprocess.DEVNULL,text=True).splitlines()[0],
              clock_note='10 ns testbench period. Frames/s and us are simulated at that clock; hardware Fmax and power unmeasured.',
              interval='Mean of six retire-to-retire intervals in second traversal of same six clean nonzero frames',
              command=sys.argv)
    meta['args']['outdir']=str(target)
    write_json(target/'manifest.json',meta)
    summary={}
    try:
        with tempfile.TemporaryDirectory(prefix='mini_scope_sources_') as tmp:
            for design in args.designs:
                summary[design]=benchmark(design,target,cases,refs,args,Path(tmp))
        if 'baseline' in summary:
            for metrics in summary.values():
                metrics['throughput_speedup_vs_baseline']=summary['baseline']['steady_ii_cycles']/metrics['steady_ii_cycles']
        write_json(target/'summary.json',summary); meta['status']='PASS'
        for name,m in summary.items():
            print(f"{name}: {m['frames']} frames PASS; II {m['steady_ii_cycles']:.3f}, first frame {m['first_frame_cycles']} cycles")
    finally:
        if meta['status']=='RUNNING': meta['status']='FAIL'
        write_json(target/'manifest.json',meta)

if __name__=='__main__':
    main()
