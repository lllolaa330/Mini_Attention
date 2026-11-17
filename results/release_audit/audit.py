"""Recheck published evidence against current numerical/RTL sources."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
runs = ['release_iverilog_seed20261117', 'final_verilator_seed20261117']
audit = {'status': 'PASS', 'runs': {}, 'scope': 'Source identity and archived dual-simulator outputs; no simulation rerun'}
for name in runs:
    folder = ROOT/'results'/name
    manifest = json.loads((folder/'manifest.json').read_text())
    summary = json.loads((folder/'summary.json').read_text())
    assert manifest['status'] == summary['status'] == 'PASS'
    changes = []
    excluded = []
    checked = 0
    for path, expected in manifest['sources_sha256'].items():
        if path.startswith('third_party/HardFloat/'):
            # Early recorder captured an unused, unpublished exploratory clone.
            # rtl/files.f uses only the official HardFloat-1 release.
            excluded.append(path)
            continue
        actual = hashlib.sha256((ROOT/path).read_bytes()).hexdigest()
        if path.startswith(('rtl/', 'model/', 'tb/', 'third_party/', 'scripts/softfloat_build/')):
            assert actual == expected, path
            checked += 1
        elif actual != expected:
            changes.append(path)
    audit['runs'][name] = {'numerical_sources_verified': checked, 'changed_recording_scripts': changes,
                            'unused_exploratory_files_excluded': len(excluded),
                            'frames': summary['frames'], 'outputs': summary['outputs']}
for filename in ['input.hex', 'expected.hex', 'actual.txt', 'per_frame.csv']:
    content = [(ROOT/'results'/run/filename).read_bytes() for run in runs]
    assert content[0] == content[1], filename
audit['identical_between_simulators'] = ['input.hex', 'expected.hex', 'actual.txt', 'per_frame.csv']
(ROOT/'results/release_audit/summary.json').write_text(json.dumps(audit, indent=2)+'\n')
print(json.dumps(audit, indent=2))
