"""Compare public handshakes for the continuous, ready-sink main batches."""
import csv
import hashlib
import json
from pathlib import Path
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
sys.path.insert(0, str(ROOT))
from scripts.run import verify_frames


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_batch(build, trace):
    manifest = json.loads((build / "manifest.json").read_text())
    raw_log = (trace / "simulation.log").read_text()
    assert "TB PASS" in raw_log
    cases = json.loads((build / "cases.json").read_text())
    frames, _ = verify_frames(trace / "actual.txt", raw_log, cases, False, 0)
    main = [f for f in frames if f["batch"] == "main"]
    assert len(main) == 25 and all(f["mode"] == 0 for f in main)
    keys = ("first_in_cycle", "first_out_cycle", "last_out_cycle")
    result = []
    for i, f in enumerate(main):
        row = {"frame": i, "case": f["name"]}
        for key in keys:
            row[key] = f[key]
            row[key.removesuffix("_cycle") + "_interval"] = f[key] - main[i-1][key] if i else None
        row["first_latency"] = f["first_output_latency_cycles"]
        row["last_latency"] = f["cycles"]
        result.append(row)
    return result, {
        "archived_build": str(build.relative_to(ROOT)),
        "archived_trace": str(trace.relative_to(ROOT)),
        "protocol": manifest["input_protocol"],
        "beats_per_frame": manifest["input_beats_per_frame"],
        "sim": manifest["verilator_version"],
        "seed": manifest["seed"],
        "input_sha256": sha(trace / "input.hex"),
        "expected_p_sha256": sha(trace / "expected_p.hex"),
        "expected_y_sha256": sha(trace / "expected.hex"),
        "simulation_log_sha256": sha(trace / "simulation.log"),
        "capture_sha256": sha(trace / "actual.txt"),
        "rtl_sha256": manifest["sources_sha256"]["rtl/attention_fp16.sv"],
        "tb_sha256": manifest["sources_sha256"]["tb/tb_attention.sv"],
        "first_frame_latency_inclusive": {"first_output": result[0]["first_latency"], "last_output": result[0]["last_latency"]},
        "input_start_intervals": [row["first_in_interval"] for row in result[1:]],
        "output_start_intervals": [row["first_out_interval"] for row in result[1:]],
        "output_end_intervals": [row["last_out_interval"] for row in result[1:]],
        "correctness_verified": {"frames_in_trace_including_recovery": len(frames), "outputs_checked_per_frame": 256},
    }


if __name__ == "__main__":
    dirs = [Path(s).resolve() for s in sys.argv[1:]]
    if len(dirs) != 4:
        raise SystemExit("Pass old build, old simulation, new build, new simulation.")
    summary = {"test": "25 consecutive main frames, continuously-valid source and continuously-ready sink",
               "latency": "cycles inclusive, accepted first input to accepted first/last output",
               "interval": "difference of same type of accepted handshake on consecutive frames"}
    records = []
    for version, offset in (("before", 0), ("after", 2)):
        rows, metadata = load_batch(*dirs[offset:offset+2])
        records.extend(dict(version=version, **row) for row in rows)
        summary[version] = metadata
    for key in ("seed", "input_sha256", "expected_p_sha256", "expected_y_sha256", "sim"):
        assert summary["before"][key] == summary["after"][key], key
    assert [r["case"] for r in records[:25]] == [r["case"] for r in records[25:]]
    for src, key in (("rtl/attention_fp16.sv", "rtl_sha256"), ("tb/tb_attention.sv", "tb_sha256")):
        assert sha(OUT.parent / "before" / src) == summary["before"][key]
        assert sha(ROOT / src) == summary["after"][key]
    with (OUT / "frames.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=records[0])
        writer.writeheader()
        writer.writerows(records)
    (OUT / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    for key in ("before", "after"):
        print(key, summary[key]["first_frame_latency_inclusive"], summary[key]["input_start_intervals"],
              summary[key]["output_end_intervals"])
