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
- **There is no development sign-in.** Sign-in is Google (ADM-01), which no test can perform, so
  tests mint a token with `tests/mint_token.php <email|role>` (CLI only, admin DB connection) and
  `tests/_auth.php` wraps it as `token_for($role)`. `auth.php providers` is the "is the server up"
  probe, not `list_dev_users`.
- **A team scope means the team and every team beneath it** (ORG-01). `teams.parent_team_id` makes the
  tree; `engine/org_lib.php team_closure()` reads it once per request, and anything that writes a
  parent, sort order, lead or visibility must call it again with `$fresh = true`.
- **Portfolios are now role families, and they group people, not teams** (ORG-02). `dbo.role_families`
  + `people.role_family_id`. `portfolio_id` is not a parameter anywhere any more.
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
C:\xampp\php\php.exe tests\run_all.php     # every PHP suite listed in run_all.php; re-seeds before and after
python engine\test_solver.py               # CP-SAT hard-constraint checks (no server needed)
"C:\temp\flutter sdk\flutter\bin\flutter.bat" analyze                        # in mobile/
"C:\temp\flutter sdk\flutter\bin\flutter.bat" test test/org_layout_test.dart  # chart geometry; no server
"C:\temp\flutter sdk\flutter\bin\flutter.bat" test test/screens_smoke_test.dart --dart-define=TEST_TOKEN=$(C:/xampp/php/php.exe tests/mint_token.php delivery_lead)
```

The smoke test needs that `TEST_TOKEN`: there is no development sign-in to fall back on, and a
minted token is the only way in for something that cannot open a browser.

**`analyze` is not enough on its own.** It proves the client compiles; it draws nothing.
`screens_smoke_test.dart` renders every screen against the running API at desktop,
tablet and phone widths and in dark theme, and fails on any framework exception, error
state or blank screen. Its first run found 428 layout overflows that `analyze` and a
green `build web` had both been perfectly happy with. It needs the server up and the demo
seeded. Three things about it worth knowing before you change it:

- It drives its pumps inside `tester.runAsync`, because the test binding fakes async and
  the screens' real HTTP calls would otherwise never resolve.
- There is no Manrope or Inter under `flutter test`, so every glyph is an em square and
  strings measure 2–3× their real width. That makes it a strict overflow test, not a
  faithful one: check a genuine near-miss in the browser against `docs/screens/` before
  reworking a layout to satisfy it.
- It draws each screen's **first** view, which for a long time meant Settings was only ever
  checked on Work types. A layout fault in a later section rendered a blank panel that every
  check was happy with, so the test now walks all eleven Settings sections. A screen that
  hides content behind a tab needs the same treatment; drawing it once proves less than it
  looks like it does.

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
