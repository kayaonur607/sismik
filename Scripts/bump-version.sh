#!/usr/bin/env bash
# Sürüm numarasını artırır ve build numarasını 1'e döndürür
# (ör. 2.1.1 (4) → 2.1.2 (1)). Yeni sürümün ilk build'i 1'den başlar.
# Uygulama, widget ve bildirim uzantısının Debug/Release ayarlarının hepsi
# birlikte güncellenir.
#
# Kullanım:  ./Scripts/bump-version.sh           → yama:  2.1.1 → 2.1.2
#            ./Scripts/bump-version.sh minor     → ara:   2.1.1 → 2.2.0
#            ./Scripts/bump-version.sh major     → ana:   2.1.1 → 3.0.0
#            ./Scripts/bump-version.sh 2.5.0     → doğrudan 2.5.0
#            ./Scripts/bump-version.sh --keep-build ...  → build numarasına dokunmaz
set -euo pipefail

cd "$(dirname "$0")/.."
PBXPROJ="${PBXPROJ:-Sismik.xcodeproj/project.pbxproj}"

keep_build=false
part="patch"
for arg in "$@"; do
  case "$arg" in
    --keep-build) keep_build=true ;;
    patch|minor|major) part="$arg" ;;
    [0-9]*.[0-9]*) part="$arg" ;;
    *) echo "Hata: bilinmeyen seçenek: $arg (patch | minor | major | X.Y.Z | --keep-build)" >&2; exit 1 ;;
  esac
done

current=$(grep -Eo 'MARKETING_VERSION = [0-9.]+;' "$PBXPROJ" | grep -Eo '[0-9]+(\.[0-9]+)*' | sort -u)
if [ -z "$current" ]; then
  echo "Hata: $PBXPROJ içinde MARKETING_VERSION bulunamadı." >&2; exit 1
fi
if [ "$(echo "$current" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "Hata: hedeflerde farklı sürümler var: $(echo $current). Önce eşitleyin." >&2; exit 1
fi

IFS='.' read -r major minor patch <<< "$current"
minor=${minor:-0}; patch=${patch:-0}
case "$part" in
  patch) next="$major.$minor.$((patch + 1))" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  *)
    [[ "$part" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Hata: sürüm X.Y.Z biçiminde olmalı: $part" >&2; exit 1; }
    next="$part" ;;
esac

sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${next};/g" "$PBXPROJ"
if [ "$keep_build" = false ]; then
  sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = 1;/g" "$PBXPROJ"
fi
build=$(grep -Eo 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | head -1 | grep -Eo '[0-9]+')
echo "Sürüm: $current → $next   (build $build, $(grep -c "MARKETING_VERSION = ${next};" "$PBXPROJ") ayar güncellendi)"
