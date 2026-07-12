# marble-race-rng

A Roblox marble-drop RNG game. Core loop: launch a batch of equipped marbles down a peg
board, bank their value through slot multipliers, unlock rarer marbles (crates + luck),
prestige. The architecture below was established in the 2026-07 refactor — follow it for
all new code, and pull legacy stragglers toward it when touching them.

## Toolchain

- Rojo 7.6.1 (`rojo serve` + Studio plugin) syncs `src/` into Studio per `default.project.json`.
- Roblox Studio MCP server (`mcp__Roblox_Studio__*` tools) drives the live Studio instance:
  world edits, play testing, console output. Load schemas via ToolSearch with the full
  `mcp__Roblox_Studio__` prefix.
- `rojo serve` reads `default.project.json` ONCE — any project-file change requires
  restarting the serve process AND a manual plugin reconnect in Studio. After a reconnect,
  the plugin ADDS new instances but does not delete superseded ones on kind collisions —
  probe the Studio tree for structural markers of your newest change and delete stale
  duplicates via MCP before trusting any play test.

## Source-of-truth rules

- Scripts are ONLY edited as repo files under `src/`. Never write or edit scripts via MCP,
  even in unsynced locations.
- Anything Rojo manages (all of `src/`) must not be modified via Studio/MCP. Resolve Rojo
  sync diffs toward the filesystem.
- Non-Rojo world content (models, parts, constraints, tags, attributes, authored GUIs like
  MainGui/ShopGui/PrestigeGui) is edited via MCP or by hand in Studio.
- Script-facing config on world objects lives in CollectionService tags + attributes; repo
  code reads them. No config baked into instance names or hierarchy positions. Tag names
  are registered in `shared/Config/Tags.luau`, attribute names in `shared/Config/Attributes.luau`.

## Layout

```
src/
  server/
    init.server.luau      -- the ONLY server Script (bootstrap)
    Services/             -- one module per service
    Utility/              -- server-only classes/helpers (e.g. ObbyZone)
  client/
    init.client.luau      -- the ONLY LocalScript (bootstrap; StarterPlayerScripts.Main)
    Controllers/          -- one module per controller
  shared/
    Config/               -- pure-data feature config modules
    Remote/               -- *Net.luau remote-definition modules
    Utility/              -- Signal, StringUtils, WeightedRandom, AutoScale, UIButton, AnimationService
    (root)                -- shared domain modules (BallSkins, BallEffects, ProfileStats,
                             UpgradeInfo, CosmeticBonus, SoundService, ScoreUI/AnnounceUI/WarnUI,
                             ProductService, PolicyGate, BallPlotService, ...)
  replicatedfirst/        -- LoadingScreen only (deliberately dependency-free)
```

## Testing policy

- Test implemented mechanics via MCP (play mode + execute_luau + simulated input) to the
  extent practical — anything that gates further work must be tested before building on it.
- Tests don't need to be comprehensive: prioritize high-value, practical-to-automate checks.
  The user playtests too and bugs can be worked backwards from there.
- Skip tests whose cost far exceeds their value (game feel, camera behavior); record those
  as needs-human-playtest items and say so.

### MCP verification playbook (hard-won; do not relearn)

- `execute_luau` runs in a plugin-level VM with its OWN module cache: `require()`ing a
  server module returns a fresh, empty-state copy — never probe module state that way.
  Verify through the game's real surface only: invoke/fire the `*Net` remotes from the
  Client datamodel, send DevService chat commands programmatically
  (`TextChatService.TextChannels.RBXGeneral:SendAsync("/tier luck 3")`), teleport the
  character onto touch pads (`char:PivotTo(...)`), and observe shared Instances
  (tags, attributes, console prints).
- The plugin VM's require cache goes stale after edits, and play snapshots can race rojo
  sync: check `module.Source:find(...)` INSIDE the session before trusting a run.
- Pure shared-module math is safe to test via execute_luau (fresh copies are fine for
  stateless functions).

### Before each commit

1. User takes a game snapshot (.rbxl) covering hand-placed content not regenerable from
   scripts. Prompt them for this.
2. Confirm no script content exists only in Studio (everything script-like is in `src/`).

## Code conventions

### Architecture

- Service/controller split. Services (`src/server/Services/`) own authoritative state and
  game logic. Controllers (`src/client/Controllers/`) handle input, rendering, and UI,
  reading replicated state through remotes.
