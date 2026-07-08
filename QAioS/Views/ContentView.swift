import SwiftUI
import AppKit

/// Ana ekran: solda kontrol paneli, sağda canlı hata log akışı.
struct ContentView: View {
    @EnvironmentObject private var monitor: LogMonitor
    @ObservedObject private var settings = AppSettings.shared

    @StateObject private var stepStore = TestStepStore()
    @StateObject private var actionRecorder = UserActionRecorder()
    @StateObject private var scenarioStore = ScenarioStore()

    private enum RightTab: String, CaseIterable, Identifiable {
        case errors = "Error Logs"
        case steps = "Test Steps"
        case scenario = "Scenario"
        var id: String { rawValue }
    }

    @State private var rightTab: RightTab = .errors
    /// Log ekranında gösterilecek severity'ler (filtre onay kutuları). Varsayılan: hepsi.
    @State private var visibleSeverities: Set<LogEntry.Severity> = Set(LogEntry.Severity.allCases)
    @State private var processName = ""
    @State private var source: LogSource = .mac
    @State private var selectedEntry: LogEntry?
    @State private var showSettings = false
    @State private var isAnalyzing = false
    @State private var isFindingBugs = false
    @State private var bugSummary: String?
    @State private var analysisElapsed = 0
    @State private var analysisTimer: Timer?
    @State private var analysisResult: String?
    @State private var errorMessage: String?
    @State private var showCopiedToast = false

    private let analysisService = AnalysisService()

