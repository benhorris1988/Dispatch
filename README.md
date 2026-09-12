# Dispatch — delivery planning and resource management

Dispatch holds a team's pipeline of work (projects, small changes, incidents, service requests), its
skills and availability, rough-order-of-magnitude estimates and business benefits, and schedules the
work automatically — treating **plan stability** as a first-class objective. The engine never edits
the committed plan: it *proposes* changes with a reason and a stability cost, and a person commits.

Built from *Dispatch — Requirements and Design v0.1* (8 Sep 2026). This repository is the local
implementation on the same stack as the Badminton project it was modelled on:

| Layer | Implementation |
|---|---|
| Client | Flutter (`mobile/`): desktop web planning views (Overview, Pipeline, Work item, Schedule, Changes, Team & skills, Person, Estimate, Benefits, Reports, Settings) and phone layout (My week, Pipeline, Changes, Add work) from one codebase |
| API | PHP 8.2 (`api/`), one file per resource, `POST {"action"}` + JWT. Dev sign-in locally; Entra ID OIDC when configured |
| Database | Microsoft SQL Server (`DispatchDB` on `localhost\LIVE`), schema in `db/01_schema.sql` |
| Scheduling engine | Heuristic list scheduler, diff, stability costing, guardrails and explainer in PHP (`api/engine/`); optional CP-SAT solver service in Python/OR-Tools (`engine/`) |

## Running it locally

```bash
# 1. Database (Windows auth to the LIVE instance). Edit the two placeholder passwords first
#    and put the same values in api/config.php.
sqlcmd -S "localhost\LIVE" -E -i db/00_create_database.sql
sqlcmd -S "localhost\LIVE" -E -i db/01_schema.sql

# 2. Secrets
cp api/config.example.php api/config.php      # fill in jwt_secret, db, db_admin

# 3. Demo data (Data Platform team, 8 people, committed plan + open proposal; "today" = Tue 8 Sep 2026)
C:\xampp\php\php.exe seed_demo.php

# 4. API + web app on http://localhost:8090
powershell -ExecutionPolicy Bypass -File run_local.ps1

# 5. Web build (once, and after client changes)
cd mobile
flutter build web --release --base-href=/mobile/build/web/ --dart-define=API_BASE=http://localhost:8090/api
# then open http://localhost:8090/  → redirects to the app
```

Optional CP-SAT solver: `cd engine && python -m pip install -r requirements.txt && python -m uvicorn
app:app --port 8010`; set `engine_url` in `api/config.php`. Without it every cycle uses the PHP
heuristic (the R1 behaviour in the roadmap).

Nightly cycle (propose at 02:00): schedule `C:\xampp\php\php.exe cron.php` in Task Scheduler, or press
**Propose replan now** in the app.

Optional Apache serving instead of the built-in server — add to `httpd.conf`:
`Alias /dispatch "C:/xampp/htdocs/dispatch"` plus a `<Directory>` block allowing it, and build the web
app with `--base-href=/dispatch/mobile/build/web/`.

## Repository layout

```
api/            PHP endpoints (auth, workspace_config, work_items, estimates, benefits, people, skills,
                plan, replan, changes, overview, reports, notifications, audit) + engine/ library
db/             00_create_database.sql, 01_schema.sql (schema of record)
docs/           API.md (contract), ENGINE_MODEL.md (solver model), requirements extract
engine/         Python FastAPI + OR-Tools CP-SAT service (optional)
mobile/         Flutter app
tests/          PHP CLI suites run against the local server
seed_demo.php   Wipe-and-reseed demo data (CLI only)
cron.php        Nightly propose cycle (CLI only)
```

## Sign-in

Locally, `dev_login_enabled` lets you pick any seeded user (delivery lead, admin, each team member, a
requester, a benefit owner) so every role can be exercised. Production sign-in is Entra ID (OIDC):
set `entra.tenant_id`, `entra.client_id` and `entra.group_roles` in `api/config.php`; `auth.php`
verifies the ID token against the tenant JWKS and maps group claims to roles.

See `docs/API.md` for every endpoint and `CLAUDE.md` for the things that are easy to get wrong.
