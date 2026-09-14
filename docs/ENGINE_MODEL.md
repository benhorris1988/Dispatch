# Scheduling engine model (the wire shape between PHP and the solver)

`api/engine/model.php` builds the planning model from the database. `api/engine/planner.php` solves
it in PHP (the heuristic list scheduler of spec 8.9, always available). When `engine_url` is set in
`api/config.php` and a cycle asks for `engine: 'cpsat'`, `api/engine/cpsat_client.php` serialises the
same model and POSTs it to the Python OR-Tools service in `engine/` (spec 8.8). **Any failure falls
back to the heuristic** and records the reason in `plan_versions.solver_stats.fallback`, so the
solver is an optimisation, never a dependency.

## Request — `POST {engine_url}/solve`

```jsonc
{
  "budget_seconds": 60,          // policy.solver_budget_seconds
  "model": {
    "schema_version": 1,
    "workspace_id": 1,
    "today": "2026-09-08",
    "hours_per_day": 7.5,
    "working_days": ["Mon","Tue","Wed","Thu","Fri"],
    "days": ["2026-09-08", "..."],        // every working day in the modelled horizon, ascending
    "windows": {
      "today": "2026-09-08",
      "freeze_end": "2026-09-18",         // last locked day (freeze_horizon_days working days out)
      "planned_end": "2026-10-09",        // end of the planned window
      "indicative_end": "2027-03-05"      // end of the modelled horizon
    },
    "scope": {                            // SCH-13: what this model plans for (see "Planning scope" below)
      "kind": "workspace",                // workspace | team | portfolio
      "team_id": null, "portfolio_id": null,
      "team_ids": null,                   // the teams in scope; null = every team
      "partial": false                    // true when people[] is not the whole workspace
    },
    "policy": {
      "objective_weights": {"valueCompletion":1,"lateness":3,"unscheduledValue":5,
                            "loadImbalance":0.5,"contextSwitching":0.5,"stabilityPlanned":2,"preferences":0.2},
      "change_budget_days": 5, "min_improvement_pct": 5,
      "target_load_min": 80, "target_load_max": 90,
      "small_fill_threshold_days": 3, "pairing_cost_threshold_days": 2,
      "max_concurrent_items": 2, "min_focus_days": 2
    },
    "people": [{
      "id": 1, "name": "Priya Kaur",
      "max_concurrent": 2, "min_focus_days": 2,
      "skills": {"3": 4, "5": 3},         // {skill_id: proficiency 0-4}
      "development": {"3": 3},            // {skill_id: target level} — pairing bonus when matched
      "prefers": "Platform and infrastructure work",
      "avoid": "Power BI report building",
      "protected": false,                 // STAB-12: doubles the stability cost of moves
      "rota_weeks": ["2026-09-28"],       // Mondays this person is on the incident rota
      "capacity": [[7.5, 0.9], ...]       // one [available_hours, reserve_hours] pair PER ENTRY OF days[],
                                          // already multiplied by the scope's share of that day (TEAM-09; 1 in a workspace model)
    }],
    "items": [{                           // schedulable items with remaining effort only
      "id": 42, "ref": "WI-1042", "policy": "planned",   // planned | interrupt
      "granularity": "week",              // halfDay | day | week — bucket size from the size class
      "counts_for_wip": true,
      "remaining_days": 36.0,             // latest estimate (likely or P80 per policy) × (1 − progress)
      "skill_effort": {"3": 14.0, "6": 10.0} | null,     // {skill_id: days} when the estimate splits effort
      "skills": [{"skill_id": 3, "min_proficiency": 3}],
      "deps": [33], "soft_deps": [],      // finish-to-start predecessors (uncleared, not delivered)
      "earliest_start": null, "needed_by": "2026-11-27",
      "priority": 78.0,                   // 0-100 priority score (spec 8.4)
      "protected": false, "small": false, // small = remaining_days <= small_fill_threshold_days
      "type_name": "Project", "tags": ["supplier","master-data"]
    }],
    "committed": [{                       // the baseline plan: stability is measured against this
      "id": 501, "work_item_id": 42, "person_id": 1,
      "from_date": "2026-09-21", "to_date": "2026-10-09",
      "allocation_pct": 100, "locked": false, "is_reserve": false
    }],
    "scope_person_ids": []                // non-empty on an urgent cycle: only these people may move
  }
}
```

## Response

```jsonc
{
  "assignments": [
    {"work_item_id": 42, "person_id": 1, "from_date": "2026-09-21", "to_date": "2026-10-09", "allocation_pct": 100}
  ],
  "objective": 1234.5,                    // the solver's own score (informational)
  "terms": {"lateness": 2, "unscheduled_value": 0},
  "solve_seconds": 12.4,
  "proved_optimal": true,
  "status": "OPTIMAL"                     // OPTIMAL | FEASIBLE | INFEASIBLE | UNKNOWN
}
```

The PHP side re-scores the returned plan with its own objective function, so the solver's `objective`
and `terms` are recorded for diagnostics but never trusted for the guardrail arithmetic. Items absent
from `assignments` are treated as unscheduled and reported on the watch list. `plan_check_constraints()`
in `cpsat_client.php` re-validates every returned plan against the hard constraints; a violation is
treated as a solver failure and the heuristic result is used instead.

