#!/bin/sh
# `/map` sözleşmesini uçtan uca doğrular:
#   1) Cloud Functions kodunu derler.
#   2) Sunucunun GERÇEK `/map` gövde üretim yolunu (toMapProjection +
#      stripNullish + gzip) express üzerinden bir HTTP ucu olarak çalıştırır.
#   3) Yanıtı gerçek bir HTTP isteğiyle çeker.
#   4) Uygulamanın GERÇEK `Earthquake` decoder'ıyla çözer ve detay teknik
#      kartının okuduğu alanların hayatta kaldığını doğrular.
#
# Neden gerekli: harita havuzundaki nesne yalnızca haritayı çizmez; kullanıcı
# bir işarete dokunup "Detay"a gittiğinde aynı nesne `EarthquakeDetailView`e
# geçer ve detay ekranı kaydı sunucudan tazelemez. Bu yüzden `/map` yanıtından
# alan düşürmek yayımlanmış istemcileri de sessizce bozabilir.
#
# Kullanım:
#   Scripts/verify-map-contract.sh              # yerel örnek veriyle
#   MAP_URL=https://.../map Scripts/verify-map-contract.sh   # canlı uçla
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
served="$work/served.json"

cleanup() {
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$repo_root/functions/verify-map-server.tmp.cjs"
  rm -rf "$work"
}
trap cleanup EXIT

server_pid=""

if [ -n "${MAP_URL:-}" ]; then
  echo "Canlı uç kullanılıyor: $MAP_URL"
  curl -fsS --compressed "$MAP_URL" -o "$served"
else
  echo "Cloud Functions derleniyor…"
  (cd "$repo_root/functions" && npm run build >/dev/null)

  fixture="$repo_root/tests/fixtures/map-sample.json"
  if [ ! -f "$fixture" ]; then
    echo "Örnek veri yok: $fixture" >&2
    echo "MAP_URL ortam değişkeniyle canlı uca karşı çalıştırabilirsiniz." >&2
    exit 2
  fi

  cat > "$repo_root/functions/verify-map-server.tmp.cjs" <<'NODE'
// Sunucunun gerçek /map gövde üretim yolunu izole bir HTTP ucu olarak sunar.
const express = require('express');
const { gzipSync } = require('zlib');
const fs = require('fs');
const { toMapProjection } = require('./lib/worker-utils');

const data = JSON.parse(fs.readFileSync(process.env.MAP_FIXTURE, 'utf8'));

// index.ts'teki stripNullish ile birebir aynı davranış.
function stripNullish(q) {
  const out = {};
  for (const [key, value] of Object.entries(q)) {
    if (value === null || value === undefined || value === false) continue;
    if ((key === 'maximumIntensity' || key === 'communityIntensity')
        && typeof value === 'number' && value <= 0) continue;
    out[key] = value;
  }
  return out;
}

// index.ts'teki createMapCacheEntry ile birebir aynı ifade.
function createMapCacheEntry(records) {
  const json = JSON.stringify(records.map(q => stripNullish(toMapProjection(q))));
  return { json, gzip: gzipSync(Buffer.from(json), { level: 6 }) };
}

const entry = createMapCacheEntry(data);

const app = express();
app.get('/map', (req, res) => {
  res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Vary', 'Accept-Encoding');
  if (/\bgzip\b/i.test(String(req.headers['accept-encoding'] || ''))) {
    res.setHeader('Content-Encoding', 'gzip');
    res.send(entry.gzip);
  } else {
    res.send(entry.json);
  }
});

const server = app.listen(0, () => {
  fs.writeFileSync(process.env.MAP_PORT_FILE, String(server.address().port));
});
NODE

  port_file="$work/port"
  MAP_FIXTURE="$fixture" MAP_PORT_FILE="$port_file" \
    node "$repo_root/functions/verify-map-server.tmp.cjs" &
  server_pid=$!

  tries=0
  while [ ! -s "$port_file" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then echo "sunucu başlamadı" >&2; exit 1; fi
    sleep 0.1
  done
  port=$(cat "$port_file")

  echo "Gerçek HTTP isteği yapılıyor (gzip)…"
  curl -fsS --compressed "http://127.0.0.1:$port/map" -o "$served"
  rm -f "$repo_root/functions/verify-map-server.tmp.cjs"
fi

echo "iOS decoder derleniyor (uygulamanın gerçek kaynakları)…"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
cp "$repo_root/Scripts/verify-map-contract.swift" "$work/main.swift"

xcrun -sdk iphonesimulator swiftc -O \
  -target arm64-apple-ios18.0-simulator \
  -sdk "$sdk" \
  -o "$work/verify-map-contract" \
  "$repo_root/Sismik/Utilities/FastISODate.swift" \
  "$repo_root/Sismik/Utilities/AppPreferences.swift" \
  "$repo_root/Sismik/Utilities/CountryFlag.swift" \
  "$repo_root/Sismik/Utilities/Theme.swift" \
  "$repo_root/Sismik/Models/MagnitudeLevel.swift" \
  "$repo_root/Sismik/Utilities/Extensions.swift" \
  "$repo_root/Sismik/Models/Earthquake.swift" \
  "$work/main.swift"

echo "Yanıt gerçek iOS decoder'ıyla çözülüyor…"
device=$(xcrun simctl list devices booted -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; ids=[x["udid"] for v in d.values() for x in v]; print(ids[0] if ids else "")')

if [ -z "$device" ]; then
  echo "Açık simülatör yok, geçici olarak başlatılıyor…"
  device=$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; ids=[x["udid"] for k,v in d.items() if "iOS" in k for x in v]; print(ids[0] if ids else "")')
  if [ -z "$device" ]; then echo "kullanılabilir iOS simülatörü yok" >&2; exit 2; fi
  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  sleep 10
fi

xcrun simctl spawn "$device" "$work/verify-map-contract" "$served"
