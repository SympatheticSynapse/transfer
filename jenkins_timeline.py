#!/usr/bin/env python3
"""
jenkins_timeline.py

Parses a folder of pre-downloaded Jenkins pipeline console logs and renders
a swimlane Gantt chart showing which pipeline (file) occupied which agent,
running which stage, over time. Also identifies stash/unstash events.

Usage:
    python3 jenkins_timeline.py --folder /path/to/logs --plot-out timeline.png

    # Restrict the chart to specific files if it gets crowded:
    python3 jenkins_timeline.py --folder /path/to/logs --files build1.log build2.log

Outputs (in the current directory unless overridden):
    jenkins_stage_report.csv     one row per stash/unstash event
    jenkins_stage_timeline.csv   one row per stage: file, stage, agent, start, end
    <plot-out>.png               the swimlane Gantt chart

Parsing notes:
    Jenkins pipeline logs mark ANY named block -- not just stages -- with
    "[Pipeline] { (Name)" (e.g. parallel branches, "Declarative: ..." steps).
    All blocks, named or not, are pushed onto a single stack so that a
    parallel branch or other nested block closing doesn't get mistaken for
    the enclosing stage closing. Only blocks explicitly preceded by a bare
    "[Pipeline] stage" line are treated as stages.
"""

import argparse
import csv
import glob
import os
import sys
from datetime import datetime
import re

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.dates import DateFormatter, AutoDateLocator

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

ISO_TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\]\s?(.*)$")
SIMPLE_TS_RE = re.compile(r"^(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(.*)$")

STAGE_MARKER_RE = re.compile(r"^\[Pipeline\]\s+stage\s*$")
BLOCK_OPEN_RE = re.compile(r"^\[Pipeline\]\s+\{(?:\s*\((.+)\))?\s*$")
BLOCK_CLOSE_RE = re.compile(r"^\[Pipeline\]\s+\}\s*$")
NODE_START_RE = re.compile(r"^\[Pipeline\]\s+node\s*$")
RUNNING_ON_RE = re.compile(r"^Running on\s+(\S+)\s+in\s+(.+)$")
STASH_RE = re.compile(r"^\[Pipeline\]\s+stash\s*$")
UNSTASH_RE = re.compile(r"^\[Pipeline\]\s+unstash\s*$")
STASHED_DETAIL_RE = re.compile(r"^Stashed\s+(\d+)\s+file\(s\)", re.IGNORECASE)
UNSTASHED_DETAIL_RE = re.compile(r"^Unstash(?:ed)?\s+(\d+)?\s*file\(s\)?.*", re.IGNORECASE)


def parse_timestamp(raw):
    """Try ISO and simple HH:MM:SS timestamps. Return (datetime|None, rest_of_line)."""
    m = ISO_TS_RE.match(raw)
    if m:
        ts_str, rest = m.group(1), m.group(2)
        ts_str = ts_str.rstrip("Z")
        for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
            try:
                return datetime.strptime(ts_str, fmt), rest
            except ValueError:
                continue
        return None, rest

    m = SIMPLE_TS_RE.match(raw)
    if m:
        ts_str, rest = m.group(1), m.group(2)
        for fmt in ("%H:%M:%S.%f", "%H:%M:%S"):
            try:
                return datetime.strptime(ts_str, fmt), rest
            except ValueError:
                continue
        return None, rest

    return None, raw


def fmt_ts(ts):
    if ts is None:
        return ""
    if ts.year == 1900:
        return ts.strftime("%H:%M:%S")
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def fmt_duration(start, end):
    if start is None or end is None:
        return ""
    secs = (end - start).total_seconds()
    if secs < 0:
        return ""
    return f"{secs:.1f}s"


