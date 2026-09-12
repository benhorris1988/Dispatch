# Database — DispatchDB (Microsoft SQL Server)

Dispatch runs on **Microsoft SQL Server**, not PostgreSQL. Locally that is the named instance
`localhost\LIVE` and the database `DispatchDB`. PHP talks to it through the `sqlsrv` driver and every
query is `dbo.`-qualified T-SQL.

> The requirements document targets Azure Database for PostgreSQL for a production deployment. This
> implementation deliberately mirrors the local SQL Server stack used by the Badminton project on the
> same box.

## Files

| File | What it is |
|---|---|
| `00_create_database.sql` | Creates the database, the two logins/users and their role memberships. Run once, as an administrator. |
| `01_schema.sql` | **The schema of record.** Idempotent — every object is guarded, so it is safe to re-run after edits. Also creates the reporting views `vw_assignments_committed` and `vw_estimate_accuracy`. |

## Creating the database from scratch

Run all three steps from the repository root, in this order.

```bash
# 1. Database, logins and permissions (Windows auth to the LIVE instance)
sqlcmd -S "localhost\LIVE" -E -i db/00_create_database.sql

# 2. Tables, indexes and views — idempotent, re-run whenever the schema changes
sqlcmd -S "localhost\LIVE" -E -i db/01_schema.sql

# 3. Demo dataset (wipes and reseeds every table; CLI only)
C:\xampp\php\php.exe seed_demo.php
```

### Passwords

The two passwords in `00_create_database.sql` — `CHANGE_ME_APP` for `dispatch_app` and
`CHANGE_ME_ADMIN` for `dispatch_admin` — are **placeholders**, because that file is checked into the
repository. Replace them with real values before running the script, and put the same values in
`api/config.php`, which is gitignored and is the only place real secrets live:

* `db` — the `dispatch_app` credentials used by every API endpoint (reader/writer + EXECUTE).
* `db_admin` — the `dispatch_admin` credentials (db_owner) used only by the CLI scripts through
  `migration_connect.php`.

Do not confuse `api/config.php` (the secrets file) with `api/workspace_config.php` (the endpoint that
serves a workspace's configuration to the client).

## Seeding

`seed_demo.php` is the single entry point. It requires `migration_connect.php`, refuses to run over
HTTP, **deletes every row in every table** and reseeds the identity columns, then rebuilds the whole
demo dataset in three parts:

| File | Contents |
|---|---|
| `seed_demo.php` | Workspace, work types, size classes, scheduling policy, day rates, team, 8 people, 12 users, 12 skills, the skills matrix, availability, the incident rota and derived `capacity_days`. |
| `seed_demo_items.php` | 42 open work items and 46 delivered ones, skill requirements, the WI-1042 tasks, dependencies, estimates, 31 benefits and their quarterly realisations. |
| `seed_demo_plan.php` | Plan versions v1–v7 (v6 committed, v7 the candidate), assignments, the open nightly proposal and its eight changes, replan triggers, stability weeks, the person change log, notifications, audit events, comments, progress logs and integration rows. |

The demo "today" is **Tuesday 8 September 2026** and the committed plan runs through **Friday
18 September 2026**. `today()` in `api/lib.php` honours the `fake_today` key in `api/config.php`;
remove that key for live use.

Re-running the seed is safe and idempotent — object ids are identical on every run because the
identity columns are reseeded first.

## Checking a seeded database

```bash
sqlcmd -S "localhost\LIVE" -E -d DispatchDB -W -Q "
  SELECT
    (SELECT COUNT(*) FROM dbo.work_items WHERE status NOT IN ('delivered','cancelled')) AS open_items,
    (SELECT COUNT(*) FROM dbo.work_items WHERE status IN ('draft','needs_estimate','needs_benefit','ready')) AS unscheduled,
    (SELECT COUNT(*) FROM dbo.work_items WHERE status = 'needs_estimate') AS needs_estimate,
    (SELECT COUNT(*) FROM dbo.plan_versions WHERE status = 'committed') AS committed_plans,
    (SELECT COUNT(*) FROM dbo.change_proposals) AS change_proposals,
    (SELECT COUNT(*) FROM dbo.stability_weeks) AS stability_weeks"
```

Expected: 42 open items, 18 unscheduled, 6 needing an estimate, exactly 1 committed plan version
(v6, with assignments for all 8 people), 8 change proposals on one open proposal, and 12
stability weeks.

## Schema conventions

* Every tenant-scoped table carries `workspace_id`; API code must always filter on it.
* Dates are `DATE` (working days); timestamps are `DATETIME2` in Europe/London local time.
* Money is stored in whole currency units; the client does the formatting (£210k).
* Availability rows carry a **type only** (`leave|training|sickness|other`) — never a reason (ADM-05).
* `ref_sequences` holds the next reference number per prefix (`WI`, `INC`, `SR`).
