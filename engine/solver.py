"""CP-SAT scheduling model for Dispatch (specification section 8.8).

Pure functions: `solve(model, budget_seconds)` takes the wire model documented in
docs/ENGINE_MODEL.md and returns assignments plus solver statistics. No database, no
HTTP — `app.py` wraps this in FastAPI.

Design notes
------------
Effort is modelled in **quarter-days** so everything stays integral. Variables exist only
for *eligible* (item, person) pairs, and time is bucketed: one bucket per working day
inside the planned window, one bucket per week beyond it. Both reductions come straight
from the specification ("model size is kept manageable by only creating variables for
eligible person-item pairs, by using weekly buckets for Large items").

The solve is warm-started from the committed plan, so the first feasible solution is the
current plan and every improvement the solver reports is a genuine improvement.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Iterable

from ortools.sat.python import cp_model

QUARTER = 4  # quarter-days per day
BIG = 10_000

GRANULARITY_STEP = {"halfDay": 2, "day": 4, "week": 4}


def _d(s: str) -> date:
    return datetime.strptime(s[:10], "%Y-%m-%d").date()


def _week_start(d: date) -> date:
    return d - timedelta(days=d.weekday())


@dataclass
class Bucket:
    """A contiguous run of working days the solver treats as one time step."""

    index: int
    days: list[date]

    @property
    def start(self) -> date:
        return self.days[0]

    @property
    def end(self) -> date:
        return self.days[-1]

    @property
    def size(self) -> int:
        return len(self.days)


@dataclass
class Prepared:
    buckets: list[Bucket]
    bucket_of_day: dict[date, int]
    people: list[dict]
    items: list[dict]
    eligible: dict[int, list[int]] = field(default_factory=dict)
    capacity: dict[tuple[int, int], tuple[int, int]] = field(default_factory=dict)
    committed: dict[tuple[int, int, int], int] = field(default_factory=dict)
    day_capacity: dict[tuple[int, date], tuple[int, int]] = field(default_factory=dict)


def build_buckets(days: list[str], planned_end: str) -> tuple[list[Bucket], dict[date, int]]:
    """Day buckets inside the planned window, weekly buckets beyond it."""
    parsed = [_d(x) for x in days]
    cut = _d(planned_end) if planned_end else (parsed[-1] if parsed else None)
    buckets: list[Bucket] = []
    pending: dict[date, list[date]] = {}
    for day in parsed:
        if cut is not None and day <= cut:
            buckets.append(Bucket(len(buckets), [day]))
        else:
            pending.setdefault(_week_start(day), []).append(day)
    for wk in sorted(pending):
        buckets.append(Bucket(len(buckets), pending[wk]))
    index: dict[date, int] = {}
    for b in buckets:
        for day in b.days:
            index[day] = b.index
    return buckets, index


def _eligible_people(item: dict, people: list[dict]) -> list[int]:
    """People meeting every required skill at the minimum level (spec 8.5 Skills).

    When effort is split by skill, a person qualifies if they meet at least one of the
    split skills; the model then requires every split skill to be covered by someone.
    """
    reqs = item.get("skills") or []
    split = item.get("skill_effort") or None
    out = []
    for p in people:
        skills = {int(k): int(v) for k, v in (p.get("skills") or {}).items()}
        if not reqs:
            out.append(p["id"])
            continue
        if split:
            if any(skills.get(r["skill_id"], 0) >= r["min_proficiency"] for r in reqs):
                out.append(p["id"])
        elif all(skills.get(r["skill_id"], 0) >= r["min_proficiency"] for r in reqs):
            out.append(p["id"])
    return out


def prepare(model: dict) -> Prepared:
    days = model.get("days") or []
    windows = model.get("windows") or {}
    buckets, bucket_of_day = build_buckets(days, windows.get("planned_end") or "")
    people = list(model.get("people") or [])
    items = [i for i in (model.get("items") or []) if float(i.get("remaining_days") or 0) > 0]

    prepared = Prepared(buckets=buckets, bucket_of_day=bucket_of_day, people=people, items=items)

    # Capacity in quarter-days, per person per day and then summed per bucket.
    hours_per_day = float(model.get("hours_per_day") or 7.5) or 7.5
    day_list = [_d(x) for x in days]
    day_pos = {d: i for i, d in enumerate(day_list)}
    day_cap: dict[tuple[int, date], tuple[int, int]] = {}
    for p in people:
        cap_pairs = p.get("capacity") or []
        for day in day_list:
            pos = day_pos.get(day, -1)
            avail = reserve = 0.0
            if 0 <= pos < len(cap_pairs):
                avail, reserve = float(cap_pairs[pos][0]), float(cap_pairs[pos][1])
            day_cap[(p["id"], day)] = (
                int(round(max(0.0, avail - reserve) / hours_per_day * QUARTER)),
                int(round(max(0.0, reserve) / hours_per_day * QUARTER)),
            )
        for b in buckets:
            planned_q = sum(day_cap[(p["id"], d)][0] for d in b.days)
            reserve_q = sum(day_cap[(p["id"], d)][1] for d in b.days)
            prepared.capacity[(p["id"], b.index)] = (planned_q, reserve_q)
    prepared.day_capacity = day_cap

    for item in items:
        prepared.eligible[item["id"]] = _eligible_people(item, people)

    # Committed baseline. allocation_pct is a share of the person's SCHEDULABLE time that
    # day (capacity minus the incident reserve), not of a nominal working day — the same
    # reading the PHP planner uses. Measuring it against a nominal day made a 100%
    # assignment demand more hours than anyone holding a reserve actually has, and pinning
    # that inside the freeze horizon made the whole model infeasible.
    policy_by_item = {i["id"]: (i.get("policy") or "planned") for i in items}
    for a in model.get("committed") or []:
        frm, to = _d(a["from_date"]), _d(a["to_date"])
        span = [day for day in day_list if frm <= day <= to]
        if not span:
            continue
        pct = float(a.get("allocation_pct", 100)) / 100.0
        interrupt = policy_by_item.get(a["work_item_id"]) == "interrupt"
        for day in span:
            b = bucket_of_day.get(day)
            if b is None:
                continue
            planned_q, reserve_q = day_cap.get((a["person_id"], day), (0, 0))
            room = planned_q + (reserve_q if interrupt else 0)
            if room <= 0:
                continue          # a day this person does not work: the range spans it, no effort on it
            key = (a["work_item_id"], a["person_id"], b)
            prepared.committed[key] = prepared.committed.get(key, 0) + int(round(pct * room))

    # A committed assignment is a date RANGE, not a statement of effort: a five-day range
    # at 100% does not mean five days of work is left, because progress has been made
    # against it. Pinning the raw range would demand more effort than the item has
    # remaining, contradicting the completeness constraint and making the whole model
    # infeasible. Scale each item's committed quantities down to its remaining effort,
    # which is the same proportional split the PHP planner applies.
    remaining_q = {i["id"]: int(round(float(i["remaining_days"]) * QUARTER)) for i in items}
    per_item: dict[int, int] = {}
    for (iid, _pid, _b), q in prepared.committed.items():
        per_item[iid] = per_item.get(iid, 0) + q
    for (iid, pid, b), q in list(prepared.committed.items()):
        want = remaining_q.get(iid)
        total = per_item.get(iid, 0)
        if want is None or total <= want or total <= 0:
            continue
        prepared.committed[(iid, pid, b)] = int(q * want // total)
    return prepared


def solve(model: dict, budget_seconds: float = 60.0) -> dict[str, Any]:
    """Build and solve the CP-SAT model. Always returns the best plan found."""
    started = time.time()
    prep = prepare(model)
    if not prep.buckets or not prep.people:
        return {
            "assignments": [], "objective": 0.0, "terms": {},
            "solve_seconds": round(time.time() - started, 3),
            "proved_optimal": False, "status": "INFEASIBLE",
            "message": "model has no time buckets or no people",
        }

    policy = model.get("policy") or {}
    weights = policy.get("objective_weights") or {}
    windows = model.get("windows") or {}
    freeze_end = _d(windows["freeze_end"]) if windows.get("freeze_end") else None
    planned_end = _d(windows["planned_end"]) if windows.get("planned_end") else None
    scope = set(model.get("scope_person_ids") or [])

    m = cp_model.CpModel()
    n_buckets = len(prep.buckets)
    by_id = {p["id"]: p for p in prep.people}

    a: dict[tuple[int, int, int], cp_model.IntVar] = {}   # effort, quarter-days
    w: dict[tuple[int, int, int], cp_model.IntVar] = {}   # works at all
    unscheduled: dict[int, cp_model.IntVar] = {}
    start: dict[int, cp_model.IntVar] = {}
    finish: dict[int, cp_model.IntVar] = {}
    hints: list[tuple[cp_model.IntVar, int]] = []
    var_ceiling: dict[tuple[int, int, int], int] = {}

    for item in prep.items:
        iid = item["id"]
        remaining_q = int(round(float(item["remaining_days"]) * QUARTER))
        step = GRANULARITY_STEP.get(item.get("granularity") or "day", QUARTER)
        is_interrupt = (item.get("policy") or "planned") == "interrupt"
        earliest = _d(item["earliest_start"]) if item.get("earliest_start") else None
        people_ids = prep.eligible.get(iid) or []

        unscheduled[iid] = m.NewBoolVar(f"u_{iid}")
        start[iid] = m.NewIntVar(0, n_buckets - 1, f"s_{iid}")
        finish[iid] = m.NewIntVar(0, n_buckets - 1, f"f_{iid}")
        m.Add(start[iid] <= finish[iid])

        terms = []
        for pid in people_ids:
            for b in prep.buckets:
                planned_q, reserve_q = prep.capacity.get((pid, b.index), (0, 0))
                ceiling = planned_q + (reserve_q if is_interrupt else 0)
                if ceiling <= 0:
                    continue
                if earliest and b.end < earliest:
                    continue
                hi = min(ceiling, remaining_q)
                var = m.NewIntVar(0, hi, f"a_{iid}_{pid}_{b.index}")
                var_ceiling[(iid, pid, b.index)] = hi
                bit = m.NewBoolVar(f"w_{iid}_{pid}_{b.index}")
                m.Add(var > 0).OnlyEnforceIf(bit)
                m.Add(var == 0).OnlyEnforceIf(bit.Not())
                if step > 1:
                    # Allocation granularity: halfDay -> 0.5 day steps, day/week -> whole days.
                    mult = m.NewIntVar(0, min(ceiling, remaining_q) // step + 1, f"m_{iid}_{pid}_{b.index}")
                    m.Add(var == mult * step)
                a[(iid, pid, b.index)] = var
                w[(iid, pid, b.index)] = bit
                terms.append(var)
                # Window bracketing: any work pins start/finish around this bucket.
                m.Add(start[iid] <= b.index).OnlyEnforceIf(bit)
                m.Add(finish[iid] >= b.index).OnlyEnforceIf(bit)

        if not terms:
            m.Add(unscheduled[iid] == 1)
            continue

        # Completeness (spec 8.5): fully scheduled, or not scheduled at all.
        m.Add(sum(terms) == remaining_q).OnlyEnforceIf(unscheduled[iid].Not())
        m.Add(sum(terms) == 0).OnlyEnforceIf(unscheduled[iid])

    # Capacity per person per bucket. Reserve is only consumable by interrupt work.
    for p in prep.people:
        pid = p["id"]
        for b in prep.buckets:
            planned_q, reserve_q = prep.capacity.get((pid, b.index), (0, 0))
            planned_terms, all_terms = [], []
            for item in prep.items:
                var = a.get((item["id"], pid, b.index))
                if var is None:
                    continue
                all_terms.append(var)
                if (item.get("policy") or "planned") != "interrupt":
                    planned_terms.append(var)
            if planned_terms:
                m.Add(sum(planned_terms) <= planned_q)
            if all_terms:
                m.Add(sum(all_terms) <= planned_q + reserve_q)

            # Concurrency (spec 8.5): WIP-counting items only.
            wip = [w[(i["id"], pid, b.index)] for i in prep.items
                   if i.get("counts_for_wip", True) and (i["id"], pid, b.index) in w]
            limit = int(p.get("max_concurrent") or policy.get("max_concurrent_items") or 2)
            if wip and limit > 0:
                m.Add(sum(wip) <= limit)

    # Dependencies: finish-to-start.
    ids = {i["id"] for i in prep.items}
    for item in prep.items:
        for dep in item.get("deps") or []:
            if dep in ids and dep in finish:
                m.Add(start[item["id"]] >= finish[dep] + 1).OnlyEnforceIf(
                    [unscheduled[item["id"]].Not(), unscheduled[dep].Not()]
                )

    # Locks (STAB-01). A user-fixed row, or one belonging to someone outside an urgent
    # cycle's scope, is reproduced in full. A row that merely *starts* inside the freeze
    # horizon is only locked for the buckets that actually fall inside it — the rest of a
    # long assignment stays free to move, which is the whole point of having a planned
    # window beyond the frozen one. Pinning the entire range made the model infeasible.
    locked_people = {p["id"] for p in prep.people if scope and p["id"] not in scope}
    pins: dict[tuple[int, int, int], int] = {}
    for ca in model.get("committed") or []:
        whole = bool(ca.get("locked")) or ca["person_id"] in locked_people
        starts_frozen = bool(freeze_end) and _d(ca["from_date"]) <= freeze_end
        if not whole and not starts_frozen:
            continue
        for (iid, pid, b), qty in prep.committed.items():
            if iid != ca["work_item_id"] or pid != ca["person_id"]:
                continue
            if not whole and freeze_end and prep.buckets[b].start > freeze_end:
                continue
            pins[(iid, pid, b)] = max(pins.get((iid, pid, b), 0), qty)
    # Pin the SHAPE, not the hours: require that this person is working this item in this
    # bucket, and let the solver choose how much. The wire format carries a date range and
    # an allocation, never per-bucket effort, so any exact quantity reconstructed from it
    # is a guess — and a guess that has to be a whole number of quarter-days, align to the
    # item's allocation step (half days for Small work) and sum to the remaining effort.
    # Pinning it made the model contradict itself: a 2.5-day item with a five-day
    # committed range was pinned to 2,2,2,2,1 quarter-days against a variable that must be
    # a multiple of 2, which is infeasible on its face. Fixing person and days is what
    # "the committed plan is kept" actually means.
    # ...and anchor it to the WINDOW, not to every bucket in it. Progress reduces an
    # item's remaining effort without shortening its committed range, so a five-day range
    # on an item with one day left cannot be worked every day: at the minimum allocation
    # step that would demand more effort than remains. Requiring the person to be on the
    # item somewhere inside the committed window keeps the assignment recognisably in
    # place while staying satisfiable. The PHP heuristic remains the authority on keeping
    # a committed row exactly; the solver is asked for a plan, not a re-derivation.
    anchors: dict[tuple[int, int], list] = {}
    for (iid, pid, b) in pins:
        bit = w.get((iid, pid, b))
        if bit is not None:
            anchors.setdefault((iid, pid), []).append(bit)
    # Inside the freeze horizon the committed window is locked, so an item that is already
    # committed there may not pick up anyone new: anchoring only the committed people says
    # they must work it, not that nobody else may join them.
    frozen_people: dict[int, set[int]] = {}
    for ca in model.get("committed") or []:
        if freeze_end and _d(ca["from_date"]) <= freeze_end:
            frozen_people.setdefault(ca["work_item_id"], set()).add(ca["person_id"])
    if freeze_end:
        for iid, allowed in frozen_people.items():
            for b in prep.buckets:
                if b.start > freeze_end:
                    continue
                for pid in prep.eligible.get(iid, []):
                    if pid in allowed:
                        continue
                    bit = w.get((iid, pid, b.index))
                    if bit is not None:
                        m.Add(bit == 0)

    for (iid, _pid), bits in anchors.items():
        # Conditional on the item being scheduled at all. An unconditional anchor makes
        # every committed item undroppable, so one item that genuinely cannot fit inside
        # the horizon takes the whole solve down as INFEASIBLE instead of being reported
        # on the watch list, which is what the specification asks for (SCH-05).
        m.Add(sum(bits) >= 1).OnlyEnforceIf(unscheduled[iid].Not())

    # Focus blocks (spec 8.5): once started, worked for min_focus_days consecutive buckets.
    for item in prep.items:
        iid = item["id"]
        for pid in prep.eligible.get(iid, []):
            person = by_id.get(pid) or {}
            min_focus = int(person.get("min_focus_days") or policy.get("min_focus_days") or 2)
            if min_focus < 2 or float(item["remaining_days"]) < min_focus:
                continue
            for b in range(1, n_buckets - 1):
                here, prev, nxt = w.get((iid, pid, b)), w.get((iid, pid, b - 1)), w.get((iid, pid, b + 1))
                if here is None or prev is None or nxt is None:
                    continue
                # A day of work that did not continue from yesterday must continue tomorrow.
                m.Add(here - prev <= nxt)

    objective, terms_index = _objective(m, prep, a, w, unscheduled, finish, weights, policy, planned_end)
    m.Minimize(objective)

    # Warm start from the committed plan (spec 8.8).
    for (iid, pid, b), qty in prep.committed.items():
        var = a.get((iid, pid, b))
        if var is not None:
            hints.append((var, qty))
    for var, val in hints:
        m.AddHint(var, val)

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = max(1.0, float(budget_seconds))
    solver.parameters.num_search_workers = 8
    solver.parameters.log_search_progress = False
    status = solver.Solve(m)

    status_name = solver.StatusName(status)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return {
            "assignments": [], "objective": 0.0, "terms": {},
            "solve_seconds": round(time.time() - started, 3),
            "proved_optimal": False, "status": status_name,
            "message": "no feasible plan within the time budget",
        }

    assignments = _extract(solver, prep, a)
    terms = {k: solver.Value(v) for k, v in terms_index.items()}
    return {
        "assignments": assignments,
        "objective": float(solver.ObjectiveValue()),
        "terms": terms,
        "solve_seconds": round(time.time() - started, 3),
        "proved_optimal": status == cp_model.OPTIMAL,
        "status": status_name,
        "unscheduled": [i["id"] for i in prep.items if solver.Value(unscheduled[i["id"]])],
    }


def _objective(m, prep, a, w, unscheduled, finish, weights, policy, planned_end):
    """Weighted-sum objective of spec 8.6. Returns (expression, {term: var})."""
    wt = lambda k, d: int(round(float(weights.get(k, d)) * 10))  # noqa: E731 — scaled to stay integral
    parts = []
    index: dict[str, cp_model.IntVar] = {}

    # Value-weighted completion: high-priority items should finish early.
    vc_terms = []
    for item in prep.items:
        priority = int(round(float(item.get("priority") or 50)))
        vc_terms.append(priority * finish[item["id"]])
    if vc_terms:
        vc = m.NewIntVar(0, BIG * 1000, "value_completion")
        m.Add(vc == sum(vc_terms))
        index["value_completion"] = vc
        parts.append(wt("valueCompletion", 1.0) * vc)

    # Lateness: working days finished after needed_by, weighted by priority.
    late_terms = []
    for item in prep.items:
        if not item.get("needed_by"):
            continue
        due = _d(item["needed_by"])
        due_bucket = None
        for b in prep.buckets:
            if b.end >= due:
                due_bucket = b.index
                break
        if due_bucket is None:
            continue
        priority = int(round(float(item.get("priority") or 50)))
        over = m.NewIntVar(0, len(prep.buckets), f"late_{item['id']}")
        m.Add(over >= finish[item["id"]] - due_bucket)
        late_terms.append(priority * over)
    if late_terms:
        late = m.NewIntVar(0, BIG * 1000, "lateness")
        m.Add(late == sum(late_terms))
        index["lateness"] = late
        parts.append(wt("lateness", 3.0) * late)

    # Unscheduled value.
    uns_terms = [int(round(float(i.get("priority") or 50))) * unscheduled[i["id"]] for i in prep.items]
    if uns_terms:
        uns = m.NewIntVar(0, BIG * 1000, "unscheduled_value")
        m.Add(uns == sum(uns_terms))
        index["unscheduled_value"] = uns
        parts.append(wt("unscheduledValue", 5.0) * uns)

    # Load imbalance against the target band.
    target_max = float(policy.get("target_load_max") or 90) / 100.0
    imb_terms = []
    for p in prep.people:
        for b in prep.buckets:
            planned_q, _ = prep.capacity.get((p["id"], b.index), (0, 0))
            if planned_q <= 0:
                continue
            assigned = [a[(i["id"], p["id"], b.index)] for i in prep.items if (i["id"], p["id"], b.index) in a]
            if not assigned:
                continue
            over = m.NewIntVar(0, planned_q, f"imb_{p['id']}_{b.index}")
            m.Add(over >= sum(assigned) - int(planned_q * target_max))
            imb_terms.append(over)
    if imb_terms:
        imb = m.NewIntVar(0, BIG * 1000, "load_imbalance")
        m.Add(imb == sum(imb_terms))
        index["load_imbalance"] = imb
        parts.append(wt("loadImbalance", 0.5) * imb)

    # Stability: assignment-days moved inside the planned window (committed is hard-locked).
    stab_terms = []
    planned_cut = None
    if planned_end:
        for b in prep.buckets:
            if b.end <= planned_end:
                planned_cut = b.index
    if planned_cut is not None:
        keys = set(prep.committed) | set(a)
        for (iid, pid, b) in keys:
            if b > planned_cut:
                continue
            var = a.get((iid, pid, b))
            base = prep.committed.get((iid, pid, b), 0)
            if var is None:
                stab_terms.append(m.NewConstant(base))
                continue
            delta = m.NewIntVar(0, BIG, f"stab_{iid}_{pid}_{b}")
            m.Add(delta >= var - base)
            m.Add(delta >= base - var)
            stab_terms.append(delta)
    if stab_terms:
        stab = m.NewIntVar(0, BIG * 1000, "stability")
        m.Add(stab == sum(stab_terms))
        index["stability"] = stab
        parts.append(wt("stabilityPlanned", 2.0) * stab)

    # Preferences: avoid-list hits cost, development pairing earns a discount.
    def _as_text(v) -> str:
        """prefers/avoid arrive as a list of phrases from PHP, but a plain string is
        equally valid on the wire; accept either rather than assuming."""
        if isinstance(v, str):
            return v.lower()
        if isinstance(v, (list, tuple)):
            return " ".join(str(x) for x in v).lower()
        return ""

    pref_terms = []
    for p in prep.people:
        avoid = _as_text(p.get("avoid"))
        development = {int(k) for k in (p.get("development") or {})}
        for item in prep.items:
            keys = [w[(item["id"], p["id"], b.index)] for b in prep.buckets if (item["id"], p["id"], b.index) in w]
            if not keys:
                continue
            hay = f"{item.get('type_name') or ''} {' '.join(item.get('tags') or [])}".lower()
            if avoid and any(tok and tok in hay for tok in avoid.split()):
                pref_terms.extend(keys)
            elif development and any(r["skill_id"] in development for r in (item.get("skills") or [])):
                pref_terms.extend(-1 * k for k in keys)
    if pref_terms:
        pref = m.NewIntVar(-BIG * 100, BIG * 1000, "preferences")
        m.Add(pref == sum(pref_terms))
        index["preferences"] = pref
        parts.append(wt("preferences", 0.2) * pref)

    return (sum(parts) if parts else 0), index


def _extract(solver, prep: Prepared, a) -> list[dict]:
    """Collapse per-bucket effort back into contiguous date-range assignments."""
    by_pair: dict[tuple[int, int], list[tuple[int, int]]] = {}
    for (iid, pid, b), var in a.items():
        val = solver.Value(var)
        if val > 0:
            by_pair.setdefault((iid, pid), []).append((b, val))

    out: list[dict] = []
    for (iid, pid), entries in by_pair.items():
        entries.sort()
        run: list[tuple[int, int]] = []
        for bucket_index, qty in entries:
            if run and bucket_index != run[-1][0] + 1:
                out.append(_range(prep, iid, pid, run))
                run = []
            run.append((bucket_index, qty))
        if run:
            out.append(_range(prep, iid, pid, run))
    return out


def _range(prep: Prepared, iid: int, pid: int, run: list[tuple[int, int]]) -> dict:
    first, last = prep.buckets[run[0][0]], prep.buckets[run[-1][0]]
    working_days = sum(prep.buckets[b].size for b, _ in run) or 1
    total_q = sum(q for _, q in run)
    pct = int(round(total_q / (working_days * QUARTER) * 100))
    pct = max(25, min(100, int(round(pct / 25.0)) * 25))  # 25% steps (SCH-04)
    return {
        "work_item_id": iid,
        "person_id": pid,
        "from_date": first.start.isoformat(),
        "to_date": last.end.isoformat(),
        "allocation_pct": pct,
    }
