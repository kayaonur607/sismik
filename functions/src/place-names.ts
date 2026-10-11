import * as fs from 'fs';
import * as path from 'path';

// MARK: - Koordinattan yer adı (tweet)
//
// EMSC ve NOA yer olarak kaba Flinn-Engdahl bölgesi verir ("CENTRAL TURKEY",
// "Greece"); AFAD'ın yurt dışı/deniz başlıkları Türkçedir. İngilizce tweet
// için bunlar USGS biçiminde koordinattan adlandırılır: "26 km SE of
// Kahramanmaraş, Türkiye". Veri: Natural Earth 10m yerleşimleri (kamu malı),
// `Scripts/build-places.py` ile üretilen assets/data/places.json. Dış servis
// yok: sınır, gecikme ve kesinti riski taşımaz.

/// [ad, eyalet/il, ülke, enlem, boylam]
type PlaceRow = [string, string, string, number, number];

let places: PlaceRow[] | null = null;

function loadPlaces(): PlaceRow[] {
  if (places) return places;
  const file = [
    path.join(__dirname, '..', 'assets', 'data', 'places.json'),
    path.join(process.cwd(), 'assets', 'data', 'places.json')
  ].find(candidate => fs.existsSync(candidate));
  places = file ? JSON.parse(fs.readFileSync(file, 'utf8')) as PlaceRow[] : [];
  return places;
}

/// Bir yerin tweet'te görünen bölge adı: ABD'de eyalet (USGS gibi), diğer
/// ülkelerde ülke. Türkiye resmi İngilizce adıyla yazılır.
function regionOf(row: PlaceRow): string {
  const [, admin1, country] = row;
  if (country === 'United States of America') return admin1 || 'United States';
  if (country === 'Turkey') return 'Türkiye';
  return country;
}

const DIRECTIONS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];

function toRad(value: number): number { return value * Math.PI / 180; }

function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/// Yerden depreme 16 yönlü pusula yönü ("SE": deprem yerin güneydoğusunda).
function compassFrom(lat1: number, lon1: number, lat2: number, lon2: number): string {
  const y = Math.sin(toRad(lon2 - lon1)) * Math.cos(toRad(lat2));
  const x = Math.cos(toRad(lat1)) * Math.sin(toRad(lat2)) - Math.sin(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.cos(toRad(lon2 - lon1));
  const bearing = (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
  return DIRECTIONS[Math.round(bearing / 22.5) % 16];
}

export interface NearestPlace {
  name: string;
  region: string;
  distanceKm: number;
  direction: string;
}

/// Bu uzaklıktan ötesi "yakın yer" sayılmaz (açık okyanus, sırt); çağıran
/// taraf sağlayıcının bölge adına düşer.
export const NEAREST_PLACE_MAX_KM = 400;

export function nearestPlace(lat: number, lon: number): NearestPlace | null {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  let best: PlaceRow | null = null;
  let bestKm = Infinity;
  const latWindow = NEAREST_PLACE_MAX_KM / 111;
  for (const row of loadPlaces()) {
    // Ucuz ön eleme: enlem farkı pencere dışındaysa haversine gereksiz.
    if (Math.abs(row[3] - lat) > latWindow) continue;
    const km = distanceKm(row[3], row[4], lat, lon);
    if (km < bestKm) { bestKm = km; best = row; }
  }
  if (!best || bestKm > NEAREST_PLACE_MAX_KM) return null;
  return { name: best[0], region: regionOf(best), distanceKm: bestKm, direction: compassFrom(best[3], best[4], lat, lon) };
}

/// "26 km SE of Kahramanmaraş" — 5 km'den yakınsa yalnızca yer adı.
export function describeNearest(place: NearestPlace): string {
  const km = Math.round(place.distanceKm);
  return km < 5 ? place.name : `${km} km ${place.direction} of ${place.name}`;
}

/// Flinn-Engdahl bölge adını ("SOUTH OF TONGA ISLANDS") okunur yazar:
/// "South of Tonga Islands".
export function titleCaseRegion(value: string): string {
  const small = new Set(['of', 'the', 'and', 'off', 'near', 'in']);
  return String(value || '').toLowerCase().split(/(\s+|-|,)/).map((word, index) =>
    index > 0 && small.has(word) ? word : word.charAt(0).toUpperCase() + word.slice(1)
  ).join('').trim();
}

// MARK: - Türkiye'de mi?
//
// Twitter eşiği için (Türkiye M3.0+, diğer her yer M5.5+). Kutu değil gerçek
// sınır: AFAD'ın izlediği kutu Yunanistan, Ege adaları, Kıbrıs ve Kafkasya'yı
// da kapsıyor ve orada M3 paylaşımı tweet sayısını dört katına çıkarıyordu.
// Kara poligonu denizleri içermez; Marmara ve kıyıya yakın deniz depremleri
// kıyıdan ≤ 30 km ve en yakın yerleşim Türkiye ise sayılır (Türk kıyısına
// yakın Yunan adalarındaki olaylar en yakın yerleşimi Yunan olduğu için dışarıda).

let turkiyeRings: Array<Array<[number, number]>> | null = null;

function loadTurkiye(): Array<Array<[number, number]>> {
  if (turkiyeRings) return turkiyeRings;
  const file = [
    path.join(__dirname, '..', 'assets', 'data', 'turkiye.json'),
    path.join(process.cwd(), 'assets', 'data', 'turkiye.json')
  ].find(candidate => fs.existsSync(candidate));
  turkiyeRings = file ? JSON.parse(fs.readFileSync(file, 'utf8')) : [];
  return turkiyeRings!;
}

function insideRing(ring: Array<[number, number]>, lat: number, lon: number): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if ((yi > lat) !== (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export const TURKIYE_COASTAL_KM = 30;

export function isInTurkiye(lat: number, lon: number): boolean {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return false;
  // Ucuz ön eleme: Türkiye'nin çevre kutusu (payla).
  if (lat < 35.5 || lat > 42.5 || lon < 25.3 || lon > 45) return false;
  const rings = loadTurkiye();
  if (rings.some(ring => insideRing(ring, lat, lon))) return true;
  let coastKm = Infinity;
  for (const ring of rings) {
    for (const [x, y] of ring) coastKm = Math.min(coastKm, distanceKm(y, x, lat, lon));
  }
  if (coastKm > TURKIYE_COASTAL_KM) return false;
  return nearestPlace(lat, lon)?.region === 'Türkiye';
}

/// Testler için: yer listesini dışarıdan verir.
export function setPlacesForTesting(rows: PlaceRow[] | null): void {
  places = rows;
}
