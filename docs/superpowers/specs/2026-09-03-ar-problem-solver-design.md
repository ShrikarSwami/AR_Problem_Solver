# AR_Problem_Solver — Design Spec

**Date:** 2026-09-03
**Status:** Approved — scaffolding phase
**SDK verified against:** `facebook/meta-wearables-dat-ios` v0.9.0 (cloned and read: `samples/CameraAccess`, `samples/DisplayAccess`, `AGENTS.md`)

## 1. Goal

An iOS app that lets a wearer of Meta Ray-Ban Display glasses:

1. Capture a photo of a problem (a math worksheet, a broken appliance, a wiring
   diagram) from the glasses camera.
2. Send that image to the Claude API with a system prompt tuned for
   step-by-step problem breakdown.
3. Read the solution back on the glasses display as a paginated,
   teleprompter-style flow, advancing pages with the Meta Neural Wristband.

## 2. Constraints & environment

| Item | Decision |
|------|----------|
| Min iOS | 17.0 (matches Meta's samples; enables `@Observable` / `Observation`) |
| Project generation | XcodeGen — `project.yml` is the source of truth, `.xcodeproj` is generated and gitignored |
| Dependency | `https://github.com/facebook/meta-wearables-dat-ios` v0.9.0 via SPM (declared in `project.yml`) |
| DAT modules | `MWDATCore`, `MWDATCamera`, `MWDATDisplay` (app); `MWDATMockDevice` (tests + DEBUG) |
| Claude API key | `Secrets.xcconfig` (gitignored) for dev builds; in-app Settings field stored in Keychain overrides at runtime; `Secrets.xcconfig.example` committed |
| Claude model | `claude-sonnet-5`, Messages API `POST /v1/messages`, `anthropic-version: 2023-06-01`, non-streaming for v1 |

## 3. Module layout

```
Sources/AR_Problem_Solver/
  App/
    AR_Problem_SolverApp.swift    Wearables.configure(); .onOpenURL -> handleUrl; injects AppModel
    AppModel.swift                top-level @Observable app state, owns services + coordinator
    RootView.swift                capture button, status, results list, Settings sheet
  Wearables/
    WearablesService.swift        wraps Wearables.shared: configure, registration, devicesStream, permissions
    GlassesCameraService.swift    DeviceSession -> addCamera -> stream.capturePhoto(.jpeg) -> PhotoData
    GlassesDisplayService.swift   DeviceSession -> addDisplay -> send(DisplayableView); routes tap callbacks
    WearablesProtocols.swift      CameraProviding, DisplayProviding — seams for tests
  Claude/
    ClaudeClient.swift            URLSession call to /v1/messages; ProblemSolving conformance
    ClaudeModels.swift            Codable request/response; base64 image content block
    ProblemSolverPrompt.swift     system prompt string + output contract
  Solver/
    SolverCoordinator.swift       capture -> package -> call Claude -> parse -> hand to teleprompter
    SolutionStep.swift            parsed step model
    SolutionParser.swift          response text -> [SolutionStep]
  Display/
    TeleprompterController.swift  page index; next/previous/repeat; re-sends on change
    TeleprompterDisplay.swift     [SolutionStep] + index -> one root MWDATDisplay.FlexBox page
  Settings/
    SettingsView.swift            API key entry, device/registration status, MockDevice toggle (DEBUG)
    KeychainStore.swift           minimal Keychain wrapper for the API key
  Support/
    Secrets.swift                 reads ANTHROPIC_API_KEY from Info.plist (populated by xcconfig)
    AppLog.swift                  os.Logger wrapper
Tests/AR_Problem_SolverTests/
    SolutionParserTests.swift
    SolverCoordinatorTests.swift  fakes for CameraProviding / DisplayProviding / ProblemSolving
project.yml
Secrets.xcconfig.example
Progress.md
```

## 4. Data flow

1. **Capture** — `SolverCoordinator.solve()` calls `GlassesCameraService.capturePhoto()`:
   `wearables.createSession(deviceSelector: AutoDeviceSelector(wearables:))` ->
   `session.start()` -> await `session.stateStream()` == `.started` ->
   `session.addCamera(config: StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 24))` ->
   `camera.stream.start()` -> await `stream.statePublisher` == `.streaming` ->
   `stream.capturePhoto(format: .jpeg)` -> first value from `stream.photoDataPublisher`
   (`PhotoData.data`) -> `camera.stop()`, `session.stop()`.
2. **Package** — JPEG `Data` -> base64 -> Claude `image` content block (`media_type: image/jpeg`)
   plus a short user text. System prompt = `ProblemSolverPrompt.system`.
3. **Call** — `ClaudeClient.solve(imageJPEG:)` -> `POST https://api.anthropic.com/v1/messages`.
   Key resolution order: Keychain (in-app) -> `Secrets` (xcconfig) -> throw `ClaudeError.missingAPIKey`.
4. **Parse** — `SolutionParser.parse(_:)` splits the response on the numbered-step
   contract. Fallback: entire text as a single step.
5. **Render** — `TeleprompterController` holds `[SolutionStep]` + `index`.
   `TeleprompterDisplay.page(step:index:count:)` returns one root `FlexBox`
   (`MWDATDisplay.Text` heading "Step n / N", body text, `ButtonGroup { Previous / Next / Repeat }`).
   `GlassesDisplayService.send(_:)` is called on every index change. Button `onClick`
   closures mutate the controller and trigger the next `send`. Wristband pinch =
   the gesture that fires those `Button` handlers (DAT 0.9 has no scroll primitive).

## 5. Key decisions

- **Teleprompter is pagination, not free scrolling.** The Display DSL exposes
  `FlexBox`/`Text`/`Button`/`ButtonGroup`/`Image`/`VideoPlayer` only. The
  `CarMaintenanceDisplay.tutorialStep` sample is the exact precedent. Long step
  bodies are soft-chunked to a character budget so each page fits the viewport.
- **Services sit behind protocols** (`CameraProviding`, `DisplayProviding`,
  `ProblemSolving`) so `SolverCoordinator` is unit-testable with fakes, and the
  camera path is exercisable with MockDeviceKit.
- **Sessions:** camera and display each create their own `DeviceSession`. A
  future optimization may reuse one session for both capabilities; not attempted
  in v1.
- **Info.plist** carries the full DAT block: `MWDAT` (`AppLinkURLScheme`,
  `MetaAppID`, `ClientToken`, `TeamID`, `DAMEnabled = true`), Bluetooth /
  local-network / Bonjour keys, `UISupportedExternalAccessoryProtocols` =
  `com.meta.ar.wearable`, `LSApplicationQueriesSchemes` = `fb-viewapp`,
  background modes (`bluetooth-central`, `bluetooth-peripheral`, `processing`).
  All identifiers come from `$(VAR)` build settings fed by xcconfig.
- **No secrets committed.** `Secrets.xcconfig` and `*.xcodeproj` are gitignored;
  `Secrets.xcconfig.example` is the template.

## 6. Out of scope for v1

- Video capture / live preview on the phone (photo only).
- Streaming Claude responses (non-streaming request/response only).
- Reusing a single `DeviceSession` across camera + display.
- Persisting past solutions.
- Localization.

## 7. What cannot be verified in this environment

End-to-end operation requires: physical Ray-Ban Display glasses + Neural Band,
Meta AI app pairing, a Wearables Developer Center app registration
(`MetaAppID` / `ClientToken`), and an Anthropic API key. Without hardware,
MockDeviceKit covers the camera path only — the Display module has no mock, so
`GlassesDisplayService` and `TeleprompterDisplay` are code-complete but
unverifiable here. This session's verification target is: `xcodegen generate`
succeeds and `xcodebuild ... build` compiles against the resolved DAT package.

## 8. Verification

```
xcodegen generate
xcodebuild -scheme AR_Problem_Solver \
  -destination 'generic/platform=iOS Simulator' build
```

If SPM cannot reach GitHub to resolve the DAT package in this environment, that
is reported as a blocker — not worked around with stubs.
