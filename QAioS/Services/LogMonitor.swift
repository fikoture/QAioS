import Foundation
import Combine

/// Logların nereden okunacağını belirler.
enum LogSource: String, CaseIterable, Identifiable {
    /// Bu Mac'te çalışan süreçler (`/usr/bin/log stream`).
    case mac
    /// Açık (booted) iOS Simulator içindeki süreçler
    /// (`xcrun simctl spawn booted log stream`).
    case simulator
    /// USB ile bağlı iPhone/iPad (`idevicesyslog`, libimobiledevice).
    case device

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac:       return "macOS"
        case .simulator: return "Simulator"
        case .device:    return "Device"
        }
    }
}

/// Unified log'u gerçek zamanlı izler — Console.app'in gösterdiği veri
/// kaynağının ta kendisi, ama Console.app hiç açılmadan (headless).
///
/// Kaynaklar:
///   • macOS      → /usr/bin/log stream (ndjson)
///   • Simulator  → xcrun simctl spawn booted log stream (ndjson)
///   • Device     → idevicesyslog (USB'ye bağlı iPhone/iPad, düz metin syslog)
///
/// Ek yakalamalar:
///   • Hata bağlamı: hatadan hemen önceki log satırları (repro için).
///   • Sistem anlık görüntüsü: hata anında hedef sürecin CPU/MEM/RSS durumu
///     + sistem load/bellek özeti (Instruments benzeri hafif veri).
///   • Crash report'lar: Console.app'in "Crash Reports" bölümünün izlediği
///     ~/Library/Logs/DiagnosticReports klasörü izlenir; hedef sürece ait
///     yeni .ips/.crash dosyaları CRASH kaydı olarak akışa düşer.
///
/// İZİN NOTU: Bu sınıfın çalışması için App Sandbox kapalı olmalıdır
/// (bkz. QAioSApp.swift üstündeki açıklama).
final class LogMonitor: ObservableObject {

    // MARK: - SwiftUI'ya yayınlanan durum

    /// Sadece hata içeren (CRASH / ERROR / FATAL) log satırları. UI buna bağlanır.
    @Published private(set) var errorLogs: [LogEntry] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var statusMessage = "Ready"

    // MARK: - Özel durum

    private enum ParseMode { case ndjson, deviceSyslog }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = Data()
    private var stderrBuffer = Data()
    private let decoder = JSONDecoder()
    private static let maxEntries = 1000
    private static let contextSize = 6                 // hata öncesi saklanan satır sayısı

    private var parseMode: ParseMode = .ndjson
    private var activeSource: LogSource = .mac
    private var targetName = ""

    /// Hatadan önceki son satırlar (tüm seviyeler) — repro bağlamı.
    /// Yalnızca stdout okuma thread'inde erişilir.
    private var recentLines: [String] = []

    /// Anlık görüntü üretimini sınırlamak için (hata fırtınalarında ps spam'i olmasın).
    private var lastSnapshot: SystemSnapshot?
    private var lastSnapshotAt = Date.distantPast
    private var targetPID: Int32?

    /// Crash report klasör izleyicisi.
    private var crashWatcher: DispatchSourceFileSystemObject?
    private var seenCrashFiles = Set<String>()
    private static let crashDir = NSString(string: "~/Library/Logs/DiagnosticReports").expandingTildeInPath

    // Tekilleştirme: imza → errorLogs içindeki index.
    private var signatureIndex: [String: Int] = [:]
    /// Çağrı yığını örneği alınmış imzalar (tekrar örneklememek için).
    private var sampledSignatures = Set<String>()
    /// İzleme başlarken "bilinen" (baseline) sayılan imzalar; yeni/bilinen ayrımı için.
    private(set) var baselineSignatures = Set<String>()

    /// Kanıt yakalama (ekran görüntüsü/video/trace).
    let capture = CaptureService()
    /// Oturum sonrası dışa aktarım için CaptureService'e erişim sağlanır.

    deinit { stop() }

    // MARK: - Kontrol

