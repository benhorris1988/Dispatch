-- Dispatch — schema of record (SQL Server). Idempotent: safe to re-run.
-- Every tenant-scoped table carries workspace_id. Dates are DATE (working days);
-- timestamps are DATETIME2 in Europe/London local time (matches the box's SQL clock).
USE DispatchDB;
GO
SET NOCOUNT ON;

IF OBJECT_ID('dbo.workspaces') IS NULL
CREATE TABLE dbo.workspaces (
  id INT IDENTITY(1,1) PRIMARY KEY,
  name NVARCHAR(120) NOT NULL,
  time_zone NVARCHAR(64) NOT NULL DEFAULT 'Europe/London',
  working_days NVARCHAR(40) NOT NULL DEFAULT 'Mon,Tue,Wed,Thu,Fri',
  hours_per_day DECIMAL(4,2) NOT NULL DEFAULT 7.5,
  currency CHAR(3) NOT NULL DEFAULT 'GBP',
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.users') IS NULL
CREATE TABLE dbo.users (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  email NVARCHAR(200) NOT NULL,
  display_name NVARCHAR(120) NOT NULL,
  short_name NVARCHAR(40) NULL,                -- "Ben A."
  role NVARCHAR(30) NOT NULL DEFAULT 'viewer',  -- admin|delivery_lead|team_lead|team_member|benefit_owner|requester|viewer
  person_id INT NULL,                           -- FK added after people
  directory_object_id NVARCHAR(64) NULL,
  active BIT NOT NULL DEFAULT 1,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  CONSTRAINT uq_users_email UNIQUE (workspace_id, email)
);

IF OBJECT_ID('dbo.work_types') IS NULL
CREATE TABLE dbo.work_types (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  name NVARCHAR(60) NOT NULL,
  plural NVARCHAR(60) NOT NULL,
  prefix NVARCHAR(8) NOT NULL,
  colour CHAR(7) NOT NULL,
  policy NVARCHAR(12) NOT NULL DEFAULT 'planned',   -- planned|interrupt
  requires_estimate BIT NOT NULL DEFAULT 1,
  requires_benefit BIT NOT NULL DEFAULT 0,
  default_size_stamp CHAR(1) NULL,
  allowed_sizes NVARCHAR(20) NULL,                  -- e.g. 'S' or 'S,M'; NULL = all
  size_unit NVARCHAR(6) NOT NULL DEFAULT 'days',    -- days|hours (per-type size override)
  description NVARCHAR(300) NULL,
  requirements_template NVARCHAR(MAX) NULL,
  sort_order INT NOT NULL DEFAULT 0,
  retired BIT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.size_classes') IS NULL
CREATE TABLE dbo.size_classes (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  work_type_id INT NULL REFERENCES dbo.work_types(id),  -- NULL = workspace default scope; set = override for that type
  name NVARCHAR(40) NOT NULL,
  stamp CHAR(1) NOT NULL,
  min_days DECIMAL(6,2) NULL,        -- in the scope's unit (days, or hours for hour-based overrides)
  max_days DECIMAL(6,2) NULL,        -- NULL = open-ended
  planning_days DECIMAL(6,2) NULL,   -- used until an estimate exists
  default_estimate_class TINYINT NOT NULL DEFAULT 3,
  granularity NVARCHAR(8) NOT NULL DEFAULT 'day',  -- halfDay|day|week
  counts_for_wip BIT NOT NULL DEFAULT 1,
  is_custom BIT NOT NULL DEFAULT 0,
  sort_order INT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.scheduling_policies') IS NULL
CREATE TABLE dbo.scheduling_policies (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  version INT NOT NULL DEFAULT 1,
  is_current BIT NOT NULL DEFAULT 1,
  freeze_horizon_days INT NOT NULL DEFAULT 10,
  planning_horizon_weeks INT NOT NULL DEFAULT 4,
  model_horizon_weeks INT NOT NULL DEFAULT 26,
  change_budget_days INT NOT NULL DEFAULT 5,
  min_improvement_pct DECIMAL(5,2) NOT NULL DEFAULT 5,
  incident_reserve_pct DECIMAL(5,2) NOT NULL DEFAULT 12,
  rota_reserve_pct DECIMAL(5,2) NOT NULL DEFAULT 25,
  propose_cadence NVARCHAR(40) NOT NULL DEFAULT 'daily 02:00',
  commit_cadence NVARCHAR(40) NOT NULL DEFAULT 'weekly Mon 09:00',
  max_concurrent_items INT NOT NULL DEFAULT 2,
  min_focus_days INT NOT NULL DEFAULT 2,
  plan_at NVARCHAR(12) NOT NULL DEFAULT 'mostLikely',   -- mostLikely|p80
  solver_budget_seconds INT NOT NULL DEFAULT 60,
  small_fill_threshold_days DECIMAL(5,2) NOT NULL DEFAULT 3,
  target_load_min INT NOT NULL DEFAULT 80,
  target_load_max INT NOT NULL DEFAULT 90,
  auto_apply_outside_horizon BIT NOT NULL DEFAULT 0,
  require_ack_inside_horizon BIT NOT NULL DEFAULT 1,
  reestimate_class_threshold TINYINT NULL,             -- EST-09: require re-estimate if class worse than this
  objective_weights NVARCHAR(MAX) NOT NULL DEFAULT '{"valueCompletion":1,"lateness":3,"unscheduledValue":5,"loadImbalance":0.5,"contextSwitching":0.5,"stabilityPlanned":2,"preferences":0.2}',
  priority_weights NVARCHAR(MAX) NOT NULL DEFAULT '{"value":40,"urgency":25,"riskCompliance":15,"dependencyLeverage":10,"age":10,"confidenceScale":{"high":1,"medium":0.7,"low":0.4},"severityScores":{"P1":100,"P2":90,"P3":70,"P4":50}}',
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  created_by INT NULL REFERENCES dbo.users(id)
);

IF OBJECT_ID('dbo.teams') IS NULL
CREATE TABLE dbo.teams (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  name NVARCHAR(80) NOT NULL,
  lead_person_id INT NULL
);

IF OBJECT_ID('dbo.people') IS NULL
CREATE TABLE dbo.people (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  team_id INT NULL REFERENCES dbo.teams(id),
  name NVARCHAR(120) NOT NULL,
  initials CHAR(2) NULL,
  email NVARCHAR(200) NULL,
  role_title NVARCHAR(80) NULL,
  tagline NVARCHAR(160) NULL,                -- "Terraform and Databricks lead"
  days_per_week DECIMAL(3,1) NOT NULL DEFAULT 5,
  working_pattern NVARCHAR(200) NOT NULL DEFAULT '{"Mon":7.5,"Tue":7.5,"Wed":7.5,"Thu":7.5,"Fri":7.5}',  -- hours per weekday
  pattern_label NVARCHAR(120) NULL,          -- "Mon–Thu full, Fri half day"
  max_concurrent INT NULL,                   -- NULL = policy default
  min_focus_days INT NULL,
  prefers NVARCHAR(200) NULL,
  avoid NVARCHAR(200) NULL,
  line_manager NVARCHAR(80) NULL,
  colour CHAR(7) NULL,
  directory_object_id NVARCHAR(64) NULL,
  active BIT NOT NULL DEFAULT 1,
  protected_until DATE NULL,                 -- STAB-12
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_users_person')
  ALTER TABLE dbo.users ADD CONSTRAINT fk_users_person FOREIGN KEY (person_id) REFERENCES dbo.people(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_teams_lead')
  ALTER TABLE dbo.teams ADD CONSTRAINT fk_teams_lead FOREIGN KEY (lead_person_id) REFERENCES dbo.people(id);

IF OBJECT_ID('dbo.skills') IS NULL
CREATE TABLE dbo.skills (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  name NVARCHAR(80) NOT NULL,
  category NVARCHAR(60) NULL,
  description NVARCHAR(300) NULL,
  sort_order INT NOT NULL DEFAULT 0,
  retired BIT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.person_skills') IS NULL
CREATE TABLE dbo.person_skills (
  person_id INT NOT NULL REFERENCES dbo.people(id),
  skill_id INT NOT NULL REFERENCES dbo.skills(id),
  proficiency TINYINT NOT NULL DEFAULT 0,      -- 0 None,1 Aware,2 Practitioner,3 Independent,4 Expert
  endorsed_by NVARCHAR(200) NULL,              -- comma list of endorsing person ids
  certified BIT NOT NULL DEFAULT 0,
  development_target TINYINT NULL,             -- target level (TEAM-05)
  pairing_enabled BIT NOT NULL DEFAULT 0,      -- scheduler may pair on matching work
  updated_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  PRIMARY KEY (person_id, skill_id)
);

IF OBJECT_ID('dbo.availability') IS NULL
CREATE TABLE dbo.availability (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  person_id INT NOT NULL REFERENCES dbo.people(id),
  from_date DATE NOT NULL,
  to_date DATE NOT NULL,
  type NVARCHAR(12) NOT NULL,                  -- leave|training|sickness|other  (NEVER a reason — ADM-05)
  fraction DECIMAL(3,2) NOT NULL DEFAULT 1.0,  -- share of the day unavailable
  source NVARCHAR(12) NOT NULL DEFAULT 'manual',  -- manual|hr|calendar
  label NVARCHAR(80) NULL,                     -- display label e.g. "Leave", "Training"
  created_by INT NULL REFERENCES dbo.users(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.incident_rota') IS NULL
CREATE TABLE dbo.incident_rota (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  person_id INT NOT NULL REFERENCES dbo.people(id),
  week_start DATE NOT NULL,                    -- Monday
  CONSTRAINT uq_rota UNIQUE (workspace_id, week_start, person_id)
);

IF OBJECT_ID('dbo.capacity_days') IS NULL
CREATE TABLE dbo.capacity_days (
  workspace_id INT NOT NULL,
  person_id INT NOT NULL REFERENCES dbo.people(id),
  day DATE NOT NULL,
  available_hours DECIMAL(5,2) NOT NULL,       -- after pattern + availability
  reserve_hours DECIMAL(5,2) NOT NULL,         -- incident reserve (12% / 25% on rota)
  derived_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  PRIMARY KEY (person_id, day)
);

IF OBJECT_ID('dbo.work_items') IS NULL
CREATE TABLE dbo.work_items (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  ref NVARCHAR(16) NOT NULL,                   -- WI-1042
  work_type_id INT NOT NULL REFERENCES dbo.work_types(id),
  size_class_id INT NULL REFERENCES dbo.size_classes(id),
  custom_effort_days DECIMAL(6,2) NULL,
  title NVARCHAR(200) NOT NULL,
  summary NVARCHAR(MAX) NULL,
  requirements_text NVARCHAR(MAX) NULL,
  tags NVARCHAR(300) NULL,                     -- comma separated
  status NVARCHAR(20) NOT NULL DEFAULT 'draft', -- draft|needs_estimate|needs_benefit|ready|scheduled|in_progress|blocked|delivered|cancelled
  health NVARCHAR(12) NULL,                    -- on_track|at_risk|late|blocked (derived, cached)
  priority_score DECIMAL(5,1) NULL,            -- 0..100 scaled
  priority_terms NVARCHAR(MAX) NULL,           -- json breakdown of the terms
  priority_override_points INT NULL,           -- ±20
  priority_pinned_score DECIMAL(5,1) NULL,
  priority_override_reason NVARCHAR(300) NULL,
  priority_override_expires DATE NULL,
  priority_override_by INT NULL REFERENCES dbo.users(id),
  risk_weight DECIMAL(3,2) NULL,               -- 0..1
  severity NVARCHAR(4) NULL,                   -- P1..P4 for interrupt-driven
  requested_by NVARCHAR(120) NULL,
  sponsor NVARCHAR(120) NULL,
  owner_person_id INT NULL REFERENCES dbo.people(id),
  needed_by DATE NULL,
  earliest_start DATE NULL,
  ready_at DATETIME2 NULL,
  started_at DATE NULL,
  delivered_at DATE NULL,
  actual_effort_days DECIMAL(6,2) NULL,
  progress_pct INT NOT NULL DEFAULT 0,
  external_url NVARCHAR(400) NULL,
  external_ref NVARCHAR(60) NULL,
  protected_until DATE NULL,
  created_by INT NULL REFERENCES dbo.users(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  updated_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  CONSTRAINT uq_work_items_ref UNIQUE (workspace_id, ref)
);

IF OBJECT_ID('dbo.ref_sequences') IS NULL
CREATE TABLE dbo.ref_sequences (
  workspace_id INT NOT NULL,
  prefix NVARCHAR(8) NOT NULL,
  next_value INT NOT NULL,
  PRIMARY KEY (workspace_id, prefix)
);

IF OBJECT_ID('dbo.tasks') IS NULL
CREATE TABLE dbo.tasks (
  id INT IDENTITY(1,1) PRIMARY KEY,
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  title NVARCHAR(200) NOT NULL,
  size_class_id INT NULL REFERENCES dbo.size_classes(id),
  effort_days DECIMAL(6,2) NULL,
  skill_id INT NULL REFERENCES dbo.skills(id),
  sequence INT NOT NULL DEFAULT 0,
  status NVARCHAR(16) NOT NULL DEFAULT 'todo'   -- todo|doing|done
);

IF OBJECT_ID('dbo.dependencies') IS NULL
CREATE TABLE dbo.dependencies (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  from_work_item_id INT NOT NULL REFERENCES dbo.work_items(id),   -- predecessor (must finish first)
  to_work_item_id INT NOT NULL REFERENCES dbo.work_items(id),     -- successor
  type NVARCHAR(12) NOT NULL DEFAULT 'finish_start',              -- finish_start|soft
  cleared_at DATE NULL,
  CONSTRAINT uq_dependency UNIQUE (from_work_item_id, to_work_item_id)
);

IF OBJECT_ID('dbo.skill_requirements') IS NULL
CREATE TABLE dbo.skill_requirements (
  id INT IDENTITY(1,1) PRIMARY KEY,
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  skill_id INT NOT NULL REFERENCES dbo.skills(id),
  min_proficiency TINYINT NOT NULL DEFAULT 2,
  effort_days DECIMAL(6,2) NULL,
  note NVARCHAR(120) NULL,
  CONSTRAINT uq_skill_req UNIQUE (work_item_id, skill_id)
);

IF OBJECT_ID('dbo.estimates') IS NULL
CREATE TABLE dbo.estimates (
  id INT IDENTITY(1,1) PRIMARY KEY,
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  version INT NOT NULL DEFAULT 1,
  method NVARCHAR(12) NOT NULL DEFAULT 'three_point',   -- size|three_point|rollup
  optimistic DECIMAL(6,2) NULL,
  likely DECIMAL(6,2) NULL,
  pessimistic DECIMAL(6,2) NULL,
  estimate_class TINYINT NOT NULL DEFAULT 3,            -- 5 ±50 … 1 ±5
  day_rate DECIMAL(8,2) NULL,
  assumptions NVARCHAR(MAX) NULL,
  reason NVARCHAR(300) NULL,
  skill_split NVARCHAR(MAX) NULL,                        -- json [{skill_id, label, days}]
  author_user_id INT NULL REFERENCES dbo.users(id),
  author_name NVARCHAR(120) NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  CONSTRAINT uq_estimate_version UNIQUE (work_item_id, version)
);

IF OBJECT_ID('dbo.day_rates') IS NULL
CREATE TABLE dbo.day_rates (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  name NVARCHAR(60) NOT NULL,
  rate DECIMAL(8,2) NOT NULL,
  currency CHAR(3) NOT NULL DEFAULT 'GBP',
  effective_from DATE NOT NULL,
  is_blended BIT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.benefits') IS NULL
CREATE TABLE dbo.benefits (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  type NVARCHAR(20) NOT NULL,                  -- cost_avoidance|productivity|revenue|risk_reduction|compliance|other
  annual_value DECIMAL(12,2) NOT NULL DEFAULT 0,
  currency CHAR(3) NOT NULL DEFAULT 'GBP',
  confidence NVARCHAR(8) NOT NULL DEFAULT 'medium',  -- low|medium|high
  qualitative_scale TINYINT NULL,              -- BEN-02 non-financial 1..5
  realisation_from DATE NULL,
  owner_person_id INT NULL REFERENCES dbo.people(id),
  owner_name NVARCHAR(120) NULL,
  narrative NVARCHAR(MAX) NULL,
  status NVARCHAR(12) NOT NULL DEFAULT 'planned', -- planned|in_flight|realising|realised|at_risk
  realised_value DECIMAL(12,2) NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.benefit_realisations') IS NULL
CREATE TABLE dbo.benefit_realisations (
  id INT IDENTITY(1,1) PRIMARY KEY,
  benefit_id INT NOT NULL REFERENCES dbo.benefits(id),
  quarter NVARCHAR(8) NOT NULL,                -- 'Q1 2027'
  planned_value DECIMAL(12,2) NOT NULL DEFAULT 0,
  realised_value DECIMAL(12,2) NULL,
  confirmed_by INT NULL REFERENCES dbo.users(id),
  confirmed_at DATETIME2 NULL
);

IF OBJECT_ID('dbo.plan_versions') IS NULL
CREATE TABLE dbo.plan_versions (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  version_no INT NOT NULL,
  status NVARCHAR(12) NOT NULL DEFAULT 'proposed',  -- proposed|committed|superseded|discarded|scenario
  engine NVARCHAR(12) NOT NULL DEFAULT 'heuristic', -- heuristic|cpsat|manual|import
  generated_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  generated_by INT NULL REFERENCES dbo.users(id),
  committed_at DATETIME2 NULL,
  committed_by INT NULL REFERENCES dbo.users(id),
  committed_through DATE NULL,                 -- end of the freeze horizon at commit
  policy_version INT NULL,
  inputs_hash NVARCHAR(64) NULL,
  objective_score DECIMAL(12,2) NULL,
  objective_terms NVARCHAR(MAX) NULL,          -- json
  stability_cost_days DECIMAL(8,2) NULL,
  solver_stats NVARCHAR(MAX) NULL,             -- json {solveSeconds, provedOptimal, ...}
  scenario_name NVARCHAR(120) NULL,
  notes NVARCHAR(400) NULL
);

IF OBJECT_ID('dbo.assignments') IS NULL
CREATE TABLE dbo.assignments (
  id INT IDENTITY(1,1) PRIMARY KEY,
  plan_version_id INT NOT NULL REFERENCES dbo.plan_versions(id),
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  person_id INT NOT NULL REFERENCES dbo.people(id),
  from_date DATE NOT NULL,
  to_date DATE NOT NULL,
  allocation_pct INT NOT NULL DEFAULT 100,
  state NVARCHAR(12) NOT NULL DEFAULT 'planned',   -- committed|planned|indicative
  role_label NVARCHAR(40) NULL,                -- 'lead', 'with Sam, Hana', 'phase 2'
  locked_until DATE NULL,
  fixed_by INT NULL REFERENCES dbo.users(id),  -- SCH-06 user-fixed assignment
  fixed_person BIT NOT NULL DEFAULT 0,
  fixed_dates BIT NOT NULL DEFAULT 0,
  is_reserve BIT NOT NULL DEFAULT 0,
  note NVARCHAR(200) NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_assignments_plan_person')
  CREATE INDEX ix_assignments_plan_person ON dbo.assignments(plan_version_id, person_id, from_date);

IF OBJECT_ID('dbo.proposals') IS NULL
CREATE TABLE dbo.proposals (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  candidate_plan_version_id INT NULL REFERENCES dbo.plan_versions(id),
  base_plan_version_id INT NULL REFERENCES dbo.plan_versions(id),
  kind NVARCHAR(10) NOT NULL DEFAULT 'nightly',  -- nightly|urgent|manual|preview
  status NVARCHAR(12) NOT NULL DEFAULT 'open',   -- open|decided|expired|superseded
  generated_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  generated_by INT NULL REFERENCES dbo.users(id),
  improvement_pct DECIMAL(6,2) NULL,
  below_threshold BIT NOT NULL DEFAULT 0,
  summary_before NVARCHAR(MAX) NULL,           -- json {late_items, value_quarter, people_over_100, single_skill_deps, assignment_days_changed, total_assignment_days, stability_index}
  summary_after NVARCHAR(MAX) NULL,
  triggers NVARCHAR(MAX) NULL,                 -- json [{type,label,occurredAt}]
  carried_over_note NVARCHAR(300) NULL,
  scope_person_ids NVARCHAR(200) NULL,         -- urgent cycles: comma list
  engine NVARCHAR(12) NOT NULL DEFAULT 'heuristic',
  decided_at DATETIME2 NULL
);

IF OBJECT_ID('dbo.change_proposals') IS NULL
CREATE TABLE dbo.change_proposals (
  id INT IDENTITY(1,1) PRIMARY KEY,
  proposal_id INT NOT NULL REFERENCES dbo.proposals(id),
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  person_id INT NULL REFERENCES dbo.people(id),
  work_item_id INT NULL REFERENCES dbo.work_items(id),
  kind NVARCHAR(12) NOT NULL DEFAULT 'move',   -- move|extend|reassign|add|remove|split|pair
  headline NVARCHAR(200) NOT NULL,             -- "Start WI-1033 two days later"
  before_json NVARCHAR(MAX) NULL,              -- {label, personId, from, to, allocationPct}
  after_json NVARCHAR(MAX) NULL,
  reason NVARCHAR(400) NULL,                   -- plain-language explanation
  trigger_ids NVARCHAR(100) NULL,
  objective_delta NVARCHAR(MAX) NULL,          -- json {lateness:-1,...}
  stability_cost_days DECIMAL(6,2) NOT NULL DEFAULT 0,
  inside_freeze BIT NOT NULL DEFAULT 0,
  impact_chips NVARCHAR(MAX) NULL,             -- json [{label, tone: ok|warn|info|bad}]
  affected_person_ids NVARCHAR(200) NULL,
  guardrail_status NVARCHAR(16) NOT NULL DEFAULT 'ok',  -- ok|needs_approval|held_budget|held_threshold
  guardrail_reason NVARCHAR(300) NULL,
  decision NVARCHAR(10) NOT NULL DEFAULT 'pending',     -- pending|accepted|rejected|edited
  decided_by INT NULL REFERENCES dbo.users(id),
  decided_at DATETIME2 NULL,
  decision_reason NVARCHAR(300) NULL,
  acknowledged_at DATETIME2 NULL,
  ack_required BIT NOT NULL DEFAULT 0,          -- CHG-06: set at commit when require_ack_inside_horizon is on
  sort_order INT NOT NULL DEFAULT 0
);
-- CHG-06. Added after the table existed, so it is applied separately for an existing database.
IF COL_LENGTH('dbo.change_proposals', 'ack_required') IS NULL
  ALTER TABLE dbo.change_proposals ADD ack_required BIT NOT NULL CONSTRAINT df_change_proposals_ack_required DEFAULT 0;

IF OBJECT_ID('dbo.replan_triggers') IS NULL
CREATE TABLE dbo.replan_triggers (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  type NVARCHAR(24) NOT NULL,                  -- intake|estimate|incident|leave|sickness|dependency|delivered|policy|manual
  class NVARCHAR(8) NOT NULL DEFAULT 'batched',  -- batched|urgent|manual
  label NVARCHAR(300) NULL,
  occurred_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  source_entity NVARCHAR(30) NULL,
  source_id INT NULL,
  person_ids NVARCHAR(200) NULL,
  processed_at DATETIME2 NULL,
  proposal_id INT NULL REFERENCES dbo.proposals(id)
);

IF OBJECT_ID('dbo.audit_events') IS NULL
CREATE TABLE dbo.audit_events (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  occurred_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  actor_user_id INT NULL,
  actor_name NVARCHAR(120) NULL,
  action NVARCHAR(40) NOT NULL,                -- create|update|delete|approve|reject|commit|config
  entity NVARCHAR(40) NOT NULL,
  entity_id INT NULL,
  entity_label NVARCHAR(200) NULL,
  before_json NVARCHAR(MAX) NULL,
  after_json NVARCHAR(MAX) NULL,
  reason NVARCHAR(300) NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_audit_entity')
  CREATE INDEX ix_audit_entity ON dbo.audit_events(workspace_id, entity, entity_id, occurred_at);

IF OBJECT_ID('dbo.notifications') IS NULL
CREATE TABLE dbo.notifications (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  user_id INT NOT NULL REFERENCES dbo.users(id),
  kind NVARCHAR(30) NOT NULL,                  -- change_proposed|change_committed|approval_requested|item_assigned|estimate_requested|realisation_due|watch_list
  title NVARCHAR(200) NOT NULL,
  body NVARCHAR(600) NULL,
  link NVARCHAR(200) NULL,                     -- app route e.g. /changes/12, /items/WI-1042
  urgent BIT NOT NULL DEFAULT 0,
  channel NVARCHAR(12) NOT NULL DEFAULT 'in_app',
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  read_at DATETIME2 NULL
);

IF OBJECT_ID('dbo.notification_prefs') IS NULL
CREATE TABLE dbo.notification_prefs (
  user_id INT NOT NULL REFERENCES dbo.users(id),
  kind NVARCHAR(30) NOT NULL,
  in_app BIT NOT NULL DEFAULT 1, push BIT NOT NULL DEFAULT 1, email_digest BIT NOT NULL DEFAULT 0, teams BIT NOT NULL DEFAULT 0,
  digest NVARCHAR(10) NOT NULL DEFAULT 'daily',
  PRIMARY KEY (user_id, kind)
);

IF OBJECT_ID('dbo.item_comments') IS NULL
CREATE TABLE dbo.item_comments (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  work_item_id INT NULL REFERENCES dbo.work_items(id),
  change_proposal_id INT NULL REFERENCES dbo.change_proposals(id),
  author_user_id INT NULL REFERENCES dbo.users(id),
  author_name NVARCHAR(120) NULL,
  body NVARCHAR(MAX) NOT NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

IF OBJECT_ID('dbo.stability_weeks') IS NULL
CREATE TABLE dbo.stability_weeks (
  workspace_id INT NOT NULL,
  week_start DATE NOT NULL,
  total_assignment_days DECIMAL(8,2) NOT NULL DEFAULT 0,
  moved_assignment_days DECIMAL(8,2) NOT NULL DEFAULT 0,
  changes_inside_freeze INT NOT NULL DEFAULT 0,
  planned_load_pct DECIMAL(5,1) NULL,
  actual_load_pct DECIMAL(5,1) NULL,
  note NVARCHAR(200) NULL,
  PRIMARY KEY (workspace_id, week_start)
);

IF OBJECT_ID('dbo.person_change_log') IS NULL
CREATE TABLE dbo.person_change_log (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  person_id INT NOT NULL REFERENCES dbo.people(id),
  work_item_id INT NULL REFERENCES dbo.work_items(id),
  changed_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  week_start DATE NOT NULL,
  inside_freeze BIT NOT NULL DEFAULT 0,
  assignment_days DECIMAL(6,2) NOT NULL DEFAULT 0,
  reason NVARCHAR(300) NULL,
  change_proposal_id INT NULL
);

IF OBJECT_ID('dbo.progress_logs') IS NULL
CREATE TABLE dbo.progress_logs (
  id INT IDENTITY(1,1) PRIMARY KEY,
  work_item_id INT NOT NULL REFERENCES dbo.work_items(id),
  person_id INT NULL REFERENCES dbo.people(id),
  logged_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  progress_pct INT NOT NULL,
  effort_days DECIMAL(5,2) NULL,
  note NVARCHAR(300) NULL
);

IF OBJECT_ID('dbo.integrations') IS NULL
CREATE TABLE dbo.integrations (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  system NVARCHAR(30) NOT NULL,                -- jira|azure_devops|servicenow|hr_leave|m365|teams|timesheets|powerbi
  enabled BIT NOT NULL DEFAULT 0,
  config_json NVARCHAR(MAX) NULL,
  last_sync_at DATETIME2 NULL,
  last_status NVARCHAR(200) NULL
);
GO

-- Read-only reporting views (REP-03 / Power BI).
CREATE OR ALTER VIEW dbo.vw_assignments_committed AS
SELECT a.id, pv.workspace_id, pv.version_no, a.work_item_id, wi.ref, wi.title, wt.name AS work_type,
       a.person_id, p.name AS person, a.from_date, a.to_date, a.allocation_pct, a.state
FROM dbo.assignments a
JOIN dbo.plan_versions pv ON pv.id = a.plan_version_id AND pv.status = 'committed'
JOIN dbo.work_items wi ON wi.id = a.work_item_id
JOIN dbo.work_types wt ON wt.id = wi.work_type_id
JOIN dbo.people p ON p.id = a.person_id;
GO
CREATE OR ALTER VIEW dbo.vw_estimate_accuracy AS
SELECT wi.workspace_id, wi.id AS work_item_id, wi.ref, wi.title, wt.name AS work_type, sc.stamp,
       e.likely AS estimated_days, wi.actual_effort_days, wi.delivered_at,
       CASE WHEN e.likely > 0 THEN wi.actual_effort_days / e.likely END AS ratio
FROM dbo.work_items wi
JOIN dbo.work_types wt ON wt.id = wi.work_type_id
LEFT JOIN dbo.size_classes sc ON sc.id = wi.size_class_id
OUTER APPLY (SELECT TOP 1 * FROM dbo.estimates x WHERE x.work_item_id = wi.id ORDER BY x.version DESC) e
WHERE wi.status = 'delivered' AND wi.actual_effort_days IS NOT NULL;
GO

-- ---------------------------------------------------------------------------------------
-- Outbound webhooks and the public API (INT-07).
--
-- Events are DERIVED from dbo.audit_events rather than emitted by each endpoint: every
-- mutation already writes an audit row with its before and after, so the audit log is a
-- natural outbox and no endpoint has to remember to fire anything. webhook_cursor records
-- how far each workspace has been scanned.
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.webhook_subscriptions') IS NULL
CREATE TABLE dbo.webhook_subscriptions (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  url NVARCHAR(400) NOT NULL,
  secret NVARCHAR(120) NOT NULL,               -- HMAC-SHA256 signing secret; never returned by the API
  events NVARCHAR(300) NOT NULL,               -- comma list, or '*' for every event
  description NVARCHAR(200) NULL,
  active BIT NOT NULL DEFAULT 1,
  created_by INT NULL REFERENCES dbo.users(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_delivery_at DATETIME2 NULL,
  last_status NVARCHAR(200) NULL,
  consecutive_failures INT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.webhook_deliveries') IS NULL
CREATE TABLE dbo.webhook_deliveries (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  subscription_id INT NOT NULL REFERENCES dbo.webhook_subscriptions(id),
  event NVARCHAR(40) NOT NULL,                 -- plan.committed | proposal.created | change.decided | workitem.statusChanged
  payload NVARCHAR(MAX) NOT NULL,
  source_audit_id INT NULL,
  status NVARCHAR(12) NOT NULL DEFAULT 'pending',  -- pending|delivered|failed|abandoned
  attempts INT NOT NULL DEFAULT 0,
  next_attempt_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_status NVARCHAR(200) NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  delivered_at DATETIME2 NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_webhook_deliveries_due')
  CREATE INDEX ix_webhook_deliveries_due ON dbo.webhook_deliveries(status, next_attempt_at);

IF OBJECT_ID('dbo.webhook_cursor') IS NULL
CREATE TABLE dbo.webhook_cursor (
  workspace_id INT NOT NULL PRIMARY KEY,
  last_audit_id INT NOT NULL DEFAULT 0,
  scanned_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

-- Per-person iCalendar feed tokens (VIEW-09, and the publish half of INT-04).
IF OBJECT_ID('dbo.calendar_feeds') IS NULL
CREATE TABLE dbo.calendar_feeds (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  person_id INT NOT NULL REFERENCES dbo.people(id),
  token NVARCHAR(64) NOT NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_read_at DATETIME2 NULL,
  revoked BIT NOT NULL DEFAULT 0,
  CONSTRAINT uq_calendar_feed_token UNIQUE (token)
);
GO

-- ---------------------------------------------------------------------------------------
-- Data retention (ADM-05, NFR-DATA-02). Plan history is kept for a configurable number of
-- months (24 by default) and the audit trail for a configurable number of years (7 by
-- default). Both are per workspace, and a purge records what it removed in the audit trail
-- it is trimming — so there is always evidence that a purge happened, even once the rows
-- it removed are gone.
-- ---------------------------------------------------------------------------------------
IF COL_LENGTH('dbo.workspaces', 'plan_history_months') IS NULL
  ALTER TABLE dbo.workspaces ADD plan_history_months INT NOT NULL DEFAULT 24;
IF COL_LENGTH('dbo.workspaces', 'audit_retention_years') IS NULL
  ALTER TABLE dbo.workspaces ADD audit_retention_years INT NOT NULL DEFAULT 7;
IF COL_LENGTH('dbo.workspaces', 'retention_last_run_at') IS NULL
  ALTER TABLE dbo.workspaces ADD retention_last_run_at DATETIME2 NULL;
GO

-- ---------------------------------------------------------------------------------------
-- Inbound intake (INT-02, and the pattern for INT-01 and INT-03).
--
-- The half of an incident integration that needs no ServiceNow instance: an endpoint that
-- accepts an incident and turns it into interrupt-driven work. ServiceNow (or anything
-- else) posts to it with a shared secret. external_ref makes a repost idempotent, because
-- a ticket system that retries must not create the same incident twice.
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.intake_sources') IS NULL
CREATE TABLE dbo.intake_sources (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  system NVARCHAR(30) NOT NULL,                -- servicenow | jira | other
  name NVARCHAR(120) NOT NULL,
  secret NVARCHAR(120) NOT NULL,               -- shared secret; never returned by the API
  work_type_id INT NULL REFERENCES dbo.work_types(id),   -- NULL = the workspace's interrupt type
  severity_threshold NVARCHAR(4) NULL,         -- e.g. 'P3': anything less urgent is ignored
  field_map NVARCHAR(MAX) NULL,                -- json: {title: 'short_description', severity: 'priority', ...}
  severity_map NVARCHAR(MAX) NULL,             -- json: {'1': 'P1', '2': 'P2', ...}
  default_person_id INT NULL REFERENCES dbo.people(id),  -- NULL = whoever is on the incident rota
  active BIT NOT NULL DEFAULT 1,
  created_by INT NULL REFERENCES dbo.users(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_seen_at DATETIME2 NULL,
  last_status NVARCHAR(200) NULL,
  received_count INT NOT NULL DEFAULT 0,
  created_count INT NOT NULL DEFAULT 0,
  ignored_count INT NOT NULL DEFAULT 0
);

IF OBJECT_ID('dbo.intake_log') IS NULL
CREATE TABLE dbo.intake_log (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  source_id INT NOT NULL REFERENCES dbo.intake_sources(id),
  external_ref NVARCHAR(80) NULL,
  outcome NVARCHAR(20) NOT NULL,               -- created | duplicate | below_threshold | rejected
  work_item_id INT NULL REFERENCES dbo.work_items(id),
  detail NVARCHAR(300) NULL,
  payload NVARCHAR(MAX) NULL,
  received_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_intake_log_ref')
  CREATE INDEX ix_intake_log_ref ON dbo.intake_log(workspace_id, external_ref);
GO

-- ---------------------------------------------------------------------------------------
-- BEN-02: a non-financial benefit carries a qualitative scale and an optional proxy value
-- so it can still weigh on priority. qualitative_scale already exists on dbo.benefits.
-- ---------------------------------------------------------------------------------------
IF COL_LENGTH('dbo.benefits', 'proxy_value') IS NULL
  ALTER TABLE dbo.benefits ADD proxy_value DECIMAL(12,2) NULL;   -- currency-equivalent stand-in for a non-financial benefit
IF COL_LENGTH('dbo.benefits', 'is_financial') IS NULL
  ALTER TABLE dbo.benefits ADD is_financial BIT NOT NULL DEFAULT 1;

-- NOT-04: weekly digest. When each user last received one, so the digest covers changes
-- since then rather than a fixed window.
IF COL_LENGTH('dbo.users', 'last_digest_at') IS NULL
  ALTER TABLE dbo.users ADD last_digest_at DATETIME2 NULL;

-- MOB-04: push registration. One row per device; the token is what APNs or FCM address.
IF OBJECT_ID('dbo.device_tokens') IS NULL
CREATE TABLE dbo.device_tokens (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  user_id INT NOT NULL REFERENCES dbo.users(id),
  platform NVARCHAR(10) NOT NULL,              -- ios | android | web
  token NVARCHAR(400) NOT NULL,
  device_label NVARCHAR(120) NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_seen_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  active BIT NOT NULL DEFAULT 1,
  CONSTRAINT uq_device_token UNIQUE (token)
);

-- Outbound push deliveries, queued like webhooks and sent by whichever sender is configured.
IF OBJECT_ID('dbo.push_deliveries') IS NULL
CREATE TABLE dbo.push_deliveries (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL,
  notification_id INT NULL REFERENCES dbo.notifications(id),
  device_token_id INT NOT NULL REFERENCES dbo.device_tokens(id),
  title NVARCHAR(200) NOT NULL,
  body NVARCHAR(600) NULL,
  link NVARCHAR(200) NULL,
  status NVARCHAR(12) NOT NULL DEFAULT 'pending',   -- pending|sent|failed|abandoned|unconfigured
  attempts INT NOT NULL DEFAULT 0,
  next_attempt_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  last_status NVARCHAR(200) NULL,
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  sent_at DATETIME2 NULL
);
GO

-- ---------------------------------------------------------------------------------------
-- TEAM-09 / SCH-13: loans.
--
-- A loan lends a person to another team for a dated period at a share of their time. It is
-- deliberately NOT a team dimension on dbo.capacity_days: a loan does not change how many
-- hours the person has, only which team those hours belong to, so the split is resolved
-- at read time (capacity.php team_share_for) from this table. Loans that happened are
-- history: end_loan shortens to_date rather than deleting the row.
--
-- Cross-team structure lives in the ORG block at the foot of this file: teams nest under
-- teams (ORG-01) and a role family is a discipline people belong to across teams (ORG-02,
-- renamed from portfolios, which used to group whole teams).
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.person_loans') IS NULL
CREATE TABLE dbo.person_loans (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  person_id INT NOT NULL REFERENCES dbo.people(id),
  from_team_id INT NOT NULL REFERENCES dbo.teams(id),   -- the person's home team when the loan was made
  to_team_id INT NOT NULL REFERENCES dbo.teams(id),     -- the borrowing team
  from_date DATE NOT NULL,
  to_date DATE NOT NULL,                                -- inclusive; end_loan shortens it, never deletes
  allocation_pct INT NOT NULL DEFAULT 100,              -- share of the person's time that moves (1..100)
  reason NVARCHAR(300) NULL,                            -- why the loan was made (business reason, not personal data)
  created_by INT NULL REFERENCES dbo.users(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_person_loans_person')
  CREATE INDEX ix_person_loans_person ON dbo.person_loans(workspace_id, person_id, from_date, to_date);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_person_loans_team')
  CREATE INDEX ix_person_loans_team ON dbo.person_loans(workspace_id, to_team_id, from_date, to_date);
GO

-- ---------------------------------------------------------------------------------------
-- ORG-01..05: team hierarchy, reporting lines, role families, restricted teams.
--
-- Teams nest under teams (parent_team_id). The planning scope of a team is the team plus
-- every descendant, resolved in api/engine/org_lib.php (team_closure) rather than in SQL,
-- so one query per request answers every ancestor/descendant question.
--
-- A role family is a discipline a PERSON belongs to (Data engineering, Analytics), not a
-- group of teams: it spans the tree. It replaces dbo.portfolios, which grouped whole teams;
-- the rename below migrates each team's portfolio onto that team's people, then drops the
-- column. Everything is visible to everyone unless a team is explicitly restricted with a
-- stated reason (ORG-04) — a business reason about the work, never personal data (ADM-05).
-- ---------------------------------------------------------------------------------------
IF COL_LENGTH('dbo.teams', 'parent_team_id') IS NULL
  ALTER TABLE dbo.teams ADD parent_team_id INT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_teams_parent')
  ALTER TABLE dbo.teams ADD CONSTRAINT fk_teams_parent FOREIGN KEY (parent_team_id) REFERENCES dbo.teams(id);
IF COL_LENGTH('dbo.teams', 'sort_order') IS NULL
  ALTER TABLE dbo.teams ADD sort_order INT NOT NULL CONSTRAINT df_teams_sort_order DEFAULT 0;
IF COL_LENGTH('dbo.teams', 'description') IS NULL
  ALTER TABLE dbo.teams ADD description NVARCHAR(300) NULL;
IF COL_LENGTH('dbo.teams', 'directory_object_id') IS NULL
  ALTER TABLE dbo.teams ADD directory_object_id NVARCHAR(64) NULL;   -- Entra group object id, for a later sync
IF COL_LENGTH('dbo.teams', 'visibility') IS NULL
  ALTER TABLE dbo.teams ADD visibility NVARCHAR(12) NOT NULL CONSTRAINT df_teams_visibility DEFAULT 'everyone';  -- everyone|restricted
IF COL_LENGTH('dbo.teams', 'visibility_reason') IS NULL
  ALTER TABLE dbo.teams ADD visibility_reason NVARCHAR(300) NULL;
GO
-- New columns are only visible to a later batch, so the keys and indexes over them follow a GO.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='ck_teams_visibility')
  ALTER TABLE dbo.teams ADD CONSTRAINT ck_teams_visibility CHECK (visibility IN ('everyone','restricted'));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_teams_parent')
  CREATE INDEX ix_teams_parent ON dbo.teams(workspace_id, parent_team_id, sort_order);

-- Reporting line (ORG-02). people.line_manager stays as a free-text legacy column but is never
-- written again: the API returns the manager's name derived from this FK.
IF COL_LENGTH('dbo.people', 'manager_person_id') IS NULL
  ALTER TABLE dbo.people ADD manager_person_id INT NULL;
IF COL_LENGTH('dbo.people', 'role_family_id') IS NULL
  ALTER TABLE dbo.people ADD role_family_id INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_people_manager')
  ALTER TABLE dbo.people ADD CONSTRAINT fk_people_manager FOREIGN KEY (manager_person_id) REFERENCES dbo.people(id);

-- portfolios -> role_families. sp_rename keeps the data and the identity values on an existing
-- database; a fresh database falls through to the CREATE.
IF OBJECT_ID('dbo.portfolios') IS NOT NULL AND OBJECT_ID('dbo.role_families') IS NULL
BEGIN
  EXEC sp_rename 'dbo.portfolios', 'role_families';
  IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_portfolio_name')
    EXEC sp_rename 'dbo.uq_portfolio_name', 'uq_role_family_name', 'OBJECT';
END

IF OBJECT_ID('dbo.role_families') IS NULL
CREATE TABLE dbo.role_families (
  id INT IDENTITY(1,1) PRIMARY KEY,
  workspace_id INT NOT NULL REFERENCES dbo.workspaces(id),
  name NVARCHAR(80) NOT NULL,                -- 'Data engineering', 'Analytics'
  description NVARCHAR(300) NULL,
  lead_person_id INT NULL REFERENCES dbo.people(id),
  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
  CONSTRAINT uq_role_family_name UNIQUE (workspace_id, name)
);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_people_role_family')
  ALTER TABLE dbo.people ADD CONSTRAINT fk_people_role_family FOREIGN KEY (role_family_id) REFERENCES dbo.role_families(id);

-- One-off: a team's portfolio becomes a role family on each of that team's people, then the
-- column goes. Dynamic SQL because this file must still compile once the column is dropped.
IF COL_LENGTH('dbo.teams', 'portfolio_id') IS NOT NULL
BEGIN
  EXEC('UPDATE p SET p.role_family_id = t.portfolio_id FROM dbo.people p JOIN dbo.teams t ON t.id = p.team_id
        WHERE p.role_family_id IS NULL AND t.portfolio_id IS NOT NULL');
  IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='fk_teams_portfolio')
    ALTER TABLE dbo.teams DROP CONSTRAINT fk_teams_portfolio;
  EXEC('ALTER TABLE dbo.teams DROP COLUMN portfolio_id');
END

-- ADM-01: which identity provider owns the account. google | entra | seed | test.
IF COL_LENGTH('dbo.users', 'auth_provider') IS NULL
  ALTER TABLE dbo.users ADD auth_provider NVARCHAR(20) NULL;
GO
