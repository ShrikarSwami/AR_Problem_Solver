# AR_Problem_Solver — Progress

_Living status doc. Update it at the end of every working session so the next
session can resume without re-deriving context._

**Last updated:** 2026-09-03
**Current phase:** Scaffolding complete — compiling skeleton

---

## 1. What this project is

iOS app. A wearer of Meta Ray-Ban Display glasses captures a photo of a problem,
the app sends it to the Claude API with a step-by-step-breakdown system prompt,
and the answer is read back on the glasses as a paginated teleprompter that the
wearer advances with the Meta Neural Wristband.

Full design: [`docs/superpowers/specs/2026-09-03-ar-problem-solver-design.md`](docs/superpowers/specs/2026-09-03-ar-problem-solver-design.md)

## 2. Setup milestones

| Milestone | Status | Notes |
|-----------|--------|-------|
| Git repo + license | ✅ | Pre-existing (`Initial commit`) |
| Architecture designed & approved | ✅ | Brainstorm → spec, 2026-09-03 |
| DAT SDK API verified | ✅ | Cloned `facebook/meta-wearables-dat-ios` v0.9.0; read both sample apps + `AGENTS.md` |
| `project.yml` (XcodeGen) | ✅ | SPM dep on DAT 0.9.0; 4 products wired |
| Info.plist with DAT keys | ✅ | `Resources/Info.plist` — MWDAT block, BT/local-network/Bonjour, external accessory |
| Secrets handling | ✅ | `Secrets.xcconfig` (gitignored) + `.example`; Keychain override |
| Source skeleton (all layers) | ✅ | App / Wearables / Claude / Solver / Display / Settings / Support |
| Unit tests (parser + coordinator) | ✅ | Fakes for camera/solver/display seams |
| `xcodegen generate` succeeds | ✅ | Clean generation |
| `xcodebuild … build` compiles | ✅ | Builds for iOS Simulator against DAT 0.9.0 (resolved from GitHub) |
| Unit tests pass | ✅ | 7/7 on iPhone 17 sim (parser + coordinator) |
| Runs on device with real glasses | ❌ | Needs hardware + Meta registration + API key |

## 3. Architectural decisions

- **Min iOS 17** — matches Meta's samples; lets us use `@Observable` / `Observation`.
- **XcodeGen** — `project.yml` is source of truth; `*.xcodeproj` is gitignored and regenerated.
- **Teleprompter = pagination, not scrolling.** DAT 0.9 Display DSL has no scroll
  primitive. Each solution step is one `FlexBox` page with Back / Next / Repeat
  buttons; the wristband pinch fires those button handlers. Precedent:
  `samples/DisplayAccess/.../CarMaintenanceDisplay.swift` (`tutorialStep`).
- **Protocol seams** (`PhotoCapturing`, `DisplaySending`, `ProblemSolving`) keep
  `SolverCoordinator` / `TeleprompterController` unit-testable and let the camera
  path run against MockDeviceKit.
- **Separate `DeviceSession` per capability** (camera, then display). Reusing one
  session for both is a future optimization, not done in v1.
- **Claude key resolution order:** Keychain (in-app Settings) → `Secrets.xcconfig`
  → throw `ClaudeError.missingAPIKey`.
- **Non-streaming Claude call**, `claude-sonnet-5`, `max_tokens` 1024,
  `anthropic-version: 2023-06-01`.
- **Rigid prompt output contract** (`PROBLEM:` / `STEP n:` / `DONE`) so
  `SolutionParser` splits pages without a second model call; graceful fallbacks
  for numbered lists and unstructured prose.

## 4. Component map

| File | Responsibility |
|------|----------------|
| `App/AppModel.swift` | Composition root; owns services + coordinator |
| `App/AR_Problem_SolverApp.swift` | `Wearables.configure()`, `.onOpenURL` → `handleUrl` |
| `App/RootView.swift` | Phone UI: status, Capture & Solve, Settings sheet |
| `Wearables/WearablesService.swift` | SDK config, registration state, device list |
| `Wearables/GlassesCameraService.swift` | Camera lifecycle → one JPEG (`PhotoCapturing`) |
| `Wearables/GlassesDisplayService.swift` | Display session + `send()` (`DisplaySending`) |
| `Wearables/WearablesProtocols.swift` | Test seams + `GlassesError` |
| `Claude/ClaudeClient.swift` | `/v1/messages` call (`ProblemSolving`) |
| `Claude/ClaudeModels.swift` | Codable wire types, `ClaudeError` |
| `Claude/ProblemSolverPrompt.swift` | System prompt + output contract |
| `Solver/SolverCoordinator.swift` | capture → Claude → parse → teleprompter |
| `Solver/SolutionParser.swift` | response text → `Solution` (+ soft-split) |
| `Solver/SolutionStep.swift` | `SolutionStep`, `Solution` models |
| `Display/TeleprompterController.swift` | page index; next/prev/repeat; re-send |
| `Display/TeleprompterDisplay.swift` | `[SolutionStep]` → `FlexBox` pages |
| `Settings/SettingsView.swift` | API key entry, connect/disconnect |
| `Settings/KeychainStore.swift` | Keychain wrapper for the API key |
| `Support/Secrets.swift` | reads `ANTHROPIC_API_KEY` from Info.plist |
| `Support/AppLog.swift` | `os.Logger` categories |

