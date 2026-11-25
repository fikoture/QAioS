#!/bin/bash
# ============================================================================
# QAioS — sabit (stable) kod imzalama kimliği kurar. BİR KEZ çalıştırılır.
#
# NEDEN: Ad-hoc (`codesign -s -`) imza binary hash'ine bağlıdır; her derlemede
# değişir ve macOS TCC (Screen Recording / Accessibility izinleri) uygulamayı
# "yeni" sanıp izinleri sıfırlar → her seferinde tekrar izin ister.
#
# ÇÖZÜM: Kendi imzalı bir kod imzalama sertifikası oluşturup özel bir
# anahtarlıkta saklarız. build.sh bu sabit kimlikle imzalar; imzanın
# "designated requirement"ı (bundle ID + sertifika) değişmediği için izinler
# bir kez verildikten sonra derlemeler arası korunur.
#
# Kullanım:  ./setup-codesign.sh
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="QAioS Code Signing"
KEYCHAIN="qaios-signing.keychain"
KEYCHAIN_DB="$HOME/Library/Keychains/${KEYCHAIN}-db"
KC_PASS="qaios"
P12_PASS="qaios123"

# Zaten kuruluysa çık (kimlik özel anahtarlıkta görünüyorsa).
if security find-identity -p codesigning "$KEYCHAIN_DB" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ İmzalama kimliği zaten mevcut: \"$IDENTITY\""
    exit 0
fi

echo "▸ Özel anahtarlık oluşturuluyor…"
security create-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # otomatik kilitlenmesin

echo "▸ Self-signed kod imzalama sertifikası üretiliyor…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = QAioS Code Signing
[ ext ]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
# -legacy: macOS'un Security çerçevesi OpenSSL 3.x'in yeni PKCS12 formatını
# okuyamaz; eski uyumlu algoritmalarla üret. Parola boş OLMAMALI (MAC hatası).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:"$P12_PASS" -name "$IDENTITY" 2>/dev/null

echo "▸ Anahtarlığa aktarılıyor…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
# codesign anahtara sormadan erişebilsin (özel anahtarlık parolası bilindiğinden çalışır).
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1

# Anahtarlığı kullanıcı arama listesine ekle (mevcutları koruyarak).
EXISTING=$(security list-keychains -d user | sed 's/[":]//g' | xargs)
if ! echo "$EXISTING" | grep -q "$KEYCHAIN_DB"; then
    security list-keychains -d user -s $EXISTING "$KEYCHAIN_DB"
fi

# Not: Sertifika self-signed olduğu için "trusted" değildir (CSSMERR_TP_NOT_TRUSTED);
# bu codesign için SORUN DEĞİLDİR — hash ile imzalarız. TCC izin kalıcılığı
# imzanın designated requirement'ına bağlıdır, sistem güvenine değil.

HASH=$(security find-identity -p codesigning "$KEYCHAIN_DB" 2>/dev/null \
        | grep "$IDENTITY" | grep -oE '[0-9A-F]{40}' | head -1)
if [ -n "$HASH" ]; then
    echo "✅ Hazır. Kimlik: \"$IDENTITY\" (hash: $HASH)"
    echo "   Artık ./build.sh bu sabit kimlikle imzalar; izinleri BİR KEZ"
    echo "   verdikten sonra derlemeler arası tekrar sorulmaz."
else
    echo "⚠️  Kimlik bulunamadı; build.sh ad-hoc imzaya düşecek."
    exit 1
fi
