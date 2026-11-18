#!/usr/bin/env python3
"""Read-only independent audit of the final four regressions and frozen benchmarks."""
import csv
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys

ARCHIVE = Path(__file__).resolve().parent
ROOT = ARCHIVE.parents[1]
RUNS = {
    'os_iverilog': '20261118_121751_os_iverilog_seed20261117_23777',
    'os_verilator': '20261118_121751_os_verilator_seed20261117_23780',
    'ws_iverilog': '20261118_121751_ws_iverilog_seed20261117_23781',
    'ws_verilator': '20261118_121751_ws_verilator_seed20261117_23779',
}


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_check(record, substitutions=None):
    substitutions = substitutions or {}
    mismatches = []
    for rel, expected in record.items():
        actual_path = substitutions.get(rel, ROOT / rel)
        actual = sha(actual_path) if actual_path.is_file() else None
        if actual != expected:
            mismatches.append({'path': rel, 'expected': expected, 'actual': actual})
    require(not mismatches, f'Source mismatch: {mismatches}')
    return {'files_checked': len(record), 'mismatches': mismatches}


def half(word):
    return struct.unpack('>e', struct.pack('>H', word))[0]


def math_attention(words):
    # Independent scalar mathematical reference; no SoftFloat, ROM, or FP16
    # internal arithmetic. Ordinary double sums cross-check the archived fsum.
    q, k, v = [[half(x) for x in words[o:o+256]] for o in (0, 256, 512)]
    result = []
    for row in range(16):
        logits = [sum(q[16*row+t]*k[16*col+t] for t in range(16))/4 for col in range(16)]
        exponentials = [math.exp(x-max(logits)) for x in logits]
        denominator = sum(exponentials)
        result.extend(sum(exponentials[t]*v[16*t+col] for t in range(16))/denominator for col in range(16))
    return result


