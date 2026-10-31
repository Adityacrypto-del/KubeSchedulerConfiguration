#!/usr/bin/env python3
"""Summarise benchmark runs for KubeSchedulerConfiguration.

Reads benchmarks/results/<config>/run-*/metrics.csv and writes:

  results/summary.csv    config, metric, median, min, max, runs
  results/summary.json   the same, nested by config
  docs/benchmark-gpus.svg  where the 8,000 GPUs ended up, per config
  docs/benchmark-jobs.svg  multi-Pod job outcomes, per config

It also prints a Markdown results table. Charts show the run with the median
GPU utilisation of each config, so that each bar adds up to the real total.

Usage: summarize.py
"""

import csv
import glob
import json
import os
import statistics

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(BENCH_DIR)
RESULTS = os.path.join(BENCH_DIR, "results")
CONFIGS = ["stock", "binpack", "binpack-gang", "binpack-gang-topology"]
METRICS = [
    ("throughput_pods_per_s", "Throughput (Pods/s)", "{:.0f}"),
    ("latency_p50_s", "Latency p50 (s)", "{:.2f}"),
    ("latency_p95_s", "Latency p95 (s)", "{:.2f}"),
    ("latency_p99_s", "Latency p99 (s)", "{:.2f}"),
    ("pods_bound", "Pods bound (of 3,724)", "{:.0f}"),
    ("gpu_utilisation", "GPU utilisation", "{:.1%}"),
    ("stranded_gpus", "Stranded GPUs", "{:.0f}"),
    ("multi_pod_fully_placed", "Multi-Pod jobs fully placed (of 625)", "{:.0f}"),
    ("multi_pod_partially_placed", "Multi-Pod jobs partially placed", "{:.0f}"),
    ("multi_pod_not_placed", "Multi-Pod jobs not placed", "{:.0f}"),
    ("gpus_held_by_partial_jobs", "GPUs held by partially placed jobs", "{:.0f}"),
    ("large_jobs_fully_placed", "Large jobs fully placed (of 60)", "{:.0f}"),
    ("multi_pod_one_rack_fraction", "Fully placed multi-Pod jobs within one rack", "{:.1%}"),
]

# Reference palette, categorical slots 1-4 in order (validated for adjacent
# pairs). Same meaning in both charts: blue = placed and useful, orange = held
# by a partially placed job, aqua = stranded, yellow = free whole nodes / not placed.
BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
SURFACE, TEXT, TEXT2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def parse(value):
    """Turn a metrics.csv cell back into the number, bool or None run.py wrote."""
    if value == "":
        return None
    if value in ("True", "False"):
        return value == "True"
    for kind in (int, float):
        try:
            return kind(value)
        except ValueError:
            pass
    return value


def load():
    runs = {}
    for config in CONFIGS:
        files = sorted(glob.glob(os.path.join(RESULTS, config, "run-*", "metrics.csv")))
        if files:
            runs[config] = [{k: parse(v) for k, v in next(csv.DictReader(open(f))).items()} for f in files]
    return runs


def fmt(spec, v):
    return "n/a" if v is None else spec.format(v)


