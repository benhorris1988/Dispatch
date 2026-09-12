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
models/{json,user,config,person,work_item,plan,value,models}.dart
widgets/{chips,person_avatar,panel,stat_tile,indicators,buttons,states,dispatch_logo,widgets}.dart
screens/*_screen.dart     one file per route (placeholders use ComingSoon)
```

## State (provider)
- `context.watch<Session>()` — `user`, `signedIn`, `can(String minRole)`, `isAdmin/isDeliveryLead/isTeamLead`, `signInDev(id)`, `signOut()`.
- `context.read<WorkspaceConfig>()` — `workTypes`, `sizeClasses`, `policy`, `workspace`, `workType(id)`, `sizeClass(id)`, `typeColour({id,name,hex})`, `load()`.
- `context.read<ShellState>()` — `setPlanStatus(text, {committed})`, `setPendingChanges(n)`, `setUnreadNotifications(n)`, `setPageTitle(title, {breadcrumb})`, `refreshCounts()` (calls changes.php current, notifications.php list, overview.php get).

## API
`Api.post(endpoint, action, [body]) → Map<String,dynamic>`, `Api.get(endpoint, [query])`, `Api.base`, `Api.token`;
throws `ApiException(message, code)` (`isAuth`, `isNotImplemented`). `listOf(raw, fromJson)`. Auth: `Api.listDevUsers()`, `Api.devLogin(id)`, `Api.me()`.

## Format (`services/format.dart`)
`fmtDate`, `fmtShortDate` ('Fri 18 Sep'), `fmtDayMonth`, `fmtDateRange`, `fmtWeekCommencing` ('w/c 7 Sep'), `fmtRelativeDay`, `fmtTime`,
`fmtMoneyK` (£210k), `fmtMoney`, `fmtPct`, `fmtDays`, `fmtDelta`, `parseDate`, `dotJoin`, `initialsOf`, `humanise`.

## Models (`import 'models/models.dart'`; all `fromJson`, null-tolerant)
`User` (+`UserPerson`, `Workspace`, `DevUser`, `roleRank`, `roleLabel`, `kRoleOrder`), `WorkType`, `SizeClass`, `Policy`, `Person`, `Skill`,
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
- Shell: `PageBody({child, onRefresh, maxWidth, padding})` — standard padded, width-clamped scroll container; `Breaks.of/isPhone/wide/cols/gutter`.

## Screens and routes
`Routes` constants: `/overview /pipeline /items/:ref /items/:ref/estimate /schedule /changes /changes/:id /team /people/:id /estimates /benefits /reports /settings /my-week /add-work /notifications /more /sign-in`; helpers `Routes.item(ref)`, `Routes.change(id)`, `Routes.person(id)`.
Constructors: `PipelineScreen({query})`, `WorkItemScreen({required ref})`, `EstimateScreen({required ref})`, `ChangeDetailScreen({required id})`, `PersonScreen({required id})`; others no-arg.

## Decisions
- Screens own their own scroll view (`PageBody`); the shell supplies chrome only. Route transitions are `NoTransitionPage`.
- Phone: bottom tabs My week / Pipeline / Changes / More; `/more` hosts theme toggle + sign out. Tablet: 72px icon rail.
- Role gating hides controls (`session.can('delivery_lead')`), never relies on 403s.
- Dark mode fully defined; use theme colours (`Theme.of(context).colorScheme`, `DispatchColors`) not literals, so both themes work.
- Charts: `fl_chart` is a dependency (use it for the Reports / Benefits / Person charts, or CustomPainter for the small ones).
