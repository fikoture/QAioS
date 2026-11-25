# QAioS: Log Monitoring and AI Bug Reporting for macOS

**by SentinelAI**

QAioS is a native macOS app (Swift / SwiftUI) that watches a target process's
unified log in real time, catches errors (`ERROR` / `FATAL` / `EXCEPTION` /
`CRASH`), captures rich evidence around each failure, and turns them into
developer-ready bug reports and Jira tickets, with **AI** or **fully offline
(local)** engines.

It reads the same log source Console.app uses, but headless. Console.app is
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
  target app** (app entry, clicks with UI element names, typing; content is never
  stored).
- **Test scenario templates:** load a CSV/text scenario and QAioS auto-checks
  which expected steps were performed.
- **Bug recognition, AI or Local:** decide which errors are real bugs vs. benign
  noise, with reasons. The local engine is rule-based, instant, offline.
- **Jira ticket, AI or Manual:** generate a full Jira ticket. The Manual engine
  is an **enterprise, offline** generator (category, confidence, root cause,
  component, labels, per-bug breakdown, acceptance criteria, evidence).
- **Reproduction steps** (right-click a bug) and a **self-contained HTML report**.
- **Slack/Teams webhook** notifications on new CRASH/FATAL.
- **Persistent permissions** via a stable code-signing identity (grant once).

---

## Install on your Mac

**Requirements**

- A Mac with macOS 14 (Sonoma) or newer, Apple Silicon or Intel
- Apple's command line tools (gives you `swiftc` and `git`). If you do not have
  them, run this once in Terminal and click **Install**:

  ```bash
  xcode-select --install
  ```

- Optional: full **Xcode** from the App Store, only if you want to monitor apps
  in the **iOS Simulator**.
- Optional: `brew install libimobiledevice`, only if you want to monitor a
  **USB-connected iPhone/iPad**.

**Steps**

```bash
git clone https://github.com/fikoture/QAioS.git
cd QAioS
./setup-codesign.sh   # once: creates a local signing identity so macOS remembers permissions
./build.sh            # compiles and signs QAioS.app (takes under a minute)
open QAioS.app
```

`build.sh` compiles the sources with `swiftc`, assembles a standard `.app`
bundle and signs it. Re-run `./build.sh` after any source change. No Xcode
project is needed.

> The app is packaged **without App Sandbox**. This is required so it can run
> the `log stream` subprocess.

If macOS says the app "cannot be opened", right-click `QAioS.app` in Finder,
choose **Open**, then **Open** again. This happens once for apps that are not
from the App Store.

---

## Test it in 5 minutes (no test app needed)

This walkthrough uses the built-in `logger` command, which writes to the same
unified log that QAioS watches. You need only Terminal and QAioS.

1. Open QAioS. Set **Source = macOS** and **Process Name = `logger`**, then click
   **Start**. The status dot turns green.
2. In Terminal, send one line for each severity:

   ```bash
   logger "QAioS test ERROR: payment request failed"
   logger "QAioS test FATAL: unexpectedly found nil while unwrapping"
   logger "QAioS test EXCEPTION: NSRangeException index 5 beyond bounds"
   logger "QAioS test CRASH: simulated crash"
   ```

   **Expected:** four rows appear in QAioS, tagged ERROR, FATAL, EXCEPTION and
   CRASH.
3. Send the same line three times:

   ```bash
   for i in 1 2 3; do logger "QAioS test ERROR: duplicate check"; done
   ```

   **Expected:** one row with a `x3` badge (deduplication).
4. Click **Local** under **Bug Recognition**. **Expected:** each error gets a
   category and a reason, without any network access.
5. Click **Manual** under **Jira Ticket**. **Expected:** a full ticket opens;
   **Copy to Clipboard** works.
6. Export the **HTML report**. **Expected:** a single self-contained HTML file
   with all errors and evidence.
7. Click **Stop**, send another `logger` line. **Expected:** no new row appears.

**AI features (optional).** Every AI button has an offline twin, so steps 1 to 7
work without a key. To try the AI buttons, either paste your own key in
**Settings > AI**, or start the app with a key from an environment variable:

```bash
NVIDIA_API_KEY=your_key_here ./QAioS.app/Contents/MacOS/QAioS
```

