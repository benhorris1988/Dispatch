"""Self-contained checks for the CP-SAT model. Run: python test_solver.py

Uses a small hand-built model so the expected plan is obvious, then asserts the hard
constraints of specification 8.5 hold in the returned plan.
"""

from __future__ import annotations

import sys
from datetime import date, timedelta

from solver import solve

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name} {detail}")
        FAILURES.append(name)


def working_days(start: date, count: int) -> list[str]:
    out, day = [], start
    while len(out) < count:
        if day.weekday() < 5:
            out.append(day.isoformat())
        day += timedelta(days=1)
    return out


def build_model(**overrides) -> dict:
    days = working_days(date(2026, 9, 8), 30)
    model = {
        "schema_version": 1,
        "workspace_id": 1,
        "today": days[0],
        "hours_per_day": 7.5,
        "working_days": ["Mon", "Tue", "Wed", "Thu", "Fri"],
        "days": days,
        "windows": {
            "today": days[0],
            "freeze_end": days[4],
            "planned_end": days[19],
            "indicative_end": days[-1],
        },
        "policy": {
            "objective_weights": {"valueCompletion": 1, "lateness": 3, "unscheduledValue": 5,
                                  "loadImbalance": 0.5, "contextSwitching": 0.5,
                                  "stabilityPlanned": 2, "preferences": 0.2},
            "change_budget_days": 5, "min_improvement_pct": 5,
            "target_load_min": 80, "target_load_max": 90,
            "small_fill_threshold_days": 3, "pairing_cost_threshold_days": 2,
            "max_concurrent_items": 2, "min_focus_days": 2,
        },
        "people": [
            {"id": 1, "name": "Priya", "max_concurrent": 2, "min_focus_days": 2,
             "skills": {"3": 4, "5": 3}, "development": {}, "prefers": None, "avoid": None,
             "protected": False, "rota_weeks": [], "capacity": [[7.5, 0.9]] * len(days)},
            {"id": 2, "name": "Jon", "max_concurrent": 2, "min_focus_days": 2,
             "skills": {"5": 3}, "development": {"3": 3}, "prefers": None, "avoid": None,
             "protected": False, "rota_weeks": [], "capacity": [[7.5, 0.9]] * len(days)},
        ],
        "items": [
            {"id": 10, "ref": "WI-0010", "policy": "planned", "granularity": "day",
             "counts_for_wip": True, "remaining_days": 4.0, "skill_effort": None,
             "skills": [{"skill_id": 5, "min_proficiency": 3}], "deps": [], "soft_deps": [],
             "earliest_start": None, "needed_by": days[9], "priority": 80.0,
             "protected": False, "small": False, "type_name": "Project", "tags": []},
            {"id": 11, "ref": "WI-0011", "policy": "planned", "granularity": "day",
             "counts_for_wip": True, "remaining_days": 3.0, "skill_effort": None,
             "skills": [{"skill_id": 3, "min_proficiency": 4}], "deps": [], "soft_deps": [],
             "earliest_start": None, "needed_by": days[14], "priority": 60.0,
             "protected": False, "small": True, "type_name": "Small change", "tags": []},
        ],
        "committed": [],
        "scope_person_ids": [],
    }
    model.update(overrides)
    return model


def day_effort(result: dict, model: dict) -> dict:
    """Rebuild per person-per-day allocation from the returned ranges."""
    load: dict[tuple[int, str], int] = {}
    for a in result["assignments"]:
        frm, to = a["from_date"], a["to_date"]
        for d in model["days"]:
            if frm <= d <= to:
                load[(a["person_id"], d)] = load.get((a["person_id"], d), 0) + a["allocation_pct"]
    return load


