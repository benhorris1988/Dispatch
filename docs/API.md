# Dispatch API contract

Convention (mirrors the Badminton project): one PHP file per resource under `/api`, called with
`POST` and a JSON body `{"action": "...", ...params}`, header `Authorization: Bearer <JWT>`.
Every response is `{status:"ok", ...}` or `{status:"error", message}` with an HTTP code
(400 validation, 401 auth, 403 role, 404 missing, 409 conflict/guardrail, 422 missing param, 500).
Every endpoint begins:

```php
require_once __DIR__ . '/db_connect.php';      // $conn + helpers (lib.php)
require_once __DIR__ . '/auth_middleware.php'; // $userId, $userName, $wsId, $role, $personId
$action = param('action', 'list');
```

Helpers in `lib.php`: `param`, `require_param`, `rows/row/scalar/insert/update`, `ok/fail`,
`audit`, `notify`, `notify_person`, `add_trigger`, `require_role`, `has_role`,
`add_working_days`, `working_days_between`, `week_start`, `today()` (honours `fake_today` in config).
**Always filter by `workspace_id = $wsId`.** Every mutation writes an `audit_events` row.
Dates are `YYYY-MM-DD` strings; timestamps `YYYY-MM-DD HH:MM:SS`; money in whole currency units
(annual_value 210000 → the client shows £210k). JSON columns are decoded before returning.

Roles rank: viewer < requester < team_member < benefit_owner < team_lead < delivery_lead < admin.

## Shared shapes

```
Person       {id, name, initials, colour, role_title, tagline, team_id, team_name, days_per_week, working_pattern{Mon..Fri hours},
              pattern_label, max_concurrent, min_focus_days, prefers, avoid, line_manager, active, email}
WorkTypeRef  {id, name, plural, prefix, colour, policy}
WorkItemRow  {id, ref, title, work_type_id, type_name, type_colour, type_policy, size_stamp, size_name, is_custom,
              custom_effort_days, status, health, priority_score, benefit_value, rom_low, rom_high, rom_unit,
              skills:[{skill_id,name,min_proficiency}], needed_by, earliest_start, planned_from, planned_to,
              assignees:[{person_id,initials,colour,name}], requested_by, sponsor, progress_pct, created_at, updated_at}
Assignment   {id, plan_version_id, work_item_id, ref, title, type_colour, type_name, size_stamp, person_id, from_date, to_date,
              allocation_pct, state, role_label, locked, fixed_person, fixed_dates, is_reserve, note}
Change       {id, proposal_id, person:{id,name,initials,colour}, work_item:{id,ref,title}, kind, headline, before:{label,person_id,from,to,allocation_pct},
              after:{...}, reason, stability_cost_days, inside_freeze, impact_chips:[{label,tone}], affected_people:[Person-lite],
              guardrail_status, guardrail_reason, decision, decided_by_name, decided_at, decision_reason, acknowledged_at,
              ack_required, awaiting_ack}
```

`ack_required` is written at commit time from the policy switch `require_ack_inside_horizon`
(CHG-06); `awaiting_ack` is `ack_required && !acknowledged_at` on an accepted or edited change.
Both are added by `changes.php`; other endpoints' Change shapes omit them.

## auth.php  (exists)
`list_dev_users`, `dev_login{user_id}`, `oidc_login{id_token}`, `me`.

## workspace_config.php — workspace vocabulary and policy (CFG-*)
(Named `workspace_config.php` because `api/config.php` is the gitignored secrets file.)
- `get` → `{workspace, work_types:[{...all columns, item_count, open_item_count}], size_classes:[{...}], incident_size_classes:[...], policy:{... objective_weights{}, priority_weights{} decoded}, day_rates:[...]}`
- `save_work_type{id?, name, plural, prefix, colour, policy, requires_estimate, requires_benefit, default_size_stamp, allowed_sizes, description}` (admin) → `{work_type}`; audit `config`.
- `reorder_work_types{ids:[...]}` (admin)
- `retire_work_type{id, retype_to_id?}` (admin): 409 with `{open_items}` when open items use it and no `retype_to_id` (CFG-03); with it, bulk re-types then retires.
- `save_size_class{id?, work_type_id?, name, stamp, min_days, max_days, planning_days, default_estimate_class, granularity, counts_for_wip, is_custom}` (admin): validates non-overlapping bands within scope → 409 message like "This size band overlaps Medium. Change the start of Large to 16 days or the end of Medium to 15." (CFG-05)
- `delete_size_class{id}` (admin; 409 if items use it)
- `save_policy{...policy fields, objective_weights, priority_weights}` (admin): inserts a NEW version row (is_current=1, previous set 0) → `{policy}`; adds trigger type policy class manual.
  `priority_weights` keys: `value, urgency, riskCompliance, dependencyLeverage, age, confidenceScale{high,medium,low}, severityScores{P1..P4}` and, for BEN-02,
  `qualitativeValuePerPoint` — the currency-equivalent of one qualitative scale point for a non-financial benefit with no proxy value (default 25000, read by `engine/priority.php` and `benefits.php`).
- `export` → `{config: {...Appendix A JSON shape}}`; `import{config}` (admin, CFG-10).
- `save_workspace{name, time_zone, working_days, hours_per_day, currency}` (admin)
- `save_day_rate{id?, name, rate, currency, effective_from, is_blended}` (admin)

## people.php — team, skills, availability, loans (TEAM-*)
- `list{team_id?, portfolio_id?, include_inactive?}` → `{people:[Person + {load_pct (next 4 weeks, from committed plan), skills:[{skill_id, proficiency}], on_rota_weeks:[...], loans:[Loan], on_loan_to: Loan|null, loaned_from: Loan|null}], teams:[{id,name,lead_person_id,portfolio_id,portfolio_name}], scope:{kind:'workspace'|'team'|'portfolio', team_id, portfolio_id, name, team_ids}}`
  With `team_id` or `portfolio_id` (TEAM-09) the list is that scope's **planning pool**: its home members plus anyone loaned into it up to the end of the modelled horizon. A borrowed person carries `loaned_from` (the loan that brings them in); `on_loan_to` is the loan that moves a person elsewhere *today*, or null; `loans` is every loan touching today..horizon. `load_pct` in a scoped list weights each person by the scope's share of them (a 50% loan counts half for each team). 404 for an unknown team or portfolio.