def parse_log_file(path):
    """Parse a single Jenkins console log.
    Returns (events, stage_records):
      events: list of stash/unstash event dicts
      stage_records: list of {file, stage, agent, start_ts, end_ts, wait_start, run_start}
        wait_start/run_start describe queueing time waiting for an executor:
        if set, [wait_start, run_start] was spent waiting and [run_start, end_ts]
        was actually running on the agent. If unset, the whole [start_ts, end_ts]
        span is running time (agent was already held when the stage began).
    """
    events = []
    stage_records = []
    block_stack = []       # every open block, named or not: {type, name, start_ts, agent}
    current_agent = None
    pending_stage_marker = False
    pending_event = None   # ('stash'|'unstash', ts, lineno)
    node_request_stack = []  # {request_ts, stage_block or None} per open "[Pipeline] node"
    top_level_waits = []      # waits not tied to a specific stage (whole-pipeline agent)

    with open(path, "r", errors="replace") as f:
        for lineno, raw_line in enumerate(f, 1):
            raw_line = raw_line.rstrip("\n")
            ts, line = parse_timestamp(raw_line)

            if STAGE_MARKER_RE.match(line):
                pending_stage_marker = True
                continue

            m = BLOCK_OPEN_RE.match(line)
            if m:
                name = m.group(1)
                is_stage = pending_stage_marker and name is not None
                if is_stage:
                    # Mark the nearest enclosing stage as a "container" --
                    # Jenkins' declarative parallel-stages feature marks both
                    # the grouping stage AND each branch with [Pipeline] stage,
                    # so the container fully overlaps its children in time.
                    for block in reversed(block_stack):
                        if block["type"] == "stage":
                            block["has_child_stage"] = True
                            break
                block_stack.append({
                    "type": "stage" if is_stage else "other",
                    "name": name,
                    "start_ts": ts,
                    "agent": current_agent,
                    "has_child_stage": False,
                    "wait_start": None,
                    "run_start": None,
                })
                pending_stage_marker = False
                continue
            else:
                pending_stage_marker = False

            if BLOCK_CLOSE_RE.match(line) and block_stack:
                finished = block_stack.pop()
                if finished["type"] == "stage":
                    agent = finished["agent"] or "(unknown)"
                    stage_records.append({
                        "file": os.path.basename(path),
                        "stage": finished["name"],
                        "agent": agent,
                        "start_ts": finished["start_ts"],
                        "end_ts": ts,
                        "is_container": finished["has_child_stage"],
                        "wait_start": finished["wait_start"],
                        "run_start": finished["run_start"],
                    })
                continue

            if NODE_START_RE.match(line):
                current_agent = None
                nearest_stage = None
                for block in reversed(block_stack):
                    if block["type"] == "stage":
                        nearest_stage = block
                        break
                node_request_stack.append({"request_ts": ts, "stage_block": nearest_stage})
                continue

            m = RUNNING_ON_RE.match(line)
            if m:
                current_agent = m.group(1)
                node_req = node_request_stack.pop() if node_request_stack else None
                wait_start = node_req["request_ts"] if node_req else None
                stage_block = node_req["stage_block"] if node_req else None

                # Stamp this agent onto the nearest currently-open stage
                # *right now*, rather than relying on push-time or
                # close-time snapshots. This is correct regardless of
                # nesting order: whether the whole pipeline opens one node
                # around many stages (Running on fires before any stage is
                # pushed -- push-time capture on later stages handles that),
                # or each stage declares its own `agent {}` (node opens
                # *inside* the stage, so Running on fires while that stage
                # is already on the stack -- this live update corrects it
                # immediately instead of leaving it to be inferred later).
                for block in reversed(block_stack):
                    if block["type"] == "stage":
                        block["agent"] = current_agent
                        if stage_block is block and wait_start is not None and ts > wait_start:
                            block["wait_start"] = wait_start
                            block["run_start"] = ts
                        break
                else:
                    # No stage currently open -- this node/agent was acquired
                    # at the top level, wrapping stages that haven't started
                    # yet. Queue it; the first stage that inherits this agent
                    # without its own wait will get this as a leading gap.
                    if wait_start is not None and ts > wait_start:
                        top_level_waits.append({
                            "agent": current_agent, "wait_start": wait_start,
                            "run_start": ts, "consumed": False,
                        })
                continue

            if STASH_RE.match(line):
                pending_event = ("stash", ts, lineno)
                continue

            if UNSTASH_RE.match(line):
                pending_event = ("unstash", ts, lineno)
                continue

            if pending_event:
                kind, event_ts, event_lineno = pending_event
                detail = ""
                if kind == "stash" and STASHED_DETAIL_RE.match(line):
                    detail = line.strip()
                elif kind == "unstash" and UNSTASHED_DETAIL_RE.match(line):
                    detail = line.strip()

                # Attribute to the nearest enclosing *stage* block, not just
                # whatever block happens to be on top (could be an unnamed
                # script{}/parallel branch nested inside the stage).
                stage_name = "(no stage)"
                stage_start = None
                for block in reversed(block_stack):
                    if block["type"] == "stage":
                        stage_name = block["name"]
                        stage_start = block["start_ts"]
                        break

                events.append({
                    "file": os.path.basename(path),
                    "stage": stage_name,
                    "agent": current_agent or "(unknown)",
                    "event": kind,
                    "event_time": fmt_ts(event_ts),
                    "detail": detail,
                    "stage_start": fmt_ts(stage_start),
                    "line_no": event_lineno,
                })
                pending_event = None
                continue

    if block_stack:
        unclosed_stages = [b["name"] for b in block_stack if b["type"] == "stage"]
        if unclosed_stages:
            print(
                f"WARNING: {os.path.basename(path)}: reached end of file with "
                f"{len(block_stack)} block(s) still open, including stage(s) "
                f"{unclosed_stages!r}. This usually means a '[Pipeline] }}' closing "
                f"line wasn't recognized (unexpected log format) or the build is "
                f"still running -- these stages will be excluded from the chart "
                f"since they have no end time.",
                file=sys.stderr,
            )

    # Attach any top-level (whole-pipeline) queueing wait to the first stage
    # that inherited that agent without a wait of its own -- e.g. a single
    # `node { stage('A'){...}; stage('B'){...} }` that had to queue before
    # "Running on" fired: stage A gets the leading gap, B does not (the
    # agent was already held continuously by then).
    for wait in top_level_waits:
        if wait["consumed"]:
            continue
        candidates = [
            r for r in stage_records
            if r["agent"] == wait["agent"] and r["wait_start"] is None
            and r["start_ts"] >= wait["run_start"]
        ]
        if candidates:
            first = min(candidates, key=lambda r: r["start_ts"])
            first["wait_start"] = wait["wait_start"]
            first["run_start"] = wait["run_start"]
            wait["consumed"] = True

    return events, stage_records