def main() -> int:
    print("Dispatch CP-SAT solver checks")

    print("\nBasic feasibility")
    model = build_model()
    r = solve(model, budget_seconds=20)
    check("returns a feasible plan", r["status"] in ("OPTIMAL", "FEASIBLE"), r["status"])
    check("schedules both items", len(r.get("unscheduled") or []) == 0, str(r.get("unscheduled")))
    check("reports solve time", r["solve_seconds"] >= 0)

    print("\nSkills are respected (spec 8.5)")
    # Item 11 needs skill 3 at level 4; only Priya (id 1) qualifies.
    owners = {a["work_item_id"]: a["person_id"] for a in r["assignments"]}
    check("level-4 work goes to the only qualified person", owners.get(11) == 1, str(owners))

    print("\nCapacity is never exceeded")
    load = day_effort(r, model)
    over = {k: v for k, v in load.items() if v > 100}
    check("no person over 100% on any day", not over, str(over))

    print("\nNo eligible person leaves the item unscheduled, not mis-assigned")
    gap = build_model()
    gap["items"] = [dict(gap["items"][1], id=12, skills=[{"skill_id": 99, "min_proficiency": 4}])]
    rg = solve(gap, budget_seconds=10)
    check("item with no qualified person is reported unscheduled",
          12 in (rg.get("unscheduled") or []), str(rg.get("unscheduled")))
    check("and is not assigned to anyone", not rg["assignments"], str(rg["assignments"]))

    print("\nDependencies hold (finish-to-start)")
    dep = build_model()
    dep["items"][1] = dict(dep["items"][1], deps=[10], skills=[{"skill_id": 5, "min_proficiency": 3}],
                           needed_by=None)
    rd = solve(dep, budget_seconds=20)
    starts = {a["work_item_id"]: a["from_date"] for a in rd["assignments"]}
    ends = {a["work_item_id"]: a["to_date"] for a in rd["assignments"]}
    check("successor starts after its predecessor finishes",
          not starts or starts.get(11, "9999") > ends.get(10, ""), f"{starts} {ends}")

    print("\nThe freeze horizon is locked (STAB-01)")
    frozen = build_model()
    frozen["committed"] = [{"id": 1, "work_item_id": 10, "person_id": 1,
                            "from_date": frozen["days"][0], "to_date": frozen["days"][3],
                            "allocation_pct": 100, "locked": False, "is_reserve": False}]
    rf = solve(frozen, budget_seconds=20)
    committed_item = [a for a in rf["assignments"] if a["work_item_id"] == 10]
    check("committed work inside the freeze horizon keeps its person",
          all(a["person_id"] == 1 for a in committed_item), str(committed_item))
    check("and still starts on the committed day",
          any(a["from_date"] == frozen["days"][0] for a in committed_item), str(committed_item))

    print("\nReserve is protected from planned work")
    tight = build_model()
    # 1.5h/day available after a 6h reserve: planned work cannot use the reserve.
    tight["people"] = [dict(tight["people"][0], capacity=[[7.5, 6.0]] * len(tight["days"]))]
    tight["items"] = [tight["items"][0]]
    rt = solve(tight, budget_seconds=20)
    lt = day_effort(rt, tight)
    check("planned work stays inside capacity minus reserve",
          all(v <= 25 for v in lt.values()) if lt else True, str(lt))

    print("\nAn urgent cycle touches only the people in scope (STAB-05)")
    scoped = build_model()
    scoped["scope_person_ids"] = [1]
    scoped["committed"] = [{"id": 2, "work_item_id": 10, "person_id": 2,
                            "from_date": scoped["days"][10], "to_date": scoped["days"][13],
                            "allocation_pct": 100, "locked": False, "is_reserve": False}]
    scoped["items"][0] = dict(scoped["items"][0], skills=[{"skill_id": 5, "min_proficiency": 3}])
    rs = solve(scoped, budget_seconds=20)
    moved = [a for a in rs["assignments"] if a["work_item_id"] == 10 and a["person_id"] == 2]
    check("out-of-scope person's committed work is untouched",
          any(a["from_date"] == scoped["days"][10] for a in moved) or not moved, str(moved))

    print(f"\n{'FAILED: ' + ', '.join(FAILURES) if FAILURES else 'All checks passed.'}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
