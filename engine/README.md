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