- Exactly one bootstrap `Script` (`src/server/init.server.luau`) and one bootstrap
  `LocalScript` (`src/client/init.client.luau`). They only require and start modules — no
  game logic in bootstrap scripts.
- Server lifecycle is two-phase: ordered `Init()` calls (synchronous wiring), then
  `task.spawn(Service.Start)` for services that run long loops (DayNight, Obstacle,
  OverheadStats, PhysicalLeaderboard). The Init ORDER in init.server.luau is load-bearing
  and every ordering constraint is documented by the comment on its entry — keep those
  comments truthful when adding services. Controllers are `Init()`-only.
- Each service manages one independent element of the game. Services communicate via
  direct require or `Signal` events, not by reaching into each other's internals.
- Side effects belong at the call site, explicitly. Ball spawn paint is the canonical
  example: `BallService.Spawn` stamps `SkinId` and calls
  `BallEffects.ApplySpawnDefaults` + `ApplyAppearance` directly — do NOT reintroduce
  competing signal/tag listeners whose correctness depends on connection order. Signals
  are for genuine cross-service *events* (BallSpawned, BallBanked, Changed), not for
  routing a single owner's responsibility.
- Client-side, CollectionService tags are a legitimate discovery mechanism for replicated
  server instances (the client has no call-site hook) — e.g. BallEffects' value-UI attach.

### Shared two-sided modules

Some features are one module with server and client halves, gated by
`RunService:IsServer()`/`IsClient()` blocks (SoundService, ScoreUI, AnnounceUI, WarnUI,
BallEffects, ProductService, PolicyGate) or explicit `InitServer()`/`InitClient()` entry
points the bootstraps pick between (BallPlotService). Acceptable for tightly-mirrored
features; the server half must not hold references the client can't load (their remotes
come from the `*Net` modules, never created inline).

### Typing & OOP

- Strict Luau typing: `--!strict` at the top of every module. (Legacy exceptions exist —
  `Utility/Signal.luau` is `--!nocheck`, a couple of old files lack the directive; don't
  add new ones.)
- Prefer composition over inheritance. Classes only for N-instance entities with
  lifecycles (`server/Utility/ObbyZone`); services/controllers are plain singleton module
  tables.
- Static verification: VS Code diagnostics go stale after mass file moves. For a rigorous
  check, run the luau-lsp CLI (`~/.vscode/extensions/johnnymorganz.luau-lsp-*/bin/server
  analyze --sourcemap sourcemap.json --definitions <globalTypes> src`) and, for refactors,
  diff its error set against a `git worktree` of the pre-change commit. Regenerate the
  sourcemap (`rojo sourcemap`) after moving files.

### Signals & remotes

- Same-side signals use `shared/Utility/Signal.luau` EXCLUSIVELY. No BindableEvents, ever.
- RemoteEvent/RemoteFunction names are never string-coupled between services and
  controllers. The owning feature defines its remotes in a `*Net.luau` module in
  `src/shared/Remote/` (e.g. `CurrencyNet` defines `BalanceChanged`/`GetBalance`); both
  sides require that module. The Net module is the single place a remote is created
  (server, at require time, parented to the module) and looked up (client, `WaitForChild`).
- Standard `*Net.luau` structure (see `CurrencyNet.luau` as the reference): local
  `remoteEvent(name)`/`remoteFunction(name)` helpers that branch on
  `RunService:IsServer()`, then a single exported table of remotes. Each remote field
  carries a comment documenting direction and payload types
  (e.g. `-- Server -> Client: (newBalance: number, delta: number, reason: string)`).
  No other logic lives in a Net module.
- Server-driven client feedback (banners, SFX, ball VFX, currency-fly) goes through
  `FxNet` — one owner per remote; never create a second creator for an existing remote.

### Config

- A service, or a tightly-coupled group of services, defines its tunable constants in a
  module under `src/shared/Config/` named for the feature (e.g. `Config/Launcher.luau`
  for BallLaunchService, `Config/Crates.luau` for the crate economy). No magic
  numbers/strings local to the service module itself — with one carve-out: purely visual
  "juice" constants (tween times, pixel offsets) may live at the top of the UI module
  that uses them, clearly grouped.
- Anything that reads or produces the same values requires the same Config module —
  server roll and client preview must share it (e.g. `Config/Crates` + `Utility/WeightedRandom`
  are used by CosmeticService AND the reel/sample previews, so displayed odds can't drift
  from real ones).