def audit_run(name, dirname):
    path = ROOT / 'results' / dirname
    manifest, summary = read(path/'manifest.json'), read(path/'summary.json')
    require(manifest['status'] == summary['status'] == 'PASS', f'{name} not PASS')
    require(manifest['seed'] == 20261117 and manifest['stalls'] == 1 and manifest['random_count'] == 8,
            f'{name} parameter mismatch')
    source_result = source_check(manifest['sources_sha256'])
    log = (path/'simulation.log').read_text()
    require(len(re.findall(r'^TB PASS$', log, re.M)) == 1, f'{name} missing unique TB PASS')
    cases = read(path/'cases.json')
    require(len(cases) == 25, f'{name} expected 25 unique input cases')
    require([int(x, 16) for x in (path/'input.hex').read_text().split()] ==
            [x for c in cases for x in c['words']], f'{name} input fixture mismatch')
    require([int(x, 16) for x in (path/'expected.hex').read_text().split()] ==
            [x for c in cases for x in c['expected']], f'{name} expected fixture mismatch')
    reference_delta = max(abs(a-b) for c in cases
                          for a, b in zip(math_attention(c['words']), c['float64_reference']))
    require(reference_delta < 1e-12, f'{name} independent float64 reference mismatch')
    with (path/'per_frame.csv').open() as stream:
        frames = list(csv.DictReader(stream))
    actual_lines = (path/'actual.txt').read_text().splitlines()
    require(len(actual_lines) == len(frames)*256 == summary['outputs'], f'{name} output count mismatch')
    previous_cycle, maxima = -1, [0.0, 0.0]
    for run, frame in enumerate(frames):
        cid, words, cycles = int(frame['case']), [None]*256, []
        rows = iter(actual_lines[run*256:(run+1)*256])
        for diagonal in range(31):
            group_cycle = None
            for col in range(max(0, diagonal-15), min(15, diagonal)+1):
                index = (diagonal-col)*16+col
                r, c, idx, bits, clock = next(rows).split()
                require((int(r), int(c), int(idx)) == (run, cid, index), f'{name} lane/order mismatch run {run}')
                value, clock = int(bits, 16), int(clock)
                require(math.isfinite(half(value)), f'{name} non-finite output')
                require(value == cases[cid]['expected'][index], f'{name} bit mismatch run {run}, idx {index}')
                words[index] = value
                if group_cycle is None:
                    require(clock > previous_cycle, f'{name} non-monotonic handshake cycle')
                    group_cycle = previous_cycle = clock
                    cycles.append(clock)
                require(clock == group_cycle, f'{name} lanes in one beat have different cycles')
        require(cycles[0] == int(frame['first_out_cycle']) and cycles[-1] == int(frame['last_out_cycle']),
                f'{name} CSV output timing mismatch')
        require(int(frame['cycles']) == cycles[-1]-int(frame['first_in_cycle'])+1,
                f'{name} CSV latency mismatch')
        delta = [half(x)-y for x, y in zip(words, cases[cid]['float64_reference'])]
        rmse, max_abs = math.sqrt(math.fsum(d*d for d in delta)/256), max(map(abs, delta))
        require(rmse <= .06 and max_abs <= .20, f'{name} error thresholds exceeded')
        require(rmse == float(frame['rmse']) and max_abs == float(frame['max_abs_error']),
                f'{name} CSV error metrics mismatch')
        require(summary['per_frame'][run]['case'] == cid and summary['per_frame'][run]['rmse'] == rmse
                and summary['per_frame'][run]['max_abs_error'] == max_abs, f'{name} summary mismatch')
        maxima = [max(maxima[0], rmse), max(maxima[1], max_abs)]
    require(maxima == [summary['max_frame_rmse'], summary['max_abs_error']], f'{name} maxima mismatch')
    ws = name.startswith('ws')
    require(summary['frames'] == len(frames) == (49 if ws else 47), f'{name} frame count mismatch')
    require(summary['coverage']['resets'] == (19 if ws else 17), f'{name} reset count mismatch')
    for label, key in [('COVERAGE', 'coverage'), ('STREAM_COVERAGE', 'stream_coverage'), ('V_COVERAGE', 'v_coverage')]:
        match = re.findall(rf'^{label} (.+)$', log, re.M)
        require(len(match) == 1, f'{name} missing unique {label}')
        parsed = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', match[0])}
        require(parsed == summary[key], f'{name} log/summary coverage mismatch')
    stream, v = summary['stream_coverage'], summary['v_coverage']
    require(stream['top_reset_mask'] == (511 if ws else 255) and stream['softmax_reset_mask'] == 126
            and stream['queued_resets'] == 1 and stream['long_stall_cycles'] == 2500,
            f'{name} reset/backpressure coverage mismatch')
    require(all(stream[k] > 0 for k in ('input_blocked', 'overlap_v_qk', 'overlap_v_sm',
                                        'next_input_output', 'first_output_pv')), f'{name} overlap not covered')
    require(v['pv_steps_before_v_complete'] > 0 and v['pv_missing_v_cycles'] > 0
            and v['pv_wait_resets'] == 1 and v['ws_partial_v_resets'] == int(ws)
            and v['output_input_bubble_stalls'] >= 12
            and (v['ws_rows_during_sm'] > 0 if ws else v['ws_rows_during_sm'] == 0),
            f'{name} V scheduling coverage missing')
    return {'directory': str(path.relative_to(ROOT)), 'source_check': source_result,
            'manifest_sha256': sha(path/'manifest.json'), 'summary_sha256': sha(path/'summary.json'),
            'frames': len(frames), 'outputs': len(actual_lines), 'output_beats': len(frames)*31,
            'max_frame_rmse': maxima[0], 'max_abs_error': maxima[1],
            'independent_float64_reference_max_delta': reference_delta,
            'coverage': summary['coverage'], 'stream_coverage': stream, 'v_coverage': v}