- `get{id}` → `{person + {loans:[Loan] (90 days back to the horizon), on_loan_to}, skills:[{skill_id,name,category,proficiency,endorsed_by:[names],certified,development_target,pairing_enabled,single_point (bool: this person is the only one ≥3)}], assignments:[Assignment (committed plan, from today)], availability:[...], rota:[week_start...], stats:{load_pct_4w, concurrent_now, concurrent_max, changes_8w, team_median_changes_8w, next_rota_week}, change_history:[{week_start, changes, inside_freeze}] (8 weeks), stability_note}`
- `save{id?, ...Person fields, team_id}` (team_lead; a team_member may save only their own person) → `{person}`
- `deactivate{id}` (admin): sets active=0; flags future assignments → returns `{flagged_assignments}` and, when there were any, `urgent_replan` (STAB-05; scoped to everyone still active plus the leaver, so their work can be offered to somebody else).
- `set_skill{person_id, skill_id, proficiency, certified?, development_target?, pairing_enabled?}` (own or team_lead)
- `endorse_skill{person_id, skill_id}` (team_lead) appends endorser.
- `add_availability{person_id, from_date, to_date, type, fraction?}` (own or team_lead) → recompute capacity_days for the range; add trigger `leave` (class urgent if from_date within freeze horizon, else batched). NEVER store a reason (ADM-05). An urgent trigger also starts a scoped replan cycle immediately (STAB-05) and the reply carries `urgent_replan:{proposal_id, changes, held, scope_person_ids}` (or `{skipped}` when there was nothing to replan). A failure there never fails this request.
- `delete_availability{id}` (409 if source != manual — imported records can be corrected not deleted, TEAM-07)
- `set_rota{week_start, person_id}` / `clear_rota{week_start, person_id}` (team_lead) → recompute capacity.
- `capacity{person_id?, from, to, team_id?}` → `{days:[{person_id, day, available_hours, reserve_hours, assigned_hours, team_share?, team_available_hours?}]}`. With `team_id`, each day also says what share of it belongs to that team (1 for a home member with no loan, the loan's share for a borrowed person or a lent one, 0 when the person is entirely elsewhere) and the hours that share is worth. `capacity_days` itself never changes for a loan.
- `recompute_capacity{from?, to?}` (team_lead) → derives capacity_days for everyone (TEAM-10) → `{days_written}`

### Loans (TEAM-09)
```
Loan  {id, person_id, person_name, from_team_id, from_team_name, to_team_id, to_team_name, from_date, to_date (inclusive),
       allocation_pct (1..100: the share of the person's time that moves), share (allocation_pct/100), reason, created_by, created_at}
```
A loan lends a person to another team for a dated period at a share of their time. It does **not** write to
`capacity_days`: the person still has the same hours, and which team those hours belong to is resolved at read
time (`engine/capacity.php team_pool()` / `team_share_for()`). For the loan's dates and share the person's
capacity belongs to the borrowing team and they are eligible for its work (see `build_model` `team_id` /
`portfolio_id` in ENGINE_MODEL.md). `reason` is a business reason — never personal data (ADM-05).
- `add_loan{person_id, to_team_id, from_date, to_date, allocation_pct?=100, reason?}` (delivery_lead+, or a team_lead whose own person sits in or leads either team) → `{loan, trigger:{id, class}, freeze_horizon_end, urgent_replan?}`. The person's current team is the lending team. 400 when `to_date < from_date`, the share is outside 1..100, or the target is the person's own team; 409 with `{overlaps: Loan}` when it overlaps another loan of the same person (a person is lent to one place at a time). Audited; raises a `leave`-class trigger for the person — batched, or **urgent when from_date is inside the freeze horizon** (the same rule as `add_availability`), in which case a scoped cycle starts and `urgent_replan` reports it (a whole-workspace cycle moves nothing for a loan and reports `skipped`).
- `end_loan{id, to_date?}` (same authority) → `{loan, trigger}`. Ends a loan early: `to_date` must satisfy `from_date ≤ to_date ≤ current to_date` (400 otherwise — extending is a new loan); omitted, the loan ends yesterday. A loan that happened is history and is never deleted; a loan that has **not started yet** is cancelled outright (`{loan:null, cancelled:true}`). Audited; `leave` trigger, urgent when the days handed back fall inside the freeze horizon.
- `loans{person_id? | team_id?, from?, to?}` → `{loans:[Loan], window}` — loans touching the window (default today to the end of the modelled horizon); `team_id` matches the lending or the borrowing side.

## skills.php — catalogue + matrix (TEAM-01, TEAM-04)
- `list{team_id?, portfolio_id?, include_retired?}` → `{skills:[{id,name,category,description,retired,people_at_3_plus,demand_days_6w,supply_days_6w,single_point}], scope}`
- `matrix{team_id?, portfolio_id?}` → `{skills:[...as list], people:[Person-lite + load_pct + loaned_in], cells:{ "<person_id>:<skill_id>": {proficiency, certified, development_target, pairing_enabled} }, summary:{single_point_skills:[names], two_person_skills:[names], well_covered:int, team_name}, scope, availability_4w:[{person, label, from, to, type, days, kind:'leave'|'training'|'pattern'|'rota'}], development:[{person, skill, from_level, to_level, pairing_enabled, note}], demand_vs_supply:[{skill, demand_days, supply_days, exceeds}]}`
  demand = sum over open items requiring the skill of remaining effort share in the next 6 weeks (planned assignment days on items requiring the skill); supply = qualified people's capacity days in 6 weeks.
  With `team_id` / `portfolio_id` (TEAM-09) people, cells, coverage counts and supply are the scope's planning pool (home members plus anyone loaned in, `loaned_in: true`), with supply weighted by the scope's share of each person-day. Demand for **unscheduled** work stays workspace-wide, because an unscheduled item belongs to no team yet.
- `save{id?, name, category, description}` (admin), `merge{from_id, into_id}` (admin), `retire{id}` (admin).

## portfolios.php — groups of teams for cross-team views and planning (TEAM-09, SCH-13)
A portfolio is a named grouping of teams within a workspace; a team belongs to at most one (`teams.portfolio_id`).
Reads are open to every signed-in role; edits are admin.
- `list` → `{portfolios:[{id, name, description, lead_person_id, lead_name, teams:[{id, name, lead, headcount, loaned_in, loaned_out, load_pct, available_hours, assigned_hours}], team_count, headcount, load_pct, available_hours, assigned_hours}], unassigned_teams:[...], window}` — load over the next four weeks from the committed plan, each person weighted by the team's share of them.
- `overview{portfolio_id}` → `{portfolio, teams:[team + Figures + {people:[{person_id, available_hours, assigned_hours, load_pct, home, share_days}]}], totals: Figures, loans:[Loan] (touching the portfolio's teams in the planned window), window:{from, to, planned_end}, target_load_min, target_load_max, definitions}` — the cross-team view: every team side by side, and the portfolio computed **the same way as a team** (not summed), so `totals.headcount = Σ teams`, `totals.available_hours = Σ teams`, `totals.assigned_hours = Σ teams` hold by arithmetic while `single_skill_deps` can be *smaller* than any team's (the other team covers the skill) and a loan between two of its teams is neither in nor out.
  ```
  Figures {headcount (home members), pool_size, loaned_in, loaned_out (people lent into / out of this set of teams within the window),
           available_hours, assigned_hours, load_pct (next 4 weeks, share-weighted),
           single_skill_deps, single_skill_names (skills the set's committed work needs in the planned window that exactly one pooled person holds at the level),
           stability_index, moved_days_4w, total_days_4w (STAB-08 restricted to the set's own people),
           open_proposals (pending changes in the open proposal naming one of the set's own people)}
  ```
- `save{id?, name, description?, lead_person_id?}` (admin) → `{portfolio + teams}`; 409 on a duplicate name.
- `delete{id}` (admin): 409 with `{teams}` while any team still references it.
- `add_team{portfolio_id, team_id}` (admin) → `{team, portfolio}` — moves the team if it was in another portfolio; `remove_team{team_id}` (admin) → `{team}` (409 when it is in none).
- Every mutation is audited (`portfolio`, `team`).

## work_items.php — pipeline (PIP-*, REQ-*, VIEW-08)
- `list{status?, type_id?, size_stamp?, skill_id?, team_id?, q?, sort?, dir?, scheduled?:'yes'|'no', limit?, offset?}` → `{items:[WorkItemRow], total, counts:{all, unscheduled, scheduled, in_progress, delivered, needs_estimate, needs_benefit, skills_gap}, queue_health:{needs_estimate:{count, oldest_days}, needs_benefit:{...}, skills_gap:{...}}}`
- `get{ref | id}` → `{item: WorkItemRow + {summary, requirements_text, tags:[...], severity, risk_weight, priority_terms{...}, priority_override{points, pinned_score, reason, expires, by}, owner_person_id, external_url, external_ref, external_link (REQ-05, below) | null, delivered_at, actual_effort_days, ready_at},
   skills:[{skill_id,name,min_proficiency,effort_days,note,coverage_count,coverage_label ("4 people at L3 or above"), single_point, qualified:[Person-lite]}],
   dependencies:{needs:[{id,ref,title,type,status,health,needed_by,cleared_at}], unblocks:[...]},
   plan:{planned_from, planned_to, assignees:[Person-lite], changes_30d, stability_label, enters_committed_on, slack_days, needed_by},
   estimate: latest Estimate + {expected, sd, p80, implied_stamp, cost_likely, cost_low, cost_high} | null, estimate_count,
   benefits:[Benefit], benefit_total, benefit_confidence, blended_cost (PERT expected days x day rate), payback_months (blended_cost / (benefit_total / 12)),
   tasks:[{id,title,size_stamp,effort_days,skill_name,sequence,status}], tasks_rollup_days,
   assignments:[Assignment (committed plan)], comments:[{id,author_name,body,created_at}],
   readiness:{items:[{key,label,done}], ready:bool}, history_count}`
- `create{title, work_type_id, size_stamp?, custom_effort_days?, summary?, tags?, requested_by?, sponsor?, needed_by?, earliest_start?, skills:[{skill_id,min_proficiency}]?, benefit?:{type,annual_value,confidence,realisation_from,owner_name}, severity?}` (requester) → allocates ref from ref_sequences (PIP-02), status per policy (needs_estimate if requires_estimate else needs_benefit if requires_benefit else ready; interrupt types → ready with priority from severity), computes priority, audit, trigger intake (urgent for interrupt types). → `{item}`, plus `urgent_replan` for an interrupt type (STAB-05: an incident starts a scoped cycle immediately instead of waiting for the nightly run; a failure there never fails the intake).
- `update{id, ...fields}` (requester on own draft; team_lead otherwise) → history via audit with before/after per field (PIP-11).
- `set_external_link{id | ref, url, external_ref?, system?, reason?}` (team_lead) / `clear_external_link{id | ref}` (team_lead) — REQ-05. Stores
  `external_url` (absolute http(s), ≤400 chars) and `external_ref` (≤60; `ref` is accepted for it only when the item was addressed by `id`,
  because `ref` is otherwise the item lookup key). Both audited as field `external_link`. `system` ∈ jira | servicenow | sharepoint |
  azure_devops | other is **inferred from the URL host** on every read (atlassian.net → jira, service-now.com → servicenow,
  sharepoint.com → sharepoint, dev.azure.com / visualstudio.com → azure_devops, else other); there is no column for it, so an explicit
  `system` is validated, echoed with a `system_note` and kept on the audit row, but a later `get` shows the inferred one.
  → `{external_link, item}`. `get` returns
  `external_link: {url, ref, system, system_label, badge:{state, live, source, label, note, last_seen_at, times_seen?, source_name?}}`.
  **The badge is honest about liveness.** No Jira / ServiceNow / SharePoint integration exists, so for a link a person typed in the badge
  is `{state:'link_only', live:false, note:'No integration for <System> is connected; this is a link.'}`. The one genuinely live case is an
  item `intake.php` raised from a ticket system: `intake_log` records every post, so the badge is `{state:'raised'|'duplicate_seen', live:true,
  source:'intake_log', source_name, last_seen_at, times_seen}` — Dispatch's own record of what the caller posted, never the ticket's current
  state in the source system, and the `note` says so. Delete the intake source and the badge falls back to `link_only`.
- `set_status{id, status, reason?}` validates transitions against type policy (PIP-04): e.g. ready requires readiness complete; delivered requires actual_effort_days → sets delivered_at, trigger `delivered`; blocked/cancelled OK any time. 409 with message when invalid.
- `history{id}` → `{events:[{occurred_at, actor_name, action, field?, before, after, reason}]}` (from audit_events entity 'work_item' + estimates/benefits/assignments touching the item)
- `add_task/update_task/delete_task{...}`, `rollup_tasks{id}` → sets custom_effort_days from task sum & creates estimate version method rollup.
- `add_dependency{from_id, to_id, type}` (cycle detection → 409), `remove_dependency{id}`
- `set_skill_requirement{id, skill_id, min_proficiency, effort_days?, note?}` / `remove_skill_requirement{id, skill_id}`
- `add_comment{id, body}` → `{comment}`; @mentions of person names create notifications.
- `request_estimate{id, note?}` (team_lead) → `{requested:true, notified:int, to:'owner'|'team_lead'|'nobody', item}`; raises
  `estimate_requested` (NOT-01) to the item's owner, or to every team lead when it has none. 409 when the item is
  delivered or cancelled. `notified` counts the rows actually written, so a recipient who has turned the kind off
  in-app is not reported as told. The same notification is raised automatically whenever `set_status` or `create`
  leaves an item in `needs_estimate`.
- `override_priority{id, points?|pinned_score?, reason, expires}` (delivery_lead) / `clear_override{id}`; recompute score.
- `log_progress{id, progress_pct, effort_days?, note?}` (team_member) → progress_logs + item progress_pct.
- `similar{id}` → `{items:[{ref,title,size_stamp,estimated_days,actual_days,delivered_at,estimate_id}]}` (same size + overlapping skills, delivered) (EST-08)
- `bulk{ids:[...], op:'retype'|'resize'|'tag'|'cancel'|'assign_owner', value}` (team_lead) (PIP-10)
- `recompute_priorities` (delivery_lead) → runs priority scoring for all open items (see engine/priority.php) → `{updated}`.

## estimates.php (EST-*)
- `list` → `{items:[WorkItemRow + {estimate_class, likely, expected, p80, method, version, updated_at, author_name}], calibration}` (for the Estimates nav page: items needing estimate first, then recent).
- `get{work_item_id}` → `{item:WorkItemRow, latest:Estimate+derived, versions:[Estimate+derived], calibration:{by_stamp:[{stamp, n, median_ratio}], recommendation:string, large_over_pct}, similar:[...], day_rate, classes:[{class,label:'±30%',description}]}`
- `save{work_item_id, method, optimistic?, likely?, pessimistic?, size_stamp?, estimate_class, day_rate?, assumptions?, reason?, skill_split:[{skill_id?,label,days}]?}` (team_lead or owner) → new version; if method size uses planning value; updates item size_class if implied stamp differs?? — NO: keep item size; return `implied_stamp`. Upward re-estimate adds trigger `estimate` (STAB-09). Moves status needs_estimate → needs_benefit/ready per policy. Returns `{estimate}`.
- Derived maths: expected = (o + 4m + p)/6; sd = (p − o)/6; p80 = expected + 0.8416·sd; class tolerance {5:50,4:40,3:30,2:15,1:5}%; cost = likely × day_rate; range = cost × (1 ± tol).

## benefits.php (BEN-*)
- `list{type?, owner?, status?, quarter?, work_item_id?}` → `{benefits:[Benefit + {ref,title,item_status,item_type_colour,item_type_name}], totals:{in_plan, in_pipeline, realised_ytd, at_risk, at_risk_count, items_without_case, items_without_case_note, items_total, items_with_benefits, benefit_count, added_this_quarter, target_annual, target_pct, year, non_financial_count, qualitative_proxy_total}, by_type:[{type,label,colour,value,count}], by_quarter:[{quarter, label, planned, realised, planned_in_quarter, realised_in_quarter, confirmed}], by_owner:[{owner_name, owner_person_id, count, value, realised}], priority_note, types:[...], qualitative_scales:[{scale, label}], qualitative_value_per_point}`.
  **Money totals are financial-only** (`in_plan`, `in_pipeline`, `at_risk`, `added_this_quarter`): a non-financial benefit's proxy is a
  stand-in for the priority score, not a forecast anyone will be asked to realise. The register says "plus N non-financial benefits" from
  `non_financial_count`, and `qualitative_proxy_total` is Σ `proxy_value ?? qualitative_scale × per-point default` over them (BEN-02).
- `Benefit` = `{id, work_item_id, type, type_label, type_colour, annual_value, currency, confidence, is_financial, qualitative_scale, qualitative_label, proxy_value, realisation_from, realisation_quarter, owner_person_id, owner_name, narrative, status, realised_value, created_at}`.
- `save{id?, work_item_id, type, is_financial? (default true), annual_value, currency?, confidence, qualitative_scale?, proxy_value?, realisation_from, owner_person_id?, owner_name?, narrative?, status?}` (benefit_owner) → `{benefit, priority_score, priority_terms}`; recomputes item priority.
  BEN-02: `qualitative_scale` is 1 minor · 2 useful · 3 significant · 4 major · 5 transformational (labels published in `list.qualitative_scales`,
  so the client does not invent them). A **non-financial** benefit (`is_financial:false`) **must** carry a scale (422 otherwise, with the valid
  scale in the body), may carry a `proxy_value` (a non-negative currency-equivalent stand-in) and defaults `annual_value` to 0. A financial one
  still needs `annual_value`; any `proxy_value` sent for it is dropped. Switching a benefit back to financial clears the proxy.
- `delete{id}`; `record_realisation{benefit_id, quarter, realised_value}` (benefit_owner) → updates benefit status.
- `export_csv` → `{csv, rows, filename}` — columns include Financial (Yes/No), Qualitative scale, Qualitative label and Proxy value.

## plan.php — schedule, versions, assignments (VIEW-01..05, SCH-06/07, CHG-05)
- `schedule{from?, to?, plan_version_id?, team_id?, type_id?, skill_id?, item_id?, overlay_proposal_id?}` → `{plan_version:{id,version_no,status,committed_at,committed_through}, windows:{today, freeze_end (last committed day), planned_end, indicative_end}, weeks:[{week_start, label:'w/c 7 Sep', state:'committed'|'planned'|'indicative'}], people:[Person-lite + {load_pct (for the visible horizon), days_per_week}], assignments:[Assignment], availability:[{person_id, from_date, to_date, type, label}], rota:[{person_id, week_start}], unscheduled:[WorkItemRow (top by priority)], unscheduled_count, moved_assignment_ids:[...] (when overlay)}`  Default from = Monday of this week, to = +6 weeks. Load% = assigned hours / capacity over visible range.
- `versions` → `{versions:[PlanVersion + {assignment_count, change_count}]}`; `version{id}` → assignments.
- `restore{plan_version_id, reason}` (delivery_lead): copies the version into a new committed version (CHG-05).
- `move_assignment{assignment_id, from_date, to_date, person_id?, allocation_pct?, preview:bool, reason?}` (delivery_lead; inside freeze horizon requires `reason`, 409 otherwise with message "Inside the freeze horizon. Ask a delivery lead to approve, or move the start to Monday …"): when preview → `{knock_on:[{ref,title,person,from,to,effect}], stability_cost_days, inside_freeze, warnings:[...]}` computed by the heuristic (engine/planner.php `preview_move`); when not preview → creates a new committed plan version = current + the move (+ knock-on if `apply_knock_on`), records a manual change_proposal with decision accepted, person_change_log, stability_weeks, notifications. (SCH-07)
- `fix_assignment{assignment_id, fixed_person, fixed_dates}` / `unfix` (delivery_lead) (SCH-06)
- `lock_state` → `{committed_through, next_proposal_at, last_proposal_at, open_changes}` (for the header pill)

## replan.php — the engine entry points (SCH-*, STAB-*)
- `propose{kind:'manual'|'nightly'|'urgent', scope_person_ids?:[...], engine?:'heuristic'|'cpsat'}` (delivery_lead) → builds model from DB, runs planner (engine/planner.php, or the Python CP-SAT service if configured and requested), diffs against the committed plan, costs stability, applies guardrails, stores plan_version (proposed) + proposal + change_proposals + summary; expires/supersedes the previous open proposal noting carry-over (CHG-08). → `{proposal_id, changes, held, improvement_pct, below_threshold, summary_before, summary_after, solver_stats}`
  **Planning scope (SCH-13, engine side done; endpoint wiring pending):** `build_model()` accepts `team_id` or `portfolio_id` (see ENGINE_MODEL.md). `propose` and `preview` should pass them through so a cycle can be run for one team, for a portfolio's teams together, or for the whole workspace as now. A scoped model still yields a **complete** workspace candidate (rows of people outside the scope pass through unchanged), so it stores and commits like any other.
- `preview{changes:[...hypothetical: add_item{work_item_id}, remove_item, person_away{person_id,from,to}]}` → heuristic what-if within 2 s → `{summary_before, summary_after, changes:[Change-lite]}` (SCH-08, SCH-11 lite)
- `scenario_save{name, changes, team_id?|portfolio_id?}` → plan_versions status scenario, the planning scope stored in `solver_stats.scope` and echoed as `scope` on each scenario; `scenarios` list; `scenario_adopt{id}` → becomes a proposal, re-run under the saved scope.
- `run_nightly` (CLI or cron_key) — same as propose kind nightly, plus priority recompute + capacity derivation + stability_weeks roll-up. Also `cron.php` CLI wrapper.
  `steps` additionally carries:
  `auto_apply:{enabled, applied, leftover, plan_version_id?, skipped?, blocked?}` (CHG-07 — when `auto_apply_outside_horizon`
  is on, pending changes that pass every guardrail and fall wholly outside the freeze horizon are accepted and
  committed without review, each audited with action `auto_apply`; a proposal below `min_improvement_pct` is never
  auto-applied (STAB-04), and anything left over is re-proposed so it still reaches a reviewer);
  `realisation_due:{due, notified, already_told}` (NOT-01 — a benefit whose `realisation_from` has passed with no
  confirmed realisation, once per benefit ever, to the benefit owner or else to the delivery leads);
  `watch_list_notices:{entries, notified, repeats_suppressed}` (NOT-01 — a watch-list entry naming a person, or an
  item they own, at most once per entry per week).
- `watch_list` → `{items:[{kind:'skills_gap'|'no_estimate'|'over_capacity'|'late'|'single_point'|'reestimate', title, body, suggestion, link, tone}]}` (SCH-05, edge cases 8.13)
  `reestimate` entries (EST-09) are added by this endpoint only, from `reestimate_class_threshold`; `overview.php`
  builds its watch list from `engine/watchlist.php` and does not carry them.

## changes.php — proposals and review (CHG-*)
- `current` → `{proposal:{id, kind, generated_at, status, triggers:[{type,label}], summary_before, summary_after, improvement_pct, below_threshold, carried_over_note, budget:{used, limit, per_person:[{person, used}]}}, changes:[Change], held:[Change], awaiting_ack:[Change], guardrails:[{key,label,detail,enabled}], counts:{proposed, held, pending, awaiting_ack}}` — the open proposal (or the latest decided one with `status`).
  `awaiting_ack` lists the committed changes whose affected person has not acknowledged them yet (CHG-06); it is
  empty when `require_ack_inside_horizon` is off, because the switch is read at commit time and recorded per change.
- `list{status?}` → past proposals; `get{id}`.
- `decide{change_id, decision:'accepted'|'rejected', reason?}` (delivery_lead): a change with guardrail_status needs_approval requires `reason`; held_budget/held_threshold require admin (override) + reason else 409 with the guardrail message. Accepting applies the change into a new committed plan version (or accumulates: see `commit`).
   Implementation: decisions are recorded on the change; `commit{proposal_id}` (delivery_lead) materialises all accepted changes into a new committed plan version (copy current committed → apply each accepted change's after_json), marks proposal decided, notifies affected people (kind change_committed; urgent if inside_freeze), writes person_change_log + stability_weeks, audit. `decide` returns `{change, proposal_counts}`; the client calls `commit` when done ("Accept N selected" = decide each then commit).
   `commit` also: sets `ack_required` on every accepted inside-freeze change when `require_ack_inside_horizon` is on (CHG-06);
   raises `item_assigned` (NOT-01) for anyone the commit gives work they did not already hold; and refuses with **409**
   `{message:"Re-estimate required before entering the committed window: …", reestimate_blocked:[{change_id, work_item_id, ref, estimate_class, threshold}]}`
   when `reestimate_class_threshold` is set and an accepted change would move an item with a worse estimate class into
   the committed window (EST-09). Returns `{proposal, plan_version, committed, stability_week, ack_required, items_assigned}`.
   The implementation is `api/engine/commit.php`, shared with replan.php's nightly auto-apply.
- `accept_all_passing{proposal_id}` → decides accepted for every pending change with guardrail_status ok, then commits.
- `reject_all{proposal_id}`.
- `edit{change_id, after:{person_id?, from, to, allocation_pct?}, reason}` → recost stability (engine), decision 'edited' + accepted.
- `acknowledge{change_id}` (the affected team member) → acknowledged_at.
- `comment{change_id, body}`; `mine` → `{changes:[Change affecting $personId, last 8 weeks], pending_ack:[...]}` (STAB-07, My week banner).

## overview.php (VIEW-06)
- `get` → `{today, workspace_name, people_count, committed:{count, due_this_week, delta_vs_last_fortnight, items:[WorkItemRow + {due, status_label}]}, load:{pct, target_min, target_max, band_label}, stability:{index_pct, delta_pts, definition}, reserve:{used_pct, reserve_pct, open_incidents}, proposals:{count, items:[Change-lite {id, person, headline, sub}]}, watch_list:[...], effort_by_week:[{week_start,label, by_type:[{type,colour,days}], unallocated_days}], next_proposal_at}`
- `my_week{week_start?}` (mobile My week) → `{person, week:{days:[{date, label, dow, assignments:[Assignment+{pct_of_day, progress_pct, day_n, day_total, with:[names]}], hours_available, hours_assigned, leave}]}, changes_affecting:[Change], reserve:{pct, hours_week, used_hours}, coming_up:[Assignment], load_pct}`

## reports.php (REP-*)
- `get{range:'4w'|'12w'|'12m'}` → `{stability:[{week_start,label,index_pct,changes_inside_freeze,note}], this_week_index, load:[{week_start,label,planned_pct,actual_pct,above_90}], accuracy:{points:[{ref,stamp,estimated,actual,group:'sm'|'lc'}], median_sm, median_lc, n}, delivered:[{month,label,by_type:[{type,colour,count}]}], cycle_time_delta_pct, definitions:{stability:..., load:..., accuracy:..., delivered:...}}`
- `export_csv{report}` → `{csv}`

## notifications.php
- `list` → `{notifications:[{id, kind, title, body, link, urgent, channel, created_at, read_at, read}], unread}`; `mark_read{id|all}`; `prefs` / `save_prefs{kind, in_app, push, email_digest, teams, digest}`
- Eight kinds, all of them generated: the seven of NOT-01 — `change_proposed` and `approval_requested` by `replan.php propose`;
  `change_committed` and `item_assigned` by `changes.php commit`; `estimate_requested` by `work_items.php`
  (`request_estimate`, or any move into `needs_estimate`); `realisation_due` and `watch_list` by `replan.php run_nightly` — plus
  `digest`, the weekly digest itself when it is delivered in-app (NOT-04, `digest.php`). The `in_app` switch on `digest` decides whether a
  digest that cannot be emailed is written at all; `email_digest` on *any* kind makes the user a recipient of the weekly run.
- `lib.php notify()` reads `dbo.notification_prefs` before writing (NOT-02). The row is the in-app copy, so in-app is
  the floor: **with in-app off for that kind nothing is written at all**, and `notify()` returns null. `channel` records
  the route the user's switches select — `digest` when an email digest on a daily or weekly cadence will carry it,
  `teams` when Teams is on, otherwise `in_app`. An urgent notification never rides a digest and stays `in_app` (NOT-03).
  Push is not a channel value: `notify()` also queues one `push_deliveries` row per active device through
  `engine/push_lib.php` (MOB-04, see `devices.php`); whether that is ever sent depends on provider credentials. A user with no preference row for a kind
  gets the documented default (in-app on), which is the same default `prefs` shows.

## digest.php — weekly digest per person (NOT-04)
- `preview` → your own digest, composed now, nothing sent (any role); `preview{user_id}` (team_lead+) → someone else's.
  → `{digest, transport: 'smtp'|'php_mail'|null, delivery_note}`.
- `digest` = `{user:{id,name,email,person_id,person_name}, workspace, generated_at, period:{today, week_from (next Monday), week_to (Sunday), label, capacity_days}, since, since_is_default, last_digest_at,
  summary:{has_person, assignments, effort_days, capacity_days, load_pct, leave, changes, awaiting_ack, watch_list, carried_notifications}, summary_line, subject, empty,
  next_week:[{assignment_id, work_item_id, ref, title, type_name, type_colour, status, from_date, to_date, in_week_from, in_week_to, days_in_week, allocation_pct, effort_days, role_label, is_reserve, starts_in_week, finishes_in_week, needed_by, priority_score, link}],
  leave:[{from_date, to_date, type, label, fraction}]  (type and label only — never a reason, ADM-05),
  changes:[{at, ref, title, kind, kind_label, headline, reason, week_start, inside_freeze, assignment_days, change_proposal_id, link, source:'person_change_log'|'change_proposals'}],
  awaiting_ack:[{change_proposal_id, proposal_id, headline, reason, ref, title, inside_freeze, decided_at, link}],
  watch_list:[{kind, title, body, suggestion, tone, link}]  (entries whose person_id is the user's person),
  carried_notifications:[{id, kind, title, body, link, created_at, read}]  (this user's notifications with channel='digest' since `since` — the NOT-02 preference finally consumed),
  text, html}`.
  "Next week" is Monday–Sunday after the week containing `today()` (the planner's date) and assignments come from the **committed** plan, clipped
  to the week. "Since" is `users.last_digest_at`, or seven days of real time before now on a first digest (`since_is_default:true`).
- `send{user_id}` (admin) → one digest; `send` (admin) → everyone active with `email_digest` on for any kind and cadence not `off`
  (`digest_recipients()`). Also runnable without a session from the CLI (`cron_digest.php`) or with `cron_key`.
  → `{transport, recipients, emailed, in_app, undelivered, results:[{user_id, name, email, delivered, sent, transport, in_app, notification_id, reason, since, last_digest_at, subject, summary}], note}`.
  **Delivery is reported, never assumed.** `sent` is true only when a configured transport (`engine/mail_lib.php`) accepted the mail. With no
  transport — this repository ships none — the digest is written to `dbo.notifications` as kind `digest`, title = subject, body = `summary_line`,
  link `/my-week`, and the result says `{sent:false, in_app:true, reason:'no mail transport configured'}`. With the user's in-app switch for
  `digest` off as well, `delivered:false` and the reason says so. `users.last_digest_at` advances **only when something was delivered**, so an
  undelivered digest's changes are still in the next one. Every send is audited (`entity:'digest'`, `action:'send'`, after = what happened).
- Weekly job: `cron_digest.php [--workspace=N] [--user=N]` (CLI), documented for Task Scheduler in the file header (Friday 16:00).

## devices.php — device registrations for push (MOB-04)
- `register{platform: ios|android|web, token, device_label?}` → `{device, created, push}`: upsert on `token` for the signed-in
  user (a device that signs in as someone else is re-homed to them; audited with the reason). `unregister{token}` deactivates
  (own device; an admin may deactivate any in the workspace; another workspace's token is a 404). `list{all?}` → own devices —
  `all:true` shows the workspace to an admin — with `push:{fcm, apns, configured, note}` saying whether this server has a sender.
  `test_push` queues a test to the caller's active devices and dispatches at once (409 with no device). `deliveries{limit?, all?}`.
- Device shape `{id, user_id, user_name, platform, token_hint, device_label, created_at, last_seen_at, active}` — the token is
  never returned whole. Delivery shape `{id, notification_id, device_token_id, platform, title, body, link, status, attempts,
  next_attempt_at, last_status, created_at, sent_at}`; `status` is `pending|sent|failed|abandoned|unconfigured`.
- **Honesty rule**: a row is `sent` only after FCM or APNs answered 2xx. With no `push.*` keys in `config.php` the dispatcher
  marks it `unconfigured` and `last_status` names the key to set. `cron_push.php` (CLI, Task Scheduler every minute) dispatches.

## v1.php — public read-only REST API (INT-07)
Routed by `router.php` from `/v1/*`; same bearer token as the app; `GET` only (anything else → 405).
Errors are RFC 9457 problem details (`application/problem+json`). Lists page with `?limit=` (1–200)
and an opaque `cursor` returned as `page.next_cursor`.
- `/v1` → index of resources and the webhook event names; `/v1/openapi.yaml` → the OpenAPI 3.1 document (`docs/openapi.yaml`).
- `/v1/work-items{?status,type,updated_since}`, `/v1/work-items/{ref}`, `/v1/people`, `/v1/skills`, `/v1/plan` (newest committed version),
  `/v1/assignments{?plan_version_id,person_id,from,to}` — the version must belong to the workspace and be committed or superseded (proposals and scenarios are 404),
  `/v1/proposals`, `/v1/benefits` (carries `is_financial`, `qualitative_scale`, `proxy_value`), `/v1/estimates`, `/v1/reports/stability`.

## webhooks.php — outbound webhooks (INT-07), admin only
- `list` → subscriptions, recent deliveries and the event catalogue (`plan.committed`, `proposal.created`, `change.decided`, `workitem.statusChanged`).
- `save{id?, url, events, description?, active?}` (creates with a generated secret, returned once), `rotate_secret{id}`, `delete{id}`, `test{id}` (ping, dispatched immediately),
  `deliveries{subscription_id?, status?}`, `retry{delivery_id}`, `run` (scan the audit log and dispatch what is due — also the `cron_webhooks.php` path).
- Deliveries carry `X-Dispatch-Event`, `X-Dispatch-Delivery` and `X-Dispatch-Signature: sha256=<HMAC-SHA256 of the raw body>`; back-off 1 min → 5 min → 30 min → 2 h → 6 h, then `abandoned`. At-least-once; events are derived from `audit_events` behind a per-workspace cursor.

## calendar.php — per-person iCalendar feed (VIEW-09, INT-04)
- `GET /api/calendar.php?token=…` → `text/calendar` of that person's committed assignments, authorised by the token alone. Leave is never included (ADM-05).
- `POST {action: my_feed}` (bearer) → your feed URL, creating the token on first call; `revoke` → invalidates it.

## intake.php — inbound incident intake (INT-02)
- `POST /api/intake.php?source=<id>` with header `X-Dispatch-Intake-Secret` and a JSON incident `{external_ref, title, severity, description?, url?}` → creates an interrupt-type work item above the source's severity threshold, priority from severity (P1–P4), starts an urgent cycle; idempotent on `external_ref` (a repost answers 200 with the existing item and is logged as `duplicate_seen`).
- Bearer, admin: `list` (sources with their log), `save{id?, name, work_type_id?, severity_threshold, active?}` (a new source's secret is generated and returned once), `delete{id}`, `log{source_id?}`.
- The intake log is what `work_items.php get.external_link.badge` reads for an intake-raised item (REQ-05).

## retention.php — data retention (ADM-05, NFR-DATA-02)
- `get` → `{plan_history_months (24), audit_retention_years (7), last_run_at, older_than_policy:{plan_versions, audit_events}}`.
- `save{plan_history_months, audit_retention_years}` (admin), `preview` (what a purge would remove; removes nothing), `purge{confirm:true}` (admin; also `cron_retention.php` CLI for every workspace).
- Never purged: the committed plan, the newest superseded version, any version a proposal references, and work items, people, benefits or estimates.

## audit.php
- `list{entity?, q?, from?, to?, limit?, offset?}` (admin) → `{events, total}`; `export_csv`.

## Engine library (api/engine/) — pure PHP, no HTTP
- `capacity.php`: `derive_capacity($conn,$wsId,$from,$to,$personIds=null)` writes capacity_days. TEAM-09: `scope_team_ids($conn,$wsId,['team_id'|'portfolio_id'])`, `loans_in_window(...)`, `team_pool($conn,$wsId,$teamIds,$from,$to)` (home members + loaned-in people, with their loans), `team_share_for($poolEntry,$day)` (0..1 share of that person-day belonging to the team set), `team_load($conn,$wsId,$teamIds,$from,$to)` (share-weighted capacity, assigned hours and load per person and in total).
- `priority.php`: `compute_priority_scores($conn,$wsId)` implements section 8.4 (value 40 / urgency 25 / risk 15 / leverage 10 / age 10, confidence scale, P90 normalisation, severity for interrupt types, override, nightly rescale so top ≈ 100). Stores priority_score + priority_terms JSON `{value:{input,normalised,weight,contribution}, urgency:{...}, risk:{...}, leverage:{...}, age:{...}, override:{...}, raw_total, scaled}`.
  BEN-02: the Value term sums, per benefit and confidence-scaled, `annual_value` for a financial benefit and `proxy_value ?? qualitative_scale × qualitativeValuePerPoint` for a
  non-financial one (`items_lib.php benefit_priority_value()`; the per-point default is `priority_weights.qualitativeValuePerPoint`, 25000 when unset). The term records its
  working so the item page can show it: `value:{input, input_raw, p90, normalised, weight, contribution, financial, qualitative, proxy_used, qualitative_source:'proxy'|'scale_default'|'mixed'|null, qualitative_value_per_point, non_financial_count}`,
  where `input = financial + qualitative`.
  For an **interrupt** item (BEN-04) the five planned terms are marked `skipped:'interrupt policy'` with a zero
  contribution, and the score comes from `severity:{input:'P1', label, normalised, weight:100, contribution}`. The same
  contribution is republished as the `urgency` term with `alias_of:'severity'`, so a breakdown that renders only the
  five planned terms reproduces the score instead of drawing five empty bars; anything summing the terms must skip a
  term carrying `alias_of`.
- `model.php`: `build_model($conn,$wsId,$opts)` → arrays: people (capacity per day incl. reserve and the scope's `share`, skills, maxConcurrent, minFocus, prefs, `home`, `loans`), items (remaining effort per policy planAt, granularity, required skills, deps, earliest start, needed_by, priority, interrupt flag, `external`), committed assignments, policy, windows, `scope`. `$opts.team_id` / `$opts.portfolio_id` build a team or portfolio model (SCH-13); neither = the whole workspace as one pool. Returns null for an unknown workspace, team or portfolio.
- `commit.php`: `commit_proposal($conn,$wsId,$proposal,$opts)` materialises accepted changes into a new committed version (CHG-05/06, EST-09, NOT-01); `auto_apply_outside_horizon($conn,$wsId,$proposalId)` is the nightly CHG-07 pass; `reestimate_blocked_changes(...)` is the EST-09 gate. Shared by changes.php and replan.php.
- `planner.php`: `heuristic_plan($model, $opts)` list scheduling per 8.9 (respects all hard constraints in 8.5; incoming work the policy counts as small — `remaining_days <= small_fill_threshold_days` — is queued ahead of larger incoming work so it fills the gaps the kept committed work leaves (STAB-10); never moves committed/locked; extend-in-place for upward re-estimates (STAB-09); incidents consume reserve then displace lowest-priority planned work of that person (SCH-10); `scope_person_ids` for urgent cycles) → candidate assignments + unscheduled reasons + objective terms (8.6).
- `diff.php`: `diff_plans($committed,$candidate,$model)` → list of changes with kind, before/after, stability_cost_days (assignment-days moved inside committed+planned windows; indicative = 0), inside_freeze, affected people; `objective_delta`.
- `guardrails.php`: `apply_guardrails($changes,$proposalImprovementPct,$policy)` → guardrail_status per change (needs_approval inside freeze; held_budget when a person's moved days in a week exceed change_budget_days; held_threshold when improvement < min_improvement_pct) + budget usage.
- `explain.php`: `explain_change($change,$model,$triggers)` → headline + plain-English reason + impact chips (e.g. "Stability cost 2 assignment-days", "Due date unchanged", "Inside freeze horizon · needs your approval", "Skills risk reduced", "Benefit realised 1 week earlier").
- `summary.php`: `plan_summary($assignments,$model)` → {late_items, value_quarter, people_over_100, single_skill_deps, assignment_days_changed, total_assignment_days, stability_index}.
- `mail_lib.php`: `mail_transport()` → `'smtp'|'php_mail'|null` from `api/config.php` (`smtp.host` selects a minimal built-in SMTP client — EHLO, STARTTLS, AUTH LOGIN;
  `mail.php_mail` selects PHP `mail()`); `mail_send($to,$subject,$text,$html,$inApp?)` → `{sent, transport, reason, in_app, notification_id}`. `sent` is true only when a
  transport accepted the message; otherwise, given `$inApp = {conn, workspace_id, user_id, body, link}`, it writes an in-app notification of kind `digest` (honouring that
  user's in-app switch for the kind) and says so. Nothing in this repository configures a transport.
- `cpsat_client.php`: POSTs the model to `engine_url`/solve when configured; falls back to heuristic on error/timeout and records `solver_stats.fallback`.
- `push_lib.php`: `push_queue($conn,$wsId,$userId,$title,$body,$link,$notificationId)` — called by `notify()`, one row per active device, never fails the caller; `push_dispatch($conn,$wsId,$limit)` sends via FCM HTTP v1 (service-account OAuth2, RS256) or APNs (ES256 provider token, HTTP/2), deactivates dead tokens, backs off 1m/5m/30m then abandons, and marks `unconfigured` when no sender is configured; `push_config()` reports what is configured and why not.

## Python engine (engine/) — optional CP-SAT service
FastAPI on 127.0.0.1:8010: `POST /solve {model, budget_seconds}` → `{assignments, objective, terms, solve_seconds, proved_optimal, status}`; `GET /health`. Same model JSON as build_model. Implements 8.8.
