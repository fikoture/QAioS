import Foundation
import AppKit

/// Oturumu tek, kendi kendine yeten bir HTML raporuna dönüştürür:
/// yakalanan eylemler + hatalar (bağlam, snapshot, ekran görüntüsü gömülü)
/// tek bir zaman çizelgesinde. Ekran görüntüleri base64 olarak gömülür, böylece
/// HTML dosyası tek başına paylaşılabilir.
struct SessionExporter {

    /// HTML raporunu üretip diske yazar, dosya URL'sini döndürür.
    static func exportHTML(processName: String,
                           logs: [LogEntry],
                           steps: [TestStep],
                           scenario: ScenarioStore,
                           videoPath: String?,
                           tracePath: String?,
                           to directory: URL) throws -> URL {
        var timeline: [(time: String, kind: String, html: String)] = []

        for step in steps {
            timeline.append((TestStepStore.timeString(step.time), "action",
                             "<span class='act'>\(esc(step.title))</span>"))
        }
        for log in logs {
            var block = "<span class='sev \(log.severity.rawValue.lowercased())'>\(log.severity.rawValue)</span> "
            block += "<span class='msg'>\(esc(log.message))</span>"
            if log.occurrenceCount > 1 { block += " <span class='count'>×\(log.occurrenceCount)</span>" }
            if !log.subsystem.isEmpty { block += "<div class='sub'>\(esc(log.subsystem))</div>" }
            if !log.context.isEmpty {
                block += "<details><summary>Pre-error context</summary><pre>\(esc(log.context.joined(separator: "\n")))</pre></details>"
            }
            if let snap = log.snapshot {
                block += "<details><summary>System snapshot</summary><pre>\(esc(snap.formatted))</pre></details>"
            }
            if let shot = log.screenshotPath, let img = base64Image(shot) {
                block += "<details open><summary>Screenshot</summary><img src='\(img)'/></details>"
            }
            timeline.append((log.timestamp, "error", block))
        }

        let rows = timeline.map { item in
            "<tr class='\(item.kind)'><td class='ts'>\(esc(item.time))</td><td>\(item.html)</td></tr>"
        }.joined(separator: "\n")

        let scenarioHTML = scenario.steps.isEmpty ? "" : """
        <h2>Scenario: \(esc(scenario.name)) — \(scenario.passedCount)/\(scenario.steps.count) matched</h2>
        <ul class='scenario'>
        \(scenario.steps.map { "<li class='\($0.matched ? "ok" : "miss")'>\($0.matched ? "✓" : "✗") \(esc($0.text))</li>" }.joined(separator: "\n"))
        </ul>
        """

        var artifacts = "<ul>"
        if let videoPath { artifacts += "<li>Screen recording: <code>\(esc(videoPath))</code></li>" }
        if let tracePath { artifacts += "<li>Instruments trace: <code>\(esc(tracePath))</code></li>" }
        artifacts += "</ul>"

        let errorCount = logs.reduce(0) { $0 + $1.occurrenceCount }
        let html = """
        <!doctype html><html><head><meta charset='utf-8'>
        <title>QAioS Report — \(esc(processName))</title>
        <style>
          body{font:14px -apple-system,sans-serif;margin:0;background:#111;color:#eee}
          header{padding:20px 24px;background:linear-gradient(120deg,#071229,#0a6b80)}
          h1{margin:0;font-size:22px} .meta{color:#bcd;margin-top:4px}
          h2{padding:0 24px;margin-top:24px}
          .summary{padding:0 24px;color:#9ab}
          table{border-collapse:collapse;width:100%;margin-top:8px}
          td{border-top:1px solid #222;padding:8px 12px;vertical-align:top}
          td.ts{white-space:nowrap;color:#89a;font-family:monospace;width:90px}
          tr.error{background:#1a0f10} tr.action td:last-child{color:#9cf}
          .sev{font-weight:700;padding:1px 6px;border-radius:4px;font-size:11px}
          .sev.error{background:#5a3a10;color:#fb0} .sev.fatal{background:#5a1010;color:#f66}
          .sev.crash{background:#3a1050;color:#c9f}
          .count{background:#333;border-radius:8px;padding:1px 7px;font-size:11px}
          .sub{color:#789;font-size:12px} .act{color:#9cf}
          pre{background:#000;padding:8px;border-radius:6px;overflow:auto;font-size:12px}
          img{max-width:100%;border-radius:6px;margin-top:6px}
          details{margin-top:6px} summary{cursor:pointer;color:#8ac}
          ul.scenario{list-style:none;padding:0 24px} .scenario li.ok{color:#6d6} .scenario li.miss{color:#f77}
          code{background:#000;padding:2px 5px;border-radius:4px}
        </style></head><body>
        <header><h1>🛡️ QAioS Report — \(esc(processName))</h1>
        <div class='meta'>Generated \(ISO8601DateFormatter().string(from: Date())) · by SentinelAI</div></header>
        <div class='summary'>\(steps.count) actions · \(logs.count) unique errors (\(errorCount) total)</div>
        \(scenarioHTML)
        <h2>Artifacts</h2>\(artifacts)
        <h2>Timeline</h2>
        <table>\(rows)</table>
        </body></html>
        """

        let out = directory.appendingPathComponent("QAioS-report.html")
        try html.data(using: .utf8)!.write(to: out)
        return out
    }

    private static func base64Image(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
