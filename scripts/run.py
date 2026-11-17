#!/usr/bin/env python3
"""One-command reproducible RTL regression; Python 3.9+, Icarus or Verilator."""
import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.attention import bit_model, encode, errors, reference
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


def compile_tb(args, run, name, parameter, value):
    src = RTL + [f'tb/{name}.sv']
    if args.sim == 'iverilog':
        exe = run / f'{name}.vvp'
        command(['iverilog', '-g2012', '-Wall', '-s', name, *([f'-P{name}.{parameter}={value}'] if parameter else []),
                 '-o', exe] + src, run / f'{name}_compile.log', args.timeout)
        return ['vvp', exe]
    obj = run / f'obj_{name}'
    cmd = ['verilator', '--binary', '--timing', '--assert', '-j', '2',
           '-Wno-fatal', '--top-module', name, *([f'-G{parameter}={value}'] if parameter else []), '--Mdir', obj,
           '-o', name]
    if args.waves:
        cmd += ['--trace']
    command(cmd + src, run / f'{name}_compile.log', args.timeout)
    return [obj / name]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', choices=['iverilog', 'verilator'], default='iverilog')
    parser.add_argument('--random', type=int, default=8, dest='random_count')
    parser.add_argument('--seed', type=int, default=20261117)
    parser.add_argument('--stalls', type=int, choices=[0, 1], default=1,
                        help='Main regression stalls; reset recovery always includes stalls')
    parser.add_argument('--outdir', type=Path, help='New directory; must not already exist')
    parser.add_argument('--waves', action='store_true', help='Write potentially large VCD (gitignored)')
    parser.add_argument('--vectors', type=Path, help='Custom JSON list: {name, category, words:[768 binary16 integers]}')
    parser.add_argument('--timeout', type=int, default=600, help='Wall-clock seconds per subprocess')
    args = parser.parse_args()
    if args.random_count < 0 or not 0 <= args.seed <= 0x7fffffff or args.timeout < 1:
        parser.error('Require random >= 0, 0 <= seed <= 2^31-1, timeout >= 1')
    for tool in ([args.sim, 'vvp'] if args.sim == 'iverilog' else ['verilator', 'make']):
        if not shutil.which(tool):
            parser.error(f'Missing executable: {tool}; see README.md installation section')
    tag = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).strftime('%Y%m%d_%H%M%S')
    run = (args.outdir or ROOT / 'results' / f'{tag}_{args.sim}_seed{args.seed}_{os.getpid()}').resolve()
    run.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    manifest = {'status': 'RUNNING', 'command': sys.argv, 'seed': args.seed,
                'random_count': args.random_count, 'stalls': args.stalls, 'simulator': args.sim,
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
        for case in cases:
            case['expected'] = bit_model(case['words'])
            case['float64_reference'] = reference(case['words'])
        write_json(run / 'cases.json', cases)
        (run / 'input.hex').write_text(''.join(f'{h:04x}\n' for c in cases for h in c['words']))
        (run / 'expected.hex').write_text(''.join(f'{h:04x}\n' for c in cases for h in c['expected']))
        shutil.copyfile(ROOT/'rtl/exp_fp16.hex', run/'exp_fp16.hex')
        exe = compile_tb(args, run, 'tb_attention', 'CASES', len(cases))
        cmd = exe + ['+INPUT=input.hex', '+EXPECTED=expected.hex',
                     '+OUTPUT=actual.txt', f'+SEED={args.seed}', f'+STALLS={args.stalls}']
        if args.waves:
            cmd += ['+WAVE=attention.vcd']
        command(cmd, run / 'simulation.log', args.timeout, cwd=run)
        log = (run / 'simulation.log').read_text()
        if 'TB PASS' not in log:
            raise RuntimeError('Simulation ended without TB PASS')
        expected_runs = list(range(len(cases))) + [(phase+7) % len(cases) for phase in range(8)] + [(phase+11) % len(cases) for phase in range(1,6)]
        captures = [[] for _ in expected_runs]
        previous_run = 0
        last_cycle = -1
        for line in (run / 'actual.txt').read_text().splitlines():
            rid, cid, idx, bits, cyc = line.split()
            rid, cid, idx, cyc = map(int, (rid, cid, idx, cyc))
            if not 0 <= rid < len(captures) or cid != expected_runs[rid]:
                raise RuntimeError(f'Unexpected run/case in capture: {line}')
            if rid < previous_run or rid > previous_run+1 or cyc <= last_cycle:
                raise RuntimeError(f'Capture reordering: {line}')
            previous_run, last_cycle = rid, cyc
            if idx != len(captures[rid]):
                raise RuntimeError(f'Duplicate/missing output in capture: {line}')
            captures[rid].append(int(bits, 16))
        latency = {int(r): {'cycles': int(c), 'mode': int(m)}
                   for r, _, c, m in re.findall(r'FRAME PASS run=(\d+) case=(\d+) cycles=(\d+) mode=(\d+)', log)}
        report = []
        for rid, cid in enumerate(expected_runs):
            case = cases[cid]
            actual = captures[rid]
            if actual != case['expected']:
                raise RuntimeError(f'Bit mismatch/missing output in captured run {rid}')
            rmse, maximum = errors(actual, case['float64_reference'])
            passed = rmse <= 0.06 and maximum <= 0.20
            item = {'run': rid, 'case': cid, 'name': case['name'],
                    'category': case['category'] if rid < len(cases) else 'reset_recovery',
                    'bit_exact': True, 'finite': True, 'rmse': rmse,
                    'max_abs_error': maximum, 'passed': passed, **latency[rid]}
            report.append(item)
            if not passed:
                raise RuntimeError(f'Accuracy failure: {item}')
        coverage = re.search(r'COVERAGE frames=(\d+) resets=(\d+) input_bubbles=(\d+) output_stall_cycles=(\d+) no_stall_cycles=(\d+)', log)
        if not coverage:
            raise RuntimeError('Missing coverage summary')
        summary = {'status': 'PASS', 'frames': len(report), 'outputs': 256*len(report),
                   'max_frame_rmse': max(r['rmse'] for r in report),
                   'max_abs_error': max(r['max_abs_error'] for r in report),
                   'limits': {'rmse': 0.06, 'max_abs_error': 0.20},
                   'coverage': dict(zip(['frames', 'resets', 'input_bubbles', 'output_stall_cycles', 'no_stall_cycles'], map(int, coverage.groups()))),
                   'per_frame': report}
        write_json(run / 'summary.json', summary)
        with (run / 'per_frame.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=['run', 'case', 'name', 'category', 'cycles',
                                                       'mode', 'bit_exact', 'finite', 'rmse', 'max_abs_error', 'passed'])
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