def print_table(rows, columns):
    widths = [len(c) for c in columns]
    for r in rows:
        for i, c in enumerate(columns):
            widths[i] = max(widths[i], len(str(r.get(c, ""))))

    def fmt_row(values):
        return "  ".join(str(v).ljust(widths[i]) for i, v in enumerate(values))

    print(fmt_row(columns))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt_row([r.get(c, "") for c in columns]))


# ---------------------------------------------------------------------------
# Plotting
# ---------------------------------------------------------------------------

PALETTE = [
    "#2a78d6", "#eb6834", "#1baf7a", "#a561c9",
    "#e0b400", "#d64b6f", "#4bb3d6", "#8a8f98",
]


def pack_sublanes(rows_for_agent):
    """Greedy interval packing: assign each row a sub-lane index so that
    overlapping time ranges on the same agent never share a lane. Uses the
    full span including any queueing wait, so a "waiting for an agent" gap
    still reserves its lane and never visually collides with another bar."""
    def eff_start(r):
        return r["wait_start"] if r.get("wait_start") is not None else r["start_ts"]

    lane_end_times = []
    ordered = sorted(rows_for_agent, key=eff_start)
    for r in ordered:
        placed = False
        start = eff_start(r)
        for lane_idx, end_time in enumerate(lane_end_times):
            if start >= end_time:
                lane_end_times[lane_idx] = r["end_ts"]
                r["lane"] = lane_idx
                placed = True
                break
        if not placed:
            lane_end_times.append(r["end_ts"])
            r["lane"] = len(lane_end_times) - 1
    return ordered, len(lane_end_times)


def collapse_to_pipeline_view(rows):
    """Merge all stage records for the same (file, agent) into a single
    span -- one bar per pipeline run on that agent, instead of one bar per
    stage. A pipeline holds its agent for the whole run (small gaps between
    consecutive stages are just log formatting overhead, not the pipeline
    leaving and re-acquiring the agent), so this always spans
    min(start) .. max(end) rather than splitting on small gaps."""
    by_key = {}
    for r in rows:
        by_key.setdefault((r["file"], r["agent"]), []).append(r)

    merged = []
    for (file, agent), items in by_key.items():
        items_sorted = sorted(items, key=lambda r: r["start_ts"])
        first = items_sorted[0]
        merged.append({
            "file": file,
            "agent": agent,
            "stage": file,
            "start_ts": min(r["start_ts"] for r in items),
            "end_ts": max(r["end_ts"] for r in items),
            "wait_start": first.get("wait_start"),
            "run_start": first.get("run_start"),
        })
    return merged


