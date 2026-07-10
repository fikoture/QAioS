import Foundation
import Combine

/// Desteklenen AI sağlayıcıları. NVIDIA, Groq ve Other, OpenAI uyumlu
/// chat/completions uç noktası kullanır; Anthropic kendi Messages API'sini.
/// "Other": kullanıcının kendi OpenAI uyumlu uç noktası (endpoint düzenlenebilir).
enum AIProvider: String, CaseIterable, Identifiable {
    case nvidia
    case groq
    case anthropic
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nvidia:    return "NVIDIA NIM"
        case .groq:      return "Groq"
        case .anthropic: return "Anthropic"
        case .other:     return "Other"
        }
    }

    var defaultModel: String {
        switch self {
        case .nvidia:    return "openai/gpt-oss-120b"
        case .groq:      return "llama-3.3-70b-versatile"
        case .anthropic: return "claude-opus-4-8"
        case .other:     return "gpt-4o"
        }
    }

    /// Sabit uç noktalar; "Other" için varsayılan (kullanıcı değiştirebilir).
    var defaultEndpoint: URL {
        switch self {
        case .nvidia:    return URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
        case .groq:      return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .other:     return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    /// Uç nokta yalnızca "Other" için düzenlenebilir.
    var hasEditableEndpoint: Bool { self == .other }

    /// Alan ipucu olarak gösterilen anahtar ön eki (zorunlu değil).
    var keyHint: String {
        switch self {
        case .nvidia:    return "nvapi-…"
        case .groq:      return "gsk_…"
        case .anthropic: return "sk-ant-…"
        case .other:     return "your API key"
        }
    }

    /// Gömülü varsayılan anahtar: kullanıcı Settings'ten kendi anahtarını
    /// girmediyse buna düşülür; böylece uygulama kutudan çıkar çıkmaz çalışır.
    /// Boş string → gömülü anahtar yok (kullanıcı girmek zorunda).
    var defaultKey: String {
        switch self {
        case .nvidia:    return "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"
        case .groq:      return ""
        case .anthropic: return ""
        case .other:     return ""
        }
    }
}

/// Uygulama ayarları: seçili sağlayıcı, sağlayıcı başına API anahtarı,
/// model ve (Other için) uç nokta. Anahtarlar yalnızca kullanıcı tarafından
/// uygulama içinden girilir.
///
/// NOT: Anahtarlar UserDefaults'ta (plaintext plist) saklanır — kişisel
/// geliştirme makinesi için yeterli; dağıtılacaksa Keychain'e taşınmalı.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var provider: AIProvider {
        didSet { defaults.set(provider.rawValue, forKey: "ai.provider") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "ai.provider") ?? ""
        provider = AIProvider(rawValue: raw) ?? .nvidia
    }

    // MARK: - API anahtarları

    func apiKey(for provider: AIProvider) -> String? {
        if let key = defaults.string(forKey: "ai.key.\(provider.rawValue)"), !key.isEmpty {
            return key
        }
        // Kullanıcı anahtarı yoksa gömülü varsayılan anahtara düş (varsa).
        if !provider.defaultKey.isEmpty {
            return provider.defaultKey
        }
        return nil
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: "ai.key.\(provider.rawValue)")
        objectWillChange.send()
    }

    // MARK: - Modeller

    func model(for provider: AIProvider) -> String {
        if let m = defaults.string(forKey: "ai.model.\(provider.rawValue)"), !m.isEmpty {
            return m
        }
        return provider.defaultModel
    }

    func setModel(_ model: String, for provider: AIProvider) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: "ai.model.\(provider.rawValue)")
        objectWillChange.send()
    }

    // MARK: - Uç noktalar

    func endpoint(for provider: AIProvider) -> URL {
        guard provider.hasEditableEndpoint,
              let raw = defaults.string(forKey: "ai.endpoint.\(provider.rawValue)"),
              let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
        else { return provider.defaultEndpoint }
        return url
    }

    func setEndpoint(_ endpoint: String, for provider: AIProvider) {
        guard provider.hasEditableEndpoint else { return }
        defaults.set(endpoint.trimmingCharacters(in: .whitespaces), forKey: "ai.endpoint.\(provider.rawValue)")
        objectWillChange.send()
    }

    /// Seçili sağlayıcı için kullanılabilir bir anahtar var mı?
    var isConfigured: Bool { apiKey(for: provider) != nil }

    // MARK: - Yakalama ayarları (ekran görüntüsü / video / trace)

    /// Bool ayarlar için varsayılan-true erişimci (anahtar yoksa `true`).
    private func boolDefaultTrue(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    var captureScreenshots: Bool {
        get { boolDefaultTrue("capture.screenshots") }
        set { defaults.set(newValue, forKey: "capture.screenshots"); objectWillChange.send() }
    }

    var recordVideo: Bool {
        get { boolDefaultTrue("capture.video") }
        set { defaults.set(newValue, forKey: "capture.video"); objectWillChange.send() }
    }

    var recordTrace: Bool {
        get { defaults.bool(forKey: "capture.trace") }   // varsayılan kapalı (tam Xcode gerekir)
        set { defaults.set(newValue, forKey: "capture.trace"); objectWillChange.send() }
    }

    // MARK: - Bildirim webhook (Slack / Teams)

    var webhookURL: String {
        get { defaults.string(forKey: "notify.webhook") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "notify.webhook"); objectWillChange.send() }
    }
    var notifyOnCrash: Bool {
        get { defaults.bool(forKey: "notify.onCrash") }
        set { defaults.set(newValue, forKey: "notify.onCrash"); objectWillChange.send() }
    }
    var webhookConfigured: Bool { !webhookURL.isEmpty }
}
