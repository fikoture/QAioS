import Foundation

/// Yakalanan hata loglarını seçili AI sağlayıcısına gönderip
/// "Kök Neden Analizi" + "Jira Ticket" formatında rapor üretir.
///
/// Sağlayıcı ve API anahtarı AppSettings üzerinden yönetilir
/// (uygulama içi Ayarlar ekranı → UserDefaults, yoksa ortam değişkeni).
struct AnalysisService {

    enum AnalysisError: LocalizedError {
        case missingAPIKey(AIProvider)
        case httpError(status: Int, body: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "No API key configured for \(provider.displayName). Enter one in Settings."
            case .httpError(let status, let body):
                return "API error (HTTP \(status)): \(body.prefix(300))"
            case .emptyResponse:
                return "The API returned an empty response."
            }
        }
    }

    private static let systemPrompt = """
    You are a senior macOS QA engineer. You will receive error lines filtered \
    from a process's unified log output. Respond in English, in Markdown, \
    with exactly these two sections:

    ## Root Cause Analysis
    Group the errors and explain the likely root causes with supporting evidence.

    ## Jira Ticket
    Fill in these fields: **Summary**, **Priority** (Blocker/Critical/Major/Minor), \
    **Component**, **Environment**, **Description**, **Steps to Reproduce**, \
    **Expected Result**, **Actual Result**, **Attachments** (relevant log lines).

    ## Test Step Verification
    You will also receive the test steps the tester performed (with timestamps). \
    Cross-check each step against the captured errors: mark which steps passed, \
    which step most likely triggered each error (correlate timestamps), and \
    derive concrete Steps to Reproduce from them. If a test scenario template is \
    provided, report which expected steps passed or failed.

    Use ALL available evidence to make this a flawless, developer-ready report: \
    per-error pre-error context, system snapshots, and especially the Instruments \
    call-stack samples (from `sample`) when present — identify the exact function/ \
    frame where the failure originates and cite it. Add a "## Developer Handoff" \
    section with: the precise failing call stack (if sampled), the suspected file/ \
    module, a minimal reproduction, and any Instruments trace reference provided.
    """

    // MARK: - AI Analizi

    func analyze(logs: [LogEntry], steps: [TestStep],
                 scenarioMarkdown: String?, instrumentsInfo: String? = nil,
                 processName: String) async throws -> String {
        let scenarioSection = scenarioMarkdown.map {
            "\n\nExpected test scenario template (matched against captured actions):\n\($0)"
        } ?? ""
        let instrumentsSection = instrumentsInfo.map {
            "\n\nInstruments / profiling artifacts:\n\($0)"
        } ?? ""

        let userPrompt = """
        Process: \(processName)

        Test steps automatically captured by QAioS (timestamped user actions):
        \(Self.stepsDump(steps))\(scenarioSection)\(instrumentsSection)

        Captured errors (deduplicated; ×N = occurrence count) with pre-error \
        context, system snapshots and Instruments call-stack samples:

        \(Self.detailedLogDump(logs))
        """

        return try await chat(system: Self.systemPrompt, user: userPrompt, maxTokens: 16000)
    }

    // MARK: - Özellik 1: Bug triyajı (hangi hatalar gerçek bug?)

    private static let triageSystem = """
    You are a senior QA triage engineer. Not every logged error is a bug. \
    Framework warnings, simulator-only limitations (e.g. audio/StoreKit not \
    available in Simulator), transient system messages, and expected recoverable \
    errors are NOT bugs. A BUG is a defect in the application under test that \
    causes wrong behavior, a crash, data loss, or a failed user action.

    You will receive a numbered list of deduplicated errors. For EACH one decide \
    whether it indicates a real application bug. Respond with ONLY a JSON object, \
    no prose, of the exact shape:
    {"verdicts":[{"index":0,"is_bug":true,"severity":"Critical","reason":"..."}]}
    severity ∈ Blocker|Critical|Major|Minor|None (None when is_bug is false). \
    reason: one concise sentence explaining WHY it is or isn't a bug.
    """

    /// Yakalanan (tekilleştirilmiş) hataları AI ile triyaj eder; her hatanın
    /// id'sine karşılık bir BugVerdict döndürür.
    func classifyBugs(logs: [LogEntry]) async throws -> [UUID: BugVerdict] {
        let items = Array(logs.enumerated())
        let listing = items.map { idx, e in
            "\(idx). [\(e.severity.rawValue)]\(e.subsystem.isEmpty ? "" : " {\(e.subsystem)}") \(e.message.prefix(300))"
        }.joined(separator: "\n")

        let user = "Errors to triage:\n\(listing)\n\nReturn the JSON object now."
        let raw = try await chat(system: Self.triageSystem, user: user, maxTokens: 4096)

        // Yanıttan JSON nesnesini toleranslı biçimde çıkar (markdown fence vb. olabilir).
        guard let obj = Self.extractJSONObject(raw),
              let verdicts = obj["verdicts"] as? [[String: Any]] else {
            throw AnalysisError.emptyResponse
        }

        var result: [UUID: BugVerdict] = [:]
        for v in verdicts {
            guard let idx = v["index"] as? Int, idx >= 0, idx < items.count else { continue }
            let isBug = (v["is_bug"] as? Bool) ?? false
            let severity = (v["severity"] as? String) ?? (isBug ? "Major" : "None")
            let reason = (v["reason"] as? String) ?? ""
            result[items[idx].element.id] = BugVerdict(isBug: isBug, severity: severity, reason: reason)
        }
        return result
    }

    // MARK: - Özellik 2: Repro talimatı (tek bug için ayrı rapor)

    private static let reproSystem = """
    You are a senior QA engineer writing REPRODUCTION STEPS for a developer. \
    Given one bug — its error, the pre-error log context, the Instruments \
    call-stack sample, the system snapshot, and the exact user actions captured \
    before it — write a precise, self-contained reproduction guide in Markdown \
    with these sections:

    ## Bug Summary
    ## Environment (OS, device/simulator, build)
    ## Preconditions
    ## Steps to Reproduce (numbered, exact, derived from the captured user actions)
    ## Expected Result
    ## Actual Result (cite the error + failing stack frame)
    ## Supporting Evidence (context lines, snapshot, screenshot note if present)

    Be concrete. If information is missing, state the reasonable assumption. \
    Respond in English.
    """

    /// Tek bir bug için, yakalanan tüm kanıtları kullanarak repro talimatı üretir.
    func reproductionSteps(for entry: LogEntry, steps: [TestStep],
                           processName: String) async throws -> String {
        var evidence = """
        Process: \(processName)
        Error: [\(entry.severity.rawValue)]\(entry.occurrenceCount > 1 ? " (×\(entry.occurrenceCount))" : "") \(entry.subsystem.isEmpty ? "" : "{\(entry.subsystem)} ")\(entry.message)
        """
        if let bug = entry.bug {
            evidence += "\nTriage: bug=\(bug.isBug), severity=\(bug.severity), reason=\(bug.reason)"
        }
        if !entry.context.isEmpty {
            evidence += "\n\nPre-error context:\n" + entry.context.joined(separator: "\n")
        }
        if let snap = entry.snapshot {
            evidence += "\n\nSystem snapshot:\n" + snap.formatted
        }
        if let stack = entry.stackSample {
            evidence += "\n\nCall-stack sample:\n```\n" + String(stack.prefix(2500)) + "\n```"
        }
        evidence += "\n\nUser actions captured before/around the error (timestamped):\n" + Self.stepsDump(steps)

        return try await chat(system: Self.reproSystem, user: evidence, maxTokens: 3000)
    }

    /// Metin içinden ilk dengeli JSON nesnesini ({...}) ayıklayıp sözlüğe çevirir.
    private static func extractJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
            i = text.index(after: i)
        }
        guard let e = end else { return nil }
        let json = String(text[start...e])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - Sağlayıcı-bağımsız tek çağrı noktası

    /// Seçili sağlayıcıya bir system+user mesajı gönderir, metni döndürür.
    private func chat(system: String, user: String, maxTokens: Int) async throws -> String {
        let settings = AppSettings.shared
        let provider = settings.provider
        guard let apiKey = settings.apiKey(for: provider) else {
            throw AnalysisError.missingAPIKey(provider)
        }
        switch provider {
        case .anthropic:
            return try await callAnthropic(apiKey: apiKey, model: settings.model(for: .anthropic),
                                           system: system, userPrompt: user, maxTokens: min(maxTokens, 16000))
        case .nvidia, .groq, .other:
            return try await callOpenAICompatible(endpoint: settings.endpoint(for: provider), apiKey: apiKey,
                                                  model: settings.model(for: provider),
                                                  system: system, userPrompt: user, maxTokens: maxTokens)
        }
    }

    // MARK: - Anthropic Messages API

    private struct AnthropicRequest: Encodable {
        struct Message: Encodable { let role, content: String }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct AnthropicResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]
    }

    private func callAnthropic(apiKey: String, model: String,
                               system: String, userPrompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: AIProvider.anthropic.defaultEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(AnthropicRequest(
            model: model,
            max_tokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: userPrompt)]
        ))

        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw AnalysisError.emptyResponse }
        return text
    }

    // MARK: - OpenAI uyumlu API (NVIDIA NIM, Groq)

    private struct OpenAIRequest: Encodable {
        struct Message: Encodable { let role, content: String }
        let model: String
        let max_tokens: Int
        let temperature: Double
        let messages: [Message]
    }

    private struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private func callOpenAICompatible(endpoint: URL, apiKey: String, model: String,
                                      system: String, userPrompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(OpenAIRequest(
            model: model,
            max_tokens: maxTokens,
            temperature: 0.3,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: userPrompt),
            ]
        ))

        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AnalysisError.emptyResponse
        }
        return text
    }

    // MARK: - Ortak HTTP

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnalysisError.httpError(status: http.statusCode,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Markdown fallback (API anahtarı yoksa)

    /// Jira'ya elle yapıştırılabilecek Markdown rapor üretir.
    func markdownReport(logs: [LogEntry], steps: [TestStep],
                        scenarioMarkdown: String?, instrumentsInfo: String? = nil,
                        processName: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let counts = Dictionary(grouping: logs, by: \.severity)
            .map { "\($0.key.rawValue): \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")

        // Yerel triyajla önceliği ve bug/gürültü ayrımını türet (API'siz).
        let verdicts = LocalBugClassifier.classify(logs)
        let bugs = logs.filter { verdicts[$0.id]?.isBug == true }
        let priority = Self.priority(from: bugs.compactMap { verdicts[$0.id]?.severity })
        let summary = bugs.first.map {
            "[\($0.severity.rawValue)] \($0.message.prefix(90))"
        } ?? "Errors observed in \(processName)"

        // Bug'ları önce, gürültüyü sonra listele (gerekçeleriyle).
        let bugList = bugs.isEmpty ? "_No clear bugs detected by local triage._" :
            bugs.enumerated().map { i, e in
                "\(i + 1). **[\(verdicts[e.id]?.severity ?? "")]** \(e.message.prefix(120))\n   _\(verdicts[e.id]?.reason ?? "")_"
            }.joined(separator: "\n")

        return """
        # 🐞 Jira Ticket — \(processName)

        | Field | Value |
        |---|---|
        | **Summary** | \(summary) |
        | **Priority** | \(priority) |
        | **Component** | \(processName) |
        | **Environment** | macOS · process `\(processName)` · \(now) |
        | **Error Count** | \(logs.count) unique (\(counts)) |

        ## Description
        While monitoring the `\(processName)` process, \(bugs.count) likely bug(s) and \
        \(logs.count - bugs.count) benign/noise entr(y/ies) were captured. Triage below \
        was produced locally (rule-based, no AI).

        ## Identified Bugs (local triage)
        \(bugList)

        ## Steps to Reproduce
        Derived from auto-captured user actions (timestamps align with the log records):
        \(Self.stepsDump(steps))
        \(scenarioMarkdown.map { "\n## Scenario Verification\n\($0)\n" } ?? "")
        ## Expected / Actual Result
        - **Expected:** The steps above complete without errors.
        - **Actual:** The bugs listed above occur.

        ## Error Details (context, snapshots & call stacks)
        \(Self.detailedLogDump(logs))
        \(instrumentsInfo.map { "\n## Instruments Artifacts\n\($0)\n" } ?? "")

        ## All Log Records
        ```
        \(Self.plainLogDump(logs))
        ```

        ---
        _Generated by QAioS (local, offline). For AI-written root-cause analysis, use “AI Ticket”._
        """
    }

    /// Bug önem etiketlerinden Jira önceliğini seçer (en yükseği).
    private static func priority(from severities: [String]) -> String {
        let order = ["Blocker", "Critical", "Major", "Minor"]
        for level in order where severities.contains(where: { $0.caseInsensitiveCompare(level) == .orderedSame }) {
            return level
        }
        return severities.isEmpty ? "Minor" : "Major"
    }

    private static func plainLogDump(_ logs: [LogEntry]) -> String {
        logs.suffix(100).map { "[\($0.timestamp)] [\($0.severity.rawValue)]\($0.occurrenceCount > 1 ? " ×\($0.occurrenceCount)" : "") \($0.subsystem) — \($0.message)" }
            .joined(separator: "\n")
    }

    /// Test adımlarının zaman damgalı, işaretli listesi.
    private static func stepsDump(_ steps: [TestStep]) -> String {
        guard !steps.isEmpty else { return "_No test steps were recorded._" }
        return steps.enumerated().map { index, step in
            "\(index + 1). [\(step.done ? "x" : " ")] \(TestStepStore.timeString(step.time)) — \(step.title)"
        }.joined(separator: "\n")
    }

    /// Her hata için bağlam satırları + sistem anlık görüntüsünü içeren
    /// ayrıntılı döküm (repro analizi için). Prompt şişmesin diye son 50 hata.
    private static func detailedLogDump(_ logs: [LogEntry]) -> String {
        logs.suffix(20).enumerated().map { index, entry in
            let occ = entry.occurrenceCount > 1 ? " (×\(entry.occurrenceCount) occurrences)" : ""
            let bugTag = entry.bug.map { $0.isBug ? " [BUG: \($0.severity)]" : " [not-a-bug]" } ?? ""
            var block = """
            ### Error \(index + 1) — [\(entry.severity.rawValue)]\(occ)\(bugTag) \(entry.timestamp)
            \(entry.subsystem.isEmpty ? "" : "Subsystem: \(entry.subsystem)\n")Message: \(entry.message)
            """
            if let bug = entry.bug {
                block += "\nTriage: \(bug.isBug ? "BUG" : "not a bug") — \(bug.reason)"
            }
            if entry.screenshotPath != nil {
                block += "\n(Screenshot captured at error time.)"
            }
            if !entry.context.isEmpty {
                block += "\n\nPre-error context (preceding log lines):\n"
                block += entry.context.map { "  \($0)" }.joined(separator: "\n")
            }
            if let snapshot = entry.snapshot {
                block += "\n\nSystem snapshot at error time:\n"
                block += snapshot.formatted.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
            }
            if let stack = entry.stackSample {
                block += "\n\nInstruments call-stack sample at error time (from `sample`, truncated):\n```\n"
                block += String(stack.prefix(1800))
                block += "\n```"
            }
            return block
        }.joined(separator: "\n\n")
    }
}
