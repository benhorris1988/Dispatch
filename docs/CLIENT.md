# Flutter client shell — what screens can rely on

Package `dispatch_app` in `mobile/`. Flutter SDK on this box: `"C:\temp\flutter sdk\flutter\bin\flutter.bat"`.
`flutter analyze` and `flutter pub get` work from Git Bash; `flutter build web` must run from PowerShell:
`& "C:\temp\flutter sdk\flutter\bin\flutter.bat" build web --release --base-href=/mobile/build/web/ --dart-define=API_BASE=http://localhost:8090/api`.

## File tree (`lib/`)

```
main.dart                 app bootstrap, providers, splash while session restores
router.dart               go_router config, homeFor(context)
app_state.dart            Session, WorkspaceConfig, ShellState, ThemePrefs
theme/tokens.dart         DispatchColors, DispatchRadius, Sp, DispatchShadow, ShellDims
theme/app_theme.dart      DispatchTheme.light()/dark(), DispatchTheme.numeric(), DispatchContext ext
shell/breaks.dart         Breaks, Pane
shell/nav.dart            Routes, NavItem, NavGroup, Nav
shell/sidebar.dart        Sidebar (280 / 72 rail)
shell/top_bar.dart        TopBar, ShellSearchField
shell/app_shell.dart      AppShell (ShellRoute wrapper), PageBody
services/api.dart         Api, ApiException, listOf()
services/format.dart      fmt* helpers
models/{json,user,config,person,org,work_item,plan,value,models}.dart
models/org.dart               OrgTree/OrgTeam/OrgPerson/RoleFamily (org.php tree), OrgTeamOption, orderTeamsByHierarchy
widgets/{chips,person_avatar,panel,stat_tile,indicators,buttons,states,dispatch_logo,widgets}.dart
widgets/tm_scope_picker.dart   PlanScope, PlanScopeOptions.load() (people.php list + role_families.php list), TmScopePicker (TEAM-09 / SCH-13 / ORG-01)
widgets/org_layout.dart        OrgLayout.layout() — the organisation chart's geometry, pure Dart, unit-tested without a server
widgets/tm_loan_chip.dart      TmLoanChip, LoanSide, loanChipLabel; widgets/tm_loan_list.dart  TmLoanList, loanStateChip
widgets/pf_metrics.dart        PfMetrics — definitions for the role-family and loan figures
services/google_auth.dart      GoogleAuth — Google sign-in (ADM-01); google_button_{stub,web}.dart is the web/native split
screens/*_screen.dart     one file per route (placeholders use ComingSoon)
screens/parts/tm_loan_dialog.dart  showTmAddLoan (people.php add_loan, 409 shown verbatim), confirmTmEndLoan (end_loan)
screens/parts/org_{canvas,details_panel,tree_list,dialogs}.dart  the organisation chart's canvas, panel, list view and dialogs
```

## State (provider)
- `context.watch<Session>()` — `user`, `signedIn`, `can(String minRole)`, `isAdmin/isDeliveryLead/isTeamLead`, `signInWithGoogle(idToken)`, `signInWithToken(token)`, `signOut()`.
- `context.read<WorkspaceConfig>()` — `workTypes`, `sizeClasses`, `policy`, `workspace`, `workType(id)`, `sizeClass(id)`, `typeColour({id,name,hex})`, `load()`.
- `context.read<ShellState>()` — `setPlanStatus(text, {committed})`, `setPendingChanges(n)`, `setUnreadNotifications(n)`, `setPageTitle(title, {breadcrumb})`, `refreshCounts()` (calls changes.php current, notifications.php list, overview.php get).

## API
`Api.post(endpoint, action, [body]) → Map<String,dynamic>`, `Api.get(endpoint, [query])`, `Api.base`, `Api.token`;
throws `ApiException(message, code)` (`isAuth`, `isNotImplemented`). `listOf(raw, fromJson)`. Auth: `Api.providers()`, `Api.googleLogin(idToken)`, `Api.me()`, `Api.listUsers()`, `Api.setRole(userId, role)`.

