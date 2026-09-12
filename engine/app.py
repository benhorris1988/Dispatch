"""Dispatch scheduling engine — CP-SAT solver service (spec 10.4).

Localhost-only FastAPI wrapper around `solver.solve`. The PHP API calls it when
`engine_url` is configured and a cycle asks for the CP-SAT engine; every failure falls
back to the PHP heuristic, so this service is optional.

    python -m pip install -r requirements.txt
    python -m uvicorn app:app --host 127.0.0.1 --port 8010
"""

from __future__ import annotations

import logging
import os
from typing import Any

from fastapi import FastAPI
from pydantic import BaseModel, Field

from solver import solve

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dispatch.engine")

DEFAULT_BUDGET = float(os.environ.get("DISPATCH_SOLVER_BUDGET", "60"))
MAX_BUDGET = float(os.environ.get("DISPATCH_SOLVER_MAX_BUDGET", "300"))

app = FastAPI(title="Dispatch scheduling engine", version="1.0")


class SolveRequest(BaseModel):
    model: dict[str, Any] = Field(..., description="Planning model — see docs/ENGINE_MODEL.md")
    budget_seconds: float | None = Field(None, description="Solver time budget in seconds")


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "engine": "cpsat", "default_budget_seconds": DEFAULT_BUDGET}


@app.post("/solve")
def solve_endpoint(req: SolveRequest) -> dict[str, Any]:
    budget = min(MAX_BUDGET, float(req.budget_seconds or DEFAULT_BUDGET))
    model = req.model or {}
    log.info(
        "solve: %s people, %s items, %s days, budget %.0fs",
        len(model.get("people") or []), len(model.get("items") or []),
        len(model.get("days") or []), budget,
    )
    try:
        result = solve(model, budget)
    except Exception as exc:  # a solver failure must never take the planner down
        log.exception("solve failed")
        return {
            "assignments": [], "objective": 0.0, "terms": {}, "solve_seconds": 0.0,
            "proved_optimal": False, "status": "ERROR", "message": str(exc),
        }
    log.info(
        "solved: %s in %.2fs, %s assignments, optimal=%s",
        result.get("status"), result.get("solve_seconds", 0),
        len(result.get("assignments") or []), result.get("proved_optimal"),
    )
    return result