def summarise(runs):
    summary = {}
    for config, ms in runs.items():
        summary[config] = {}
        for key, _, _ in METRICS:
            vals = [m[key] for m in ms if m.get(key) is not None]
            summary[config][key] = {
                "median": statistics.median(vals) if vals else None,
                "min": min(vals) if vals else None,
                "max": max(vals) if vals else None,
                "runs": len(vals),
            }
    with open(os.path.join(RESULTS, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    with open(os.path.join(RESULTS, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["config", "metric", "median", "min", "max", "runs"])
        for config, ms in summary.items():
            for key, s in ms.items():
                w.writerow([config, key, s["median"], s["min"], s["max"], s["runs"]])
    return summary


def table(summary):
    configs = list(summary)
    lines = ["| Metric | " + " | ".join(f"`{c}`" for c in configs) + " |",
             "| --- |" + " --- |" * len(configs)]
    for key, label, spec in METRICS:
        cells = []
        for c in configs:
            s = summary[c][key]
            if s["median"] is None:
                cells.append("n/a")
            elif s["min"] == s["max"]:
                cells.append(fmt(spec, s["median"]))
            else:
                cells.append(f"{fmt(spec, s['median'])} ({fmt(spec, s['min'])}–{fmt(spec, s['max'])})")
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def median_run(ms):
    ordered = sorted(ms, key=lambda m: m["gpus_bound"])
    return ordered[(len(ordered) - 1) // 2]


def stacked_chart(path, title, configs, segments, total, xlabel):
    """Horizontal stacked bars: segments is [(label, color, [value per config])]."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyBboxPatch

    plt.rcParams.update({"font.family": "sans-serif", "font.size": 10, "svg.fonttype": "none"})
    fig, ax = plt.subplots(figsize=(8.5, 0.75 * len(configs) + 1.9), facecolor=SURFACE)
    ax.set_facecolor(SURFACE)
    bar_h = 0.5
    gap = total * 0.002  # 2px-style surface gap between stacked segments
    for row, config in enumerate(configs):
        y = len(configs) - 1 - row
        left = 0
        for label, color, values in segments:
            v = values[row]
            if v <= 0:
                continue
            ax.add_patch(FancyBboxPatch((left + gap / 2, y - bar_h / 2), max(v - gap, 0), bar_h,
                                        boxstyle="round,pad=0,rounding_size=0.06", mutation_aspect=total / 40,
                                        linewidth=0, facecolor=color))
            if v / total >= 0.06:
                ax.text(left + v / 2, y, f"{v:,}", ha="center", va="center", fontsize=9,
                        color="white" if color in (BLUE,) else TEXT)
            left += v
    ax.set_xlim(0, total)
    ax.set_ylim(-0.6, len(configs) - 0.4)
    ax.set_yticks(range(len(configs)))
    ax.set_yticklabels(reversed(configs), color=TEXT)
    ax.set_xlabel(xlabel, color=TEXT2)
    ax.tick_params(colors=TEXT2, length=0)
    ax.xaxis.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_title(title, loc="left", color=TEXT, fontsize=12, pad=26)
    handles = [plt.Rectangle((0, 0), 1, 1, facecolor=c, linewidth=0) for _, c, _ in segments]
    ax.legend(handles, [l for l, _, _ in segments], loc="lower left", bbox_to_anchor=(0, 1.0),
              ncol=len(segments), frameon=False, fontsize=9, labelcolor=TEXT2, handlelength=1, borderaxespad=0.2)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)


def charts(runs):
    configs = [c for c in CONFIGS if c in runs]
    med = {c: median_run(runs[c]) for c in configs}
    full_job_gpus = [med[c]["gpus_bound"] - med[c]["gpus_held_by_partial_jobs"] for c in configs]
    stacked_chart(
        os.path.join(REPO_ROOT, "docs", "benchmark-gpus.svg"),
        "Where the 8,000 GPUs ended up (median run of 3)", configs,
        [("Bound to fully placed jobs", BLUE, full_job_gpus),
         ("Held by partially placed jobs", ORANGE, [med[c]["gpus_held_by_partial_jobs"] for c in configs]),
         ("Stranded (free on part-used nodes)", AQUA, [med[c]["stranded_gpus"] for c in configs]),
         ("Free on whole free nodes", YELLOW, [med[c]["nodes_fully_free"] * 8 for c in configs])],
        med[configs[0]]["gpu_capacity"], "GPUs")
    stacked_chart(
        os.path.join(REPO_ROOT, "docs", "benchmark-jobs.svg"),
        "Multi-Pod jobs: all Pods placed, some, or none (median run of 3)", configs,
        [("Fully placed", BLUE, [med[c]["multi_pod_fully_placed"] for c in configs]),
         ("Partially placed", ORANGE, [med[c]["multi_pod_partially_placed"] for c in configs]),
         ("Not placed", YELLOW, [med[c]["multi_pod_not_placed"] for c in configs])],
        med[configs[0]]["multi_pod_jobs"], "Multi-Pod jobs (medium and large)")


def main():
    runs = load()
    if not runs:
        raise SystemExit("no results found")
    summary = summarise(runs)
    charts(runs)
    print(table(summary))


if __name__ == "__main__":
    main()
