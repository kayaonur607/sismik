#!/usr/bin/env bash
# Build numarasını 1 artırır (ör. 2.1.1 (4) → 2.1.1 (5)).
# Uygulama, widget ve bildirim uzantısının Debug/Release ayarlarının hepsi
# birlikte güncellenir; App Store uzantıların uygulamayla aynı numarayı taşımasını ister.
#
# Kullanım:  ./Scripts/bump-build.sh          → bir artırır
#            ./Scripts/bump-build.sh 12       → 12 yapar
set -euo pipefail

cd "$(dirname "$0")/.."
PBXPROJ="${PBXPROJ:-Sismik.xcodeproj/project.pbxproj}"

current=$(grep -Eo 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | grep -Eo '[0-9]+' | sort -u)
if [ -z "$current" ]; then
  echo "Hata: $PBXPROJ içinde CURRENT_PROJECT_VERSION bulunamadı." >&2; exit 1
fi
if [ "$(echo "$current" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "Hata: hedeflerde farklı build numaraları var: $(echo $current). Önce eşitleyin." >&2; exit 1
fi

if [ $# -ge 1 ]; then
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "Hata: build numarası sayı olmalı: $1" >&2; exit 1; }
  next="$1"
else
  next=$((current + 1))
fi

sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${next};/g" "$PBXPROJ"
version=$(grep -Eo 'MARKETING_VERSION = [0-9.]+;' "$PBXPROJ" | head -1 | grep -Eo '[0-9.]+[0-9]')
echo "Build: $current → $next   (sürüm $version, $(grep -c "CURRENT_PROJECT_VERSION = ${next};" "$PBXPROJ") ayar güncellendi)"
