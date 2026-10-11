#!/bin/sh
# FastISODate'i projedeki gerçek kaynak dosyasıyla birlikte derleyip doğrular.
# Kopya kaynak kullanılmaz: sapma olursa test değil, uygulama kodu yanılır.
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Swift'te üst düzey ifadeler yalnızca main.swift içinde serbesttir.
cp "$repo_root/Scripts/verify-fastisodate.swift" "$work/main.swift"

swiftc -O \
    -o "$work/verify" \
    "$repo_root/Sismik/Utilities/FastISODate.swift" \
    "$work/main.swift"

"$work/verify"
