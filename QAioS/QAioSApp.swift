import SwiftUI

// ============================================================================
// QAioS — macOS Log İzleme & Jira Rapor Aracı
//
// İZİNLER / KURULUM NOTLARI (önemli — kod içinde istenen açıklama):
//
// 1) `log stream` komutunu Process() ile çalıştırabilmek için App Sandbox
//    KAPALI olmalıdır. Xcode'da:
//       Target > Signing & Capabilities > App Sandbox kapabilitesini kaldırın
//    (veya .entitlements dosyasında `com.apple.security.app-sandbox` = false).
//    Sandbox açıkken /usr/bin/log alt süreci başlatılamaz (EPERM).
//
// 2) Alternatif yol: OSLogStore API'si ile diğer süreçlerin loglarını okumak
//    `com.apple.developer.logs.read` entitlement'ı gerektirir. Bu entitlement
//    Apple'a özeldir (private) ve normal geliştirici hesaplarına verilmez;
//    bu yüzden bu projede `log stream` + Process() yaklaşımı kullanılıyor.
//
// 3) `log stream` unified log'un tamamını görebilmek için kullanıcının
//    admin (veya _developer grubu üyesi) olması gerekebilir. Bazı gizlilik
//    korumalı alanlar için Terminal'e "Full Disk Access" verilmesi gibi,
//    bu uygulamaya da System Settings > Privacy & Security üzerinden
//    ek izin vermek gerekebilir.
//
// 4) AnalysisService, Anthropic API anahtarını ANTHROPIC_API_KEY ortam
//    değişkeninden okur (Xcode: Scheme > Run > Arguments > Environment).
//    Anahtar yoksa "Export to Jira" butonu Markdown raporu panoya kopyalar.
// ============================================================================

@main
struct QAioSApp: App {
    // LogMonitor tüm pencere ömrü boyunca yaşasın diye App seviyesinde tutulur.
    @StateObject private var logMonitor = LogMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logMonitor)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}
