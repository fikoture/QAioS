import Foundation
import AppKit

/// Hata anı kanıtlarını yakalar:
///   • Ekran görüntüsü  → hata düştüğü an `screencapture` ile PNG
///   • Oturum kaydı     → izleme boyunca ekranın video kaydı (.mov)
///   • xctrace          → varsa Instruments trace kaydı (tam Xcode gerekir)
///
/// Tüm çıktılar oturuma özel bir klasöre (~/Library/Application Support/QAioS/
/// sessions/<zaman>) yazılır; oturum sonunda dışa aktarım bu klasörü kullanır.
///
/// İZİN NOTU: Ekran görüntüsü ve kaydı için System Settings > Privacy &
/// Security > **Screen Recording** izni gerekir. İzin yoksa screencapture
/// boş/siyah kare üretebilir; uygulama yine de çalışır (kanıt yalnızca eksik olur).
final class CaptureService {

    private(set) var sessionDir: URL
    private var recorder: Process?
    private var tracer: Process?
    private var tracePath: URL?
    private var lastShotAt = Date.distantPast

    /// Ekran görüntülerini imza başına bir kez almak için (spam önleme).
    private var shotSignatures = Set<String>()

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QAioS/sessions", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        sessionDir = base.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    /// Yeni bir oturum başlatır: klasörü tazeler, kayıt/trace'i (etkinse) başlatır.
    func startSession(processName: String, recordVideo: Bool, recordTrace: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        sessionDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QAioS/sessions/\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        shotSignatures.removeAll()

        if recordVideo { startVideo() }
        if recordTrace { startTrace(processName: processName) }
    }

    func stopSession() {
        stopVideo()
        stopTrace()
    }

    // MARK: - Ekran görüntüsü

    /// Hata anında ekran görüntüsü alır (imza başına bir kez, en fazla 1/sn).
    /// SADECE hedef sürecin penceresini yakalar (tüm ekranı değil):
    ///   • macOS  → hedef sürecin (ada/PID'e göre) en büyük penceresi
    ///   • Simulator → Simulator uygulamasının penceresi (cihaz + uygulama görüntüsü)
    /// Pencere bulunamazsa güvenli yedek olarak tüm ekranı alır.
    /// Dosya yolunu döndürür; alınamazsa nil.
    func captureScreenshot(signature: String, processName: String, pid: Int32?, source: LogSource) -> String? {
        guard !shotSignatures.contains(signature) else { return nil }
        guard Date().timeIntervalSince(lastShotAt) > 1 else { return nil }
        shotSignatures.insert(signature)
        lastShotAt = Date()

        let path = sessionDir.appendingPathComponent("error-\(signature)-\(Int(Date().timeIntervalSince1970)).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        if let windowID = Self.targetWindowID(processName: processName, pid: pid, source: source) {
            // -l <windowid>: yalnızca o pencereyi yakala. -o gölgesiz, -x sessiz.
            p.arguments = ["-x", "-o", "-l", "\(windowID)", path.path]
        } else {
            // Pencere bulunamadı (ör. arka planda) → yedek: tüm ekran.
            p.arguments = ["-x", "-o", path.path]
        }
        do {
            try p.run(); p.waitUntilExit()
        } catch { return nil }
        return FileManager.default.fileExists(atPath: path.path) ? path.path : nil
    }