## 5. Build status

<!-- Update this block after each `xcodegen generate` / `xcodebuild` run. -->

- `xcodegen generate`: ✅ (2026-09-03)
- `xcodebuild build` (iOS Simulator): ✅ **BUILD SUCCEEDED** (2026-09-03)
- `xcodebuild test` (iPhone 17 sim): ✅ 7/7 tests pass (2026-09-03)
- All DAT symbols verified against the compiled `.swiftinterface` files in the
  resolved package (`SourcePackages/checkouts/meta-wearables-dat-ios/*.xcframework`).
  Confirmed: `Wearables.configure() throws(WearablesError)` / `Wearables.shared:
  any WearablesInterface`; `AutoDeviceSelector(wearables:filter:)` with
  `DeviceFilter = @Sendable (Device) -> Bool`; `session.addCamera(config:)
  throws(DeviceSessionError) -> Camera?`; `StreamConfiguration(videoCodec:
  resolution:frameRate: UInt)`; `stream.capturePhoto(format: .jpeg) -> Bool`;
  `PhotoData.data: Data`; `session.addDisplay() throws -> Display`;
  `display.send(_ view: some DisplayableView)`; `FlexBox: DisplayableView`;
  `IconName` cases `.triangleLeftVerticalLine` / `.triangleRightVerticalLine` /
  `.checkmark` (also `.wristband`); `ListenerTokenBag` is now an `actor`.
- Fix applied during bring-up: teleprompter nav methods are `@MainActor async`
  and the Display button callbacks hop through `Task { await … }`.

## 6. How to build

```bash
brew install xcodegen          # already installed on this machine
cp Secrets.xcconfig.example Secrets.xcconfig   # then fill in values (optional for build)
xcodegen generate
open AR_Problem_Solver.xcodeproj
# or:
xcodebuild -scheme AR_Problem_Solver -destination 'generic/platform=iOS Simulator' build
```

## 7. To run for real (not possible in this environment)

