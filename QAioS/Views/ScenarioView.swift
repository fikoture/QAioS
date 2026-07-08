import SwiftUI
import UniformTypeIdentifiers

/// Test senaryosu şablonu (CSV/düz metin) yükler ve yakalanan eylemlerle
/// eşleştirmeyi gösterir. Beklenen adımlar otomatik "check" edilir.
struct ScenarioView: View {
    @ObservedObject var scenario: ScenarioStore
    @ObservedObject var stepStore: TestStepStore
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    loadTemplate()
                } label: {
                    Label("Load Template…", systemImage: "doc.badge.plus")
                }
                if !scenario.steps.isEmpty {
                    Button("Re-match") { scenario.match(against: stepStore.steps) }
                        .help("Match captured actions against the loaded scenario steps")
                    Spacer()
                    Text("\(scenario.passedCount)/\(scenario.steps.count) matched")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { scenario.clear() }
                        .controlSize(.small)
                } else {
                    Spacer()
                }
            }
            .padding(10)

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }

            Divider()

            if scenario.steps.isEmpty {
                ContentUnavailableView(
                    "No scenario loaded",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text("Load a CSV or plain-text test scenario (one expected step per line). QAioS matches your captured actions against it and auto-checks the steps that were performed.")
                )
            } else {
                List(scenario.steps) { step in
                    HStack(spacing: 10) {
                        Image(systemName: step.matched ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.matched ? .green : .secondary)
                        Text("\(step.index).")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(step.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let t = step.matchedActionTime {
                            Text(TestStepStore.timeString(t))
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        // Adımlar değiştikçe otomatik yeniden eşleştir.
        .onChange(of: stepStore.steps.count) {
            if !scenario.steps.isEmpty { scenario.match(against: stepStore.steps) }
        }
    }

    private func loadTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Select a CSV or text file with one expected test step per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try scenario.load(from: url)
            scenario.match(against: stepStore.steps)
            loadError = nil
        } catch {
            loadError = "Could not load: \(error.localizedDescription)"
        }
    }
}
