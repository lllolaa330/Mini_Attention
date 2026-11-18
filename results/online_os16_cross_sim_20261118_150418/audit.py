"""Recheck final OS runs on the checkout used by the experiment."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--icarus', type=Path, required=True)
parser.add_argument('--verilator', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

runs = {}
for name, path in (('iverilog', args.icarus), ('verilator', args.verilator)):
    manifest = json.loads((path/'manifest.json').read_text())
    assert manifest['status'] == 'PASS' and manifest['simulator'] == name
    sources = manifest['sources_sha256']
    for filename, sha in sources.items():
        assert digest(root/filename) == sha, filename
    runs[name] = {'directory': str(path.resolve().relative_to(root)),
                  'manifest_sha256': digest(path/'manifest.json'),
                  'sources_verified': len(sources)}
verified = {}
for name in ('input.hex', 'expected.hex', 'expected_p.hex', 'actual.txt',
             'cases.json', 'per_frame.csv', 'summary.json'):
    a, b = args.icarus/name, args.verilator/name
    assert a.read_bytes() == b.read_bytes(), name
    verified[name] = digest(a)
summary = json.loads((args.icarus/'summary.json').read_text())
assert summary['status'] == 'PASS' and summary['normalized_fp16_words_checked'] == summary['outputs']
resident, = [frame for frame in summary['per_frame'] if frame['resident_at_dispatch']]
first = resident['first_qk_mac']
fields = ('first_qk_mac','last_qk_mac','normalization_first_issue','normalization_last_issue',
          'normalization_first_return','normalization_last_return','first_pv_mac','first_out_cycle','last_out_cycle')
relative = {phase: resident[phase] - first + 1 for phase in fields}
report = {'status':'PASS', 'verified_utc':datetime.now(timezone.utc).isoformat(),
          'runs':runs, 'identical_files_sha256':verified, 'frames_per_simulator':summary['frames'],
          'normalized_P_bits_checked_as_fp16_words':summary['normalized_fp16_words_checked'],
          'Y_words':summary['outputs'], 'max_frame_rmse':summary['max_frame_rmse'],
          'max_abs_error':summary['max_abs_error'], 'public_input_resident_run':resident['run'],
          'resident_cycle_origin':'first valid QK MAC is cycle 1', 'resident_cycles':relative,
          'resident_simultaneous_qk_pv_mac_cycles':resident['qk_pv_overlap_cycles']}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('runs','identical_files_sha256')},indent=2))
