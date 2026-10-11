// MARK: - Toplanma alanları ve sağlık noktaları için ortak önbellek
//
// Eskiden her cihaz OpenStreetMap'i (Overpass) kendisi sorguluyordu: yanıt
// 2–6 sn sürüyor, Overpass aynı IP'den gelen yoğun istekte 429 veriyor ve
// büyük bir depremde binlerce kişi aynı mahalleyi aynı anda arıyordu.
//
// Artık dünya 0,1°'lik hücrelere bölünür (~11 × 9 km). Bir hücreyi ilk
// isteyen olunca sunucu Overpass'tan tek seferde çeker ve Firestore'a
// (`safety_cells/<hücre>`, gzip'li) yazar; aynı hücredeki herkes sonucu
// bellekten ya da CDN'den alır. Kayıt 30 günde bir tazelenir (TTL).

import { gzipSync, gunzipSync } from 'node:zlib';
import axios from 'axios';
import express from 'express';
import { Firestore } from 'firebase-admin/firestore';
import { getDistanceKm } from './worker-utils';

export type SafetyCategory = 'assemblyArea' | 'pharmacy' | 'clinic' | 'hospital' | 'grocery';

export interface SafetyPlace {
  id: string;
  /// Kategori.
  c: SafetyCategory;
  lat: number;
  lon: number;
  /// Verinin kendi dilindeki ad (yoksa boş; istemci kategori adını yazar).
  n: string;
  /// Uygulama dillerindeki adlar (`name:<dil>` etiketi olanlar).
  nl?: Record<string, string>;
  /// Adres ya da işletmeci.
  a?: string;
  /// Hücre içindeki OSM referansı (numaralı toplanma alanları).
  r?: string;
}

export const SAFETY_CELL_DEGREES = 0.1;
const CELL_TTL_MS = 30 * 86_400_000;
const EMPTY_CELL_TTL_MS = 7 * 86_400_000;
const MEMORY_TTL_MS = 6 * 3_600_000;
const MEMORY_MAX = 400;
const MAX_RADIUS_M = 12_000;
/// Kategori başına en yakın kayıt: şehir merkezinde market/eczane binlerce.
const PER_CATEGORY_LIMIT = 150;
const APP_LANGS = ['tr', 'en', 'de', 'es', 'fr', 'it', 'ja', 'ru', 'ar', 'el', 'pt', 'id', 'ko', 'zh'];
const OVERPASS_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter'
];

export function safetyCellKey(lat: number, lon: number): string {
  return `${Math.floor(lat / SAFETY_CELL_DEGREES)}_${Math.floor(lon / SAFETY_CELL_DEGREES)}`;
}

/// Merkez çevresindeki daireyi kesen hücreler (12 km'de en fazla 12).
export function safetyCellsAround(lat: number, lon: number, radiusM: number): string[] {
  const dLat = radiusM / 111_320;
  const dLon = radiusM / (111_320 * Math.max(0.2, Math.cos(lat * Math.PI / 180)));
  const keys: string[] = [];
  for (let i = Math.floor((lat - dLat) / SAFETY_CELL_DEGREES); i <= Math.floor((lat + dLat) / SAFETY_CELL_DEGREES); i++) {
    for (let j = Math.floor((lon - dLon) / SAFETY_CELL_DEGREES); j <= Math.floor((lon + dLon) / SAFETY_CELL_DEGREES); j++) {
      keys.push(`${i}_${j}`);
    }
  }
  return keys;
}

function cellBounds(key: string): { south: number; west: number; north: number; east: number } {
  const [i, j] = key.split('_').map(Number);
  return {
    south: +(i * SAFETY_CELL_DEGREES).toFixed(4),
    west: +(j * SAFETY_CELL_DEGREES).toFixed(4),
    north: +((i + 1) * SAFETY_CELL_DEGREES).toFixed(4),
    east: +((j + 1) * SAFETY_CELL_DEGREES).toFixed(4)
  };
}

/// İstemcideki `AssemblyAreaService.category(from:)` ile aynı karar.
export function safetyCategory(tags: Record<string, string>): SafetyCategory | null {
  const amenity = tags.amenity?.toLowerCase();
  const healthcare = tags.healthcare?.toLowerCase();
  const shop = tags.shop?.toLowerCase();
  if (amenity === 'hospital' || healthcare === 'hospital') return 'hospital';
  if (amenity === 'clinic' || amenity === 'doctors'
      || healthcare === 'clinic' || healthcare === 'doctor' || healthcare === 'centre') return 'clinic';
  if (amenity === 'pharmacy') return 'pharmacy';
  if (shop === 'supermarket' || shop === 'convenience' || shop === 'grocery') return 'grocery';
  if (tags.emergency === 'assembly_point' || tags['assembly_point:earthquake']?.toLowerCase() === 'yes') {
    return 'assemblyArea';
  }
  return null;
}

function address(tags: Record<string, string>): string | undefined {
  const full = tags['addr:full']?.trim();
  if (full) return full.slice(0, 160);
  const parts = [tags['addr:street'], tags['addr:housenumber'], tags['addr:city']]
    .map(value => value?.trim()).filter(Boolean);
  if (parts.length) return parts.join(', ').slice(0, 160);
  return tags.operator?.trim().slice(0, 160) || undefined;
}

