import SwiftUI

/// Kullanıcı eylemlerinin OTOMATİK yakalandığı panel. Test uzmanı adım girmez;
/// izleme aktifken QAioS uygulama geçişlerini, tıklamaları ve yazma eylemlerini
/// kendisi kaydeder. Adımlar zaman damgalıdır ve rapora aynen girer; böylece
/// hatalar "hatadan önce kullanıcı ne yaptı" bilgisiyle eşleştirilir.
struct TestStepsView: View {
    @ObservedObject var store: TestStepStore
    @ObservedObject var recorder: UserActionRecorder

    var body: some View {
        VStack(spacing: 0) {
            // Durum şeridi
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                Text(recorder.isRecording
                     ? "Recording user actions automatically…"
                     : "Actions are recorded only while the app under test is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(10)

            // Accessibility izni yoksa zengin yakalama (öğe adları + klavye) çalışmaz.
            if !recorder.accessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Grant Accessibility permission to capture clicked UI element names and typing activity. Only actions inside the target app are recorded.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Enable…") { recorder.requestPermission() }
                        .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
            }

            Divider()

            if store.steps.isEmpty {
                ContentUnavailableView(
                    "No actions captured yet",
                    systemImage: "cursorarrow.click.2",
                    description: Text("Press Start, then use the app under test. QAioS records only the clicks and typing you do inside that app (target process on macOS, the Simulator window for simulator apps) — with timestamps, included in the report.")
                )
            } else {
                List {
                    ForEach($store.steps) { $step in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $step.done)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .help("Uncheck to exclude noise from the report correlation")
                            Text(TestStepStore.timeString(step.time))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(step.title)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                store.remove(step)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove step")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)

                HStack {
                    Text("\(store.steps.count) action(s) captured · typed content is never recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.clear() }
                        .controlSize(.small)
                }
                .padding(8)
            }
        }
        .onAppear { recorder.refreshPermission() }
    }
}