## Format (`services/format.dart`)
`fmtDate`, `fmtShortDate` ('Fri 18 Sep'), `fmtDayMonth`, `fmtDateRange`, `fmtWeekCommencing` ('w/c 7 Sep'), `fmtRelativeDay`, `fmtTime`,
`fmtMoneyK` (£210k), `fmtMoney`, `fmtPct`, `fmtDays`, `fmtDelta`, `parseDate`, `dotJoin`, `initialsOf`, `humanise`.

## Models (`import 'models/models.dart'`; all `fromJson`, null-tolerant)
`User` (+`UserPerson`, `Workspace`, `AuthProviders`, `DirectoryUser`, `roleRank`, `roleLabel`, `kRoleOrder`), `WorkType`, `SizeClass`, `Policy`, `Person` (+`Loan`: `loans`, `onLoanTo`, `loanedFrom`, `isBorrowed`; `managerName`, `roleFamilyName`), `Skill`,
`PersonSkill` (+`kProficiencyLabels`), `WorkItem` (+`SkillRequirement`, `WorkStatus`/`Health` constants, `displayStatus`), `Assignment`,
`PlanVersion`, `Proposal`, `ChangeProposal` (+`ImpactChip`), `Benefit`, `Estimate` (+`SkillSplit`, `estimateClassLabel`), `AppNotification`.
Raw readers in `models/json.dart`: `asInt/asIntOr/asDouble/asBool/asStr/asDate/asIntList/asStrList/asMap/asList`.
If a model lacks a field you need, read the raw map (`asMap(r['x'])`) rather than editing shared model files — or add a NEW model file for your screen.

## Widgets (`import 'widgets/widgets.dart'`)
- `SizeStamp(String? stamp, {size=28, bool? dashed, bool? filled})` — L filled navy, C dashed by default
- `TypeChip(String name, {Color? colour, String? colourHex, compact})`, `StatusChip(String? status, {label, icon, compact})`,
  `ToneChip(label, {tone: ok|warn|bad|info|accent})`, `LegendDot(label, {colour, dashed})`, `statusStyle(status)`
- `PersonAvatar(String initials, {colour, colourHex, size=32, seed, tooltip, outlined})`, `PersonAvatar.person(Person)`, `AvatarStack(List<Person>, {size, max})`
- `Panel({title, subtitle, trailing, required child, padding, dividerAfterHeader, accent})`, `PanelHeader`,
  `DispatchCard({child, padding, onTap, accent, dashed, tint})`, `DashedBox`, `SectionLabel(text, {trailing})`, `PageHeader({title, subtitle, actions})`
- `StatTile({label, value, unit, footnote, tone: StatTone, footnoteIcon, bordered, onTap})`, `StatRow({tiles, minTileWidth})`
- `PriorityBar(double? score, {width, showNumber})`, `ProficiencySquare(int level, {size, tooltip})`, `ConfidenceDots(String? confidence, {showLabel})`,
  `ProgressBar(fraction, {colour, trailing})`, `LoadPct(pct)`
- `PrimaryButton(label, {onPressed, icon, busy, expand, navy})`, `SecondaryButton(label, {…, danger})`, `InfoPill(label, {icon, dot, onTap})`,
  `SegmentedTabs({labels, selected, onChanged, compact})`, `IconBox(icon, {onPressed, tooltip, badge})`
- `Skeleton({width, height, radius})`, `Skeleton.circle`, `SkeletonPanel({rows})`, `LoadingState`, `ErrorState({title, message, onRetry, compact})`,
  `EmptyState({icon, title, message, action})`, `ComingSoon(title)`
- `DispatchMark(size)`, `DispatchLogo({size, onDark, showTagline})`
- `widgets/benefit_widgets.dart` (BEN-02): `BenefitValueLabel.fromJson(benefitRow, {perYear, size})` — money for a financial benefit, the
  server's qualitative scale label chip plus "≈ £50k proxy" for a non-financial one; `nonFinancialNote(count, proxyTotal)` → "+ 2 non-financial (≈ £75k proxy)".