Supported variables: `NVIDIA_API_KEY`, `GROQ_API_KEY`, `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`. No key is stored in the source code.

**iOS Simulator (optional).** Boot any simulator in Xcode, run an app in it,
then in QAioS set **Source = Simulator** and **Process Name** to that app's name.

**Real iPhone/iPad (optional).** Connect it by USB, trust the computer, set
**Source = Device** and the app's process name.

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
./setup-codesign.sh   # run once: creates a persistent code-signing certificate
./build.sh            # from now on signs with that identity
```

The signature's designated requirement (bundle id + certificate) is stable
across rebuilds, so you grant the permissions **once** and macOS remembers them.

First-time prompts:
- **Screen Recording**: on the first screenshot (System Settings › Privacy &
  Security › Screen Recording → allow QAioS).
- **Accessibility**: when action capture starts (Test Steps tab › "Enable…").

> Merely launching the app never asks for anything. Permissions are requested
> only the first time the relevant feature (screenshot / action capture) is used.

---

## Sources (macOS / Simulator / Device)

- **macOS**: processes on this Mac (`/usr/bin/log stream`).
- **Simulator**: the booted iOS Simulator's log stream
  (`xcrun simctl spawn booted log stream`). Requires full Xcode. QAioS
  auto-locates Xcode and sets `DEVELOPER_DIR` even if the active toolchain is
  Command Line Tools; if Xcode is missing, it suggests
  `sudo xcode-select -s /Applications/Xcode.app`.
- **Device**: a USB iPhone/iPad via `idevicesyslog` (libimobiledevice).

All sources read the same unified log Console.app shows, **without opening
Console.app**.

### Backfill

`log stream` only shows *new* events, but many errors happen at app startup. On
**Start**, QAioS backfills the **last 10 minutes** (`log show --last 10m`) so
late-started monitoring still catches startup errors. Order no longer matters.

---

## Bug Recognition (AI vs. Local)

Two side-by-side buttons under **Bug Recognition**:

- **AI Recognize**: sends the deduplicated errors to your configured provider;
  smart, context-aware triage with explanations. Needs an API key.
- **Local**: rule-based, **instant, offline, free**. Categorizes each error
  (Nil-safety, Array Bounds, Uncaught Exception, Memory Access, Concurrency,
  Persistence, Network…), scores confidence, infers root cause (file:line +
  failing stack frame) and component, and assigns labels.

Bugs are marked **🐞** in the list; noise gets a faded `noise` tag. Details and
reasons appear in the detail window and the report.

---

## Jira Ticket (AI vs. Manual)

Two side-by-side buttons under **Jira Ticket**:

- **AI Ticket**: provider-written root-cause analysis + full Jira ticket
  (Summary, Priority, Component, Environment, Steps to Reproduce, Expected/Actual,
  Developer Handoff, call stack). Needs an API key.
- **Manual**: an **enterprise, offline** Jira ticket built by the local engine:
  ticket fields (Issue Type, Priority, Severity, Component, Labels, Frequency),
  executive summary, **per-bug breakdown** (category, confidence, root cause,
  signature, evidence, likely trigger action, expected/actual), overall Steps to
  Reproduce, attachments list, **acceptance criteria**, and a noise appendix.

Both open in a window with **Copy to Clipboard**. Paste into Jira.

---

## AI Settings (optional)

Open **⚙︎ Settings › AI**, pick a provider, enter the model name, and paste your
own API key. Nothing is hard-coded. If you prefer not to type a key in the UI,
QAioS reads it from an environment variable at launch
(`NVIDIA_API_KEY`, `GROQ_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY`):

| Provider | Endpoint | Model |
|---|---|---|
| NVIDIA NIM | fixed | your choice |
| Groq | fixed | your choice |
| Anthropic | fixed | your choice |
| **Other** | **editable**: any OpenAI-compatible endpoint (OpenAI, Azure, LM Studio, Ollama, in-house gateway) | your choice |

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

## Companion test app (optional)

To exercise QAioS, point it at any app that can raise errors on demand. A simple
iOS demo app with buttons for Handled Errors, Force-Unwrap nil, Array Out of
Range, fatalError/precondition, and Uncaught NSException works well: run it in
the Simulator, set **Source = Simulator** and **Process = <app name>** in QAioS,
then trigger each error and watch QAioS capture it.

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
