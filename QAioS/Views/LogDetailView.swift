import SwiftUI
import AppKit

/// Listeden tıklanan tek bir log kaydının detayını gösterir.
struct LogDetailView: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(entry.severity.rawValue)
                    .font(.headline.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(severityColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(severityColor)
                Text("Log Details")
                    .font(.title2.bold())
                if entry.occurrenceCount > 1 {
                    Text("×\(entry.occurrenceCount)")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                        .help("This error occurred \(entry.occurrenceCount) times (deduplicated)")
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Time").foregroundStyle(.secondary)
                    Text(entry.timestamp).font(.body.monospaced()).textSelection(.enabled)
                }
                GridRow {
                    Text("Process").foregroundStyle(.secondary)
                    Text(entry.processName).font(.body.monospaced()).textSelection(.enabled)
                }
                if !entry.subsystem.isEmpty {
                    GridRow {
                        Text("Subsystem").foregroundStyle(.secondary)
                        Text(entry.subsystem).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // AI bug triyaj sonucu (varsa).
                    if let bug = entry.bug {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: bug.isBug ? "ant.fill" : "checkmark.seal")
                                .foregroundStyle(bug.isBug ? .red : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bug.isBug ? "Bug — \(bug.severity)" : "Not a bug (benign)")
                                    .font(.headline)
                                    .foregroundStyle(bug.isBug ? .red : .secondary)
                                Text(bug.reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((bug.isBug ? Color.red : Color.green).opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text("Message").font(.headline)
                    Text(entry.message)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                    // Hatadan hemen önceki log satırları — repro bağlamı.
                    if !entry.context.isEmpty {
                        Text("Pre-error Context").font(.headline)
                        Text(entry.context.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // Hata anındaki sistem/süreç durumu (Instruments benzeri).
                    if let snapshot = entry.snapshot {
                        Text("System Snapshot at Error Time").font(.headline)
                        Text(snapshot.formatted)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // Instruments benzeri çağrı yığını örneği (FATAL/CRASH'te).
                    if let stack = entry.stackSample {
                        Text("Call Stack Sample (Instruments)").font(.headline)
                        Text(stack)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // Hata anında alınan ekran görüntüsü.
                    if let shot = entry.screenshotPath,
                       let image = NSImage(contentsOfFile: shot) {
                        HStack {
                            Text("Screenshot at Error Time").font(.headline)
                            Spacer()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shot)])
                            }
                            .controlSize(.small)
                        }
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "[\(entry.timestamp)] [\(entry.severity.rawValue)] \(entry.subsystem) — \(entry.message)",
                        forType: .string
                    )
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy to Clipboard",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }

    private var severityColor: Color {
        switch entry.severity {
        case .exception: return .pink
        case .crash: return .purple
        case .fault: return .red
        case .error: return .orange
        }
    }
}