- `screens/parts/benefit_form_dialog.dart`: `showBenefitFormDialog(context, {workItemId, workItemLabel, benefit, types, scales})` — the one add/edit form
  (Financial / Non-financial toggle; scale labels and types from `benefits.php list`, fetched if not passed; server validation shown verbatim).
- `screens/parts/external_link_panel.dart` (REQ-05): `ExternalLinkPanel({item, canEdit, onChanged})` — system label, ref, Open (`url_launcher`),
  the server's badge (`live` → coloured chip + "seen N times · last date"; `link_only` → neutral chip + note), Link / Edit / Remove for team_lead+.
- `screens/parts/digest_view.dart` (NOT-04): `DigestSection({userId})` — `digest.php preview` rendered as panels (next week with effort vs capacity,
  changes since last digest, awaiting acknowledgement, watch-list mentions, digest-routed notifications) with a delivery footer taken from the
  response's `delivery_note` / `transport`; admins get "Send now" and the `send` counts verbatim.
- Shell: `PageBody({child, onRefresh, maxWidth, padding})` — standard padded, width-clamped scroll container; `Breaks.of/isPhone/wide/cols/gutter`.

## Screens and routes
`Routes` constants: `/overview /pipeline /items/:ref /items/:ref/estimate /schedule /changes /changes/:id /team /people/:id /estimates /benefits /reports /settings /my-week /add-work /notifications /more /org /sign-in`; helpers `Routes.item(ref)`, `Routes.change(id)`, `Routes.person(id)`.
Off the shell's own constants: `/role-families/:id` (`RoleFamilyScreen.route(id)`, ORG-02 / TEAM-09 — reached from Team & skills when a role family is the chosen scope, no sidebar entry).
`/org` (`OrgChartScreen`, ORG-01..05) has a sidebar entry of its own, after Team & skills, and sits on the phone More list.
Constructors: `PipelineScreen({query})`, `WorkItemScreen({required ref})`, `EstimateScreen({required ref})`, `ChangeDetailScreen({required id})`, `PersonScreen({required id})`, `RoleFamilyScreen({required id})`; others no-arg.

### Scope (TEAM-09, SCH-13, ORG-01/02)
`PlanScope` is *Whole workspace* / a role family / a team; `scope.params` is the `{role_family_id}` or `{team_id}` to spread into a request body, `scope.phrase` reads after "planned for". A team scope means that team **and every team beneath it**; a role family is a discipline's people wherever they sit. `TmScopePicker` is a popup behind a pill (it sits in a `Wrap` of header actions at any width) and indents teams by their depth in the tree. Team & skills sends the scope to `skills.php matrix` and `people.php list`; Scenarios sends it to `replan.php preview`; the Changes empty state sends it to `replan.php propose`; the Schedule's propose sends `team_id` when its team filter is on. The result copy always names the scope it was planned for.

### Sign-in (ADM-01)
There is no development sign-in. `Api.providers()` says which identity providers this deployment offers and hands over the Google web client id, so the sign-in screen draws only buttons that work and nothing is compiled in. `GoogleAuth` wraps the plugin: on Android and iOS `signInNative()` returns an ID token, on the web Google renders its own button (`google_button_web.dart`) and the token arrives on `GoogleAuth.idTokens`. Either way it goes to `Session.signInWithGoogle()`. `Session.signInWithToken()` adopts an already-issued token and is how the smoke test gets in, because a test cannot perform a Google sign-in:

```
flutter test test/screens_smoke_test.dart --dart-define=TEST_TOKEN=<token from tests/mint_token.php>
```

## Decisions
- Screens own their own scroll view (`PageBody`); the shell supplies chrome only. Route transitions are `NoTransitionPage`.
- Phone: bottom tabs My week / Pipeline / Changes / More; `/more` hosts theme toggle + sign out. Tablet: 72px icon rail.
- Role gating hides controls (`session.can('delivery_lead')`), never relies on 403s.
- Dark mode fully defined; use theme colours (`Theme.of(context).colorScheme`, `DispatchColors`) not literals, so both themes work.
- Charts: `fl_chart` is a dependency (use it for the Reports / Benefits / Person charts, or CustomPainter for the small ones).
