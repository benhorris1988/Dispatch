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
              guardrail_status, guardrail_reason, decision, decided_by_name, decided_at, decision_reason, acknowledged_at}
```

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
- `export` → `{config: {...Appendix A JSON shape}}`; `import{config}` (admin, CFG-10).
- `save_workspace{name, time_zone, working_days, hours_per_day, currency}` (admin)
- `save_day_rate{id?, name, rate, currency, effective_from, is_blended}` (admin)

## people.php — team, skills, availability (TEAM-*)
- `list` → `{people:[Person + {load_pct (next 4 weeks, from committed plan), skills:[{skill_id, proficiency}], on_rota_weeks:[...]}], teams:[{id,name,lead_person_id}]}`
- `get{id}` → `{person, skills:[{skill_id,name,category,proficiency,endorsed_by:[names],certified,development_target,pairing_enabled,single_point (bool: this person is the only one ≥3)}], assignments:[Assignment (committed plan, from today)], availability:[...], rota:[week_start...], stats:{load_pct_4w, concurrent_now, concurrent_max, changes_8w, team_median_changes_8w, next_rota_week}, change_history:[{week_start, changes, inside_freeze}] (8 weeks), stability_note}`
- `save{id?, ...Person fields, team_id}` (team_lead; a team_member may save only their own person) → `{person}`
- `deactivate{id}` (admin): sets active=0; flags future assignments → returns `{flagged_assignments}`.
- `set_skill{person_id, skill_id, proficiency, certified?, development_target?, pairing_enabled?}` (own or team_lead)
- `endorse_skill{person_id, skill_id}` (team_lead) appends endorser.
- `add_availability{person_id, from_date, to_date, type, fraction?}` (own or team_lead) → recompute capacity_days for the range; add trigger `leave` (class urgent if from_date within freeze horizon, else batched). NEVER store a reason (ADM-05).
- `delete_availability{id}` (409 if source != manual — imported records can be corrected not deleted, TEAM-07)
- `set_rota{week_start, person_id}` / `clear_rota{week_start, person_id}` (team_lead) → recompute capacity.
- `capacity{person_id?, from, to}` → `{days:[{person_id, day, available_hours, reserve_hours, assigned_hours}]}`
- `recompute_capacity{from?, to?}` (team_lead) → derives capacity_days for everyone (TEAM-10) → `{days_written}`

## skills.php — catalogue + matrix (TEAM-01, TEAM-04)
- `list` → `{skills:[{id,name,category,description,retired,people_at_3_plus,demand_days_6w,supply_days_6w,single_point}]}`
- `matrix` → `{skills:[...as list], people:[Person-lite + load_pct], cells:{ "<person_id>:<skill_id>": {proficiency, certified, development_target, pairing_enabled} }, summary:{single_point_skills:[names], two_person_skills:[names], well_covered:int}, availability_4w:[{person, label, from, to, type, days, kind:'leave'|'training'|'pattern'|'rota'}], development:[{person, skill, from_level, to_level, pairing_enabled, note}], demand_vs_supply:[{skill, demand_days, supply_days, exceeds}]}`
  demand = sum over open items requiring the skill of remaining effort share in the next 6 weeks (planned assignment days on items requiring the skill); supply = qualified people's capacity days in 6 weeks.
- `save{id?, name, category, description}` (admin), `merge{from_id, into_id}` (admin), `retire{id}` (admin).

## work_items.php — pipeline (PIP-*, REQ-*, VIEW-08)
- `list{status?, type_id?, size_stamp?, skill_id?, team_id?, q?, sort?, dir?, scheduled?:'yes'|'no', limit?, offset?}` → `{items:[WorkItemRow], total, counts:{all, unscheduled, scheduled, in_progress, delivered, needs_estimate, needs_benefit, skills_gap}, queue_health:{needs_estimate:{count, oldest_days}, needs_benefit:{...}, skills_gap:{...}}}`
- `get{ref | id}` → `{item: WorkItemRow + {summary, requirements_text, tags:[...], severity, risk_weight, priority_terms{...}, priority_override{points, pinned_score, reason, expires, by}, owner_person_id, external_url, delivered_at, actual_effort_days, ready_at},
   skills:[{skill_id,name,min_proficiency,effort_days,note,coverage_count,coverage_label ("4 people at L3 or above"), single_point, qualified:[Person-lite]}],
   dependencies:{needs:[{id,ref,title,type,status,health,needed_by,cleared_at}], unblocks:[...]},
   plan:{planned_from, planned_to, assignees:[Person-lite], changes_30d, stability_label, enters_committed_on, slack_days, needed_by},
   estimate: latest Estimate + {expected, sd, p80, implied_stamp, cost_likely, cost_low, cost_high} | null, estimate_count,
   benefits:[Benefit], benefit_total, benefit_confidence, blended_cost (PERT expected days x day rate), payback_months (blended_cost / (benefit_total / 12)),
   tasks:[{id,title,size_stamp,effort_days,skill_name,sequence,status}], tasks_rollup_days,
   assignments:[Assignment (committed plan)], comments:[{id,author_name,body,created_at}],
   readiness:{items:[{key,label,done}], ready:bool}, history_count}`
- `create{title, work_type_id, size_stamp?, custom_effort_days?, summary?, tags?, requested_by?, sponsor?, needed_by?, earliest_start?, skills:[{skill_id,min_proficiency}]?, benefit?:{type,annual_value,confidence,realisation_from,owner_name}, severity?}` (requester) → allocates ref from ref_sequences (PIP-02), status per policy (needs_estimate if requires_estimate else needs_benefit if requires_benefit else ready; interrupt types → ready with priority from severity), computes priority, audit, trigger intake (urgent for interrupt types). → `{item}`
- `update{id, ...fields}` (requester on own draft; team_lead otherwise) → history via audit with before/after per field (PIP-11).
- `set_status{id, status, reason?}` validates transitions against type policy (PIP-04): e.g. ready requires readiness complete; delivered requires actual_effort_days → sets delivered_at, trigger `delivered`; blocked/cancelled OK any time. 409 with message when invalid.
- `history{id}` → `{events:[{occurred_at, actor_name, action, field?, before, after, reason}]}` (from audit_events entity 'work_item' + estimates/benefits/assignments touching the item)
- `add_task/update_task/delete_task{...}`, `rollup_tasks{id}` → sets custom_effort_days from task sum & creates estimate version method rollup.
- `add_dependency{from_id, to_id, type}` (cycle detection → 409), `remove_dependency{id}`
- `set_skill_requirement{id, skill_id, min_proficiency, effort_days?, note?}` / `remove_skill_requirement{id, skill_id}`
- `add_comment{id, body}` → `{comment}`; @mentions of person names create notifications.
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
- `list{type?, owner?, status?, quarter?}` → `{benefits:[Benefit + {ref,title,type_colour}], totals:{in_plan, realised_ytd, at_risk, items_without_case, items_total, added_this_quarter, target_pct}, by_type:[{type,label,colour,value}], by_quarter:[{quarter, planned, realised}], by_owner:[{owner_name, count, value}]}`
- `save{id?, work_item_id, type, annual_value, currency?, confidence, qualitative_scale?, realisation_from, owner_person_id?, owner_name?, narrative?, status?}` (benefit_owner) → recompute item priority.
- `delete{id}`; `record_realisation{benefit_id, quarter, realised_value}` (benefit_owner) → updates benefit status.
- `export_csv` → `{csv}` (string)

## plan.php — schedule, versions, assignments (VIEW-01..05, SCH-06/07, CHG-05)
- `schedule{from?, to?, plan_version_id?, team_id?, type_id?, skill_id?, item_id?, overlay_proposal_id?}` → `{plan_version:{id,version_no,status,committed_at,committed_through}, windows:{today, freeze_end (last committed day), planned_end, indicative_end}, weeks:[{week_start, label:'w/c 7 Sep', state:'committed'|'planned'|'indicative'}], people:[Person-lite + {load_pct (for the visible horizon), days_per_week}], assignments:[Assignment], availability:[{person_id, from_date, to_date, type, label}], rota:[{person_id, week_start}], unscheduled:[WorkItemRow (top by priority)], unscheduled_count, moved_assignment_ids:[...] (when overlay)}`  Default from = Monday of this week, to = +6 weeks. Load% = assigned hours / capacity over visible range.
- `versions` → `{versions:[PlanVersion + {assignment_count, change_count}]}`; `version{id}` → assignments.
- `restore{plan_version_id, reason}` (delivery_lead): copies the version into a new committed version (CHG-05).
- `move_assignment{assignment_id, from_date, to_date, person_id?, allocation_pct?, preview:bool, reason?}` (delivery_lead; inside freeze horizon requires `reason`, 409 otherwise with message "Inside the freeze horizon. Ask a delivery lead to approve, or move the start to Monday …"): when preview → `{knock_on:[{ref,title,person,from,to,effect}], stability_cost_days, inside_freeze, warnings:[...]}` computed by the heuristic (engine/planner.php `preview_move`); when not preview → creates a new committed plan version = current + the move (+ knock-on if `apply_knock_on`), records a manual change_proposal with decision accepted, person_change_log, stability_weeks, notifications. (SCH-07)
- `fix_assignment{assignment_id, fixed_person, fixed_dates}` / `unfix` (delivery_lead) (SCH-06)
- `lock_state` → `{committed_through, next_proposal_at, last_proposal_at, open_changes}` (for the header pill)

## replan.php — the engine entry points (SCH-*, STAB-*)
- `propose{kind:'manual'|'nightly'|'urgent', scope_person_ids?:[...], engine?:'heuristic'|'cpsat'}` (delivery_lead) → builds model from DB, runs planner (engine/planner.php, or the Python CP-SAT service if configured and requested), diffs against the committed plan, costs stability, applies guardrails, stores plan_version (proposed) + proposal + change_proposals + summary; expires/supersedes the previous open proposal noting carry-over (CHG-08). → `{proposal_id, changes, held, improvement_pct, below_threshold, summary_before, summary_after, solver_stats}`
- `preview{changes:[...hypothetical: add_item{work_item_id}, remove_item, person_away{person_id,from,to}]}` → heuristic what-if within 2 s → `{summary_before, summary_after, changes:[Change-lite]}` (SCH-08, SCH-11 lite)
- `scenario_save{name, ...preview payload}` → plan_versions status scenario; `scenarios` list; `scenario_adopt{id}` → becomes a proposal.
- `run_nightly` (CLI or cron_key) — same as propose kind nightly, plus priority recompute + capacity derivation + stability_weeks roll-up. Also `cron.php` CLI wrapper.
- `watch_list` → `{items:[{kind:'skills_gap'|'no_estimate'|'over_capacity'|'late'|'single_point', title, body, suggestion, link, tone}]}` (SCH-05, edge cases 8.13)

## changes.php — proposals and review (CHG-*)
- `current` → `{proposal:{id, kind, generated_at, status, triggers:[{type,label}], summary_before, summary_after, improvement_pct, below_threshold, carried_over_note, budget:{used, limit, per_person:[{person, used}]}}, changes:[Change], held:[Change], guardrails:[{key,label,detail,enabled}], counts:{proposed, held, pending}}` — the open proposal (or the latest decided one with `status`).
- `list{status?}` → past proposals; `get{id}`.
- `decide{change_id, decision:'accepted'|'rejected', reason?}` (delivery_lead): a change with guardrail_status needs_approval requires `reason`; held_budget/held_threshold require admin (override) + reason else 409 with the guardrail message. Accepting applies the change into a new committed plan version (or accumulates: see `commit`).
   Implementation: decisions are recorded on the change; `commit{proposal_id}` (delivery_lead) materialises all accepted changes into a new committed plan version (copy current committed → apply each accepted change's after_json), marks proposal decided, notifies affected people (kind change_committed; urgent if inside_freeze), writes person_change_log + stability_weeks, audit. `decide` returns `{change, proposal_counts}`; the client calls `commit` when done ("Accept N selected" = decide each then commit).
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
- `list` → `{notifications:[...], unread}`; `mark_read{id|all}`; `prefs` / `save_prefs{kind, in_app, push, email_digest, teams, digest}`

## audit.php
- `list{entity?, q?, from?, to?, limit?, offset?}` (admin) → `{events, total}`; `export_csv`.

## Engine library (api/engine/) — pure PHP, no HTTP
- `capacity.php`: `derive_capacity($conn,$wsId,$from,$to,$personIds=null)` writes capacity_days.
- `priority.php`: `compute_priority_scores($conn,$wsId)` implements section 8.4 (value 40 / urgency 25 / risk 15 / leverage 10 / age 10, confidence scale, P90 normalisation, severity for interrupt types, override, nightly rescale so top ≈ 100). Stores priority_score + priority_terms JSON `{value:{input,normalised,weight,contribution}, urgency:{...}, risk:{...}, leverage:{...}, age:{...}, override:{...}, raw_total, scaled}`.
- `model.php`: `build_model($conn,$wsId,$opts)` → arrays: people (capacity per day incl. reserve, skills, maxConcurrent, minFocus, prefs), items (remaining effort per policy planAt, granularity, required skills, deps, earliest start, needed_by, priority, interrupt flag), committed assignments, policy, windows.
- `planner.php`: `heuristic_plan($model, $opts)` list scheduling per 8.9 (respects all hard constraints in 8.5; fills gaps for small work first (STAB-10); never moves committed/locked; extend-in-place for upward re-estimates (STAB-09); incidents consume reserve then displace lowest-priority planned work of that person (SCH-10); `scope_person_ids` for urgent cycles) → candidate assignments + unscheduled reasons + objective terms (8.6).
- `diff.php`: `diff_plans($committed,$candidate,$model)` → list of changes with kind, before/after, stability_cost_days (assignment-days moved inside committed+planned windows; indicative = 0), inside_freeze, affected people; `objective_delta`.
- `guardrails.php`: `apply_guardrails($changes,$proposalImprovementPct,$policy)` → guardrail_status per change (needs_approval inside freeze; held_budget when a person's moved days in a week exceed change_budget_days; held_threshold when improvement < min_improvement_pct) + budget usage.
- `explain.php`: `explain_change($change,$model,$triggers)` → headline + plain-English reason + impact chips (e.g. "Stability cost 2 assignment-days", "Due date unchanged", "Inside freeze horizon · needs your approval", "Skills risk reduced", "Benefit realised 1 week earlier").
- `summary.php`: `plan_summary($assignments,$model)` → {late_items, value_quarter, people_over_100, single_skill_deps, assignment_days_changed, total_assignment_days, stability_index}.
- `cpsat_client.php`: POSTs the model to `engine_url`/solve when configured; falls back to heuristic on error/timeout and records `solver_stats.fallback`.

## Python engine (engine/) — optional CP-SAT service
FastAPI on 127.0.0.1:8010: `POST /solve {model, budget_seconds}` → `{assignments, objective, terms, solve_seconds, proved_optimal, status}`; `GET /health`. Same model JSON as build_model. Implements 8.8.