- Standard Config module structure (see `Config/Crates.luau` as the reference): `--!strict`,
  exported types for structured entries (e.g. `export type BoxDef`), then one table
  returned directly, with explicit type ascriptions on heterogeneous or dynamically-indexed
  sub-tables (e.g. `:: { [string]: TrackDef }`, `:: { PoolEntry }`). Config modules are
  pure data — no functions, no requires of game code (requiring other Config modules is
  fine: Upgrades → Economy/Scoring, Tutorial → Crates). Tiny pure helpers over a module's
  OWN data are tolerated (`Admin.IsAdmin`); define them BEFORE `table.freeze`.
- `table.freeze` frozen groups stay frozen; never mutate config at runtime.
- Cross-cutting registries: `Config/Tags.luau` (CollectionService tag names) and
  `Config/Attributes.luau` (attribute names) are the single vocabulary for instance
  marking — add new tags/attributes there, with a one-line comment on who reads them.

### State & attributes

- Tags and attributes exist for exactly two purposes: marking instances for scripts to
  find/use/modify, and instance-specific config (a pad's `Teleport` destination, a ball's
  spawn-time `SkinId`). System-wide config belongs in `shared/Config` modules.
- Runtime game state is NEVER stored in attributes/tags/instance values. The owning
  service holds it in its own tables (e.g. CurrencyService's balances, CoinService's
  per-player active sets) and replicates what clients need through its `*Net.luau`
  remotes. UI controllers read and mutate state exclusively through those remotes.
  (Per-ball spawn stamps like `SkinId`/`OwnerUserId` are config-at-spawn, not mutable
  state — set once at creation.)
- Persistence: DataService owns the DataStore lifecycle. A feature that persists player
  data is a "passive data service": it exposes `ApplyData(player, saved?)`,
  `SerializeData(player)`, and `Clear(player)`, gets registered in DataService's
  apply/serialize lists, and its `Init()` runs BEFORE DataService.Init() in the bootstrap
  (so the first ApplyData has somewhere to land). Follow the existing ten examples
  (Currency, Profile, Prestige, Stats, Playtime, Cosmetic, Loadout, Quest, StarterQuest,
  DailyReward).

### Error handling

- Expected failures (validation rejections, gated purchases, race outcomes) return result
  tables in the codebase's `{ ok = false, reason = "disabled" }` shape (see
  UpgradeService.Purchase, CosmeticService rolls) — never `error()`, which is reserved
  for actual bugs. Callers check `ok` and surface `reason`.

### Randomness & formatting

- Weighted sampling goes through `shared/Utility/WeightedRandom` (`PickIndexLuckBiased`
  for luck-skewed rarity rolls, `PickBy`/`PickKey` for plain picks). Never hand-roll a
  cumulative-weight walk — client previews must provably use the same sampler as the
  server roll.
- Number formatting goes through `shared/Utility/StringUtils` (`FormatMoney`,
  `FormatShort`, `FormatCompact`, `Commas`).

### Style

- Match existing file structure and naming: PascalCase modules, `*.luau` extension,
  services named `XService`, controllers named after their surface (`ShopUI`,
  `PegHeatView`, `CameraController`). Public lifecycle entry is `Init()` (capital I).

## Known debt (do not imitate; shrink when touching)

- Require cycle broken by lazy requires: ProductService → DataService → … →
  CosmeticService → (lazy, in Init) ProductService. PrestigeService/QuestService also
  lazy-require to dodge it. Works at runtime; the analyzer flags it. New code must not
  add edges to this chain.
- Client dup clusters pending extraction: the floating sample-ball rig
  (CosmeticBallSample / LoadoutDisplay / FreeRollBallSample / BallTuningPreview), the
  slot-reel spin (CrateRollUI / DailyRewardUI), swatch builders, per-file countdown
  formatters (formats intentionally differ), ShopUI/PrestigeUI's punch/flare pair.
- The `"^Ball "` prefix on CurrencyService reasons is a load-bearing string contract
  (StatsService, MoneyPerBallUI, TutorialController parse it) — keep the prefix on any
  ball-banking grant.
- Several controllers fight over `MainGui.LeftBar.TriggerQuad` by name
  (TutorialController.closeTriggerQuadPanels papers over it).
- Baseline of tolerated analyzer errors ≈79 (BallSkins literal-width mismatches,
  BallEffects internals, cycle reports). Don't add new ones — verify with the CLI diff
  technique above.
