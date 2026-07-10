# QAioS — Log Monitoring & AI Bug Reporting for macOS

**by SentinelAI**

QAioS is a native macOS app (Swift / SwiftUI) that watches a target process's
unified log in real time, catches errors (`ERROR` / `FATAL` / `EXCEPTION` /
`CRASH`), captures rich evidence around each failure, and turns them into
developer-ready bug reports and Jira tickets — with **AI** or **fully offline
(local)** engines.

It reads the same log source Console.app uses, but headless — Console.app is
never opened.

---

## Highlights

- **Three sources:** this Mac (`macOS`), a booted **iOS Simulator**, or a
  USB-connected **iPhone/iPad** (`idevicesyslog`).
- **Catches ERROR / FATAL / EXCEPTION / CRASH** with checkbox filters per level.
- **Crash reports** from `~/Library/Logs/DiagnosticReports` (Console.app's "Crash
  Reports" equivalent) are folded into the stream.
- **Deduplication:** identical errors collapse into one row with an `×N` badge.
- **Evidence at error time:** pre-error context, system snapshot (CPU/MEM/RSS),
  Instruments call-stack sample (`/usr/bin/sample`), and a **screenshot of only
  the target app's window** (not the whole screen).
- **Session recording** (`.mov`) and optional **Instruments trace** (`xctrace`).
- **Automatic test-step capture:** records what the tester does **inside the
  target app** (app entry, clicks with UI element names, typing — content never
  stored).
- **Test scenario templates:** load a CSV/text scenario and QAioS auto-checks
  which expected steps were performed.
- **Bug recognition — AI or Local:** decide which errors are real bugs vs. benign
  noise, with reasons. The local engine is rule-based, instant, offline.
- **Jira ticket — AI or Manual:** generate a full Jira ticket. The Manual engine
  is an **enterprise, offline** generator (category, confidence, root cause,
  component, labels, per-bug breakdown, acceptance criteria, evidence).
- **Reproduction steps** (right-click a bug) and a **self-contained HTML report**.
- **Slack/Teams webhook** notifications on new CRASH/FATAL.
- **Persistent permissions** via a stable code-signing identity (grant once).

---

## Requirements

- macOS 14.0+
- **Xcode** (full install) is required only for the **Simulator** source
  (`simctl`); the macOS source works without it.
- For the **Device** source: `brew install libimobiledevice`.
- An AI provider API key is optional — every AI feature has a local/offline
  counterpart.

---

## Quick Start (no Xcode project needed)

```bash
cd ~/Desktop/QAioS
./setup-codesign.sh   # ONCE: creates a stable signing identity (persistent permissions)
./build.sh            # compiles, bundles and signs QAioS.app
open QAioS.app        # or double-click in Finder
```

`build.sh` compiles the sources with `swiftc`, assembles a standard `.app`
bundle, and signs it. Re-run `./build.sh` after any source change.

> The app is packaged **without App Sandbox** — this is required so it can spawn
> the `log stream` subprocess.

### Alternative: Xcode project

1. Create a macOS SwiftUI app named `QAioS` (min deployment macOS 14).
2. Delete Xcode's generated `QAioSApp.swift`/`ContentView.swift` and add the
   files from `QAioS/`.
3. Under **Target › Signing & Capabilities**, remove **App Sandbox**.

---

## Persistent Permissions (one-time)

QAioS needs **Screen Recording** (screenshots/video) and **Accessibility**
(action capture). Because an ad-hoc signature changes on every build, macOS
resets those grants each time. To avoid that, QAioS signs with a **stable
self-signed identity**:

```bash
./setup-codesign.sh   # run once — creates a persistent code-signing certificate
./build.sh            # from now on signs with that identity
```

The signature's designated requirement (bundle id + certificate) is stable
across rebuilds, so you grant the permissions **once** and macOS remembers them.

First-time prompts:
- **Screen Recording** — on the first screenshot (System Settings › Privacy &
  Security › Screen Recording → allow QAioS).
- **Accessibility** — when action capture starts (Test Steps tab › "Enable…").

> Merely launching the app never asks for anything — permissions are requested
> only the first time the relevant feature (screenshot / action capture) is used.

---

## Sources (macOS / Simulator / Device)

- **macOS** — processes on this Mac (`/usr/bin/log stream`).
- **Simulator** — the booted iOS Simulator's log stream
  (`xcrun simctl spawn booted log stream`). Requires full Xcode. QAioS
  auto-locates Xcode and sets `DEVELOPER_DIR` even if the active toolchain is
  Command Line Tools; if Xcode is missing, it suggests
  `sudo xcode-select -s /Applications/Xcode.app`.
- **Device** — a USB iPhone/iPad via `idevicesyslog` (libimobiledevice).

All sources read the same unified log Console.app shows, **without opening
Console.app**.

### Backfill

`log stream` only shows *new* events, but many errors happen at app startup. On
**Start**, QAioS backfills the **last 10 minutes** (`log show --last 10m`) so
late-started monitoring still catches startup errors — order no longer matters.

---

## Bug Recognition (AI vs. Local)

Two side-by-side buttons under **Bug Recognition**:

- **AI Recognize** — sends the deduplicated errors to your configured provider;
  smart, context-aware triage with explanations. Needs an API key.
- **Local** — rule-based, **instant, offline, free**. Categorizes each error
  (Nil-safety, Array Bounds, Uncaught Exception, Memory Access, Concurrency,
  Persistence, Network…), scores confidence, infers root cause (file:line +
  failing stack frame) and component, and assigns labels.

Bugs are marked **🐞** in the list; noise gets a faded `noise` tag. Details and
reasons appear in the detail window and the report.

---

## Jira Ticket (AI vs. Manual)

Two side-by-side buttons under **Jira Ticket**:

- **AI Ticket** — provider-written root-cause analysis + full Jira ticket
  (Summary, Priority, Component, Environment, Steps to Reproduce, Expected/Actual,
  Developer Handoff, call stack). Needs an API key.
- **Manual** — an **enterprise, offline** Jira ticket built by the local engine:
  ticket fields (Issue Type, Priority, Severity, Component, Labels, Frequency),
  executive summary, **per-bug breakdown** (category, confidence, root cause,
  signature, evidence, likely trigger action, expected/actual), overall Steps to
  Reproduce, attachments list, **acceptance criteria**, and a noise appendix.

Both open in a window with **Copy to Clipboard** — paste into Jira.

---

## AI Settings (optional)

Open **⚙︎ Settings › AI**, pick a provider, enter the model name, and paste your
own API key (everything is entered manually — nothing is hard-coded):

| Provider | Endpoint | Model |
|---|---|---|
| NVIDIA NIM | fixed | your choice |
| Groq | fixed | your choice |
| Anthropic | fixed | your choice |
| **Other** | **editable** — any OpenAI-compatible endpoint (OpenAI, Azure, LM Studio, Ollama, in-house gateway) | your choice |

> **Provider speed & limits matter.** The same model can take seconds on one
> provider and minutes on another, and free tiers differ in rate limits (some
> reject rapid back-to-back requests). Pick the provider/model that best fits your
> latency and quota needs; the analyze button shows elapsed seconds so you can
> compare. Every AI feature also has a **Local / Manual** offline counterpart.

Other settings tabs: **Notifications** (Slack/Teams webhook on new CRASH/FATAL)
and **Capture** (screenshot / session recording / Instruments trace toggles).

> All keys are stored in `UserDefaults` (fine for a personal machine; move to
> Keychain before distributing).

---

## Companion: QAErrorLab (test app)

`~/Desktop/QAErrorLab/` is a working iOS demo app that also triggers every error
type on demand — for exercising QAioS. It uses **no audio/network/timers**, so it
doesn't consume system resources. 8 screens: a working Playground and Log
Console, plus Handled Errors, Force-Unwrap nil, Array Out of Range,
fatalError/precondition, and Uncaught NSException.

One-click launchers on the Desktop:
- `QAErrorLab-Simulator.command` — build + boot + install + launch QAErrorLab.
- `QuantumHz-Simulator.command` — same for the QuantumHz project.

---

## Project Layout

```
build.sh                         # builds & signs QAioS.app
setup-codesign.sh                # one-time stable signing identity
QAioS/
├── QAioSApp.swift               # entry point + permission notes
├── Info.plist
├── Models/LogEntry.swift        # LogEntry, Severity, BugVerdict, scenario, steps
├── Services/
│   ├── LogMonitor.swift         # log stream/show → dedup → @Published
│   ├── CaptureService.swift     # window screenshot, session video, sample, xctrace
│   ├── UserActionRecorder.swift # target-app-scoped action capture
│   ├── AnalysisService.swift    # AI provider routing (Anthropic + OpenAI-compatible)
│   ├── LocalBugClassifier.swift # offline enterprise bug triage
│   ├── JiraTicketBuilder.swift  # offline enterprise Jira ticket
│   ├── SessionExporter.swift    # self-contained HTML report
│   ├── AppSettings.swift        # providers, keys, capture/notify settings
│   └── JiraService.swift        # Slack/Teams webhook
└── Views/                       # ContentView, Settings, LogDetail, TestSteps, Scenario
```

See **HOW_TO_USE.md** for a step-by-step walkthrough.
