"""Assemble the four-design result after checking its independent runs and source identities."""
import hashlib
import json
from pathlib import Path

out = Path(__file__).resolve().parent
root = out.parents[1]
evidence = root / 'results'
four = evidence / 'os_scope_report_20261118_a'
icarus = evidence / 'os_scope_verified_wave_20261118'
verilator = evidence / 'os_scope_verilator_20261118'
extended = evidence / 'os_scope_extended_20261118'
mesh = evidence / 'os_scope_mesh_20261118_DUOqs5wN' / 'verified'
sparse = evidence / 'os_scope_sparse_protocol_20261118' / 'final'
lint = evidence / 'os_scope_rtl_lint_20261118'
negative = evidence / 'os_scope_checker_negative_298jddkr'
reset = evidence / 'os_scope_full_reset_20261118_39bfsBzN' / 'verified'


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(name, data):
    (out/name).write_text(json.dumps(data, indent=2, ensure_ascii=False)+'\n')


def matched(runs, files):
    digests = {}
    for file in files:
        h = [sha(run / file) for run in runs]
        assert len(set(h)) == 1, file
        digests[file] = h[0]
    return digests


def main():
    for run in (four, icarus, verilator, extended, mesh, sparse, lint, negative, reset):
        assert read(run/'manifest.json')['status'] == 'PASS', run
    assert read(four/'manifest.json')['period_ns'] == 10
    metrics = read(four/'summary.json')
    assert set(metrics) == {'baseline','stream','scope','os-scope'}
    sources = {}
    for run in (icarus, verilator):
        m = read(run/'os-scope/manifest.json')
        assert m['status'] == 'PASS'
        for rel, digest in m['source_sha256'].items():
            assert sha(root/rel) == digest, rel
        assert m['runner_sha256'] == sha(root/'scripts/run_scope.py')
        assert m['bench_sha256'] == sha(root/'tb/tb_scope_compare.sv')
        sources[run.name] = m['source_sha256']
    assert sources[icarus.name] == sources[verilator.name]
    inputs = matched([four, icarus, verilator], ['input.hex','cases.json'])
    # In the four-way run OS-SCOPE was built before a width-only index cleanup.
    # Numerical outputs, complete timing and activity must also match frozen RTL.
    files = ['actual.txt','expected.hex','expected_p.hex','frames.csv','mesh_checks.json','metrics.json']
    result = matched([r/'os-scope' for r in (four, icarus, verilator)], files)
    # The WS and OS SCOPE dataflows share a numerical contract.
    other_flow = matched([four/'scope', icarus/'os-scope'], ['actual.txt','expected.hex','expected_p.hex'])
    intermediates = read(icarus/'os-scope/wave_intermediates.json')
    assert intermediates['status']=='PASS' and intermediates['vcd_sha256']==sha(icarus/'os-scope/attention.vcd')
    m = read(icarus/'summary.json')['os-scope']
    assert m['status']=='PASS' and m['steady_ii_samples'] == [52]*6
    m['throughput_speedup_vs_baseline'] = metrics['baseline']['steady_ii_cycles']/m['steady_ii_cycles']
    assert metrics['os-scope'] == m
    metrics['os-scope'] = m
    assert all(row['frames'] == 35 and row['status']=='PASS' for row in metrics.values())
    write('summary.json', {d:metrics[d] for d in ('baseline','stream','scope','os-scope')})
    write('verification.json', dict(status='PASS', period_ns=10, common_inputs=inputs,
          dual_simulator_payloads_and_timing=result, ws_vs_os_scope_payloads=other_flow, wave_intermediates=intermediates,
          four_design_run=str(four.relative_to(root)), frozen_os_icarus=str(icarus.relative_to(root)),
          frozen_os_verilator=str(verilator.relative_to(root)), mesh=read(mesh/'manifest.json')['physical_elaborated'],
          extended=read(extended/'summary.json')['os-scope'], long_input_and_backpressure=str(sparse.relative_to(root)),
          in_flight_reset=read(reset/'manifest.json')['coverage'],
          strict_lint=str(lint.relative_to(root)), scoreboard_fault_injection=str(negative.relative_to(root)),
          audit_command='python3 results/os_scope_verified_20261118/verify.py'))
    print('Four designs, frozen sources, per-frame timing, P/Y and numerical checks: PASS.')


if __name__ == '__main__':
    main()
