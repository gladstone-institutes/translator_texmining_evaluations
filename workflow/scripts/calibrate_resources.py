"""Suggest config `resources:` values from Snakemake benchmark TSVs.

    uv run python workflow/scripts/calibrate_resources.py --output_dir results

Grouped by TSV basename, which is the rule name under this template's
convention. Two caveats on the numbers: `max_rss` sums the process tree, so a
forking rule reports well above its true peak; and a job the scheduler killed
writes a censored benchmark or none at all, so an observed max sitting near its
configured request probably hit the cap. Runtime is the observed maximum, not a
fit -- for rules that scale with a per-sample quantity, model it with
`_runtime_min_scaled` instead (see AGENTS.md).
"""

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path


def _num(value):
    """Benchmark fields Snakemake could not sample are the literal string "NA"."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _read_benchmark(path):
    """Return (wall_minutes, max_rss_gb) from one benchmark TSV, worst row."""
    with open(path, newline="") as f:
        rows = [r for r in csv.DictReader(f, delimiter="\t") if _num(r.get("s")) > 0]
    if not rows:
        return None
    wall_s = max(_num(r.get("s")) for r in rows)
    rss_mb = max(_num(r.get("max_rss")) for r in rows)
    return wall_s / 60.0, rss_mb / 1024.0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--output_dir", required=True,
                    help="pipeline output_dir (the parent of benchmarks/)")
    ap.add_argument("--margin", type=float, default=1.3,
                    help="headroom multiplier applied to the observed max (default 1.3)")
    args = ap.parse_args()

    root = Path(args.output_dir) / "benchmarks"
    if not root.is_dir():
        raise SystemExit(f"no benchmarks directory at {root}")

    per_rule = defaultdict(list)
    for tsv in sorted(root.rglob("*.tsv")):
        parsed = _read_benchmark(tsv)
        if parsed:
            per_rule[tsv.stem].append(parsed)

    if not per_rule:
        raise SystemExit(f"no usable benchmark rows under {root}")

    print(f"# Observed over {sum(len(v) for v in per_rule.values())} benchmark file(s) "
          f"under {root}")
    print(f"# margin = {args.margin}x. Review before pasting; read the caveats in "
          f"{Path(__file__).name}.")
    print("resources:")
    for rule_name in sorted(per_rule):
        runs = per_rule[rule_name]
        max_min = max(r[0] for r in runs)
        max_gb = max(r[1] for r in runs)
        # Round up so the suggestion is never below what was measured.
        runtime_min = max(1, math.ceil(max_min * args.margin))
        mem_gb = max(1, math.ceil(max_gb * args.margin))
        print(f"  {rule_name}:")
        print(f"    threads: <unchanged>      # benchmarks cannot infer this")
        print(f"    mem_gb: {mem_gb}"
              f"            # observed max {max_gb:.1f} GB over {len(runs)} run(s)")
        print(f"    runtime_min: {runtime_min}"
              f"       # observed max {max_min:.1f} min")


if __name__ == "__main__":
    main()
