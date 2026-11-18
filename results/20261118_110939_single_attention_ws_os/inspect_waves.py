#!/usr/bin/env python3
"""Check the delivered single-frame VCDs and extract stage boundaries."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATES = {0: 'LOAD', 1: 'CLEAR_QK', 2: 'RUN_QK', 3: 'SM_START',
          4: 'SM_WAIT', 5: 'CLEAR_PV', 6: 'RUN_PV', 7: 'EMIT',
          8: 'LOAD_W_QK', 9: 'LOAD_W_PV'}


def inspect(mode):
    path = ROOT / mode / 'attention.vcd'
    values, scope, names = {}, [], {}
    counters = dict(inputs=0, outputs=0, done_rises=0, reset_assertions=0)
    stages = []
    now = 0

    def commit(changes):
        before = values.copy()
        values.update(changes)
        if before.get('clk') == '0' and values.get('clk') == '1' and before.get('rst_n') == '1':
            if before.get('in_valid') == before.get('in_ready') == '1':
                counters['inputs'] += 1
            if before.get('out_valid') == before.get('out_ready') == '1':
                counters['outputs'] += 1
        if before.get('done') != '1' and values.get('done') == '1':
            counters['done_rises'] += 1
        if before.get('rst_n') != '0' and values.get('rst_n') == '0':
            counters['reset_assertions'] += 1
        state = values.get('state', 'x')
        if state != before.get('state') and not set(state) & {'x', 'z'}:
            stages.append(dict(time_ns=now / 1000, state=STATES[int(state, 2)]))

    with path.open() as stream:
        header = []
        for line in stream:
            header.append(line)
            parts = line.split()
            if parts and parts[0] == '$scope':
                scope.append(parts[2])
            elif parts and parts[0] == '$upscope':
                scope.pop()
            elif parts and parts[0] == '$var':
                name = parts[4]
                if scope == ['tb_attention'] and name in ('clk', 'rst_n', 'in_valid', 'in_ready', 'out_valid', 'out_ready', 'done'):
                    names[parts[3]] = name
                elif scope == ['tb_attention', 'dut'] and name == 'state':
                    names[parts[3]] = name
            elif '$enddefinitions' in line:
                break
        assert '$timescale\n\t1ps\n$end' in ''.join(header)
        pending = {}
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                commit(pending)
                pending = {}
                now = int(line[1:])
            elif line[0] in '01xz' and line[1:] in names:
                pending[names[line[1:]]] = line[0]
            elif line[0] == 'b':
                value, code = line[1:].split()
                if code in names:
                    pending[names[code]] = value
        commit(pending)
    assert counters == dict(inputs=768, outputs=256, done_rises=1, reset_assertions=1), counters
    expected = ['LOAD', 'CLEAR_QK'] + (['LOAD_W_QK'] if mode == 'ws' else [])
    expected += ['RUN_QK', 'SM_START', 'SM_WAIT', 'CLEAR_PV']
    expected += (['LOAD_W_PV'] if mode == 'ws' else []) + ['RUN_PV', 'EMIT', 'LOAD']
    assert [stage['state'] for stage in stages] == expected, stages
    summary = json.loads((ROOT / mode / 'summary.json').read_text())
    assert summary['status'] == 'PASS' and summary['frames'] == 1 and summary['outputs'] == 256
    return dict(**counters, stages=stages, end_time_ns=now / 1000,
                size_bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                cycles=summary['per_frame'][0]['cycles'], rmse=summary['max_frame_rmse'],
                max_abs_error=summary['max_abs_error'])


if __name__ == '__main__':
    result = {mode: inspect(mode) for mode in ('ws', 'os')}
    for name in ('input.hex', 'expected.hex'):
        assert (ROOT / 'ws' / name).read_bytes() == (ROOT / 'os' / name).read_bytes()
    outputs = lambda mode: [line.split()[3] for line in (ROOT / mode / 'actual.txt').read_text().splitlines()]
    assert outputs('ws') == outputs('os')
    result['same_input_and_output_bits'] = True
    (ROOT / 'wave_inspection.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
