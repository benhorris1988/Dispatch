# Working in this repo

Dispatch — delivery planning and resource management. Flutter app (`mobile/`) + PHP / **Microsoft SQL
Server** API (`api/`) + optional Python OR-Tools solver (`engine/`). Start with `README.md`, then
`docs/API.md` (the API contract every screen is built against) and `docs/ENGINE_MODEL.md`.

## Facts that are easy to get wrong

- **The database is SQL Server (`localhost\LIVE`, database `DispatchDB`), not PostgreSQL.** The
  requirements document targets Azure PostgreSQL for production; this implementation mirrors the
  Badminton project's local stack on purpose. PHP talks to it via `sqlsrv`; queries are `dbo.` T-SQL.
- `db/01_schema.sql` **is** the schema of record (idempotent). Apply it with `sqlcmd -E`.
- `api/config.php` is the **gitignored secrets file**. The workspace-configuration endpoint is
  `api/workspace_config.php`. Do not confuse the two.
- `today()` in `api/lib.php` honours `fake_today` in `api/config.php`. The demo seed is built around
  Tue 8 Sep 2026; remove that key for live use.
- The repo is served by PHP's built-in server (`run_local.ps1`, port 8090, `router.php`), not Apache.
  Apache's DocumentRoot on this box is the Badminton project; an Alias is optional (see README).
- `seed_demo.php` **wipes and reseeds every table**. CLI only, guarded by `migration_connect.php`.

## Conventions

- **API**: one PHP file per resource, `POST` with `{"action": "..."}` JSON body, `Authorization:
  Bearer <JWT>`, responses `{status, ...}`. Every endpoint includes `db_connect.php` then
  `auth_middleware.php`. Always filter by `workspace_id = $wsId`. Every mutation calls `audit()`.
- **Roles** (ADM-02): viewer < requester < team_member < benefit_owner < team_lead < delivery_lead <
  admin. Gate server-side with `require_role()`; in the client hide controls, don't rely on 403s.
- **Engine**: `api/engine/*.php` is pure PHP (no HTTP). `replan.php` orchestrates: build model →
  plan (heuristic, or CP-SAT service when configured) → diff → cost → guardrails → explain → store a
  *proposal*. The engine never edits the committed plan; `changes.php commit` does, as a new version.
- **Personal data** (ADM-05): availability rows carry a type only. Never add a reason column.
- **Money** in whole currency units; the client formats (£210k).

## Verification bar

```bash
C:\xampp\php\php.exe tests\run_all.php     # all five PHP suites; re-seeds before and after
python engine\test_solver.py               # CP-SAT hard-constraint checks (no server needed)
"C:\temp\flutter sdk\flutter\bin\flutter.bat" analyze     # in mobile/ — must be "No issues found"
```

`run_all.php` needs the local server up (`run_local.ps1`). The suites mutate the demo
deliberately, so it re-seeds before and after; run `seed_demo.php` yourself if you
interrupt one. Build the web app from **PowerShell** — the space in the Flutter SDK path
breaks the bash invocation:

```powershell
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" build web --release --base-href=/mobile/build/web/ --dart-define=API_BASE=http://localhost:8090/api
```

Two things that look like bugs and are not:

- **Mojibake in a terminal is the terminal.** Four separate reports of double-encoded
  UTF-8 turned out to be the Windows console rendering correct bytes. Check at byte level
  (`curl … | python -c "import sys; print(sys.stdin.buffer.read()[:200])"`) before
  "fixing" it; an en dash is `e2 80 93` and a double-encoded one is `c3 a2 c2 80 c2 93`.
- **Identity columns can start at 0.** Never test an id for truthiness.
