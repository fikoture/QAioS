import AppKit
import ApplicationServices
import Combine

/// Kullanıcının test sırasında yaptıklarını OTOMATİK yakalar — test uzmanı
/// adım girmez; QAioS izleme aktifken eylemleri kendisi kaydeder:
///
///   • Uygulama geçişleri  → "Switched to Safari"            (izin gerekmez)
///   • Tıklamalar          → "Clicked button “Login” in App" (Accessibility izni ile
///                            tıklanan UI öğesinin rol+başlığı çözülür; izin yoksa
///                            uygulama adı + koordinat kaydedilir)
///   • Klavye kullanımı    → "Typed in App"                  (gizlilik: yazılan içerik
///                            asla kaydedilmez, sadece yazma eylemi)
///
/// Böylece hata oluştuğunda raporda "hatadan önce kullanıcı hangi adımları
/// yaptı" zaman damgalarıyla hazır olur ve test case adımlarıyla eşleştirilir.
///
/// İZİN NOTU: Zengin yakalama (öğe adları + tuş olayları) için uygulamaya
/// System Settings > Privacy & Security > Accessibility izni verilmelidir.
/// İzin yokken de uygulama geçişleri ve ham tıklamalar yakalanır.
/// (Geliştirme notu: her yeniden derlemede ad-hoc imza değiştiği için
/// macOS izni düşürebilir; listeden kaldırıp yeniden eklemek gerekebilir.)
final class UserActionRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private weak var store: TestStepStore?
    private var eventMonitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private var lastTypingAt = Date.distantPast
    private static let typingThrottle: TimeInterval = 3   // "Typed in X" spam'ini önler

    deinit { stop() }

    // MARK: - İzin

    func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Sistem izin diyaloğunu tetikler ve Ayarlar'daki Accessibility bölümünü açar.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Kayıt

    /// Yalnızca bu uygulama (macOS'ta hedef süreç, simülatörde "Simulator")
    /// öndeyken eylemler kaydedilir. nil ise (ör. cihaz kaynağı) hiçbir eylem
    /// kaydedilmez — çünkü etkileşim Mac'te değildir.
    private var targetAppName: String?

    /// Öndeki uygulama hedef uygulama mı?
    private var isTargetFrontmost: Bool {
        guard let target = targetAppName,
              let front = NSWorkspace.shared.frontmostApplication?.localizedName
        else { return false }
        return front.caseInsensitiveCompare(target) == .orderedSame
    }

    /// `targetAppName`: yalnızca bu uygulama öndeyken kayıt yapılır.
    func start(store: TestStepStore, targetAppName: String?) {
        stop()
        self.store = store
        self.targetAppName = targetAppName
        refreshPermission()
        isRecording = true

        // 1) Uygulama geçişleri — yalnızca HEDEF uygulamaya geçişi kaydet
        //    (test uzmanının uygulamaya girdiği anı işaretler).
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let target = self.targetAppName,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName,
                  name.caseInsensitiveCompare(target) == .orderedSame
            else { return }
            self.record("Entered \(name)")
        }

        // 2) Tıklamalar (diğer uygulamalarda) — global monitor.
        let clickHandler: (NSEvent) -> Void = { [weak self] event in self?.handleClick(event) }
        if let clicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: clickHandler) {
            eventMonitors.append(clicks)
        }

        // 3) Klavye etkinliği — içerik DEĞİL, sadece "yazdı" bilgisi.
        //    Accessibility izni yoksa macOS bu olayları teslim etmez (sessizce boş kalır).
        let keyHandler: (NSEvent) -> Void = { [weak self] _ in self?.handleTyping() }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) {
            eventMonitors.append(keys)
        }
    }

    func stop() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
        appObserver = nil
        isRecording = false
    }

    // MARK: - Olay işleyiciler

    private func handleClick(_ event: NSEvent) {
        // Yalnızca hedef uygulama öndeyken kaydet (diğer uygulamalardaki
        // tıklamalar test adımı değildir).
        guard isTargetFrontmost else { return }
        let appName = targetAppName ?? "app"
        let action = event.type == .rightMouseDown ? "Right-clicked" : "Clicked"
        let point = NSEvent.mouseLocation

        if accessibilityGranted, let element = Self.elementDescription(atScreenPoint: point) {
            record("\(action) \(element) in \(appName)")
        } else {
            record("\(action) in \(appName) at (\(Int(point.x)), \(Int(point.y)))")
        }
    }

    private func handleTyping() {
        guard Date().timeIntervalSince(lastTypingAt) > Self.typingThrottle else { return }
        // Yalnızca hedef uygulama öndeyken kaydet.
        guard isTargetFrontmost else { return }
        lastTypingAt = Date()
        record("Typed in \(targetAppName ?? "app")")
    }

    private func record(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.store?.add(text)
        }
    }

    // MARK: - Accessibility: tıklanan öğeyi tanımla

    /// Ekran noktasındaki UI öğesinin rolünü ve başlığını döndürür,
    /// örn. `button “Login”` veya `text field “Username”`.
    private static func elementDescription(atScreenPoint point: NSPoint) -> String? {
        // NSEvent.mouseLocation sol-alt orijinli; AX API sol-üst orijin bekler.
        guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
        let axY = Float(screenHeight - point.y)

        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), axY, &element) == .success,
              let element
        else { return nil }

        func attribute(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }

        let role = attribute(kAXRoleDescriptionAttribute as String)
            ?? attribute(kAXRoleAttribute as String)
            ?? "element"
        let title = attribute(kAXTitleAttribute as String)
            ?? attribute(kAXDescriptionAttribute as String)
            ?? attribute(kAXValueAttribute as String).map { String($0.prefix(30)) }

        if let title, !title.isEmpty {
            return "\(role) “\(title)”"
        }
        return role
    }
}
