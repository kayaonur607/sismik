#!/bin/sh
# Sismik'i simülatörde kurar, açar ve her sekmeyi gezerek çökme/hata arar.
#
# Birim testleri kodun doğruluğunu gösterir ama uygulamanın gerçekten
# açıldığını ve canlı veriyle çalıştığını göstermez. Bu betik o boşluğu
# kapatır: derler, kurar, derin bağlantılarla sekmeleri dolaşır, ekran
# görüntüsü alır ve günlükte çökme izi arar.
#
#   Scripts/smoke-simulator.sh [simülatör adı]
set -u

SIM="${1:-iPhone 17 Pro Max}"
BID="com.kayasoftware.sismik"
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT="${TMPDIR:-/tmp}/sismik-smoke"
mkdir -p "$OUT"

echo "==> Simülatör hazırlanıyor: $SIM"
xcrun simctl boot "$SIM" 2>/dev/null || true

echo "==> Derleniyor"
if ! xcodebuild -project "$REPO/Sismik.xcodeproj" -scheme Sismik \
        -configuration Debug -destination "platform=iOS Simulator,name=$SIM" \
        build >"$OUT/build.log" 2>&1; then
    echo "HATA: derleme başarısız, ayrıntı: $OUT/build.log"
    exit 1
fi

APP=$(xcodebuild -project "$REPO/Sismik.xcodeproj" -scheme Sismik -configuration Debug \
        -destination "platform=iOS Simulator,name=$SIM" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

echo "==> Kuruluyor: $APP"
xcrun simctl install booted "$APP" || exit 1

# Karşılama akışını atla ki sekmeler doğrudan gezilebilsin.
xcrun simctl spawn booted defaults write "$BID" onboardingSeenVersion -int 6 2>/dev/null || true

xcrun simctl terminate booted "$BID" 2>/dev/null || true
echo "==> Açılıyor"
# Günlük penceresi tam da bu çalıştırmayı kapsasın; eski koşuların izleri
# yanlış alarm üretmemeli. PID ile de daraltıyoruz.
LOG_START=$(date "+%Y-%m-%d %H:%M:%S")
LAUNCH_OUT=$(xcrun simctl launch booted "$BID") || exit 1
echo "$LAUNCH_OUT"
APP_PID=$(printf '%s' "$LAUNCH_OUT" | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p')
if [ -n "$APP_PID" ]; then
    LOG_PREDICATE="processIdentifier == $APP_PID"
else
    LOG_PREDICATE="process == \"Sismik\""
fi
sleep 12
xcrun simctl io booted screenshot "$OUT/01-liste.png" >/dev/null 2>&1

# Sekmeler derin bağlantıyla gezilir (simctl'de dokunma yok).
for target in stats assembly emergency map; do
    echo "==> sismik://$target"
    xcrun simctl openurl booted "sismik://$target" >/dev/null 2>&1
    sleep 6
    xcrun simctl io booted screenshot "$OUT/$target.png" >/dev/null 2>&1
done

echo "==> Çökme taraması"
crashes=$(xcrun simctl spawn booted log show --predicate "$LOG_PREDICATE" \
            --start "$LOG_START" --style compact 2>/dev/null \
          | grep -icE "fatal error|precondition failed|index out of range|unexpectedly found nil|Swift runtime failure")

if [ "$crashes" -gt 0 ]; then
    echo "HATA: $crashes çökme izi bulundu"
    xcrun simctl spawn booted log show --predicate "$LOG_PREDICATE" --start "$LOG_START" --style compact 2>/dev/null \
      | grep -iE "fatal error|precondition failed|index out of range|unexpectedly found nil|Swift runtime failure" | head
    exit 1
fi

if ! xcrun simctl spawn booted launchctl list 2>/dev/null | grep -qi sismik; then
    echo "HATA: uygulama ayakta değil, açılışta çökmüş olabilir"
    exit 1
fi

echo "✅ Duman testi geçti — çökme yok, uygulama ayakta. Ekran görüntüleri: $OUT"