## Planning scope: teams, portfolios and loans (TEAM-09, SCH-13)

`build_model($conn, $wsId, ['team_id' => n])` or `['portfolio_id' => n]` builds a model for one team,
or for every team in a portfolio together. With neither option the model is the whole workspace as
one pool, exactly as before. The PHP-side model (`docs/API.md` → `model.php`) carries three things
the wire shape above only shows in reduced form:

- **`people[].home`** (bool) and **`people[].loans`**. The pool is the scope's *home members* (active,
  `team_id` in scope) plus anyone **loaned into** a team in scope during the horizon (`home: false`).
  A loan (`dbo.person_loans`) moves `allocation_pct` of a person's time to another team between
  `from_date` and `to_date`, inclusive.
- **`capacity[day].share`** (0..1): the part of that person-day that belongs to the scope. A home member
  lent out at 50% has 0.5 on the loan's days and 1 otherwise; a person loaned in at 50% has 0.5 on those
  days and 0 outside them; when both the lending and the borrowing team are in scope (a portfolio) the
  share is 1 — a loan inside the scope moves nothing. Shares of one day across teams add up to 1.
  `available` and `reserve` stay the WHOLE day in the PHP model; the planner books against
  `share × (available − reserve)` while `allocation_pct` keeps meaning "share of the whole day", so a
  stored assignment reads the same in every view and a 50% loan can hold at most a 50% allocation. The
  wire payload multiplies the pairs by the share instead, because the solver has no share concept.
- **`items[].external`** (bool). In a scoped model an item with a committed row on an *active* person who
  is not a home member of the scope is another team's work (or shared with one). It is not re-planned:
  its committed rows are `locked`, the planner reproduces them exactly, and it is never reported as
  unscheduled by a team that does not own it. Rows on people **outside the pool** are passed through
  verbatim (pass 1 of the heuristic; `cpsat_solve()` re-appends them), so a scoped candidate is still a
  **complete workspace plan** and stores, diffs and commits like any other. A leaver's rows are not
  external — that work must be offered to someone else. `scope.external_item_ids` lists them.

What this gives: under a team model only that team's people (plus anyone lent to it) are eligible, so
an item needing a skill the team lacks is a skills gap; under a portfolio model the pool spans its teams,
and an item whose effort is split by skill (`skill_effort`) is placed across them — one portion per
qualified person, whichever team they sit in (SCH-13). Loans respect their dates: the borrowed person is
eligible for the borrowing team's work only while, and only to the share that, the loan says.

Two consequences worth knowing. A home member's committed work is booked in full against their scoped
share, so lending someone out at 50% makes their kept assignments overflow and the planner proposes moving
them — lending has a cost, and the plan says so. A borrowed person's own (external) commitments book
against the part of the day that stays with their own team, and only the overflow eats into the lent
share, so the borrowing team sees exactly what it was promised.

The workspace (nightly) model ignores team boundaries as it always has; loans therefore change nothing
there. They matter when a cycle is scoped to a team or portfolio, and in every per-team figure
(`portfolios.php overview`, `people.php list{team_id}`, `skills.php matrix{team_id}`).

## Hard constraints the solver must honour (spec 8.5)

| Constraint | Rule |
|---|---|
| Skills | A person may only work an item if they meet `min_proficiency` for each skill they spend effort on. With `skill_effort`, at least one assigned person must meet each skill. |
| Capacity | Σ effort per person per day ≤ `available − reserve` (the pairs are already the scope's share of the day). Only `policy: "interrupt"` items may consume `reserve`. `plan_check_constraints()` reads a locked row of a loaned-in person as booking their own team's part of the day first. |
| Availability | No assignment on days where `available` is 0. |
| Dependencies | `start[j] ≥ finish[i] + 1` for each `deps` entry. `soft_deps` are a penalty, not a bar. |
| Earliest start / locks | Nothing before `earliest_start`; `committed` entries with `locked: true`, and anything inside `windows.freeze_end`, are reproduced exactly. |
| Concurrency | ≤ `max_concurrent` items with `counts_for_wip` on any day. |
| Focus blocks | Once started, an item is worked for at least `min_focus_days` consecutive days unless less effort remains. |
| Completeness | An item is scheduled to completion or left out entirely. Never truncate silently. |

## Objective (spec 8.6, minimised)

`valueCompletion × Σ(priority × completion_week)` + `lateness × Σ(priority × working days late)` +
`unscheduledValue × Σ(priority of unscheduled)` + `loadImbalance × Σ|weekly load − target band|` +
`contextSwitching × Σ(item switches per person per week beyond one)` +
`stabilityPlanned × Σ(assignment-days moved inside the planned window)` + `preferences × (avoid-list
hits − development-pairing matches)`.

Committed-window moves are hard-locked rather than penalised. Indicative moves (beyond
`windows.planned_end`) cost nothing. Warm-start from `committed` so the first feasible solution is
the current plan and every improvement is a genuine improvement.
