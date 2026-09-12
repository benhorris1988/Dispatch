# Dispatch scheduling engine (CP-SAT)

Optional Python service implementing the constraint-solver planner of specification 8.8.
The PHP heuristic in `api/engine/planner.php` covers every cycle on its own (the R1
behaviour in the roadmap); this service is the R2 optimiser and is used only when
`engine_url` is set in `api/config.php` and a cycle asks for `engine: "cpsat"`.

**Every failure — unreachable, timeout, infeasible, or a plan that breaks a hard
constraint — falls back to the heuristic** and records the reason in
`plan_versions.solver_stats.fallback`. The planner never depends on this process.

```bash
python -m pip install -r requirements.txt
python -m uvicorn app:app --host 127.0.0.1 --port 8010     # or: run_engine.bat
curl http://127.0.0.1:8010/health
python test_solver.py                                       # self-contained model check
```

| Endpoint | Purpose |
|---|---|
| `GET /health` | Liveness and the default time budget |
| `POST /solve` | `{model, budget_seconds}` → `{assignments, objective, terms, solve_seconds, proved_optimal, status}` |

The model shape is documented in `../docs/ENGINE_MODEL.md`. `solver.py` holds the model
building and is importable on its own; `app.py` is a thin FastAPI wrapper. Bind to
127.0.0.1 only — the service has no authentication because it is never publicly exposed.

## Maturity, honestly

The service returns valid plans: every hard constraint of section 8.5 holds, and
`plan_check_constraints()` on the PHP side re-validates before anything is used. On the
eight-person demo model it finds a **feasible** plan inside the 60-second budget but does
not prove optimality, and it currently schedules less of the pipeline than the PHP
heuristic does. Because the Plan service re-scores every candidate with its own objective,
a weaker plan simply fails the minimum-improvement guardrail and nothing is applied — the
chain behaves exactly as designed, it just has nothing better to offer yet.

So: the heuristic is the engine that runs the pilot (R1 in the roadmap), and this solver
is the R2 optimiser still being tuned. Weight tuning against golden datasets, a warm start
the model can actually accept, and search hints are the obvious next steps.

Three modelling decisions worth knowing, each of which made the difference between an
infeasible model and a working one:

- **Allocation is a share of the person's schedulable time that day** (capacity minus the
  incident reserve), not of a nominal working day. With a reserve held back, a 100%
  assignment measured against a nominal day demands more hours than anyone has.
- **A committed assignment is a date range, not a statement of effort.** Progress reduces
  the effort left without shortening the range, so effort reconstructed from the range is
  a guess — and one that has to be whole quarter-days, aligned to the item's allocation
  step, and sum to the remaining effort. Pinning it makes the model contradict itself.
- **Locks therefore anchor the shape, not the hours**, and only while the item is
  scheduled at all. An unconditional anchor makes every committed item undroppable, so a
  single item that cannot fit takes the whole solve down instead of appearing on the watch
  list where SCH-05 wants it.

`diagnose_infeasible.py` relaxes one constraint group at a time against a captured model
and then narrows to the smallest set of committed rows that still fails; it is what found
all three. `solve_real_model.py` runs a captured model straight through the solver.