    /// Eylem kaydının yalnızca içinde yapılacağı macOS uygulaması:
    /// macOS kaynağında hedef süreç, simülatörde "Simulator", cihazda yok.
    private var recorderTargetApp: String? {
        switch source {
        case .mac:       return processName.trimmingCharacters(in: .whitespaces)
        case .simulator: return "Simulator"
        case .device:    return nil   // etkileşim Mac'te değil → kayıt yok
        }
    }

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 270, maxWidth: 350)
            rightPanel
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .sheet(item: $selectedEntry) { entry in
            LogDetailView(entry: entry)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $analysisResult.asIdentifiable()) { result in
            AnalysisResultView(markdown: result.value)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
        // log stream dışarıdan sonlanırsa eylem kaydını da durdur.
        .onChange(of: monitor.isMonitoring) {
            if !monitor.isMonitoring { actionRecorder.stop() }
        }
        // Ayarlar düğmesi başlık çubuğunda — her zaman görünür.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("AI provider and API key settings")
            }
        }
    }

    // MARK: - Sol panel

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Büyük logo bloğu: ikon QAioS başlığının üzerinde, paneli
            // dolduracak boyutta ve ortalanmış. Ayarlar düğmesi pencere
            // başlık çubuğundadır (bkz. .toolbar aşağıda).
            VStack(spacing: 6) {
                // NSApp.applicationIconImage bundle'daki AppIcon.icns'i döndürür.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text("QAioS")
                    .font(.system(size: 34, weight: .bold))
                Text("by SentinelAI")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Kaynak seçimi: bu Mac'in süreçleri veya açık iOS Simülatörü
            Text("Source")
                .font(.headline)
            Picker("Source", selection: $source) {
                ForEach(LogSource.allCases) { src in
                    Text(src.label).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(monitor.isMonitoring)
            Group {
                switch source {
                case .mac:
                    Text("Scans processes running on this Mac via the unified log.")
                case .simulator:
                    Text("Scans the log stream of the booted iOS Simulator. The Simulator must be running.")
                case .device:
                    Text("Scans an iPhone/iPad connected over USB. Requires libimobiledevice (brew install libimobiledevice).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)   // yarım kalmasın, tam sarsın

            Text("Process Name")
                .font(.headline)
            TextField(source == .mac ? "e.g. Safari, Finder, myapp" : "e.g. MyApp (app on the device/Simulator)",
                      text: $processName)
                .textFieldStyle(.roundedBorder)
                .disabled(monitor.isMonitoring)
                .onSubmit {
                    if !monitor.isMonitoring {
                        monitor.start(processName: processName, source: source)
                        if monitor.isMonitoring { actionRecorder.start(store: stepStore, targetAppName: recorderTargetApp) }
                    }
                }

            Button {
                if monitor.isMonitoring {
                    monitor.stop()
                    actionRecorder.stop()
                } else {
                    monitor.start(processName: processName, source: source)
                    if monitor.isMonitoring {
                        // İzlemeyle birlikte kullanıcı eylemlerini de yakala.
                        actionRecorder.start(store: stepStore, targetAppName: recorderTargetApp)
                    }
                }
            } label: {
                Label(monitor.isMonitoring ? "Stop" : "Start",
                      systemImage: monitor.isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(monitor.isMonitoring ? .red : .green)
            .keyboardShortcut(.return, modifiers: .command)

            Divider()

            // Özellik 1: Logları tarayıp gerçek BUG'ları işaretle (gürültüden ayır).
            // İki yan yana buton: AI (akıllı, anahtar gerekli) ve Yerel (anında, çevrimdışı).
            Text("Bug Recognition")
                .font(.headline)
            HStack(spacing: 8) {
                Button {
                    findBugs()
                } label: {
                    if isFindingBugs {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("AI…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("AI Recognize", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(monitor.errorLogs.isEmpty || isFindingBugs || !settings.isConfigured)
                .help(settings.isConfigured
                      ? "AI marks which errors are real bugs (vs. noise) and explains why"
                      : "Configure an AI provider in Settings to use AI recognition")

                Button {
                    findBugsLocal()
                } label: {
                    Label("Local", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(monitor.errorLogs.isEmpty || isFindingBugs)
                .help("Offline, rule-based bug triage — instant, no API key needed")
            }
            .controlSize(.large)

            if let bugSummary {
                Text(bugSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Jira Ticket: iki yan yana buton — AI (akıllı, anahtar gerekli)
            // ve Manuel (yerel şablon, API'siz, anında).
            Text("Jira Ticket")
                .font(.headline)
            HStack(spacing: 8) {
                Button {
                    generateReport()
                } label: {
                    if isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("AI… \(analysisElapsed)s")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("AI Ticket", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(monitor.errorLogs.isEmpty || isAnalyzing || !settings.isConfigured)
                .help(settings.isConfigured
                      ? "AI writes root-cause analysis + full Jira ticket"
                      : "Configure an AI provider in Settings to use AI ticket")

                Button {
                    generateManualTicket()
                } label: {
                    Label("Manual", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .disabled(monitor.errorLogs.isEmpty || isAnalyzing)
                .help("Build a Jira ticket locally from a template (offline, no API key)")
            }
            .controlSize(.large)

            if isAnalyzing, settings.provider == .nvidia, analysisElapsed > 8 {
                Text("NVIDIA's free tier can queue requests for 1–2 min. For fast reports, switch to Groq in ⚙︎ Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Kendi kendine yeten HTML rapor.
            Button {
                exportHTMLReport()
            } label: {
                Label("Export HTML Report", systemImage: "doc.richtext")
                    .frame(maxWidth: .infinity)
            }
            .disabled(monitor.errorLogs.isEmpty && stepStore.steps.isEmpty)
            .help("Export a self-contained HTML report and reveal it in Finder")

            Button("Clear List") { monitor.clear() }
                .disabled(monitor.errorLogs.isEmpty)

            Spacer()

            // Durum çubuğu
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isMonitoring ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(monitor.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if showCopiedToast {
                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding()
    }

    // MARK: - Sağ panel: sekmeler (hata akışı / test adımları)

    private var rightPanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: $rightTab) {
                Text("Errors (\(monitor.errorLogs.count))").tag(RightTab.errors)
                Text("Actions (\(stepStore.steps.count))").tag(RightTab.steps)
                Text(scenarioStore.steps.isEmpty
                     ? "Scenario"
                     : "Scenario (\(scenarioStore.passedCount)/\(scenarioStore.steps.count))")
                    .tag(RightTab.scenario)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            // maxHeight: .infinity → içerik tüm yüksekliği doldursun,
            // sekme çubuğu panelin en üstüne sabitlensin.
            Group {
                switch rightTab {
                case .errors:   logList
                case .steps:    TestStepsView(store: stepStore, recorder: actionRecorder)
                case .scenario: ScenarioView(scenario: scenarioStore, stepStore: stepStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Canlı hata akışı

    /// Filtreye (seçili severity'ler) göre süzülmüş hata listesi.
    private var filteredLogs: [LogEntry] {
        monitor.errorLogs.filter { visibleSeverities.contains($0.severity) }
    }

    /// Severity başına yakalanan (tekilleştirme öncesi tekrarlar dahil) sayı.
    private func count(_ sev: LogEntry.Severity) -> Int {
        monitor.errorLogs.filter { $0.severity == sev }.reduce(0) { $0 + $1.occurrenceCount }
    }

    /// Log ekranının üstündeki filtre onay kutuları (Error / Fatal / Exception / Crash).
    private var filterBar: some View {
        HStack(spacing: 12) {
            ForEach(LogEntry.Severity.allCases, id: \.self) { sev in
                Toggle(isOn: Binding(
                    get: { visibleSeverities.contains(sev) },
                    set: { on in
                        if on { visibleSeverities.insert(sev) } else { visibleSeverities.remove(sev) }
                    }
                )) {
                    HStack(spacing: 4) {
                        Circle().fill(color(for: sev)).frame(width: 7, height: 7)
                        Text("\(sev.rawValue.capitalized) (\(count(sev)))")
                            .font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
                .help("Show/hide \(sev.rawValue) entries")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func color(for sev: LogEntry.Severity) -> Color {
        switch sev {
        case .exception: return .pink
        case .crash:     return .purple
        case .fault:     return .red
        case .error:     return .orange
        }
    }

    private var logList: some View {
        Group {
            if monitor.errorLogs.isEmpty {
                ContentUnavailableView(
                    "No errors yet",
                    systemImage: "checkmark.shield",
                    description: Text("Once monitoring starts, ERROR / FATAL / EXCEPTION / CRASH lines stream here. Use the filters above; click a row for details.")
                )
            } else {
                VStack(spacing: 0) {
                    filterBar
                    Divider()
                    if filteredLogs.isEmpty {
                        ContentUnavailableView(
                            "Nothing matches the filter",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("All matching severities are hidden. Enable a filter above.")
                        )
                    } else {
                        filteredList
                    }
                }
            }
        }
    }

    private var filteredList: some View {
        Group {
                ScrollViewReader { proxy in
                    List(filteredLogs) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedEntry = entry }  // tıklayınca detay aç
                            .help("Click to see details · right-click to analyze")
                            // Sağ tık menüsü: bu hatayı analiz et / detay / kopyala.
                            .contextMenu {
                                // Özellik 2: Repro talimatı (özellikle bug'lar için).
                                Button {
                                    reproSteps(for: entry)
                                } label: {
                                    Label("Reproduction Steps (Repro Report)", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(isAnalyzing)
                                Button {
                                    analyzeSingle(entry)
                                } label: {
                                    Label("Analyze This Error & Prepare Report", systemImage: "sparkles")
                                }
                                .disabled(isAnalyzing)
                                Button {
                                    selectedEntry = entry
                                } label: {
                                    Label("Show Details", systemImage: "info.circle")
                                }
                                Divider()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        "[\(entry.timestamp)] [\(entry.severity.rawValue)] \(entry.subsystem) — \(entry.message)",
                                        forType: .string)
                                } label: {
                                    Label("Copy Log Line", systemImage: "doc.on.doc")
                                }
                            }
                    }
                    .listStyle(.inset)
                    // Yeni log geldikçe (filtreye takılıysa) otomatik en alta kaydır.
                    .onChange(of: filteredLogs.count) {
                        if let last = filteredLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
        }
    }

    // MARK: - Export

    private var targetName: String {
        processName.isEmpty ? (monitor.errorLogs.first?.processName ?? "?") : processName
    }

    private var scenarioMarkdown: String? {
        scenarioStore.steps.isEmpty ? nil : scenarioStore.markdown
    }

    /// Instruments/trace bilgisi (varsa) — analize eklenir.
    private var instrumentsInfo: String? { monitor.capture.instrumentsSummary }

    /// Özellik 1: Logları AI ile triyaj edip gerçek bug'ları işaretler.
    private func findBugs() {
        let logs = monitor.errorLogs
        isFindingBugs = true
        bugSummary = nil
        Task {
            defer { isFindingBugs = false }
            do {
                let verdicts = try await analysisService.classifyBugs(logs: logs)
                monitor.applyBugVerdicts(verdicts)
                let bugCount = verdicts.values.filter(\.isBug).count
                bugSummary = "\(bugCount) bug\(bugCount == 1 ? "" : "s") found (AI) among \(logs.count) unique errors. Bugs are marked 🐞; right-click a bug for reproduction steps."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Yerel (API'siz) kural tabanlı bug triyajı — anında, çevrimdışı.
    private func findBugsLocal() {
        let logs = monitor.errorLogs
        let verdicts = LocalBugClassifier.classify(logs)
        monitor.applyBugVerdicts(verdicts)
        let bugCount = verdicts.values.filter(\.isBug).count
        bugSummary = "\(bugCount) bug\(bugCount == 1 ? "" : "s") found (offline heuristic) among \(logs.count) unique errors. 🐞 = bug. For a smarter triage with reasons, use Analyze with AI."
    }

    /// Özellik 2: Tek bir bug için repro talimatını ayrı rapor olarak üretir.
    private func reproSteps(for entry: LogEntry) {
        let name = targetName
        beginAnalyzing()
        Task {
            defer { endAnalyzing() }
            do {
                analysisResult = try await analysisService.reproductionSteps(
                    for: entry, steps: stepStore.steps, processName: name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Analiz süresini sayan gösterge zamanlayıcısını başlatır.
    private func beginAnalyzing() {
        isAnalyzing = true
        analysisElapsed = 0
        analysisTimer?.invalidate()
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            analysisElapsed += 1
        }
    }

    private func endAnalyzing() {
        isAnalyzing = false
        analysisTimer?.invalidate()
        analysisTimer = nil
    }

    /// Tek bir hatayı (sağ tık) analiz edip raporunu hazırlar.
    private func analyzeSingle(_ entry: LogEntry) {
        let name = targetName
        let scenario = scenarioMarkdown
        let instruments = instrumentsInfo

        // Anahtar yoksa: bu hatanın Markdown raporunu panoya kopyala.
        guard settings.isConfigured else {
            copyToClipboard(analysisService.markdownReport(
                logs: [entry], steps: stepStore.steps,
                scenarioMarkdown: scenario, instrumentsInfo: instruments, processName: name))
            return
        }

        beginAnalyzing()
        Task {
            defer { endAnalyzing() }
            do {
                analysisResult = try await analysisService.analyze(
                    logs: [entry], steps: stepStore.steps,
                    scenarioMarkdown: scenario, instrumentsInfo: instruments, processName: name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// AI ile: kök neden analizi + tam Jira ticket'ı üretir (anahtar gerekli).
    private func generateReport() {
        let logs = monitor.errorLogs
        let name = targetName
        let steps = stepStore.steps
        let scenario = scenarioMarkdown

        beginAnalyzing()
        Task {
            defer { endAnalyzing() }
            do {
                analysisResult = try await analysisService.analyze(
                    logs: logs, steps: steps, scenarioMarkdown: scenario,
                    instrumentsInfo: instrumentsInfo, processName: name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Manuel (yerel, API'siz): kurumsal Jira ticket'ı üretir (yerel triyaj +
    /// kanıtlar), listede bug rozetlerini işaretler ve pencerede gösterir.
    private func generateManualTicket() {
        let logs = monitor.errorLogs
        // Listedeki 🐞 rozetleri de dolsun.
        monitor.applyBugVerdicts(LocalBugClassifier.classify(logs))

        var art = JiraTicketBuilder.Artifacts()
        art.screenshotPaths = logs.compactMap(\.screenshotPath)
        art.videoPath = monitor.capture.sessionVideoPath
        art.tracePath = monitor.capture.sessionTracePath

        analysisResult = JiraTicketBuilder.build(
            processName: targetName,
            source: source.label,
            logs: logs,
            steps: stepStore.steps,
            scenarioMarkdown: scenarioMarkdown,
            artifacts: art)
    }

    /// Kendi kendine yeten HTML raporu üretir ve Finder'da gösterir.
    private func exportHTMLReport() {
        let name = targetName
        do {
            let url = try SessionExporter.exportHTML(
                processName: name,
                logs: monitor.errorLogs,
                steps: stepStore.steps,
                scenario: scenarioStore,
                videoPath: monitor.capture.sessionVideoPath,
                tracePath: monitor.capture.sessionTracePath,
                to: monitor.capture.sessionDir)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = "HTML export failed: \(error.localizedDescription)"
        }
    }


    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showCopiedToast = false }
    }
}

// MARK: - Tek log satırı görünümü

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.severity.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(severityColor)
                // Bug triyaj rozeti: gerçek bug 🐞, gürültü ise soluk "noise".
                if let bug = entry.bug {
                    if bug.isBug {
                        Text("🐞 BUG · \(bug.severity)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.2), in: Capsule())
                            .foregroundStyle(.red)
                    } else {
                        Text("noise")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(entry.timestamp)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if entry.occurrenceCount > 1 {
                    Text("×\(entry.occurrenceCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.25), in: Capsule())
                }
                if entry.screenshotPath != nil {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Screenshot captured")
                }
                if !entry.subsystem.isEmpty {
                    Text(entry.subsystem)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(entry.message)
                .font(.callout.monospaced())
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var severityColor: Color {
        switch entry.severity {
        case .exception: return .pink
        case .crash: return .purple
        case .fault: return .red
        case .error: return .orange
        }
    }
}

// MARK: - AI analiz sonucu sheet'i

private struct AnalysisResultView: View {
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Root Cause Analysis & Jira Ticket")
                .font(.title2.bold())
            ScrollView {
                Text(markdown)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 440)
    }
}

// MARK: - String'i sheet(item:) ile kullanabilmek için küçük yardımcı

private struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

private extension Binding where Value == String? {
    func asIdentifiable() -> Binding<IdentifiableString?> {
        Binding<IdentifiableString?>(
            get: { wrappedValue.map(IdentifiableString.init(value:)) },
            set: { wrappedValue = $0?.value }
        )
    }
}
