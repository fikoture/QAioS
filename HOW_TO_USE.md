# How to Use QAioS

A step-by-step guide, from install to a finished Jira ticket.

---

## 0. One-time setup

```bash
cd ~/Desktop/QAioS
./setup-codesign.sh    # creates a stable signing identity → permissions persist
./build.sh             # builds and signs QAioS.app
open QAioS.app
```

The first time a feature needs it, macOS will ask once for **Screen Recording**
and **Accessibility** — grant them and you won't be asked again (even after
rebuilds).

*(Optional)* To use the AI features, open **⚙︎ Settings › AI**, choose a provider
(e.g. **Groq**, which is fast), paste your API key, and **Save**. You can skip
this entirely and use the **Local** / **Manual** engines instead.

---

## 1. Choose a source and start monitoring

In the left panel:

1. **Source** — pick where the process runs:
   - **macOS** — an app on this Mac (e.g. `Safari`, `Finder`).
   - **Simulator** — an app in the booted iOS Simulator (needs full Xcode).
   - **Device** — a USB iPhone/iPad (needs `brew install libimobiledevice`).
2. **Process Name** — type the process, e.g. `Safari` or `QAErrorLab`.
3. Click **Start**. The dot turns green and the status shows "Monitoring…".

> On Start, QAioS also backfills the **last 10 minutes** of errors, so it catches
> failures that already happened (e.g. at app launch) even if you started
> monitoring late.

---

## 2. Drive the app under test

Use the target app normally. QAioS is doing three things automatically:

- **Streaming errors** into the right panel (ERROR / FATAL / EXCEPTION / CRASH).
- **Capturing evidence** at each error: a screenshot of the target app's window,
  a system snapshot, and (for FATAL/CRASH) an Instruments call-stack sample.
- **Recording your actions** *inside the target app* (app entry, clicks with UI
  element names, typing). These become timestamped test steps. Actions in other
  apps (including QAioS itself) are ignored.

### Try it with the bundled test app

Double-click **`QAErrorLab-Simulator.command`** on the Desktop to launch the
QAErrorLab test app in the Simulator. In QAioS set **Source = Simulator**,
**Process Name = `QAErrorLab`**, click **Start**, then in the app tap:

- **Log Console → Emit Error/Fault** — produces ERROR / FATAL log lines.
- **Handled Errors** — logs an error without crashing.
- **Force-Unwrap nil / Array Out of Range / fatalError / Uncaught NSException** —
  crash the app on purpose. Re-open the app afterward to keep testing.

---

## 3. Read and filter the errors

The right panel has three tabs:

- **Errors** — the live, deduplicated error stream. Above the list are **filter
  checkboxes** (Error / Fatal / Exception / Crash) with counts — tick/untick to
  focus. Repeated errors show an `×N` badge; captured screenshots show a camera
  icon.
- **Actions** — the auto-captured test steps.
- **Scenario** — load a CSV/text test scenario (one expected step per line) with
  **Load Template…**; QAioS auto-checks which steps your actions matched.

**Click a row** to open its detail window (message, context, system snapshot,
call-stack sample, screenshot). **Right-click a row** for:

- **Reproduction Steps** — a standalone repro report (AI).
- **Analyze This Error** — analyze just that one error (AI).
- **Show Details** / **Copy Log Line**.

---

## 4. Recognize bugs (which errors matter)

Not every error is a bug. Under **Bug Recognition**, click either:

- **AI Recognize** — smart AI triage with explanations (needs API key).
- **Local** — instant, offline, rule-based triage (no key). Categorizes each
  error, scores confidence, infers root cause (file:line + failing frame), and
  labels it.

Real bugs get a **🐞** badge; benign entries get a faded `noise` tag. The reason
is shown in the row's detail window.

---

## 5. Produce a Jira ticket

Under **Jira Ticket**, click either:

- **AI Ticket** — AI writes root-cause analysis + a full Jira ticket (needs key).
- **Manual** — an **enterprise, offline** ticket built locally: ticket fields,
  executive summary, per-bug breakdown (category, confidence, root cause,
  evidence, likely trigger action, expected/actual), Steps to Reproduce,
  attachments, and acceptance criteria.

A window opens with the ticket — click **Copy to Clipboard** and paste it into
Jira.

Other outputs:
- **Export HTML Report** — a single self-contained HTML file (screenshots
  embedded) revealed in Finder.
- **Settings › Notifications** — set a Slack/Teams webhook to get pinged on new
  CRASH/FATAL.

---

## 6. Stop and repeat

Click **Stop** to end monitoring (this also stops action recording and finalizes
the session recording). Use **Clear List** to reset before a new run.

---

## Typical end-to-end flow

1. `./build.sh && open QAioS.app`
2. Launch the app under test (e.g. `QAErrorLab-Simulator.command`).
3. QAioS: **Source = Simulator**, **Process = QAErrorLab**, **Start**.
4. Use the app / trigger errors.
5. **Local** (or **AI Recognize**) → bugs get 🐞.
6. **Manual** (or **AI Ticket**) → copy the Jira ticket.
7. Optionally **Export HTML Report** for a shareable artifact.

---

## Troubleshooting

- **No errors appear (Simulator):** the app only errors at startup, then sits
  idle. Keep monitoring active and re-launch/interact with the app; the 10-minute
  backfill also picks up recent startup errors. Make sure a Simulator is booted.
- **"Simulator monitoring needs full Xcode":** install Xcode and run
  `sudo xcode-select -s /Applications/Xcode.app`.
- **Screenshots are empty/black:** grant **Screen Recording** in System Settings
  and make sure the target window (or the Simulator window) is visible.
- **AI report is slow:** NVIDIA's free tier queues requests. Switch to **Groq**
  in Settings for ~2–3 s responses, or use the **Manual**/**Local** engines.
- **Actions aren't recorded:** grant **Accessibility**; actions are only recorded
  while the target app is frontmost.
