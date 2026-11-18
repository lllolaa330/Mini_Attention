#!/usr/bin/env python3
"""Extract first-frame pre-edge control states and I/O handshakes from Icarus VCD."""
import hashlib
import json
from itertools import groupby
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RUNS = {
    "os": "20261118_113652_os_iverilog_seed20261117_65508",
    "ws": "20261118_113652_ws_iverilog_seed20261117_65509",
}
TOP = ("LOAD", "CLEAR_QK", "RUN_QK", "SM_START", "SM_WAIT", "CLEAR_PV",
       "RUN_PV", "DRAIN", "LOAD_W_QK", "LOAD_W_PV", "WAIT_V")
SM = ("IDLE", "SCALE", "EXP", "SUM", "DIV_START", "DIV_WAIT", "FINISH")
TB = "tb_attention."
SIGNALS = {name: TB + name for name in (
    "clk", "cycle", "rst_n", "in_valid", "in_ready", "tx_slot", "tx_word",
    "out_valid", "out_ready", "out_lane_valid", "out_last")}
SIGNALS.update(top_state=TB+"dut.state", sm_state=TB+"dut.parallel_softmax[0].sm.state")


def rising_edges(path):
    """Apply a timestamp's complete change set *after* sampling its rising edge."""
    with path.open() as stream:
        scope, names = [], {}
        for line in stream:
            fields = line.split()
            if not fields:
                continue
            if fields[0] == "$scope":
                scope.append(fields[2])
            elif fields[0] == "$upscope":
                scope.pop()
            elif fields[0] == "$var":
                names[".".join(scope + [fields[4]])] = fields[3]
            elif fields[0] == "$enddefinitions":
                break
        codes = {key: names[fullname] for key, fullname in SIGNALS.items()}
        clock = codes["clk"]
        values = dict.fromkeys(codes.values())
        changes = {}
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                if values[clock] == 0 and changes.get(clock) == 1:
                    yield {key: values[code] for key, code in codes.items()}
                values.update(changes)
                changes.clear()
            elif line[0] in "01xXzZ":
                code = line[1:]
                if code in values:
                    changes[code] = int(line[0]) if line[0] in "01" else None
            elif line[0] in "bB":
                bits, code = line[1:].split()
                if code in values:
                    changes[code] = int(bits, 2) if set(bits) <= {"0", "1"} else None
        if values[clock] == 0 and changes.get(clock) == 1:
            yield {key: values[code] for key, code in codes.items()}


def span(start, end):
    return {"start": start, "end": end, "cycles": end-start+1}


def state_spans(frame, key, names):
    intervals = []
    for state, consecutive in groupby(frame, key=lambda s: s[key]):
        periods = list(consecutive)
        intervals.append({"name": names[state], **span(periods[0]["relative"], periods[-1]["relative"])})
    return intervals


def extract(directory):
    summary_file = directory / "summary.json"
    vcd_file = directory / "attention.vcd"
    summary = json.loads(summary_file.read_text())
    frame0, frame1 = summary["per_frame"][:2]
    if summary["status"] != "PASS" or [x["mode"] for x in (frame0, frame1)] != [0, 0]:
        raise ValueError("Expected two passing main frames driven without stalls")

    samples, inputs, outputs = [], [], []
    first_in = None
    for sample in rising_edges(vcd_file):
        in_handshake = sample["in_valid"] == 1 and sample["in_ready"] == 1
        if first_in is None:
            if not in_handshake or sample["rst_n"] != 1:
                continue
            first_in = sample["cycle"]
        rel = sample["cycle"]-first_in+1
        sample["relative"] = rel
        if sample["rst_n"] != 1 or rel != len(samples)+1:
            raise ValueError("Unexpected reset or clock gap in selected interval")
        samples.append(sample)
        if not in_handshake:
            raise ValueError(f"Missing continuous input transfer at cycle {rel}")
        slot, index = divmod(len(inputs), 768)
        if (sample["tx_slot"], sample["tx_word"]) != (slot, index):
            raise ValueError(f"Unexpected input frame/index at cycle {rel}")
        inputs.append(rel)
        if sample["out_valid"]:
            if sample["out_ready"] != 1:
                raise ValueError(f"Output backpressure at cycle {rel}")
            diagonal = len(outputs)
            if diagonal >= 31:
                raise ValueError("Second frame emitted before the end of its Q load")
            mask = sum(1 << j for j in range(16) if 0 <= diagonal-j < 16)
            if sample["out_lane_valid"] != mask or sample["out_last"] != int(diagonal == 30):
                raise ValueError(f"Unexpected output mask/last at cycle {rel}")
            outputs.append(rel)
        if len(inputs) == 1024:
            break
    if len(inputs) != 1024 or len(outputs) != 31 or outputs[-1]-outputs[0]+1 != 31:
        raise ValueError("Incomplete contiguous input/output window")
    last = outputs[-1]
    expected = (frame0["first_in_cycle"], frame0["first_out_cycle"], frame0["last_out_cycle"],
                frame0["first_output_latency_cycles"], frame0["cycles"], frame0["output_beats"],
                frame1["first_in_cycle"], frame1["input_ii_cycles"])
    measured = (first_in, first_in+outputs[0]-1, first_in+last-1,
                outputs[0], last, len(outputs), first_in+inputs[768]-1, inputs[768]-inputs[0])
    if measured != expected:
        raise ValueError(f"VCD {measured} does not match summary {expected}")

    frame = samples[:last]
    stages = state_spans(frame, "top_state", TOP)
    sub = [item for item in state_spans(frame, "sm_state", SM) if item["name"] != "IDLE"]
    segments = {key: span(inputs[offset], inputs[offset+255])
                for key, offset in (("Q",0), ("K",256), ("V",512), ("Q_next",768))}
    return {
        "run": str(directory.relative_to(ROOT)), "seed": summary["seed"],
        "case": frame0["name"], "next_case": frame1["name"],
        "summary_sha256": hashlib.sha256(summary_file.read_bytes()).hexdigest(),
        "vcd_sha256": hashlib.sha256(vcd_file.read_bytes()).hexdigest(),
        "tb_first_in_cycle": first_in, "input": segments, "top_states": stages, "softmax_row0": sub,
        "output": {"first": outputs[0], "last": last, "beats": len(outputs),
                   "words": sum(bin(s["out_lane_valid"]).count("1") for s in frame if s["out_valid"])},
        "input_ii": inputs[768]-inputs[0],
    }


def main():
    timeline = {
        "cycle_convention": "Cycle 1 is the first accepted word of frame 0. All ranges include both endpoints. "
                            "Control and handshake signals are sampled immediately before the rising edge. "
                            "State intervals stop at the final output of frame 0. Q_next covers the entire next Q.",
        "flows": {flow: extract(ROOT/"results"/name) for flow, name in RUNS.items()},
    }
    path = HERE / "timeline.json"
    path.write_text(json.dumps(timeline, ensure_ascii=False, indent=2) + "\n")
    print(path)


if __name__ == "__main__":
    main()