    func start(processName rawName: String, source: LogSource = .mac) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Enter a process name first."
            return
        }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\'")) == nil else {
            statusMessage = "Process name cannot contain quotes."
            return
        }

        stop()

        let streamArgs = [
            "stream",
            "--style", "ndjson",
            "--level", "debug",
            "--predicate", "process == \"\(name)\"",
        ]

        let process = Process()
        switch source {
        case .mac:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = streamArgs
            parseMode = .ndjson
        case .simulator:
            // `xcrun simctl`, aktif geliştirici dizini tam Xcode değilse (yalnızca
            // Command Line Tools kuruluysa) "unable to find utility simctl" verir.
            // Tam Xcode'u bulup DEVELOPER_DIR'i ayarlayarak bunu aşıyoruz.
            guard let devDir = Self.fullXcodeDeveloperDir() else {
                statusMessage = "Simulator monitoring needs full Xcode. Install Xcode, then run:\nsudo xcode-select -s /Applications/Xcode.app"
                return
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "spawn", "booted", "log"] + streamArgs
            var env = ProcessInfo.processInfo.environment
            env["DEVELOPER_DIR"] = devDir
            process.environment = env
            parseMode = .ndjson
        case .device:
            // USB'ye bağlı gerçek cihaz: libimobiledevice'ın idevicesyslog aracı.
            // Kurulum: brew install libimobiledevice
            guard let syslogPath = Self.findExecutable("idevicesyslog") else {
                statusMessage = "idevicesyslog not found. Install it with: brew install libimobiledevice"
                return
            }
            process.executableURL = URL(fileURLWithPath: syslogPath)
            process.arguments = ["--no-colors"]        // düz metin; filtreyi biz yaparız
            parseMode = .deviceSyslog
        }

        activeSource = source
        targetName = name
        targetPID = nil
        lastSnapshot = nil
        lastSnapshotAt = .distantPast
        recentLines.removeAll()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consume(chunk)
        }

        stderrBuffer.removeAll()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            if self.stderrBuffer.count < 4096 { self.stderrBuffer.append(chunk) }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.isMonitoring = false
                if proc.terminationStatus == 0 {
                    self.statusMessage = "Monitoring stopped."
                } else {
                    let detail = String(data: self.stderrBuffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.statusMessage = detail.isEmpty
                        ? "log stream exited (code \(proc.terminationStatus)). Check sandbox/permission settings."
                        : "Failed to start: \(detail)"
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            self.lineBuffer.removeAll()
            self.signatureIndex.removeAll()
            self.sampledSignatures.removeAll()
            // Mevcut hataları baseline say — yalnızca yeni imzalar "new" işaretlenir.
            self.baselineSignatures = Set(errorLogs.map(\.signature))
            isMonitoring = true
            statusMessage = "Monitoring \"\(name)\" (\(source.label))…"
            startCrashWatcher()                        // Console.app'in Crash Reports karşılığı
            // Kanıt yakalama oturumunu başlat (ekran görüntüsü/video/trace).
            let settings = AppSettings.shared
            capture.startSession(processName: name,
                                 recordVideo: settings.recordVideo,
                                 recordTrace: settings.recordTrace)
            // `log stream` yalnızca YENİ olayları gösterir. Uygulama açılışında
            // (izlemeden önce) oluşan hataları kaçırmamak için son birkaç dakikayı
            // geri getir. Böylece "önce başlat/sonra başlat" sırası önemli olmaz.
            backfillRecentErrors(name: name, source: source)
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription) (is App Sandbox disabled?)"
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        crashWatcher?.cancel()
        crashWatcher = nil
        capture.stopSession()                          // video/trace'i düzgün finalize et
        if isMonitoring {
            isMonitoring = false
            statusMessage = "Monitoring stopped."
        }
    }

    func clear() { errorLogs.removeAll() }

    /// AI triyaj sonuçlarını (id → verdict) kayıtlara işler. Ana thread'de çağrılır.
    func applyBugVerdicts(_ verdicts: [UUID: BugVerdict]) {
        for (id, verdict) in verdicts {
            if let idx = errorLogs.firstIndex(where: { $0.id == id }) {
                errorLogs[idx].bug = verdict
            }
        }
    }

    // MARK: - Satır işleme

    private func consume(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            switch parseMode {
            case .ndjson:       parseNDJSONLine(lineData)
            case .deviceSyslog: parseDeviceLine(lineData)
            }
        }
    }

    /// macOS / Simülatör: `log stream --style ndjson` satırı.
    private func parseNDJSONLine(_ data: Data) {
        guard !data.isEmpty,
              let event = try? decoder.decode(RawLogEvent.self, from: data),
              let message = event.eventMessage, !message.isEmpty
        else { return }

        let ts = event.timestamp ?? "-"
        pushContext("[\(ts)] [\(event.messageType ?? "?")] \(message)")

        guard let severity = LogEntry.Severity.from(messageType: event.messageType, message: message) else { return }

        emit(LogEntry(
            timestamp: ts,
            processName: event.process ?? targetName,
            subsystem: event.subsystem ?? "",
            severity: severity,
            message: message
        ))
    }

    /// Cihaz: idevicesyslog düz metin satırı, örn.
    /// `Jul  7 11:22:33 iPhone MyApp(UIKitCore)[321] <Error>: something failed`
    private static let deviceLineRegex = try! NSRegularExpression(
        pattern: #"^(\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+\S+\s+([^\[\(]+?)(?:\(([^)]*)\))?\[(\d+)\]\s+<(\w+)>:\s?(.*)$"#
    )

    private func parseDeviceLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return }

        let range = NSRange(line.startIndex..., in: line)
        guard let m = Self.deviceLineRegex.firstMatch(in: line, range: range),
              let tsR = Range(m.range(at: 1), in: line),
              let procR = Range(m.range(at: 2), in: line),
              let levelR = Range(m.range(at: 5), in: line),
              let msgR = Range(m.range(at: 6), in: line)
        else { return }

        let processName = String(line[procR]).trimmingCharacters(in: .whitespaces)
        // Sadece hedef süreç (büyük/küçük harf duyarsız).
        guard processName.lowercased() == targetName.lowercased() else { return }

        let ts = String(line[tsR])
        let level = String(line[levelR])          // Notice | Error | Fault | ...
        let message = String(line[msgR])
        let subsystem = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? ""

        pushContext("[\(ts)] [\(level)] \(message)")

        let mappedType: String? = ["Error": "Error", "Fault": "Fault", "Critical": "Fault"][level]
        guard let severity = LogEntry.Severity.from(messageType: mappedType, message: message) else { return }

        emit(LogEntry(
            timestamp: ts,
            processName: processName,
            subsystem: subsystem,
            severity: severity,
            message: message
        ))
    }

    /// Hata kaydını bağlam + anlık görüntü + ekran görüntüsü ile zenginleştirip,
    /// imza bazlı tekilleştirerek ana thread'e yayınlar.
    private func emit(_ entry: LogEntry) {
        var enriched = entry
        // Bağlam: hatanın kendisi hariç, ondan önceki satırlar.
        enriched.context = Array(recentLines.dropLast())
        enriched.snapshot = captureSnapshotThrottled()
        enriched.lastSeen = entry.timestamp

        let signature = enriched.signature
        // Ekran görüntüsü (etkinse, imza başına bir kez) — yalnızca hedef sürecin
        // penceresi. PID (varsa) pencere eşleştirmesini iyileştirir.
        if AppSettings.shared.captureScreenshots {
            if targetPID == nil || !pidAlive(targetPID!) {
                let out = Self.run("/usr/bin/pgrep", ["-nx", targetName])
                targetPID = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            enriched.screenshotPath = capture.captureScreenshot(
                signature: signature, processName: targetName,
                pid: targetPID, source: activeSource)
        }

        // Çağrı yığını örneği (Instruments benzeri): yalnızca kritik hatalar
        // (FATAL/CRASH) için, imza başına bir kez, süreç canlıysa. Cihaz kaynağında
        // yok. sample ~1 sn sürer; okuma thread'inde olduğu için akışı kısa süre
        // bekletir ama kritik hatalar nadirdir.
        if activeSource != .device,
           enriched.severity == .fault || enriched.severity == .crash,
           !sampledSignatures.contains(signature) {
            sampledSignatures.insert(signature)
            enriched.stackSample = capture.captureStackSample(processName: targetName)
        }

        appendDeduplicated(enriched, signature: signature, notify: true)
    }

    /// Zenginleştirilmiş bir hatayı ana thread'de tekilleştirerek listeye ekler.
    /// Hem canlı akış (emit) hem geçmiş geri getirme (backfill) buradan geçer;
    /// tüm paylaşılan durum (errorLogs, signatureIndex) yalnızca ana thread'de
    /// değiştirilir — böylece iki üretici thread arasında yarış olmaz.
    private func appendDeduplicated(_ entry: LogEntry, signature: String, notify: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Tekilleştirme: aynı imza görülmüşse sayacı artır, yeni satır ekleme.
            if let idx = self.signatureIndex[signature], idx < self.errorLogs.count {
                self.errorLogs[idx].occurrenceCount += 1
                if !entry.lastSeen.isEmpty { self.errorLogs[idx].lastSeen = entry.lastSeen }
                return
            }

            self.signatureIndex[signature] = self.errorLogs.count
            self.errorLogs.append(entry)
            if self.errorLogs.count > Self.maxEntries {
                let removed = self.errorLogs.count - Self.maxEntries
                self.errorLogs.removeFirst(removed)
                self.signatureIndex = Dictionary(uniqueKeysWithValues:
                    self.errorLogs.enumerated().map { ($0.element.signature, $0.offset) })
            }

            if notify { self.notifyIfNeeded(entry, signature: signature) }
        }
    }

    /// Yeni bir kritik hata için Slack/Teams webhook'una bildirim gönderir.
    private func notifyIfNeeded(_ entry: LogEntry, signature: String) {
        let settings = AppSettings.shared
        guard settings.notifyOnCrash, settings.webhookConfigured,
              entry.severity == .crash || entry.severity == .fault,
              !baselineSignatures.contains(signature)
        else { return }

        let text = "🛡️ QAioS — new \(entry.severity.rawValue) in \(entry.processName)\n" +
                   "\(entry.message.prefix(300))"
        let notifier = WebhookNotifier(urlString: settings.webhookURL)
        Task { await notifier.send(text) }
    }

    private func pushContext(_ line: String) {
        recentLines.append(line)
        if recentLines.count > Self.contextSize { recentLines.removeFirst() }
    }

    // MARK: - Sistem anlık görüntüsü (Instruments benzeri hafif repro verisi)

    /// Hata fırtınalarında ps'i boğmamak için 2 sn'de bir yenilenir.
    private func captureSnapshotThrottled() -> SystemSnapshot? {
        // Gerçek cihazın süreç istatistiklerine USB üzerinden erişemeyiz.
        guard activeSource != .device else { return nil }
        if Date().timeIntervalSince(lastSnapshotAt) < 2, lastSnapshot != nil {
            return lastSnapshot
        }
        let snapshot = captureSnapshot()
        lastSnapshot = snapshot
        lastSnapshotAt = Date()
        return snapshot
    }

    private func captureSnapshot() -> SystemSnapshot {
        // Hedef sürecin PID'i (simülatör süreçleri de host'ta görünür).
        if targetPID == nil || !pidAlive(targetPID!) {
            let out = Self.run("/usr/bin/pgrep", ["-nx", targetName])
            targetPID = Int32(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var processStats = "process not running (pid not found)"
        if let pid = targetPID {
            let ps = Self.run("/bin/ps", ["-o", "pid=,pcpu=,pmem=,rss=,state=,etime=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ps.isEmpty {
                processStats = "pid cpu% mem% rss(KB) state elapsed → \(ps.replacingOccurrences(of: "\n", with: " "))"
            }
        }

        let load = Self.run("/usr/sbin/sysctl", ["-n", "vm.loadavg"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let memPressure = Self.run("/usr/bin/vm_stat", [])
            .split(separator: "\n")
            .first { $0.contains("Pages free") }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

        return SystemSnapshot(
            processStats: processStats,
            systemStats: "loadavg \(load); \(memPressure)"
        )
    }

    private func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    // MARK: - Crash report izleyici (Console.app'in Crash Reports bölümü, headless)

    /// ~/Library/Logs/DiagnosticReports klasörünü izler; hedef sürece ait yeni
    /// .ips/.crash dosyalarını CRASH kaydı olarak akışa ekler. Simülatör
    /// uygulamalarının crash'leri de aynı klasöre düşer.
    private func startCrashWatcher() {
        crashWatcher?.cancel()
        crashWatcher = nil

        let fd = open(Self.crashDir, O_EVTONLY)
        guard fd >= 0 else { return }

        // Mevcut dosyaları "görülmüş" say — sadece izleme sırasında oluşanlar raporlanır.
        seenCrashFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.crashDir)) ?? [])

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility)
        )
        watcher.setEventHandler { [weak self] in self?.scanCrashReports() }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        crashWatcher = watcher
    }

    private func scanCrashReports() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.crashDir) else { return }
        for file in files where !seenCrashFiles.contains(file) {
            seenCrashFiles.insert(file)
            // Dosya adı süreçle başlar: "MyApp-2026-07-07-110203.ips"
            guard file.lowercased().hasPrefix(targetName.lowercased()) else { continue }

            let path = (Self.crashDir as NSString).appendingPathComponent(file)
            let excerpt = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))
                .map { $0.prefix(1500) } ?? ""

            // emit() üzerinden geçir → tekilleştirme + ekran görüntüsü + webhook.
            emit(LogEntry(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                processName: targetName,
                subsystem: "DiagnosticReports",
                severity: .crash,
                message: "Crash report captured: \(file)\n\n\(excerpt)"
            ))
        }
    }

    // MARK: - Yardımcılar

    /// İzleme başlarken son 10 dakikanın hatalarını (`log show --last`)
    /// arka planda geri getirir. `log stream` yalnızca yeni olayları verdiği için,
    /// bu sayede izlemeden hemen önce (ör. uygulama açılışında) oluşan hatalar da
    /// listeye düşer — "önce/sonra başlat" sırası önemli olmaz. Cihazda desteklenmez.
    private func backfillRecentErrors(name: String, source: LogSource) {
        guard source != .device else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Not: `log show` predicate'inde `messageType == "Error"` eşleşmez;
            // sürece göre süzüp seviye filtresini (Error/Fault) istemci tarafında
            // (Severity.from) yaparız — canlı akışla aynı yaklaşım. `--last`
            // varsayılan seviyede (debug/info hariç) çalışır, hafif kalır.
            let showArgs = [
                "show", "--style", "ndjson", "--last", "10m",
                "--predicate", "process == \"\(name)\"",
            ]

            let path: String
            var args: [String]
            var env = ProcessInfo.processInfo.environment
            switch source {
            case .mac:
                path = "/usr/bin/log"; args = showArgs
            case .simulator:
                guard let devDir = Self.fullXcodeDeveloperDir() else { return }
                path = "/usr/bin/xcrun"; args = ["simctl", "spawn", "booted", "log"] + showArgs
                env["DEVELOPER_DIR"] = devDir
            case .device:
                return
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return }

            // Zaman aşımı gözcüsü.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); watchdog.cancel()

            // Hâlâ aynı hedefi mi izliyoruz? (Kullanıcı bu arada durdurmuş olabilir.)
            guard let self, self.isMonitoring, self.targetName == name else { return }

            // Geçmiş satırları ayrıştır. emit()'ten farklı olarak paylaşılan parse
            // durumuna (recentLines/sampledSignatures) DOKUNMAZ — bunlar canlı akış
            // thread'ine aittir. Geçmiş kayıtlar için bağlam/snapshot/ekran görüntüsü
            // toplanmaz (o an çoktan geçti); yalnızca hata satırı + tekilleştirme.
            // notify: false → geçmiş hatalar webhook bildirimi tetiklemez.
            let dec = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let event = try? dec.decode(RawLogEvent.self, from: Data(line)),
                      let message = event.eventMessage, !message.isEmpty,
                      let severity = LogEntry.Severity.from(messageType: event.messageType, message: message)
                else { continue }
                var entry = LogEntry(
                    timestamp: event.timestamp ?? "-",
                    processName: event.process ?? name,
                    subsystem: event.subsystem ?? "",
                    severity: severity,
                    message: message
                )
                entry.lastSeen = entry.timestamp
                self.appendDeduplicated(entry, signature: entry.signature, notify: false)
            }
        }
    }

    /// Tam Xcode'un Developer dizinini bulur (simctl için gereklidir).
    /// `simctl` yalnızca tam Xcode ile gelir; Command Line Tools'ta yoktur.
    private static func fullXcodeDeveloperDir() -> String? {
        let fm = FileManager.default
        func hasSimctl(_ dir: String) -> Bool {
            fm.isExecutableFile(atPath: dir + "/usr/bin/simctl")
        }

        // 1) Aktif geliştirici dizini zaten tam Xcode'sa onu kullan.
        let active = run("/usr/bin/xcode-select", ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty, hasSimctl(active) { return active }

        // 2) Bilinen varsayılan konum.
        let standard = "/Applications/Xcode.app/Contents/Developer"
        if hasSimctl(standard) { return standard }

        // 3) Spotlight ile herhangi bir Xcode kurulumu.
        let found = run("/usr/bin/mdfind",
                        ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"])
            .split(whereSeparator: \.isNewline)
            .map { String($0) + "/Contents/Developer" }
            .first(where: hasSimctl)
        return found
    }

    /// Homebrew (Apple Silicon + Intel) ve sistem yollarında çalıştırılabilir arar.
    private static func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Kısa ömürlü komut çalıştırıp stdout döndürür (anlık görüntü toplamak için).
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
