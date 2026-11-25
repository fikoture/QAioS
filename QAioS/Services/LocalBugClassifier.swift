import Foundation

/// Kurumsal (enterprise) seviye, API'siz yerel bug triyajı.
/// Her hatayı kategorize eder; güven skoru, kök-neden çıkarımı (çağrı yığını /
/// dosya:satır), bileşen ve Jira etiketleri üretir. Tamamen kural tabanlı,
/// anında ve çevrimdışı çalışır.
enum LocalBugClassifier {

    // MARK: - Sınıflandırma kuralları

    /// (kalıp, kategori, önem, güven, etiketler). Sıra ÖNEMLİ: ilk eşleşen kazanır.
    private struct Rule {
        let patterns: [String]
        let category: String
        let severity: String
        let confidence: String
        let labels: [String]
        let isBug: Bool
    }

    /// Bug kuralları (uygulama kusuru). Güçlüden zayıfa doğru.
    private static let bugRules: [Rule] = [
        Rule(patterns: ["exc_bad_access", "exc_bad_instruction", "segmentation fault", "sigsegv"],
             category: "Memory Access Violation", severity: "Blocker", confidence: "High",
             labels: ["crash", "memory", "bad-access"], isBug: true),
        Rule(patterns: ["terminating with uncaught", "uncaught exception", "nsinvalidargumentexception",
                        "nsrangeexception", "nsgenericexception", "nsinternalinconsistencyexception"],
             category: "Uncaught Exception", severity: "Blocker", confidence: "High",
             labels: ["crash", "exception"], isBug: true),
        Rule(patterns: ["sigabrt", "abort()", "__abort"],
             category: "Abnormal Termination (abort)", severity: "Blocker", confidence: "High",
             labels: ["crash", "abort"], isBug: true),
        Rule(patterns: ["unexpectedly found nil", "force unwrap", "nil while unwrapping"],
             category: "Nil-safety (force-unwrap)", severity: "Critical", confidence: "High",
             labels: ["crash", "nil-safety"], isBug: true),
        Rule(patterns: ["index out of range", "out of bounds", "array index", "range or index"],
             category: "Array Bounds", severity: "Critical", confidence: "High",
             labels: ["crash", "bounds"], isBug: true),
        Rule(patterns: ["fatal error", "swift runtime failure"],
             category: "Fatal Runtime Error", severity: "Critical", confidence: "High",
             labels: ["crash", "runtime"], isBug: true),
        Rule(patterns: ["precondition failed", "assertion failed", "assertionfailure", "dispatch_assert"],
             category: "Assertion / Precondition", severity: "Critical", confidence: "High",
             labels: ["crash", "assertion"], isBug: true),
        Rule(patterns: ["deadlock", "priority inversion", "data race", "main thread checker",
                        "ui api called on a background thread"],
             category: "Concurrency / Threading", severity: "Major", confidence: "Medium",
             labels: ["concurrency", "threading"], isBug: true),
        Rule(patterns: ["core data", "nsmanagedobject", "sqlite error", "keychain error",
                        "failed to save", "persistent store"],
             category: "Data Persistence", severity: "Major", confidence: "Medium",
             labels: ["persistence", "data"], isBug: true),
        Rule(patterns: ["timeout", "timed out", "connection refused", "unreachable",
                        "ssl error", "certificate", "http 5", "status code 5"],
             category: "Network / Connectivity", severity: "Major", confidence: "Medium",
             labels: ["network"], isBug: true),
        Rule(patterns: ["memory warning", "jetsam", "terminated due to memory", "out of memory"],
             category: "Memory Pressure", severity: "Major", confidence: "Medium",
             labels: ["memory", "performance"], isBug: true),
    ]

    /// Gürültü kuralları (çerçeve/simülatör/geçici). Bug DEĞİL.
    private static let noiseRules: [Rule] = [
        Rule(patterns: ["loudnessmanager", "coreaudio", "unable to open stream", "aqme", "audiotoolbox"],
             category: "Simulator Audio Limitation", severity: "None", confidence: "High",
             labels: ["noise", "simulator"], isBug: false),
        Rule(patterns: ["storekit", "receiptmanager", "unfinished transactions",
                        "enumerating all current transactions", "asderror", "app store"],
             category: "StoreKit (Simulator)", severity: "None", confidence: "High",
             labels: ["noise", "storekit"], isBug: false),
        Rule(patterns: ["addinstanceforfactory", "no factory registered", "load_eligibility_plist",
                        "getpwuid", "fixing incorrect property", "invalidating promoted elements"],
             category: "Framework Bootstrap Noise", severity: "None", confidence: "High",
             labels: ["noise", "framework"], isBug: false),
        Rule(patterns: ["gesture: system gesture gate", "system gesture gate timed out",
                        "pointer lock state", "intercepting scene update", "runningboard", "rbs "],
             category: "Transient UI/System Message", severity: "None", confidence: "High",
             labels: ["noise", "ui-system"], isBug: false),
        Rule(patterns: ["ca event", "ca_event_type", "app launch measurements", "not available in the simulator",
                        "not supported in the simulator", "verify background audio", "invalidating cache",
                        "errors found! invalidating"],
             category: "Simulator / Telemetry Noise", severity: "None", confidence: "High",
             labels: ["noise", "simulator"], isBug: false),
    ]

    // MARK: - Genel API

    static func classify(_ logs: [LogEntry]) -> [UUID: BugVerdict] {
        var result: [UUID: BugVerdict] = [:]
        for entry in logs { result[entry.id] = verdict(for: entry) }
        return result
    }