def main():
    result = {'status': 'RUNNING', 'command': [sys.executable, str(Path(__file__).relative_to(ROOT))],
              'checked_at': dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(),
              'scope': 'Final 12:17:51 OS/WS x Icarus/Verilator; source identity, raw data and handshake timing, accuracy and coverage; frozen before/after benchmark lineage.',
              'limits': {'rmse': .06, 'max_abs_error': .20}, 'runs': {}, 'same_flow_simulators': {}}
    try:
        for name, dirname in RUNS.items():
            result['runs'][name] = audit_run(name, dirname)
        for flow in ('os', 'ws'):
            a, b = [ROOT/'results'/RUNS[f'{flow}_{sim}'] for sim in ('iverilog', 'verilator')]
            hashes = {}
            for filename in ('actual.txt', 'per_frame.csv', 'input.hex', 'expected.hex', 'cases.json', 'summary.json'):
                require((a/filename).read_bytes() == (b/filename).read_bytes(), f'{flow}: simulator mismatch in {filename}')
                hashes[filename] = sha(a/filename)
            require(read(a/'manifest.json')['sources_sha256'] == read(b/'manifest.json')['sources_sha256'],
                    f'{flow} simulator source sets differ')
            result['same_flow_simulators'][flow] = {'byte_identical_files_sha256': hashes,
                                                   'actual_includes_all_handshake_cycles': True}
        after = read(ARCHIVE/'after_sha256.json')
        result['after_rtl_matches_checkout'] = source_check(after)
        result['after_rtl_snapshot'] = source_check(after, {rel: ARCHIVE/'after'/rel for rel in after})
        before = read(ARCHIVE/'before_sha256.json')
        result['before_snapshot_integrity'] = source_check(before, {rel: ARCHIVE/'before'/rel for rel in before})
        result['benchmarks'] = {}
        for variant in ('before', 'after'):
            for flow in ('os', 'ws'):
                p = ARCHIVE/'benchmarks'/f'{variant}_{flow}'
                m = read(p/'manifest.json')
                require(m['status'] == 'PASS', f'{variant}_{flow} benchmark not PASS')
                substitutions = {}
                if variant == 'before':
                    # This manifest points to the shared TB's historical path;
                    # its exact original bytes were preserved before probe edits.
                    key = str((ARCHIVE/'tb_overlap_bench.sv').relative_to(ROOT))
                    substitutions[key] = ARCHIVE/'benchmarks'/'before_tb_original.sv'
                checked = source_check(m['compiled_source_sha256'], substitutions)
                for mode in ('stream', 'resident'):
                    scope = p/mode
                    require(read(scope/'summary.json')['status'] == 'PASS', f'{variant}_{flow}/{mode} not PASS')
                    require((scope/'actual.hex').read_bytes() == (scope/'expected.hex').read_bytes(),
                            f'{variant}_{flow}/{mode} bit mismatch')
                result['benchmarks'][f'{variant}_{flow}'] = {'source_check': checked,
                                                            'manifest_sha256': sha(p/'manifest.json')}
        result['probe_fix_recheck'] = {}
        for flow in ('os', 'ws'):
            for mode in ('stream', 'resident'):
                old = ARCHIVE/'pre_probe'/'benchmarks'/f'after_{flow}'/mode
                new = ARCHIVE/'benchmarks'/f'after_{flow}'/mode
                hashes = {}
                for filename in ('schedule.csv', 'timing.csv', 'summary.json', 'actual.hex', 'input.hex', 'expected.hex'):
                    require((old/filename).read_bytes() == (new/filename).read_bytes(), f'Probe fix changed {flow}/{mode}/{filename}')
                    hashes[filename] = sha(new/filename)
                result['probe_fix_recheck'][f'{flow}/{mode}'] = hashes
        old = (ARCHIVE/'pre_probe'/'after'/'rtl'/'attention_fp16.sv').read_text()
        new = (ROOT/'rtl'/'attention_fp16.sv').read_text()
        normalized = new.replace('    // Expose the WS row write on the same trace path in either configuration.\n'
                                 '    wire ws_row_load /* verilator public_flat_rd */;\n'
                                 '    wire [3:0] ws_load_row /* verilator public_flat_rd */;\n', '')
        normalized = normalized.replace('            assign ws_load_row = rows_installed[3:0];',
                                        '            wire [3:0] ws_load_row = rows_installed[3:0];')
        normalized = normalized.replace('            assign ws_row_load = (state == SM_START',
                                        '            wire ws_row_load = (state == SM_START')
        normalized = normalized.replace("            assign ws_row_load = 1'b0;\n            assign ws_load_row = 4'd0;\n", '')
        require(normalized == old, 'Probe correction changed more than signal scope/visibility')
        result['probe_fix_scope'] = 'Exact textual normalization proves only WS observer wires moved to top scope, OS constants and Verilator visibility annotations added; benchmark outputs and cycle traces were rerun and remain byte-identical.'
        result['earlier_verilator_attempts'] = {}
        for flow, pid in [('os', '14422'), ('ws', '14427')]:
            p = ROOT/'results'/f'20261118_121205_{flow}_verilator_seed20261117_{pid}'
            errors = [line for line in (p/'tb_attention_compile.log').read_text().splitlines() if line.startswith('%Error:')]
            require(read(p/'manifest.json')['status'] == 'FAIL' and any('ws_row_load' in x for x in errors),
                    f'{flow} earlier probe failure evidence differs')
            result['earlier_verilator_attempts'][flow] = {'directory': str(p.relative_to(ROOT)),
                'classification': 'Elaboration failure in hierarchical observation, no numerical run claimed', 'errors': errors}
        result['status'] = 'PASS'
    except Exception as exc:
        result['status'], result['error'] = 'FAIL', repr(exc)
    result['script_sha256'] = sha(Path(__file__))
    (ARCHIVE/'verification_audit.json').write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    print(json.dumps({'status': result['status'], 'runs': {k: (v['frames'], v['outputs']) for k, v in result['runs'].items()},
                      'error': result.get('error')}, indent=2))
    return int(result['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
