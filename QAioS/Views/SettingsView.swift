import SwiftUI

/// Ayarlar: AI sağlayıcısı, Jira entegrasyonu, bildirim webhook'u ve kanıt
/// yakalama tercihleri. Anahtarları yalnızca kullanıcı girer.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    private enum Section: String, CaseIterable, Identifiable {
        case ai = "AI", notify = "Notifications", capture = "Capture"
        var id: String { rawValue }
    }
    @State private var section: Section = .ai
    @State private var feedback: String?

    // AI alanları
    @State private var keyInput = ""
    @State private var modelInput = ""
    @State private var endpointInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.bold())

            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 12)

            switch section {
            case .ai:      aiSection
            case .notify:  notifySection
            case .capture: captureSection
            }

            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.top, 12)
        }
        .padding()
        .frame(width: 560)
        .onAppear(perform: loadAI)
    }

    // MARK: - AI

    private var aiSection: some View {
        Form {
            Picker("Provider", selection: $settings.provider) {
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            SecureField("API Key", text: $keyInput, prompt: Text(settings.provider.keyHint))
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $modelInput, prompt: Text(settings.provider.defaultModel))
                .textFieldStyle(.roundedBorder)

            if settings.provider.hasEditableEndpoint {
                TextField("Endpoint", text: $endpointInput,
                          prompt: Text(settings.provider.defaultEndpoint.absoluteString))
                    .textFieldStyle(.roundedBorder)
                Text("Any OpenAI-compatible chat/completions endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Endpoint") {
                    Text(settings.provider.defaultEndpoint.absoluteString)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Save AI") {
                    settings.setAPIKey(keyInput, for: settings.provider)
                    settings.setModel(modelInput.isEmpty ? settings.provider.defaultModel : modelInput,
                                      for: settings.provider)
                    if settings.provider.hasEditableEndpoint, !endpointInput.isEmpty {
                        settings.setEndpoint(endpointInput, for: settings.provider)
                    }
                    feedback = "\(settings.provider.displayName) settings saved."
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.provider) { loadAI() }
    }

    // MARK: - Notifications

    private var notifySection: some View {
        Form {
            TextField("Webhook URL", text: $settings.webhookURL,
                      prompt: Text("Slack or Teams incoming webhook URL"))
                .textFieldStyle(.roundedBorder)
            Toggle("Notify on new CRASH / FATAL", isOn: $settings.notifyOnCrash)
            Text("Sends a message to the webhook when a new critical error (not already present at monitoring start) is captured. Works with Slack and Microsoft Teams incoming webhooks.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    // MARK: - Capture

    private var captureSection: some View {
        Form {
            Toggle("Capture screenshot at error time", isOn: $settings.captureScreenshots)
            Toggle("Record screen during session (.mov)", isOn: $settings.recordVideo)
            Toggle("Record Instruments trace (xctrace)", isOn: $settings.recordTrace)
            Text("Screenshots and screen recording require Screen Recording permission (System Settings › Privacy & Security). Instruments trace requires a full Xcode install; if xctrace is unavailable it is skipped silently.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    // MARK: -

    private func loadAI() {
        keyInput = settings.apiKey(for: settings.provider) ?? ""
        modelInput = settings.model(for: settings.provider)
        endpointInput = settings.provider.hasEditableEndpoint
            ? settings.endpoint(for: settings.provider).absoluteString : ""
    }
}