    static func verdict(for entry: LogEntry) -> BugVerdict {
        let msg = entry.message.lowercased()
        let sub = entry.subsystem.lowercased()
        let component = inferComponent(entry)
        let rootCause = inferRootCause(entry)

        // 1) Crash raporu → en yüksek öncelik.
        if entry.severity == .crash {
            return BugVerdict(
                isBug: true, severity: "Blocker",
                reason: "A crash report was captured for the target process — an unexpected termination that must be fixed.",
                category: "Application Crash", confidence: "High", rootCause: rootCause,
                component: component, labels: ["crash", "regression-candidate"])
        }

        // 2) Bilinen bug kuralları.
        for rule in bugRules {
            if let hit = rule.patterns.first(where: { msg.contains($0) }) {
                return BugVerdict(
                    isBug: true, severity: rule.severity,
                    reason: "Matches a known \(rule.category.lowercased()) pattern (“\(hit)”) — a defect in the application.",
                    category: rule.category, confidence: rule.confidence, rootCause: rootCause,
                    component: component, labels: rule.labels)
            }
        }

        // 3) Bilinen gürültü kuralları.
        for rule in noiseRules {
            if let hit = rule.patterns.first(where: { msg.contains($0) || sub.contains($0) }) {
                return BugVerdict(
                    isBug: false, severity: "None",
                    reason: "\(rule.category): matches a benign/framework pattern (“\(hit)”), not an application defect.",
                    category: rule.category, confidence: rule.confidence, rootCause: "",
                    component: component, labels: rule.labels)
            }
        }

        // 4) Apple çerçeve alt sistemi + sadece ERROR → çoğunlukla gürültü.
        if sub.hasPrefix("com.apple.") && entry.severity == .error {
            return BugVerdict(
                isBug: false, severity: "None",
                reason: "System framework error (subsystem \(entry.subsystem)); typically benign noise rather than an app bug.",
                category: "System Framework Error", confidence: "Medium", rootCause: "",
                component: component, labels: ["noise", "framework"])
        }

        // 5) Exception / Fault (bilinmeyen) → muhtemel bug.
        if entry.severity == .exception || entry.severity == .fault {
            return BugVerdict(
                isBug: true, severity: entry.severity == .exception ? "Critical" : "Major",
                reason: "A \(entry.severity.rawValue.lowercased())-level event outside known noise patterns — likely an application defect; verify.",
                category: entry.severity == .exception ? "Uncaught Exception" : "Runtime Fault",
                confidence: "Medium", rootCause: rootCause, component: component,
                labels: [entry.severity.rawValue.lowercased(), "needs-triage"])
        }

        // 6) Uygulamanın kendi alt sisteminden ERROR → muhtemel işlevsel bug.
        if !sub.hasPrefix("com.apple.") && !entry.subsystem.isEmpty {
            return BugVerdict(
                isBug: true, severity: "Major",
                reason: "Error logged by the app's own subsystem (\(entry.subsystem)) — likely a functional application issue.",
                category: "Application Error", confidence: "Medium", rootCause: rootCause,
                component: component, labels: ["app-error", "needs-triage"])
        }

        // 7) Belirsiz.
        return BugVerdict(
            isBug: false, severity: "Minor",
            reason: "Generic error with no strong bug or noise signal; review manually.",
            category: "Unclassified", confidence: "Low", rootCause: "",
            component: component, labels: ["unclassified"])
    }

    // MARK: - Kök-neden ve bileşen çıkarımı

    /// Mesajdaki `Dosya.swift:satır` ve çağrı yığınındaki ilk uygulama frame'inden
    /// sezgisel kök neden üretir.
    private static func inferRootCause(_ entry: LogEntry) -> String {
        var parts: [String] = []

        // Mesajdaki dosya:satır (ör. "PlayerViewModel.swift:88")
        if let m = fileLineRegex.firstMatch(in: entry.message,
                                            range: NSRange(entry.message.startIndex..., in: entry.message)),
           let r = Range(m.range, in: entry.message) {
            parts.append("at \(entry.message[r])")
        }

        // Çağrı yığınında hedef sürecin ilk frame'i
        if let stack = entry.stackSample,
           let frame = firstAppFrame(in: stack, process: entry.processName) {
            parts.append("in \(frame)")
        }

        return parts.joined(separator: " ")
    }

    /// Bileşeni alt sistemden veya mesajdaki dosya adından çıkarır.
    private static func inferComponent(_ entry: LogEntry) -> String {
        if !entry.subsystem.isEmpty, !entry.subsystem.hasPrefix("com.apple.") {
            // com.company.app.module → "module" (son segment) ya da app adı
            let segs = entry.subsystem.split(separator: ".")
            if let last = segs.last, segs.count >= 2 { return String(last) }
            return entry.subsystem
        }
        if let m = fileLineRegex.firstMatch(in: entry.message,
                                            range: NSRange(entry.message.startIndex..., in: entry.message)),
           let r = Range(m.range(at: 1), in: entry.message) {
            return String(entry.message[r])   // dosya adı
        }
        return entry.processName
    }

    /// `sample` çıktısındaki, süreç adını içeren ilk anlamlı frame satırı.
    private static func firstAppFrame(in stack: String, process: String) -> String? {
        for line in stack.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.contains(process), l.contains("(") || l.contains("+") || l.contains(".swift") {
                return String(l.prefix(120))
            }
        }
        return nil
    }

    private static let fileLineRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_+]*\.swift):(\d+)"#)
}
