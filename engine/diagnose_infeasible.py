"""Find which constraint group makes a captured model infeasible.

    python engine/diagnose_infeasible.py <model.json> [budget_seconds]

Relaxes one group at a time by mutating the INPUT model, so the production solver is
exercised exactly as it ships. The first relaxation that turns INFEASIBLE into a plan is
the constraint that is over-tight.
"""

from __future__ import annotations

import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from solver import solve  # noqa: E402


def run(label: str, model: dict, budget: float) -> None:
    r = solve(model, budget)
    n = len(r["assignments"])
    print(f"  {label:<42} {r['status']:<12} {n:>4} assignments  {r['solve_seconds']:>6}s")


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TEMP", "."), "model.json")
    budget = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    with open(path, encoding="utf8") as fh:
        base = json.load(fh)

    print(f"people {len(base['people'])}, items {len(base['items'])}, "
          f"days {len(base['days'])}, committed {len(base['committed'])}\n")

    run("as captured", base, budget)

    m = copy.deepcopy(base); m["committed"] = []
    run("no committed plan (no locks, no warm start)", m, budget)

    m = copy.deepcopy(base)
    for c in m["committed"]:
        c["locked"] = False
    m["windows"] = dict(m["windows"], freeze_end=m["windows"]["today"])
    run("freeze horizon collapsed to today", m, budget)

    m = copy.deepcopy(base)
    for i in m["items"]:
        i["deps"] = []
    run("no dependencies", m, budget)

    m = copy.deepcopy(base)
    for p in m["people"]:
        p["max_concurrent"] = 99
    m["policy"] = dict(m["policy"], max_concurrent_items=99)
    run("no concurrency limit", m, budget)

    m = copy.deepcopy(base)
    for p in m["people"]:
        p["min_focus_days"] = 1
    m["policy"] = dict(m["policy"], min_focus_days=1)
    run("no minimum focus block", m, budget)

    m = copy.deepcopy(base)
    for i in m["items"]:
        i["earliest_start"] = None
        i["needed_by"] = None
    run("no earliest-start or needed-by", m, budget)

    m = copy.deepcopy(base)
    for p in m["people"]:
        p["capacity"] = [[a * 4, r] for a, r in p["capacity"]]
    run("capacity quadrupled", m, budget)

    # Smallest slice that still reproduces it: one item at a time against the real people.
    print("\n  per-item feasibility (committed plan kept):")
    bad = []
    for item in base["items"]:
        m = copy.deepcopy(base)
        m["items"] = [item]
        keep = {item["id"]}
        m["committed"] = [c for c in m["committed"] if c["work_item_id"] in keep]
        r = solve(m, 5)
        if not r["assignments"]:
            bad.append((item["ref"], r["status"], item.get("remaining_days"), len(item.get("skills") or [])))
    if bad:
        for ref, st, days, nsk in bad[:15]:
            print(f"    {ref:<12} {st:<12} remaining {days} days, {nsk} skills")
        print(f"    ({len(bad)} of {len(base['items'])} items cannot be placed even alone)")
    else:
        print("    every item is placeable on its own")
    return 0


if __name__ == "__main__":
    sys.exit(main())