    /// Hedef sürecin ekrandaki en büyük normal penceresinin CGWindowID'sini bulur.
    /// (Görüntüyü çekmek için deprecated CGWindowListCreateImage yerine
    ///  screencapture -l kullanılır; bu API yalnızca pencereyi BULMAK için.)
    private static func targetWindowID(processName: String, pid: Int32?, source: LogSource) -> CGWindowID? {
        // Sahip eşleştirmesi: simülatörde uygulama Simulator penceresinde görünür.
        let matches: (_ ownerName: String, _ ownerPID: Int32) -> Bool
        switch source {
        case .simulator:
            matches = { name, _ in name == "Simulator" }
        case .mac:
            matches = { name, ownerPID in
                name.caseInsensitiveCompare(processName) == .orderedSame
                    || (pid != nil && ownerPID == pid!)
            }
        case .device:
            return nil   // cihazda yakalanacak yerel pencere yok
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: (id: CGWindowID, area: CGFloat)?
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,  // normal pencereler
                  let ownerName = w[kCGWindowOwnerName as String] as? String,
                  let ownerPID = w[kCGWindowOwnerPID as String] as? Int,
                  let number = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            guard matches(ownerName, Int32(ownerPID)) else { continue }
            let area = width * height
            guard area >= 10_000 else { continue }   // minik yardımcı pencereleri ele
            if best == nil || area > best!.area { best = (number, area) }
        }
        return best?.id
    }

    // MARK: - Çağrı yığını örneği (Instruments'ın komut satırı karşılığı: sample)

    /// Hedef sürecin anlık çağrı yığınını `/usr/bin/sample` ile alır (1 sn).
    /// Instruments Time Profiler'ın hafif karşılığıdır; tam Xcode gerektirmez.
    /// Süreç çalışmıyorsa (crash sonrası) veya izin yoksa nil döner.
    /// Çıktı büyük olabildiği için ilk ~6000 karakter alınır.
    func captureStackSample(processName: String) -> String? {
        let out = Self.run("/usr/bin/sample", [processName, "1", "-mayDie"], timeout: 12)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().contains("cannot examine process") else { return nil }
        return String(trimmed.prefix(6000))
    }

    /// Oturum trace dosyası hakkında rapora eklenecek kısa bilgi.
    var instrumentsSummary: String? {
        guard let tracePath = sessionTracePath else { return nil }
        return "Instruments trace recorded for this session: \(tracePath)\n"
             + "Open with: xcrun xctrace import --input \"\(tracePath)\" (or double-click in Instruments)."
    }

    // MARK: - Oturum ekran kaydı

    private func startVideo() {
        stopVideo()
        let path = sessionDir.appendingPathComponent("session.mov")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v video; -x sessiz. SIGINT ile düzgün finalize edilir (bkz. stopVideo).
        p.arguments = ["-v", "-x", path.path]
        do { try p.run(); recorder = p } catch { recorder = nil }
    }

    private func stopVideo() {
        guard let recorder, recorder.isRunning else { self.recorder = nil; return }
        // screencapture -v yalnızca SIGINT'te videoyu düzgün kapatır.
        recorder.interrupt()
        recorder.waitUntilExit()
        self.recorder = nil
    }

    var sessionVideoPath: String? {
        let path = sessionDir.appendingPathComponent("session.mov").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - xctrace (Instruments)

    private func startTrace(processName: String) {
        // xctrace yalnızca tam Xcode ile gelir; yoksa sessizce atla.
        guard let xctrace = Self.findXctrace() else { return }
        let path = sessionDir.appendingPathComponent("session.trace")
        tracePath = path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: xctrace)
        p.arguments = ["record", "--template", "Time Profiler",
                       "--attach", processName, "--output", path.path]
        p.standardError = Pipe()
        do { try p.run(); tracer = p } catch { tracer = nil; tracePath = nil }
    }

    private func stopTrace() {
        guard let tracer, tracer.isRunning else { self.tracer = nil; return }
        tracer.interrupt()   // xctrace SIGINT'te trace'i finalize eder
        tracer.waitUntilExit()
        self.tracer = nil
    }

    var sessionTracePath: String? {
        guard let tracePath, FileManager.default.fileExists(atPath: tracePath.path) else { return nil }
        return tracePath.path
    }

    private static func findXctrace() -> String? {
        let out = run("/usr/bin/xcrun", ["-f", "xctrace"], timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Kısa ömürlü komut çalıştırır; `timeout` saniye içinde bitmezse sonlandırır.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }

        // Zaman aşımı gözcüsü (sample takılırsa uygulamayı kilitlemesin).
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
