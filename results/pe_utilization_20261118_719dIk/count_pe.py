"""Replay the pre-edge MAC mask of completed Mini_Attention frames."""
import argparse
import csv
from pathlib import Path


def clock_samples(vcd):
    names = {'clk', 'cycle', 'rst_n', 'pe_mac'}
    ids, values, scope = {}, {}, []
    with vcd.open() as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == '$scope':
                scope.append(parts[2])
            elif parts[0] == '$upscope':
                scope.pop()
            elif parts[0] == '$var' and scope == ['tb_attention'] and parts[4] in names:
                ids[parts[3]] = parts[4]
            elif parts[0] == '$enddefinitions':
                break
        if set(ids.values()) != names:
            raise ValueError('Waveform needs tb_attention clk, cycle, rst_n and pe_mac')
        previous = {}
        for line in f:
            s = line.strip()
            if s.startswith('#'):
                if values.get('clk') == '1' and previous.get('clk') == '0' and previous.get('rst_n') == '1':
                    yield int(previous['cycle'], 2), previous['pe_mac']
                previous = values.copy()
            elif s.startswith('b'):
                val, key = s[1:].split()
                if key in ids:
                    values[ids[key]] = val
            elif s[:1] in ('1','0','x','z') and s[1:] in ids:
                values[ids[s[1:]]] = s[0]

        if values.get('clk') == '1' and previous.get('clk') == '0' and previous.get('rst_n') == '1':
            yield int(previous['cycle'], 2), previous['pe_mac']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', type=Path, help='Icarus run with --waves')
    parser.add_argument('--frames', nargs='+', type=int, default=[0,40])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with (args.run_dir/'per_frame.csv').open() as f:
        frames = {int(row['run']):row for row in csv.DictReader(f)}
    samples = dict(clock_samples(args.run_dir/'attention.vcd'))
    with args.output.open('x') as f:
        w = csv.writer(f)
        w.writerow(['run','row','col','qk_fmas','pv_fmas','first_qk_T','last_qk_T',
                    'first_pv_T','last_pv_T','compute_cycles','compute_util_pct',
                    'input_to_last_output_cycles','frame_util_pct'])
        for run in args.frames:
            frame = frames[run]
            start, end = int(frame['first_qk_mac']), int(frame['last_out_cycle'])
            activity = [[] for _ in range(256)]
            for cycle in range(start, end+1):
                mask = int(samples[cycle], 2)
                while mask:
                    bit = mask & -mask
                    activity[bit.bit_length()-1].append(cycle-start+1)
                    mask ^= bit
            if any(len(a)!=32 for a in activity):
                raise ValueError(f'Expected 16 QK and 16 PV per PE in completed frame {run}')
            span = max(a[-1] for a in activity)
            total = end-int(frame['first_in_cycle'])+1
            assert min(a[0] for a in activity)==1
            for idx,a in enumerate(activity):
                w.writerow([run,idx//16,idx%16,16,16,a[0],a[15],a[16],a[-1],
                            span,round(3200/span,6),total,round(3200/total,6)])
            print(f'run {run}: 256 PEs verified, 32 MACs each, compute {span}, frame {total}')
if __name__ == '__main__':
    main()
