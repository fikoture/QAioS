import Foundation
import CryptoKit

/// Hata anında yakalanan sistem verileri (Instruments benzeri hafif anlık görüntü).
struct SystemSnapshot: Equatable {
    let processStats: String
    let systemStats: String

    var formatted: String {
        var lines: [String] = []
        if !processStats.isEmpty { lines.append("Process: \(processStats)") }
        if !systemStats.isEmpty { lines.append("System:  \(systemStats)") }
        return lines.joined(separator: "\n")
    }
}

/// Bug triyaj sonucu (AI veya yerel). Kurumsal alanlar isteğe bağlı doldurulur.
struct BugVerdict: Equatable {
    let isBug: Bool
    let severity: String   // Blocker | Critical | Major | Minor | None
    let reason: String     // neden bug (veya neden değil) — kısa açıklama

    // Enterprise alanları (yerel sınıflandırıcı doldurur; AI'da boş kalabilir)
    var category: String = ""       // ör. "Nil-safety", "Bounds", "Uncaught Exception"
    var confidence: String = ""     // High | Medium | Low
    var rootCause: String = ""      // sezgisel kök neden / hatalı frame / dosya:satır
    var component: String = ""      // çıkarılan modül/bileşen
    var labels: [String] = []       // Jira etiketleri
}

/// Yakalanan tek bir hata log satırını temsil eder.
struct LogEntry: Identifiable, Equatable {
    enum Severity: String, CaseIterable {
        case error = "ERROR"
        case fault = "FATAL"
        case exception = "EXCEPTION"
        case crash = "CRASH"

        static func from(messageType: String?, message: String) -> Severity? {
            let upper = message.uppercased()

            // 1) Çökme
            if upper.contains("CRASH") { return .crash }

            // 2) İstisna (uncaught NSException, terminating, kötü erişim, abort)
            if upper.contains("EXCEPTION")
                || upper.contains("TERMINATING WITH UNCAUGHT")
                || upper.contains("UNHANDLED EXCEPTION")
                || upper.contains("SIGABRT")
                || upper.contains("EXC_BAD_ACCESS") {
                return .exception
            }

            // 3) Ölümcül hata (Swift fatalError / precondition / force-unwrap nil / FATAL)
            if upper.contains("FATAL")
                || upper.contains("PRECONDITION FAILED")
                || upper.contains("UNEXPECTEDLY FOUND NIL")
                || upper.contains("INDEX OUT OF RANGE") {
                return .fault
            }

            // 4) messageType'a göre
            switch messageType {
            case "Fault": return .fault
            case "Error": return .error
            default: break
            }

            // 5) Metinde ERROR geçiyorsa
            if upper.contains("ERROR") { return .error }
            return nil
        }
    }

    let id = UUID()
    let timestamp: String
    let processName: String
    let subsystem: String
    let severity: Severity
    let message: String
    var context: [String] = []
    var snapshot: SystemSnapshot?

    /// Hata anında `sample` ile alınan çağrı yığını (Instruments benzeri).
    var stackSample: String?

    /// AI triyajı sonucu: bu hata gerçek bir bug mı, yoksa iyi huylu gürültü mü?
    /// nil = henüz analiz edilmedi.
    var bug: BugVerdict?

