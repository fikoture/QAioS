import Foundation

/// Slack veya Microsoft Teams incoming-webhook'una basit metin mesajı gönderir.
/// Her ikisi de `{"text": "..."}` gövdesini kabul eder.
///
/// Not: QAioS Jira'ya bağlanmaz — raporda hazır "Jira Ticket" formatı üretilir,
/// kullanıcı kopyala-yapıştır ile Jira'ya girer. (Bu dosya yalnızca bildirim
/// webhook'unu barındırır.)
struct WebhookNotifier {
    let urlString: String

    func send(_ text: String) async {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        _ = try? await URLSession.shared.data(for: request)
    }
}
