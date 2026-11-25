import AppKit
import ApplicationServices

/// Hedef macOS uygulamasının donup donmadığını izler (FREEZE tespiti).
///
/// Donan bir uygulama çoğu zaman log'a hiçbir şey yazmaz; sadece cevap vermeyi
/// bırakır. Bu yüzden log okumak donmayı yakalamaya yetmez. Bu sınıf, Activity
/// Monitor'deki "Not Responding" ile aynı fikri kullanır: her saniye uygulamaya
/// küçük bir Accessibility sorgusu gönderir. Uygulamanın main thread'i bloke ise
/// sorgu zaman aşımına uğrar (`kAXErrorCannotComplete`). Bu durum `threshold`
/// saniye boyunca sürerse bir FREEZE olayı üretilir.
///
/// Yanlış alarmı önlemek için:
///   • Yalnızca normal (Dock'ta görünen, `.regular`) GUI uygulamaları izlenir.
///   • Uygulama en az bir kez cevap vermeden FREEZE raporlanmaz ("armed").
///   • Her donma bir kez raporlanır; uygulama tekrar cevap verince sıfırlanır.
///
/// İzin: Accessibility (aksiyon yakalama ile aynı izin). İzin yoksa sessizce
/// hiçbir şey yapmaz.
final class HangDetector {

    /// Bu kadar saniye cevap yoksa uygulama "donmuş" sayılır.
    var threshold: TimeInterval = 3

    private let interval: TimeInterval = 1
    private let axTimeout: Float = 0.75
    private let queue = DispatchQueue(label: "qaios.hangdetector", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var processName = ""
    private var armed = false
    private var unresponsiveSince: Date?
    private var reported = false
    private var onFreeze: ((TimeInterval) -> Void)?
    private var onRecover: ((TimeInterval) -> Void)?

    /// Accessibility izni verilmiş mi?
    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// - Parameters:
    ///   - processName: izlenecek uygulamanın süreç adı (ör. "Safari").
    ///   - onFreeze: donma ilk kez `threshold`'u geçince çağrılır (arka plan thread'i).
    ///   - onRecover: raporlanmış bir donma bitince toplam süreyle çağrılır.
    func start(processName: String,
               onFreeze: @escaping (TimeInterval) -> Void,
               onRecover: @escaping (TimeInterval) -> Void) {
        stop()
        queue.sync {
            self.processName = processName
            self.onFreeze = onFreeze
            self.onRecover = onRecover
            self.resetState()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    // MARK: - İç işleyiş (yalnızca `queue` üzerinde)

    private func resetState() {
        armed = false
        unresponsiveSince = nil
        reported = false
    }

    private func targetPID() -> pid_t? {
        let name = processName.lowercased()
        let app = NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular &&
            (app.executableURL?.lastPathComponent.lowercased() == name ||
             app.localizedName?.lowercased() == name)
        }
        return app?.processIdentifier
    }

    private func tick() {
        guard AXIsProcessTrusted(), let pid = targetPID(), pid > 0 else {
            resetState()
            return
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)

        if err == .success {
            // Uygulama cevap veriyor.
            if reported, let since = unresponsiveSince {
                onRecover?(Date().timeIntervalSince(since))
            }
            armed = true
            unresponsiveSince = nil
            reported = false
            return
        }

        // Sadece zaman aşımı donma sayılır; diğer hatalar (izin yok, AX desteği
        // yok) yok sayılır.
        guard err == .cannotComplete, armed else { return }

        let now = Date()
        if unresponsiveSince == nil { unresponsiveSince = now }
        let elapsed = now.timeIntervalSince(unresponsiveSince!)
        if !reported, elapsed >= threshold {
            reported = true
            onFreeze?(elapsed)
        }
    }
}