/// Overpass yanıtını sade kayıtlara çevirir. Saf fonksiyon (testlerde).
export function parseOverpassElements(elements: any[]): SafetyPlace[] {
  const places: SafetyPlace[] = [];
  const seen = new Set<string>();
  for (const element of elements || []) {
    const tags: Record<string, string> = element?.tags || {};
    const lat = Number(element?.lat ?? element?.center?.lat);
    const lon = Number(element?.lon ?? element?.center?.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    const c = safetyCategory(tags);
    if (!c) continue;
    if (c === 'assemblyArea' && tags['assembly_point:earthquake']?.toLowerCase() === 'no') continue;
    const id = `osm-${element.type}-${element.id}`;
    if (seen.has(id)) continue;
    seen.add(id);
    const nl: Record<string, string> = {};
    for (const lang of APP_LANGS) {
      const value = tags[`name:${lang}`]?.trim();
      if (value) nl[lang] = value.slice(0, 120);
    }
    const place: SafetyPlace = {
      id, c,
      lat: Math.round(lat * 1e6) / 1e6,
      lon: Math.round(lon * 1e6) / 1e6,
      n: (tags.name || '').trim().slice(0, 120)
    };
    if (Object.keys(nl).length) place.nl = nl;
    const a = address(tags);
    if (a) place.a = a;
    const ref = tags.ref?.trim();
    if (ref) place.r = ref.slice(0, 20);
    places.push(place);
  }
  return places;
}

/// Eksik hücrelerin hepsini kapsayan tek sorgu. Genel Overpass sunucuları
/// IP başına ~2 eşzamanlı sorguya izin veriyor; hücre başına ayrı sorgu
/// zaman aşımına düşüyordu. Düzenli ifade yerine tam eşleşme: daha hızlı.
function overpassQuery(keys: string[]): string {
  const bounds = keys.map(cellBounds);
  const bbox = [
    Math.min(...bounds.map(b => b.south)), Math.min(...bounds.map(b => b.west)),
    Math.max(...bounds.map(b => b.north)), Math.max(...bounds.map(b => b.east))
  ].map(value => value.toFixed(4)).join(',');
  const clauses = [
    '["emergency"="assembly_point"]', '["assembly_point:earthquake"="yes"]',
    '["amenity"="pharmacy"]', '["amenity"="hospital"]', '["amenity"="clinic"]', '["amenity"="doctors"]',
    '["healthcare"="hospital"]', '["healthcare"="clinic"]', '["healthcare"="centre"]', '["healthcare"="doctor"]',
    '["shop"="supermarket"]', '["shop"="convenience"]', '["shop"="grocery"]'
  ];
  return `[out:json][timeout:25][bbox:${bbox}];
(
${clauses.map(clause => `  nwr${clause};`).join('\n')}
);
out center tags;`;
}

async function fetchCellsFromOverpass(keys: string[]): Promise<Map<string, SafetyPlace[]>> {
  const body = new URLSearchParams({ data: overpassQuery(keys) }).toString();
  let lastError: unknown;
  for (const endpoint of OVERPASS_ENDPOINTS) {
    try {
      const response = await axios.post(endpoint, body, {
        timeout: 30_000,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'User-Agent': 'Sismik/2.1 (+https://sismik-app.web.app; sismikapplication@gmail.com)'
        }
      });
      if (!Array.isArray(response.data?.elements)) throw new Error('overpass: unexpected response');
      const byCell = new Map<string, SafetyPlace[]>(keys.map(key => [key, []]));
      for (const place of parseOverpassElements(response.data.elements)) {
        byCell.get(safetyCellKey(place.lat, place.lon))?.push(place);
      }
      return byCell;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('overpass unavailable');
}

const memory = new Map<string, { places: SafetyPlace[]; at: number }>();
const inflight = new Map<string, Promise<SafetyPlace[] | null>>();

function remember(key: string, places: SafetyPlace[]): void {
  memory.delete(key);
  memory.set(key, { places, at: Date.now() });
  if (memory.size > MEMORY_MAX) {
    const oldest = memory.keys().next().value;
    if (oldest !== undefined) memory.delete(oldest);
  }
}

/// Hücreleri bellek → Firestore → Overpass sırasıyla çözer. Çekilemeyen
/// hücre `null` döner; yanıt eksik olduğu için kısa süre önbelleğe alınır.
export async function loadSafetyCells(db: Firestore, keys: string[], now = Date.now()): Promise<Map<string, SafetyPlace[] | null>> {
  const result = new Map<string, SafetyPlace[] | null>();
  const missing: string[] = [];
  for (const key of keys) {
    const cached = memory.get(key);
    if (cached && now - cached.at < MEMORY_TTL_MS) result.set(key, cached.places);
    else missing.push(key);
  }
  if (!missing.length) return result;

  const collection = db.collection('safety_cells');
  // Firestore yalnızca ortak önbellek: okunamazsa hücreler Overpass'tan gelir.
  const snapshots = await db.getAll(...missing.map(key => collection.doc(key))).catch((error: any) => {
    console.warn('[safety] hücre önbelleği okunamadı:', error?.message || error);
    return missing.map(() => null);
  });
  const toFetch: string[] = [];
  snapshots.forEach((snapshot, index) => {
    const key = missing[index];
    const data = snapshot?.data();
    const expireAt = data?.expire_at?.toMillis?.() ?? Number(data?.expire_at_ms || 0);
    if (!data?.payload || (expireAt && expireAt <= now)) {
      toFetch.push(key);
      return;
    }
    try {
      const places = JSON.parse(gunzipSync(Buffer.from(data.payload)).toString('utf8')) as SafetyPlace[];
      remember(key, places);
      result.set(key, places);
    } catch {
      toFetch.push(key);
    }
  });

  if (!toFetch.length) return result;
  // Aynı hücreleri aynı anda isteyen başka istek varsa onun sonucu beklenir.
  const pending = toFetch.filter(key => inflight.has(key));
  const fresh = toFetch.filter(key => !inflight.has(key));
  if (fresh.length) {
    const batch = (async () => {
      try {
        const byCell = await fetchCellsFromOverpass(fresh);
        const writer = db.batch();
        for (const [key, places] of byCell) {
          writer.set(collection.doc(key), {
            payload: gzipSync(Buffer.from(JSON.stringify(places))),
            count: places.length,
            fetched_at: now,
            expire_at: new Date(now + (places.length ? CELL_TTL_MS : EMPTY_CELL_TTL_MS))
          });
          remember(key, places);
        }
        // Yazım hatası elde edilmiş sonucu düşürmesin (Overpass sorgusu
        // 12–22 sn sürüyor); hücreler bu örneğin belleğinde zaten tutuluyor.
        await writer.commit().catch((error: any) => {
          console.warn('[safety] hücre önbelleği yazılamadı:', error?.message || error);
        });
        return byCell;
      } catch (error: any) {
        console.warn(`[safety] ${fresh.join(',')} hücreleri çekilemedi:`, error?.message || error);
        return null;
      }
    })();
    fresh.forEach(key => inflight.set(key, batch.then(byCell => byCell?.get(key) ?? null)));
    try {
      const byCell = await batch;
      fresh.forEach(key => result.set(key, byCell?.get(key) ?? null));
    } finally {
      fresh.forEach(key => inflight.delete(key));
    }
  }
  for (const key of pending) result.set(key, await inflight.get(key)!);
  return result;
}

/// Hücrelerden merkeze en yakın kayıtlar; kategori başına sınırlı.
export function nearestSafetyPlaces(
  cells: Iterable<SafetyPlace[] | null>,
  lat: number,
  lon: number,
  radiusM: number,
  perCategory = PER_CATEGORY_LIMIT
): Array<SafetyPlace & { d: number }> {
  const byCategory = new Map<SafetyCategory, Array<SafetyPlace & { d: number }>>();
  const seen = new Set<string>();
  for (const places of cells) {
    for (const place of places ?? []) {
      if (seen.has(place.id)) continue;
      seen.add(place.id);
      const d = Math.round(getDistanceKm(lat, lon, place.lat, place.lon) * 1000);
      if (d > radiusM) continue;
      const list = byCategory.get(place.c) ?? [];
      list.push({ ...place, d });
      byCategory.set(place.c, list);
    }
  }
  return [...byCategory.values()]
    .flatMap(list => list.sort((a, b) => a.d - b.d).slice(0, perCategory))
    .sort((a, b) => a.d - b.d);
}

export function registerSafetyPlacesRoute(
  app: express.Express,
  db: Firestore,
  isRateLimited: (req: express.Request, scope: string, limit: number, windowMs: number) => boolean
): void {
  app.get('/safety-places', async (req, res) => {
    const lat = Number(req.query.lat);
    const lon = Number(req.query.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 85 || Math.abs(lon) > 180) {
      res.status(400).json({ error: 'Bad coordinate' });
      return;
    }
    // CDN ıskası başına sınır; aynı mahalle CDN'den döner.
    if (isRateLimited(req, 'safety', 120, 600_000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }
    const radius = Math.min(MAX_RADIUS_M, Math.max(1_000, Number(req.query.radius) || MAX_RADIUS_M));
    try {
      const cells = await loadSafetyCells(db, safetyCellsAround(lat, lon, radius));
      const partial = [...cells.values()].some(places => places === null);
      const places = nearestSafetyPlaces(cells.values(), lat, lon, radius);
      // Eksik yanıt kısa süre tutulur: çekilemeyen hücre birazdan yeniden denenir.
      res.setHeader('Cache-Control', partial
        ? 'public, max-age=60, s-maxage=60'
        : 'public, max-age=3600, s-maxage=21600, stale-while-revalidate=86400');
      res.json({ places, partial, source: 'OpenStreetMap' });
    } catch (error: any) {
      console.error('[safety] istek başarısız:', error?.message || error);
      res.status(503).json({ error: 'Safety places unavailable' });
    }
  });
}
