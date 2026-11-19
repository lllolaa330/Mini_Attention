"""Check proposed no-stall OS/SCNA schedules on the 16x16 physical mesh.

An event at edge t writes a register just after t. Its consumer can read
on edge t+1. This is a resource/dependency model, not an RTL simulator.
GEMM A/B and SCNA x/affine/sum have independent registered links.
The 16-way row assembly feeds the newest E directly from the Right output
at its next edge; earlier lanes are retained in the row buffer.
"""
from collections import Counter
from dataclasses import dataclass


N = 16


@dataclass(frozen=True)
class Schedule:
    name: str
    ii: int
    pv: int
    skew: bool

    def exp_start(self, lane):
        strip, pair = divmod(lane, 8)
        return 32 + 8 * strip + 2 * pair if self.skew else 38


def check(plan, frames=8):
    mac = {}
    os_ports = {}
    occupancies = Counter()
    first_p_write = None

    def reserve(table, key, event):
        if key in table:
            raise AssertionError(f'{key}: {table[key]} conflicts with {event}')
        table[key] = event

    for frame in range(frames):
        base = frame * plan.ii
        for i in range(N):
            for j in range(N):
                for k in range(N):
                    for op, start in [('QK', 0), ('PV', plan.pv)]:
                        edge = base + start + i + j + k
                        reserve(mac, (i, j, edge), (op, frame, k))
                        occupancies[op] += 1
                        if j == 0:
                            reserve(os_ports, ('west', i, edge), (op, frame, k))
                        if i == 0:
                            reserve(os_ports, ('north', j, edge), (op, frame, k))

        for row in range(N):
            # Final QK MAC is at i+30. Capture the scaled last score and max
            # on i+31; the subtractor may feed an exp stack from i+32.
            max_write = base + row + 31
            exp_outputs = []
            for lane in range(N):
                strip, pair = divmod(lane, 8)
                x = base + row + plan.exp_start(lane)
                assert x > max_write
                for stage in range(8):
                    physical_row = strip * 8 + stage
                    left = x + stage
                    right = left + 1
                    # Left consumes previous Left's x delay. Right consumes
                    # this Left's affine and previous Right's running sum.
                    reserve(mac, (physical_row, 2*pair, left), ('Left', frame, row))
                    reserve(mac, (physical_row, 2*pair+1, right), ('Right', frame, row))
                    occupancies['Left'] += 1
                    occupancies['Right'] += 1
                exp_outputs.append(right)
            # Four registered sum levels, two divide stages, one P write.
            p_write = max(exp_outputs) + 4 + 2 + 1
            if first_p_write is None:
                first_p_write = p_write
            assert base + plan.pv + row > p_write
    assert occupancies == {'QK': 4096*frames, 'PV': 4096*frames,
                           'Left': 2048*frames, 'Right': 2048*frames}
    first_exp = [plan.exp_start(lane) for lane in range(N)]
    print(f'{plan.name}: {frames} frames, {len(mac)} conflict-free physical FMA uses; '
          f'row 0 Exp input {min(first_exp)}..{max(first_exp)}, '
          f'P write {first_p_write}, first PV MAC {plan.pv}, QK II {plan.ii}')


if __name__ == '__main__':
    check(Schedule('lockstep lanes', ii=70, pv=54, skew=False))
    check(Schedule('skewed lanes', ii=54, pv=70, skew=True))
    check(Schedule('skewed lanes, delayed PV', ii=52, pv=120, skew=True))