def plot_timeline(stage_records, out_path, title="Pipeline stage occupancy by agent",
                   file_filter=None, view="stage", show_containers=False):
    rows = [r for r in stage_records if r["start_ts"] is not None and r["end_ts"] is not None]
    if file_filter:
        rows = [r for r in rows if r["file"] in file_filter]
    if not show_containers:
        # Drop wrapper/container stages (e.g. a declarative "parallel stages"
        # grouping stage) that fully overlap their own child stages on the
        # same agent -- otherwise they inflate the lane count for no reason.
        rows = [r for r in rows if not r.get("is_container")]

    if view == "pipeline":
        rows = collapse_to_pipeline_view(rows)
        title = title or "Pipeline occupancy by agent"

    if not rows:
        print("No complete stage records to plot (need both start and end times).",
              file=sys.stderr)
        return

    agents = sorted({r["agent"] for r in rows})
    files = sorted({r["file"] for r in rows})
    color_map = {f: PALETTE[i % len(PALETTE)] for i, f in enumerate(files)}

    rows_by_agent = {a: [] for a in agents}
    for r in rows:
        rows_by_agent[r["agent"]].append(dict(r))

    agent_lane_counts = {}
    for a in agents:
        packed, lane_count = pack_sublanes(rows_by_agent[a])
        rows_by_agent[a] = packed
        agent_lane_counts[a] = lane_count

    lane_height = 0.9
    gap = 0.4
    agent_y_center = {}
    agent_lane_y = {}
    cursor = 0.0
    for a in agents:
        n_lanes = agent_lane_counts[a]
        lane_ys = [cursor + i * lane_height for i in range(n_lanes)]
        agent_lane_y[a] = lane_ys
        agent_y_center[a] = sum(lane_ys) / len(lane_ys)
        cursor += n_lanes * lane_height + gap

    total_height = cursor
    span_seconds = (max(r["end_ts"] for r in rows) - min(r["start_ts"] for r in rows)).total_seconds()
    fig_width = min(30, max(12, span_seconds / 60 * 0.6))
    fig_height = max(3, total_height * 0.9 + 1.5)
    fig, ax = plt.subplots(figsize=(fig_width, fig_height))

    bar_height = lane_height * 0.8
    text_objs = []
    bar_patches = []
    for a in agents:
        for r in rows_by_agent[a]:
            y = agent_lane_y[a][r["lane"]]
            run_start = r["start_ts"]
            if r.get("wait_start") is not None and r.get("run_start") is not None:
                wait_duration = r["run_start"] - r["wait_start"]
                ax.barh(
                    y, wait_duration, left=r["wait_start"], height=bar_height,
                    facecolor=color_map[r["file"]], edgecolor=color_map[r["file"]],
                    linewidth=0.5, align="center", zorder=2, alpha=0.25,
                    hatch="////",
                )
                run_start = r["run_start"]
            duration = r["end_ts"] - run_start
            patch = ax.barh(
                y, duration, left=run_start, height=bar_height,
                color=color_map[r["file"]], edgecolor="white", linewidth=0.5,
                align="center", zorder=2,
            )[0]
            mid = run_start + duration / 2
            txt = ax.text(
                mid, y, r["stage"], ha="center", va="center",
                fontsize=8, color="white", clip_on=True, zorder=3,
            )
            bar_patches.append(patch)
            text_objs.append(txt)

    for a in agents:
        lane_ys = agent_lane_y[a]
        bottom = lane_ys[-1] + lane_height / 2
        if a != agents[-1]:
            ax.axhline(bottom + gap / 2, color="#cccccc", linewidth=0.8, zorder=1)

    ax.set_yticks([agent_y_center[a] for a in agents])
    ax.set_yticklabels(agents)
    ax.set_ylim(total_height - gap, -lane_height)
    ax.set_xlabel("Time")
    ax.set_title(title)

    ax.xaxis.set_major_locator(AutoDateLocator())
    ax.xaxis.set_major_formatter(DateFormatter("%H:%M:%S"))
    fig.autofmt_xdate()
    ax.grid(axis="x", linestyle="--", alpha=0.3)

    legend_handles = [mpatches.Patch(color=color_map[f], label=f) for f in files]
    ax.legend(
        handles=legend_handles, title="Pipeline (file)",
        loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8,
    )

    fig.tight_layout()
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    for txt, patch in zip(text_objs, bar_patches):
        bar_bbox = patch.get_window_extent(renderer=renderer)
        for fontsize in (8, 7, 6, 5):
            txt.set_fontsize(fontsize)
            txt_bbox = txt.get_window_extent(renderer=renderer)
            if txt_bbox.width <= bar_bbox.width * 0.92:
                break
        else:
            txt.set_visible(False)

    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved chart to {out_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Parse Jenkins logs and plot agent occupancy timeline.")
    parser.add_argument("--folder", required=True, help="Folder containing Jenkins log files")
    parser.add_argument("--glob", default="*", help="Filename glob pattern (default: all files)")
    parser.add_argument("--out", default="jenkins_stage_report.csv", help="Stash/unstash event CSV path")
    parser.add_argument("--out-timeline", default="jenkins_stage_timeline.csv",
                         help="Per-stage start/end/agent CSV path")
    parser.add_argument("--plot-out", default="agent_timeline.png", help="Output chart image path")
    parser.add_argument("--files", nargs="*", default=None,
                         help="Optional: only include these log filenames in the chart")
    parser.add_argument("--title", default="Pipeline stage occupancy by agent")
    parser.add_argument("--view", choices=["stage", "pipeline"], default="stage",
                         help="'stage': one bar per stage (detailed). "
                              "'pipeline': one bar per pipeline run per agent (simpler, less clutter).")
    parser.add_argument("--show-containers", action="store_true",
                         help="Include wrapper stages (e.g. declarative parallel-stages groups) "
                              "that fully overlap their own child stages. Off by default since "
                              "they just duplicate their children's time range.")
    parser.add_argument("--no-plot", action="store_true", help="Only parse and write CSVs, skip the chart")
    args = parser.parse_args()

    pattern = os.path.join(args.folder, args.glob)
    files = sorted(f for f in glob.glob(pattern) if os.path.isfile(f))
    if not files:
        print(f"No files found matching {pattern}", file=sys.stderr)
        sys.exit(1)

    all_events = []
    all_stage_records = []
    for path in files:
        events, stage_records = parse_log_file(path)
        all_events.extend(events)
        all_stage_records.extend(stage_records)

    if all_stage_records:
        with open(args.out_timeline, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=[
                "file", "stage", "agent", "start_ts", "end_ts", "is_container",
                "wait_start", "run_start", "queue_wait_seconds",
            ])
            writer.writeheader()
            for r in all_stage_records:
                queue_wait = ""
                if r.get("wait_start") is not None and r.get("run_start") is not None:
                    queue_wait = round((r["run_start"] - r["wait_start"]).total_seconds(), 1)
                writer.writerow({
                    "file": r["file"], "stage": r["stage"], "agent": r["agent"],
                    "start_ts": fmt_ts(r["start_ts"]), "end_ts": fmt_ts(r["end_ts"]),
                    "is_container": r["is_container"],
                    "wait_start": fmt_ts(r.get("wait_start")),
                    "run_start": fmt_ts(r.get("run_start")),
                    "queue_wait_seconds": queue_wait,
                })
        print(f"Wrote {len(all_stage_records)} stage timeline rows to {args.out_timeline}")

    columns = ["file", "stage", "agent", "event", "event_time", "detail", "stage_start", "line_no"]
    if all_events:
        with open(args.out, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=columns)
            writer.writeheader()
            writer.writerows(all_events)
        print_table(all_events, columns)
        print(f"Wrote {len(all_events)} event rows to {args.out}")
    else:
        print("No stash/unstash events found.")

    if not args.no_plot:
        plot_timeline(
            all_stage_records, args.plot_out, title=args.title,
            file_filter=set(args.files) if args.files else None,
            view=args.view, show_containers=args.show_containers,
        )


if __name__ == "__main__":
    main()
