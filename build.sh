#!/bin/bash
# ============================================================================
# QAioS — çift tıklanabilir .app paketi üretir (Xcode projesi gerektirmez).
#
# Kullanım:  ./build.sh
# Çıktı:     ./QAioS.app  (Finder'da çift tıklayarak açılır)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QAioS"
BUNDLE="$APP_NAME.app"
ARCH="$(uname -m)"            # arm64 (Apple Silicon) veya x86_64 (Intel)
TARGET="$ARCH-apple-macos14.0"

# İkon yoksa üret (scripts/make_icon.swift → PNG → iconset → icns)
if [ ! -f assets/AppIcon.icns ]; then
    echo "▸ İkon üretiliyor…"
    mkdir -p assets/AppIcon.iconset
    swift scripts/make_icon.swift assets/AppIcon.png
    for s in 16 32 128 256 512; do
        sips -z $s $s assets/AppIcon.png --out "assets/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d assets/AppIcon.png --out "assets/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
fi

echo "▸ Derleniyor ($TARGET)…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# @main içeren dosyalar birden çok dosyayla derlenirken -parse-as-library şarttır.
xcrun swiftc -O \
    -target "$TARGET" \
    -parse-as-library \
    QAioS/QAioSApp.swift \
    QAioS/Models/LogEntry.swift \
    QAioS/Services/LogMonitor.swift \
    QAioS/Services/AnalysisService.swift \
    QAioS/Services/AppSettings.swift \
    QAioS/Services/LocalBugClassifier.swift \
    QAioS/Services/JiraTicketBuilder.swift \
    QAioS/Services/UserActionRecorder.swift \
    QAioS/Services/CaptureService.swift \
    QAioS/Services/JiraService.swift \
    QAioS/Services/SessionExporter.swift \
    QAioS/Views/ContentView.swift \
    QAioS/Views/SettingsView.swift \
    QAioS/Views/LogDetailView.swift \
    QAioS/Views/TestStepsView.swift \
    QAioS/Views/ScenarioView.swift \
    -o "$BUNDLE/Contents/MacOS/$APP_NAME"

cp QAioS/Info.plist "$BUNDLE/Contents/Info.plist"
cp assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

# İmzalama: SABİT kimlik varsa onunla imzala (izinler derlemeler arası korunur).
# Yoksa ad-hoc'a düş (izinler her derlemede sıfırlanır — bkz. ./setup-codesign.sh).
SIGNING_KEYCHAIN="$HOME/Library/Keychains/qaios-signing.keychain-db"
IDENTITY_HASH=$(security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
                 | grep "QAioS Code Signing" | grep -oE '[0-9A-F]{40}' | head -1)

if [ -n "$IDENTITY_HASH" ]; then
    echo "▸ İmzalanıyor (sabit kimlik — izinler korunur)…"
    security unlock-keychain -p "qaios" qaios-signing.keychain 2>/dev/null || true
    codesign --force --sign "$IDENTITY_HASH" --keychain "$SIGNING_KEYCHAIN" "$BUNDLE"
else
    echo "▸ İmzalanıyor (ad-hoc — izinler her derlemede sıfırlanır)…"
    echo "   İpucu: ./setup-codesign.sh çalıştırın; izinler bir kez verilince kalıcı olur."
    codesign --force --sign - "$BUNDLE"
fi

echo "✅ Hazır: $(pwd)/$BUNDLE"
echo "   Finder'da çift tıklayın veya:  open $BUNDLE"
