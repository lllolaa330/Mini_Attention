#!/usr/bin/env python3
"""One-command reproducible RTL regression; Python 3.9+, Icarus or Verilator."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import bit_model_with_probabilities, errors, reference
from model.vectors import make_cases

RTL = ['-f', 'rtl/files.f']


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def command(cmd, log, timeout=180, cwd=ROOT):
    print('+', ' '.join(map(str, cmd)), flush=True)
    with log.open('w') as stream:
        stream.write('COMMAND: ' + repr(list(map(str, cmd))) + '\n')
        stream.flush()
        try:
            subprocess.run(list(map(str, cmd)), cwd=cwd, stdout=stream,
                           stderr=subprocess.STDOUT, timeout=timeout, check=True)
        except (subprocess.SubprocessError, OSError):
            print(log.read_text()[-8000:], file=sys.stderr)
            raise


def compile_tb(args, run, name, parameter, value, extra_parameters=None, extra_sources=()):
    src = RTL + list(extra_sources) + [f'tb/{name}.sv']
    parameters = {parameter: value} if parameter else {}
    parameters.update(extra_parameters or {})
    if args.sim == 'iverilog':
        exe = run / f'{name}.vvp'
        command(['iverilog', '-g2012', '-Wall', '-s', name,
                 *[f'-P{name}.{key}={val}' for key, val in parameters.items()],
                 '-o', exe] + src, run / f'{name}_compile.log', args.timeout)
        return ['vvp', exe]
    obj = run / f'obj_{name}'
    cmd = ['verilator', '--binary', '--timing', '--assert', '-j', '2',
           '-Wno-fatal', '--top-module', name,
           *[f'-G{key}={val}' for key, val in parameters.items()], '--Mdir', obj,
           '-o', name]
    if args.waves:
        cmd += ['--trace']
    command(cmd + src, run / f'{name}_compile.log', args.timeout)
    return [obj / name]



def expected_batches(case_count, single_frame, stalls):
    batches = [('main', list(range(case_count)))]
    if single_frame:
        return batches
    if stalls:
        batches.append(('stress', [(9+i) % case_count for i in range(4)]))
    # Eight operation-level interruptions, starvation part-way through PV,
    # then a queued frame aborted while the previous frame is held at output.
    recoveries = [event+7 for event in range(8)] + [17, 18]
    batches.extend(('recovery', [case_id % case_count]) for case_id in recoveries)
    batches.append(('partial_v', [19 % case_count, 20 % case_count]))
    return batches


def read_diagonal_capture(path, case_ids):
    """Validate every transferred lane and return row-major words plus beat cycles."""
    frames = []
    previous_cycle = -1
    with path.open() as stream:
        for run_id, case_id in enumerate(case_ids):
            words = [None] * 256
            beats = []
            for diagonal in range(31):
                first_col = max(0, diagonal-15)
                for col in range(first_col, min(15, diagonal)+1):
                    idx = (diagonal-col)*16 + col
                    line = stream.readline()
                    if not line:
                        raise ValueError(f'Missing output in run {run_id}, diagonal {diagonal}, index {idx}')
                    rid, cid, index, bits, clock = line.split()
                    if (int(rid), int(cid), int(index)) != (run_id, case_id, idx):
                        raise ValueError(f'Expected run {run_id}, case {case_id}, index {idx}; got {line.strip()}')
                    cycle = int(clock)
                    if col == first_col:
                        if cycle <= previous_cycle:
                            raise ValueError(f'New output beat must advance the cycle: {line.strip()}')
                        beats.append(cycle)
                        previous_cycle = cycle
                    elif cycle != previous_cycle:
                        raise ValueError(f'Cycle changed within diagonal {diagonal}: {line.strip()}')
                    word = int(bits, 16)
                    if not 0 <= word <= 0xffff:
                        raise ValueError(f'Output outside binary16: {line.strip()}')
                    words[idx] = word
            frames.append((words, beats))
        if stream.readline():
            raise ValueError('Extra data after the last expected output beat')
    return frames


def cycle_stats(values):
    if not values:
        return None
    return {'min': min(values), 'max': max(values), 'mean': sum(values)/len(values)}


def verify_frames(path, log, cases, single_frame, stalls):
    batches = expected_batches(len(cases), single_frame, stalls)
    case_ids = [cid for _, ids in batches for cid in ids]
    captured = read_diagonal_capture(path, case_ids)
    markers = re.findall(r'^BATCH START first_run=(\d+) count=(\d+) kind=(\w+)$', log, re.M)
    records = re.findall(r'^FRAME PASS run=(\d+) case=(\d+) cycles=(\d+) mode=(\d+) '
                         r'first_in=(\d+) first_out=(\d+) last_out=(\d+)$', log, re.M)
    timing_keys = ('run', 'qk_first', 'qk_last', 'issue_first', 'issue_last',
                   'return_first', 'return_last', 'pv_first', 'overlap', 'resident')
    events = re.findall(r'^PIPELINE ' + ' '.join(rf'{key}=(\d+)' for key in timing_keys) + '$', log, re.M)
    if len(markers)!=len(batches) or len(records)!=len(case_ids) or len(events)!=len(records):
        raise ValueError('Incomplete or duplicate batch/frame/pipeline timing records in simulation.log')

    report, batch_timing = [], []
    for (kind, ids), (first_run, count, label) in zip(batches, markers):
        base = len(report)
        if (int(first_run), int(count), label) != (base, len(ids), kind):
            raise ValueError(f'Unexpected batch marker {first_run}, {count}, {label}')
        batch_frames = []
        for pos, cid in enumerate(ids):
            rid = base + pos
            logged_run, logged_case, cycles, mode, first_in, first_out, last_out = map(int, records[rid])
            expected_mode = 1 if kind != 'main' else (stalls if single_frame or pos >= 4 else 0)
            if (logged_run, logged_case, mode) != (rid, cid, expected_mode):
                raise ValueError(f'Unexpected frame timing record: {records[rid]}')
            words, beats = captured[rid]
            if (first_out, last_out) != (beats[0], beats[-1]) or first_out < first_in:
                raise ValueError(f'Frame {rid}: invalid first/last handshake cycles')
            if cycles != last_out-first_in+1 or (report and first_in <= report[-1]['first_in_cycle']):
                raise ValueError(f'Frame {rid}: invalid latency or input order')
            case = cases[cid]
            if words != case['expected']:
                idx = next(i for i, (a, b) in enumerate(zip(words, case['expected'])) if a != b)
                raise ValueError(f'Frame {rid}: Y[{idx//16},{idx%16}] is {words[idx]:04x}, '
                                 f'expected {case["expected"][idx]:04x}')
            rmse, maximum = errors(words, case['float64_reference'])
            if rmse > 0.06 or maximum > 0.20:
                raise ValueError(f'Frame {rid}: RMSE={rmse}, maximum error={maximum}')
            pipeline = dict(zip(timing_keys, map(int, events[rid])))
            if pipeline.pop('run') != rid:
                raise ValueError(f'Incorrect pipeline record for run {rid}')
            resident = kind == 'partial_v' and pos == 1
            if pipeline.pop('resident') != int(resident):
                raise ValueError(f'Incorrect resident frame tag for run {rid}')
            if pipeline['issue_last'] - pipeline['issue_first'] != 15 or pipeline['return_last'] - pipeline['return_first'] != 15:
                raise ValueError(f'Frame {rid} did not normalize 16 complete rows on 16 consecutive clocks')
            if resident and (not pipeline['overlap'] or pipeline['pv_first'] >= pipeline['qk_last']):
                raise ValueError('No simultaneous QK/PV MACs in the resident frame')
            frame = {
                'run': rid, 'case': cid, 'name': case['name'], 'batch': kind,
                'category': case['category'] if kind == 'main' else {
                    'recovery': 'reset_recovery', 'stress': 'backpressure_stress',
                    'partial_v': 'partial_v_streaming',
                }[kind],
                'mode': mode, 'first_in_cycle': first_in, 'first_out_cycle': first_out,
                'last_out_cycle': last_out, 'first_output_latency_cycles': first_out-first_in+1,
                'normalization_first_issue': pipeline['issue_first'],
                'normalization_last_issue': pipeline['issue_last'],
                'normalization_first_return': pipeline['return_first'],
                'normalization_last_return': pipeline['return_last'],
                'first_qk_mac': pipeline['qk_first'], 'last_qk_mac': pipeline['qk_last'],
                'first_pv_mac': pipeline['pv_first'], 'qk_pv_overlap_cycles': pipeline['overlap'],
                'resident_at_dispatch': resident, 'normalized_fp16_words_checked': 256,
                'cycles': cycles, 'input_ii_cycles': first_in-batch_frames[-1]['first_in_cycle'] if pos else None,
                'output_beats': len(beats), 'bit_exact': True, 'finite': True,
                'rmse': rmse, 'max_abs_error': maximum, 'passed': True,
            }
            batch_frames.append(frame)
            report.append(frame)

        # Start-to-start initiation intervals are meaningful within a continuous
        # batch. Resets and stimulus setup between batches introduce idle time.
        batch_timing.append({
            'kind': kind, 'first_run': base, 'frames': len(ids),
            'first_in_cycle': batch_frames[0]['first_in_cycle'],
            'first_out_cycle': batch_frames[0]['first_out_cycle'],
            'last_out_cycle': batch_frames[-1]['last_out_cycle'],
            'first_output_latency_cycles': cycle_stats([f['first_output_latency_cycles'] for f in batch_frames]),
            'frame_latency_cycles': cycle_stats([f['cycles'] for f in batch_frames]),
            'input_ii_cycles': cycle_stats([f['input_ii_cycles'] for f in batch_frames[1:]]),
        })
    return report, batch_timing



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', choices=['iverilog', 'verilator'], default='iverilog')
    parser.add_argument('--dataflow', choices=['os'], default='os',
                        help='The streaming attention core uses one shared output-stationary array for QK and PV')
    parser.add_argument('--random', type=int, default=8, dest='random_count')
    parser.add_argument('--seed', type=int, default=20261117)
    parser.add_argument('--stalls', type=int, choices=[0, 1], default=1,
                        help='Enable stalls after the first four clean main frames and run a backpressure batch; recovery always stalls')
    parser.add_argument('--single-frame', action='store_true',
                        help='Run only the first input vector, without reset-recovery tests (use --stalls 0 for clean waves)')
    parser.add_argument('--outdir', type=Path, help='New directory; must not already exist')
    parser.add_argument('--waves', action='store_true', help='Write VCD (Icarus: streaming controls and four PEs; Verilator: full trace)')
    parser.add_argument('--waves-full', action='store_true', help='Write full recursive VCD, including floating-point internals (large)')
    parser.add_argument('--vectors', type=Path, help='Custom JSON list: {name, category, words:[768 binary16 integers]}')
    parser.add_argument('--timeout', type=int, default=600, help='Wall-clock seconds per subprocess')
    args = parser.parse_args()
    if args.waves_full:
        args.waves = True
    if args.random_count < 0 or not 0 <= args.seed <= 0x7fffffff or args.timeout < 1:
        parser.error('Require random >= 0, 0 <= seed <= 2^31-1, timeout >= 1')
    for tool in ([args.sim, 'vvp'] if args.sim == 'iverilog' else ['verilator', 'make']):
        if not shutil.which(tool):
            parser.error(f'Missing executable: {tool}; see README.md installation section')
    tag = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).strftime('%Y%m%d_%H%M%S')
    run = (args.outdir or ROOT / 'results' / f'{tag}_{args.dataflow}_{args.sim}_seed{args.seed}_{os.getpid()}').resolve()
    run.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    manifest = {'status': 'RUNNING', 'command': sys.argv, 'seed': args.seed,
                'random_count': args.random_count, 'stalls': args.stalls, 'simulator': args.sim,
                'dataflow': args.dataflow, 'normalization': 'online_fp16_row_ii1',
                'single_frame': args.single_frame, 'input_protocol': 'qk_scalar_v_column16',
                'input_beats_per_frame': 528, 'output_protocol': 'diagonal_16_lane',
                'started_at': dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(),
                'python': sys.version, 'sources_sha256': {}}
    for pattern in ('rtl/*', 'tb/*.sv', 'model/*.py', 'model/*.c', 'scripts/*.py', 'scripts/softfloat_build/*', 'tests/*.py', 'third_party/HardFloat-1/**/*', 'third_party/softfloat_source/**/*', 'third_party/SOFTFLOAT_LICENSE.txt'):
        for path in sorted(ROOT.glob(pattern)):
            if not path.is_file():
                continue
            manifest['sources_sha256'][str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    git_head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=ROOT, capture_output=True, text=True)
    manifest['git_commit'] = git_head.stdout.strip() if git_head.returncode == 0 else 'UNCOMMITTED'
    manifest['git_status'] = subprocess.run(['git', 'status', '--short'], cwd=ROOT, capture_output=True, text=True).stdout
    for tool, flag in [('iverilog', '-V'), ('verilator', '--version'), ('cc', '--version')]:
        if shutil.which(tool):
            result = subprocess.run([tool, flag], capture_output=True, text=True)
            manifest[tool + '_version'] = (result.stdout + result.stderr).splitlines()[0]
    write_json(run / 'manifest.json', manifest)
    try:
        command([sys.executable, 'scripts/gen_exp.py', '--check'], run / 'lut_check.log', args.timeout)
        command([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-v'], run / 'model_tests.log', args.timeout)
        if args.vectors:
            cases = json.loads(args.vectors.read_text())
            if not isinstance(cases, list) or not cases:
                raise ValueError('Custom vectors must be a nonempty JSON list')
            manifest['custom_vectors'] = str(args.vectors.resolve())
            manifest['custom_vectors_sha256'] = hashlib.sha256(args.vectors.read_bytes()).hexdigest()
            for i, case in enumerate(cases):
                case.setdefault('name', f'custom_{i}')
                case.setdefault('category', 'custom')
        else:
            cases = make_cases(args.seed, args.random_count)
        if args.single_frame:
            cases = cases[:1]
        for case in cases:
            case['expected'], case['probabilities'] = bit_model_with_probabilities(case['words'])
            case['float64_reference'] = reference(case['words'])
        write_json(run / 'cases.json', cases)
        (run / 'input.hex').write_text(''.join(f'{h:04x}\n' for c in cases for h in c['words']))
        (run / 'expected.hex').write_text(''.join(f'{h:04x}\n' for c in cases for h in c['expected']))
        (run / 'expected_p.hex').write_text(''.join(f'{h:04x}\n' for c in cases for h in c['probabilities']))
        shutil.copyfile(ROOT/'rtl/exp_fp16.hex', run/'exp_fp16.hex')
        exe = compile_tb(args, run, 'tb_attention', 'CASES', len(cases),
                         extra_parameters={'SINGLE_FRAME': "1'b1" if args.single_frame else "1'b0"})
        cmd = exe + ['+INPUT=input.hex', '+EXPECTED=expected.hex',
                     '+EXPECTED_P=expected_p.hex', '+OUTPUT=actual.txt', f'+SEED={args.seed}', f'+STALLS={args.stalls}']
        if args.waves:
            cmd += ['+WAVE=attention.vcd']
        if args.waves_full:
            cmd += ['+WAVE_FULL']
        command(cmd, run / 'simulation.log', args.timeout, cwd=run)
        log = (run / 'simulation.log').read_text()
        if 'TB PASS' not in log:
            raise RuntimeError('Simulation ended without TB PASS')
        report, batch_timing = verify_frames(run / 'actual.txt', log, cases, args.single_frame, args.stalls)
        coverage = re.search(r'COVERAGE frames=(\d+) resets=(\d+) input_bubbles=(\d+) output_stall_cycles=(\d+) no_stall_cycles=(\d+)', log)
        if not coverage:
            raise RuntimeError('Missing coverage summary')
        coverage_values = dict(zip(['frames', 'resets', 'input_bubbles', 'output_stall_cycles', 'no_stall_cycles'],
                                   map(int, coverage.groups())))
        expected_resets = 1 if args.single_frame else 11
        if coverage_values['frames'] != len(report) or coverage_values['resets'] != expected_resets:
            raise RuntimeError(f'Unexpected coverage counts: {coverage_values}')
        stream_keys = ('input_blocked', 'overlap_v_qk', 'overlap_v_sm', 'next_input_output',
                       'first_output_pv', 'long_stall_cycles', 'queued_resets', 'reset_event_mask', 'resident_count')
        stream_match = re.search(r'^STREAM_COVERAGE ' + ' '.join(rf'{key}=(\d+)' for key in stream_keys) + '$',
                                 log, re.M)
        if not stream_match:
            raise RuntimeError('Missing streaming coverage summary')
        stream_coverage = dict(zip(stream_keys, map(int, stream_match.groups())))
        v_keys = ('pv_steps_before_v_complete', 'pv_missing_v_cycles', 'pv_wait_resets', 'output_input_bubble_stalls')
        v_match = re.search(r'^V_COVERAGE ' + ' '.join(rf'{key}=(\d+)' for key in v_keys) + '$', log, re.M)
        if not v_match:
            raise RuntimeError('Missing partial V coverage summary')
        v_coverage = dict(zip(v_keys, map(int, v_match.groups())))
        if not args.single_frame:
            required_positive = ('input_blocked', 'overlap_v_qk', 'overlap_v_sm', 'first_output_pv')
            if any(stream_coverage[key] <= 0 for key in required_positive):
                raise RuntimeError(f'Missing streaming overlap/protocol coverage: {stream_coverage}')
            if len(cases) >= 2 and stream_coverage['next_input_output'] <= 0:
                raise RuntimeError('Missing next-frame input/output overlap')
            expected_stream = {'queued_resets': 1, 'reset_event_mask': 255, 'resident_count': 1, 'long_stall_cycles': 2500 if args.stalls else 0}
            if any(stream_coverage[key] != value for key, value in expected_stream.items()):
                raise RuntimeError(f'Unexpected streaming coverage counts: {stream_coverage}')
            if (v_coverage['pv_steps_before_v_complete'] <= 0 or v_coverage['pv_missing_v_cycles'] <= 0
                    or v_coverage['output_input_bubble_stalls'] < 12 or v_coverage['pv_wait_resets'] != 1):
                raise RuntimeError(f'Incomplete partial V coverage: {v_coverage}')
            if len(re.findall(r'^PV WAIT RESET PASS$', log, re.M)) != 1:
                raise RuntimeError('Missing/duplicate PV starvation reset log')
            if sorted(map(int, re.findall(r'^RESET PASS event=(\d+)$', log, re.M))) != list(range(8)):
                raise RuntimeError('Missing, repeated or unexpected pipeline reset event')
        summary = {'status': 'PASS', 'frames': len(report), 'outputs': 256*len(report),
                   'dataflow': args.dataflow, 'normalization': 'online_fp16_row_ii1',
                   'max_frame_rmse': max(r['rmse'] for r in report),
                   'max_abs_error': max(r['max_abs_error'] for r in report),
                   'limits': {'rmse': 0.06, 'max_abs_error': 0.20},
                   'seed': args.seed, 'stalls': args.stalls, 'input_beats_per_frame': 528,
                   'output_beats': 31*len(report),
                   'normalized_fp16_words_checked': 256*len(report),
                   'coverage': coverage_values, 'stream_coverage': stream_coverage, 'v_coverage': v_coverage,
                   'batch_timing': batch_timing,
                   'per_frame': report}
        write_json(run / 'summary.json', summary)
        with (run / 'per_frame.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(report[0]))
            writer.writeheader()
            writer.writerows(report)
        manifest['status'] = 'PASS'
        print(f'PASS: {len(report)} frames, {len(report)*256} outputs; '
              f'max RMSE={summary["max_frame_rmse"]:.8f}, max abs={summary["max_abs_error"]:.8f}')
        print(f'Evidence: {run}')
    except Exception as exc:
        manifest['status'] = 'FAIL'
        manifest['error'] = repr(exc)
        print(f'FAIL: {exc}\nEvidence preserved: {run}', file=sys.stderr)
        return 1
    finally:
        manifest['elapsed_seconds'] = time.monotonic() - started
        write_json(run / 'manifest.json', manifest)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