    // Yakalama & tekilleştirme
    /// Hata anında alınan ekran görüntüsünün dosya yolu.
    var screenshotPath: String?
    /// Aynı hatanın kaç kez tekrarlandığı (imza bazlı gruplama).
    var occurrenceCount: Int = 1
    /// En son görülme zaman damgası (tekrarlar geldikçe güncellenir).
    var lastSeen: String = ""

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }

    /// Mesajdan değişken kısımları (sayı, hex, UUID, adres, yol) çıkararak
    /// stabil bir imza üretir; böylece "aynı" hatanın varyasyonları gruplanır.
    var signature: String {
        var m = message
        // UUID
        m = m.replacingOccurrences(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                                   with: "<uuid>", options: .regularExpression)
        // 0x... adresler
        m = m.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "<addr>", options: .regularExpression)
        // sayılar
        m = m.replacingOccurrences(of: #"\d+"#, with: "<n>", options: .regularExpression)
        // dosya yolları
        m = m.replacingOccurrences(of: #"/[^\s]+"#, with: "<path>", options: .regularExpression)
        let normalized = "\(severity.rawValue)|\(subsystem)|\(m)"
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// `log stream --style ndjson` çıktısındaki tek satırın modeli.
struct RawLogEvent: Decodable {
    let timestamp: String?
    let eventMessage: String?
    let messageType: String?
    let process: String?
    let subsystem: String?
}

// MARK: - Test adımları (otomatik yakalanır)

struct TestStep: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    var title: String
    var done: Bool = true
}

final class TestStepStore: ObservableObject {
    @Published var steps: [TestStep] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        steps.append(TestStep(time: Date(), title: trimmed))
    }

    func remove(_ step: TestStep) { steps.removeAll { $0.id == step.id } }
    func clear() { steps.removeAll() }

    static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }

    var markdown: String {
        guard !steps.isEmpty else { return "_No test steps were recorded._" }
        return steps.enumerated().map { i, s in
            "\(i + 1). [\(s.done ? "x" : " ")] \(Self.timeString(s.time)) — \(s.title)"
        }.joined(separator: "\n")
    }
}

// MARK: - Test senaryosu şablonu

/// Şablondan yüklenen beklenen tek bir adım; yakalanan eylemlerle eşleştirilir.
struct ScenarioStep: Identifiable {
    let id = UUID()
    let index: Int
    let text: String
    var matched: Bool = false
    var matchedActionTime: Date?
}

/// CSV/düz metin test senaryosu şablonunu tutar ve yakalanan eylemlerle eşleştirir.
final class ScenarioStore: ObservableObject {
    @Published var name: String = ""
    @Published var steps: [ScenarioStep] = []

    /// CSV veya düz metin dosyasını yükler. Her satır bir beklenen adımdır;
    /// CSV ise ilk sütun (veya "step"/"description" başlıklı sütun) kullanılır.
    func load(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return }

        // Başlık satırı sezimi
        let header = lines.first!.lowercased()
        if header.contains("step") || header.contains("description") || header.contains("action") {
            lines.removeFirst()
        }

        steps = lines.enumerated().compactMap { i, line in
            // İlk CSV sütununu al (basit; tırnaklı virgüller nadir).
            let first = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? line
            let text = first.trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
            guard !text.isEmpty else { return nil }
            return ScenarioStep(index: i + 1, text: text)
        }
        name = url.lastPathComponent
    }

    func clear() { name = ""; steps = [] }

    /// Yakalanan eylemleri beklenen adımlarla eşleştirir (sıralı, anahtar
    /// kelime örtüşmesine göre). Bir adım eşleşince sonraki adıma geçilir.
    func match(against actions: [TestStep]) {
        guard !steps.isEmpty else { return }
        var actionIdx = 0
        for i in steps.indices {
            steps[i].matched = false
            steps[i].matchedActionTime = nil
            let keywords = Self.keywords(steps[i].text)
            let startIdx = actionIdx           // kaçırılırsa buraya geri dönülür
            var cursor = actionIdx
            while cursor < actions.count {
                let action = actions[cursor].title.lowercased()
                if keywords.contains(where: { action.contains($0) }) {
                    steps[i].matched = true
                    steps[i].matchedActionTime = actions[cursor].time
                    actionIdx = cursor + 1     // yalnızca eşleşince ilerle
                    break
                }
                cursor += 1
            }
            // Eşleşme yoksa pozisyonu koru — sonraki adım aynı eylemleri deneyebilsin.
            if !steps[i].matched { actionIdx = startIdx }
        }
    }

    private static func keywords(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "to", "on", "in", "and", "click",
                                 "tap", "press", "enter", "select", "open", "with",
                                 "then", "user", "should", "verify", "check"]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
    }

    var passedCount: Int { steps.filter(\.matched).count }

    var markdown: String {
        guard !steps.isEmpty else { return "_No scenario template loaded._" }
        let header = "Scenario: \(name) — \(passedCount)/\(steps.count) steps matched\n"
        let rows = steps.map { step -> String in
            let mark = step.matched ? "x" : " "
            let time = step.matchedActionTime.map { " (at \(TestStepStore.timeString($0)))" } ?? ""
            return "\(step.index). [\(mark)] \(step.text)\(time)"
        }.joined(separator: "\n")
        return header + rows
    }
}
