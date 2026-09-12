"""Solve a captured production model with the CP-SAT engine.

Dump one first with the PHP side (build_model + cpsat_model_payload), then:
    python engine/solve_real_model.py <path-to-model.json> [budget_seconds]

Useful for diagnosing an INFEASIBLE result without going through the API.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from solver import prepare, solve  # noqa: E402


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("TEMP", "."), "model.json")
    budget = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
    with open(path, encoding="utf8") as fh:
        model = json.load(fh)

    prep = prepare(model)
    print(f"model: {len(prep.people)} people, {len(prep.items)} items, "
          f"{len(prep.buckets)} buckets, {len(model.get('committed') or [])} committed rows")

    result = solve(model, budget)
    print(f"status        : {result['status']} | proved optimal {result['proved_optimal']}")
    print(f"assignments   : {len(result['assignments'])}")
    print(f"unscheduled   : {len(result.get('unscheduled') or [])}")
    print(f"solve_seconds : {result['solve_seconds']}")
    if result.get("message"):
        print(f"message       : {result['message']}")
    if result.get("terms"):
        print("objective terms:", {k: v for k, v in list(result["terms"].items())[:8]})
    for a in result["assignments"][:5]:
        print("  ", a)
    return 0 if result["assignments"] else 1


if __name__ == "__main__":
    sys.exit(main())
