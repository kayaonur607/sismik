import axios from 'axios';
import { Earthquake, getDistanceKm } from './worker-utils';

// MARK: - GDACS (BM/AB Küresel Afet Uyarı ve Koordinasyon Sistemi)
//
// GDACS her önemli deprem için nüfus ve hasar modeline dayalı bir alarm
// seviyesi yayımlar: yeşil, turuncu, kırmızı. Seviye, ilgili deprem kaydına
// `alertLevel` olarak işlenir (USGS PAGER seviyesi zaten aynı alanı
// kullanıyor; uygulama bu alanı gösteriyor). Turuncu/kırmızı alarm, büyüklük
// eşiğinin altında kalsa bile büyük olay kartını açar (major-event.ts).
//
// Maliyet: 5 dakikada bir küçük bir JSON isteği; Firestore yok.

export interface GdacsEvent {
  id: string;
  alertLevel: 'green' | 'orange' | 'red';
  magnitude: number;
  lat: number;
  lon: number;
  time: number;
  country: string;
}

const GDACS_URL = 'https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH';
const GDACS_REFRESH_MS = 5 * 60 * 1000;
const GDACS_LOOKBACK_MS = 3 * 86400_000;

export function parseGdacsEvents(data: any): GdacsEvent[] {
  const features: any[] = Array.isArray(data?.features) ? data.features : [];
  const events: GdacsEvent[] = [];
  for (const feature of features) {
    const props = feature?.properties;
    const coords = feature?.geometry?.coordinates;
    if (!props || props.eventtype !== 'EQ' || !Array.isArray(coords)) continue;
    const level = String(props.alertlevel || '').toLowerCase();
    if (level !== 'green' && level !== 'orange' && level !== 'red') continue;
    const time = Date.parse(String(props.fromdate || '').replace(/Z?$/, 'Z'));
    const magnitude = Number(props.severitydata?.severity);
    const lat = Number(coords[1]);
    const lon = Number(coords[0]);
    if (!Number.isFinite(time) || !Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    events.push({ id: String(props.eventid), alertLevel: level, magnitude, lat, lon, time, country: String(props.country || '') });
  }
  return events;
}

let cache: { at: number; events: GdacsEvent[] } = { at: 0, events: [] };
let inFlight: Promise<GdacsEvent[]> | null = null;

export async function fetchGdacsEvents(now: number = Date.now()): Promise<GdacsEvent[]> {
  if (now - cache.at < GDACS_REFRESH_MS) return cache.events;
  if (inFlight) return inFlight;
  inFlight = (async () => {
    try {
      const from = new Date(now - GDACS_LOOKBACK_MS).toISOString().slice(0, 10);
      const response = await axios.get(GDACS_URL, {
        timeout: 8000,
        params: { eventlist: 'EQ', fromDate: from, alertlevel: 'green;orange;red' },
        headers: { 'User-Agent': 'Sismik/2.1.4 (+https://sismik-app.web.app; sismikapplication@gmail.com)' }
      });
      cache = { at: now, events: parseGdacsEvents(response.data) };
    } catch (error: any) {
      // Hata önceki sonucu korur; bir sonraki denemeyi 1 dk sonraya bırakır.
      cache = { at: now - GDACS_REFRESH_MS + 60_000, events: cache.events };
      console.warn('GDACS okunamadı:', error?.message || error);
    } finally {
      inFlight = null;
    }
    return cache.events;
  })();
  return inFlight;
}

/// GDACS olayını aynı depremin kaydına eşler (±3 dk, 150 km). Kaynağın kendi
/// seviyesi (USGS PAGER) varsa ona dokunulmaz. Değişiklik yoksa aynı dizi döner.
export function applyGdacsAlertLevels(quakes: Earthquake[], events: GdacsEvent[]): Earthquake[] {
  if (!events.length) return quakes;
  let changed = false;
  const result = quakes.map(q => {
    if (q.alertLevel || q.magnitude < 4.5) return q;
    const time = Date.parse(q.date);
    const match = events.find(event => Math.abs(event.time - time) <= 180_000
      && getDistanceKm(event.lat, event.lon, q.lat, q.lon) <= 150);
    if (!match) return q;
    changed = true;
    return { ...q, alertLevel: match.alertLevel };
  });
  return changed ? result : quakes;
}