1. Register an app in the [Wearables Developer Center](https://wearables.developer.meta.com/);
   put `MetaAppID` / `ClientToken` / `DEVELOPMENT_TEAM` in `Secrets.xcconfig`
   (or enable Meta AI Developer Mode and use `META_APP_ID = 0`).
2. Pair Ray-Ban Display glasses + Neural Band via the Meta AI app.
3. Put an Anthropic API key in `Secrets.xcconfig` or the in-app Settings screen.
4. Run on a physical iPhone (BLE + external accessory — not the simulator).
5. In-app: Connect glasses → Capture & Solve → navigate steps with the wristband.

## 7a. On-device deploy status (2026-09-03)

- Pushed to `github.com/ShrikarSwami/AR_Problem_Solver` `main`.
- Device `ShriShriiPhone` (iPhone 15, iOS 26.6.1, id `00008120-000A48E43ED1A01E`):
  connected over USB, paired, **Developer Mode enabled**.
- Signing cert present in keychain: `Apple Development: shrikarswami08@gmail.com
  (977QXZMRTZ)`. `DEVELOPMENT_TEAM = 977QXZMRTZ` set in `Secrets.xcconfig`;
  `CODE_SIGN_STYLE = Automatic` in `project.yml`.
- **Blocker:** device build fails with `No Account for Team "977QXZMRTZ"` —
  Xcode has no signed-in Apple ID, so `-allowProvisioningUpdates` can't mint a
  profile. Fix: Xcode ▸ Settings ▸ Accounts ▸ add `shrikarswami08@gmail.com`.
  Then: `xcodebuild -scheme AR_Problem_Solver -destination 'platform=iOS,id=00008120-000A48E43ED1A01E' -allowProvisioningUpdates build`
  then `xcrun devicectl device install app <path>.app` + `devicectl device process launch`.
- Camera streaming may additionally need `com.apple.developer.networking.wifi-info`
  + `HotspotConfiguration` entitlements (paid account) — not added yet; basic
  install/launch does not require them.

## 7b. Integration refinements (2026-09-03)

- **Step parser** — decimals (`3.14`) and abbreviations no longer split across
  pages; `STEP n -`/`n)`/`n.` separators all handled; trailing punctuation kept;
  stray sign-off lines after the last step are dropped; empty steps filtered.
  Prompt now asks for 3–8 single-line steps with numbers/units kept inline.
- **Camera permission** — `GlassesCameraService` checks
  `checkPermissionStatus(.camera)` first; a first miss returns
  `GlassesError.cameraPermissionNeeded` (no mid-flow app-switch), the next
  Capture triggers `requestPermission(.camera)` (Meta AI redirect).
- **Camera → display handoff** — camera `DeviceSession` fully torn down inside
  `capturePhoto()`; `SolverCoordinator` then waits `handoffDelay` (600 ms) before
  the display session opens; the display session is created once (thinking card)
  and reused for every teleprompter page. Coordinator now guards on
  `isDeviceReady` (registration) before starting.
- **Claude client** — `max_tokens` 2048; one bounded retry on 429/5xx honouring
  `retry-after`; explicit 60 s request timeout.
- **Teleprompter** — problem statement shown on step 1 only; no Back button on
  step 1; Repeat button added; brief "all steps done" card before the session
  closes (`completionLinger`).
- 10/10 unit tests pass; simulator build green.

## 7c. Launch-crash fix (2026-09-03)

Symptom: app crashed at launch in Xcode with `SIGTRAP` inside
`mach_o::Header::forEachLoadCommand`, preceded by dozens of
`objc[...] Class SUPMediaStream… / FB… is implemented in both
MWDATMockDevice.framework and MWDATCamera.framework … mysterious crashes`.

Cause: the app target linked **both** `MWDATCamera` and `MWDATMockDevice`, which
each statically embed the same Objective-C support classes. Two copies in one
binary is undefined behaviour in the objc runtime / dyld image registration.

Fix: `MWDATMockDevice` removed from both the app and test targets in
`project.yml` (nothing imported it yet). After the change: no duplicate-class
warnings, app launches and stays running on the iPhone 17 Pro simulator, 10/10
tests still pass. When MockDeviceKit tests are added, link
`MWDATMockDeviceTestClient` (the test-safe product) on a dedicated test target
only.

## 7d. DAT connection-state review + API-key hardening (2026-09-03)

**Registration-state bug (headline):** `WearablesService.isRegistered` compared
against `.available`. The DAT samples are unambiguous — `.registered` is the
authorized state; `.available` only means glasses are reachable but this app
hasn't completed the Meta AI handshake. Renamed to `isAuthorized == .registered`.
This propagated to `RootView` (button gate), `SettingsView`, and the coordinator's
`isDeviceReady`.

**Connection / authorization troubleshooting:**
- `GlassesError` now has typed cases: `notAuthorized`, `notConnected`,
  `metaAINotInstalled`, `glassesAppUpdateRequired`, `firmwareUpdateRequired`,
  `cameraPermissionNeeded/Denied`, `permissionRequestInProgress`, each with a
  user message and an optional `recovery` (connect / open update in Meta AI).
- `GlassesCameraService.ensureCameraPermission` maps DAT `PermissionError`
  (`.metaAINotInstalled`, `.noDevice`, `.requestInProgress`, `.requestTimeout`,
  `.connectionError`) to those cases instead of a blanket "denied".
- `GlassesDisplayService` rewritten: `send()` now **connects and throws** on
  failure (was fire-and-forget queue → silent no-op); maps
  `DeviceSessionError.datAppOnTheGlassesUpdateRequired` →
  `glassesAppUpdateRequired` + a callback that sets
  `WearablesService.requiresGlassesAppUpdate`; observes registration and tears
  the session down when authorization drops (mirrors the DisplayAccess sample).
- `WearablesService` watches `Compatibility` per device → `requiresFirmwareUpdate`;
  exposes `openFirmwareUpdate()` / `openGlassesAppUpdate()`; `handle(url:)` now
  filters for the `metaWearablesAction` query item (sample pattern) and surfaces
  `handleUrl` errors.
- `SettingsView` shows `connectionSummary`, connect/disconnect, and
  "Update in Meta AI" buttons when an update is required.

**API key:**
- `Secrets.xcconfig` is gitignored (verified `git check-ignore`); only
  `Secrets.xcconfig.example` is tracked.
- `ANTHROPIC_API_KEY[config=Release] =` — the build-time key is Debug-only; a
  Release build never carries it.
- Recommended path: enter the key in Settings → device Keychain (priority over
  the xcconfig value).
- `ClaudeClient.checkConnection()` → `GET /v1/models` (not token-billed) returns
  `ClaudeConnection` (`.ok(models:)` / `.unauthorized` / `.missingKey` /
  `.unreachable` / `.unexpected`). Surfaced as "Test Claude connection" in
  Settings.

**Tests:** 18/18 pass — added `ClaudeClientTests` (7: connection OK / 401 /
missing key / unreachable, solve happy-path, 429-retry, missing-key throw) with a
`URLProtocol` stub; `SolverCoordinatorTests` gains `testUnauthorizedShortCircuits`.

Simulator build green; app launches and stays running.

## 8. Next steps

- [ ] Add a DEBUG-only MockDeviceKit toggle in Settings to exercise the camera
      path without hardware (hook into `GlassesCameraService`).
- [ ] Decide: keep the camera `DeviceSession` alive to reuse for Display, or
      accept two sequential sessions.
- [ ] Tune `ProblemSolverPrompt` against real photos once hardware is available.
- [ ] Add app icon + launch assets.
