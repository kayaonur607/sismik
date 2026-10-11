import axios from 'axios';
import { Earthquake, authorityRank, getDistanceKm, isTurkiyeQuake } from './worker-utils';
export { authorityRank } from './worker-utils';

// MARK: - Büyük olay modu
//
// Türkiye'de M5.5+ ya da dünyada M7.0+ bir deprem sıradan bir liste satırı
// gibi görünmemeli. Böyle bir olay görüldüğünde:
//
//  - Canlı liste belgesine (`_public/live_quakes_v1`) `major_event` alanı
//    yazılır. API bu belgeyi zaten okuduğu için ek Firestore okuması yok;
//    liste yanıtı `X-Sismik-Major-Event` başlığında olay kimliğini taşır,
//    istemci ayrıntıyı `/major-event` ucundan (CDN önbellekli) alır.
//  - Deprem analizi (Gemini) tr ve en için hemen üretilir: binlerce kullanıcı
//    aynı dakikada detayı açtığında analiz önbellekte hazır bekler.
//  - Olay 24 saat (Türkiye M6.0+ için 72 saat) boyunca açık kalır; istemci
//    bu sürede listede ayrı bir olay kartı gösterir, artçı takibini ve
//    analizi herkese açar.
//
// Tespit yalnızca tek örnekli `scheduledPushCheck` servisinde çalışır (canlı
// belgeyi yazan tek süreç); API servisleri yalnızca okur.

export interface MajorEvent {
  id: string;
  provider: string;
  title: string;
  magnitude: number;
  depth: number;
  lat: number;
  lon: number;
  date: string;
  region: 'turkiye' | 'world';
  detected_at: number;
  expires_at: number;
  /// Canlı Etkinlik yayın kanalları (live-activity.ts); APNs yoksa yok.
  live_channels?: { prod?: string; sandbox?: string };
}

export const TURKIYE_MAJOR_MIN_MAGNITUDE = 5.5;
export const WORLD_MAJOR_MIN_MAGNITUDE = 7.0;
/// Deprem bu kadar eskiyse (ör. geç yayımlanan katalog kaydı) olay açılmaz.
const MAX_EVENT_AGE_MS = 6 * 60 * 60 * 1000;

/// GDACS/PAGER turuncu ya da kırmızı alarmı: büyüklükten bağımsız olarak
/// ciddi etki bekleniyor demektir (yoğun nüfuslu bölgede M6.2 gibi).
const IMPACT_ALERT_LEVELS = new Set(['orange', 'red']);
export const IMPACT_ALERT_MIN_MAGNITUDE = 5.5;

export function majorEventRegion(q: Earthquake): MajorEvent['region'] | null {
  if (!Number.isFinite(q.magnitude)) return null;
  const turkiye = isTurkiyeQuake(q);
  if (turkiye && q.magnitude >= TURKIYE_MAJOR_MIN_MAGNITUDE) return 'turkiye';
  if (q.magnitude >= WORLD_MAJOR_MIN_MAGNITUDE) return 'world';
  if (q.magnitude >= IMPACT_ALERT_MIN_MAGNITUDE && IMPACT_ALERT_LEVELS.has(String(q.alertLevel || '').toLowerCase())) {
    return turkiye ? 'turkiye' : 'world';
  }
  return null;
}

export function majorEventDurationMs(region: MajorEvent['region'], magnitude: number): number {
  return region === 'turkiye' && magnitude >= 6 ? 72 * 3600_000 : 24 * 3600_000;
}

/// Aynı fiziksel olay mı (ajans kopyası ya da büyüklük revizyonu)?
function sameEvent(event: MajorEvent, q: Earthquake): boolean {
  const dt = Math.abs(Date.parse(q.date) - Date.parse(event.date));
  return dt <= 120_000 && getDistanceKm(event.lat, event.lon, q.lat, q.lon) <= 100;
}

/// Aynı olayın kaydı geldi: kaynak daha yetkiliyse (ya da aynı kaynağın
/// revizyonuysa) büyüklük, derinlik, başlık ve kaynak ondan alınır — AŞAĞI
/// revizyon dahil (EMSC M5.6 → AFAD M5.4). Kimlik ve kanal korunur. Değişiklik
/// yoksa aynı nesne döner (gereksiz yazım olmaz).
function refreshedFromRecord(event: MajorEvent, q: Earthquake, region: MajorEvent['region']): MajorEvent {
  const current = authorityRank(event);
  const incoming = authorityRank(q);
  const sameSource = String(q.provider).toUpperCase() === String(event.provider).toUpperCase();
  if (incoming > current || (incoming === current && !sameSource)) return event;
  const magnitude = Math.round(q.magnitude * 10) / 10;
  if (Math.abs(magnitude - event.magnitude) < 0.05 && q.depth === event.depth && q.title === event.title && sameSource) return event;
  return {
    ...event,
    provider: q.provider,
    title: q.title,
    magnitude,
    depth: q.depth,
    expires_at: Math.max(event.expires_at, Date.parse(event.date) + majorEventDurationMs(region, magnitude))
  };
}

/// Saf karar: mevcut olay ve yeni liste verildiğinde yeni olay durumu.
/// Değişiklik yoksa `current` aynen döner (referans eşitliği yazımı engeller).
export function nextMajorEvent(current: MajorEvent | null, quakes: readonly Earthquake[], now: number): MajorEvent | null {
  let event = current && current.expires_at > now ? current : null;
  for (const q of quakes) {
    // Aynı olayın eşik altına revize edilmiş resmî kaydı da (AFAD M5.4) olayı
    // günceller; kart kapanmaz ama doğru büyüklüğü gösterir.
    if (event && sameEvent(event, q) && !majorEventRegion(q)) {
      event = refreshedFromRecord(event, q, event.region);
      continue;
    }
    const region = majorEventRegion(q);
    if (!region) continue;
    const time = Date.parse(q.date);
    if (!Number.isFinite(time) || now - time > MAX_EVENT_AGE_MS || time > now + 60_000) continue;
    if (event && sameEvent(event, q)) {
      event = refreshedFromRecord(event, q, region);
      continue;
    }
    // Farklı bir olay: yalnızca daha büyükse yerini alır (ör. öncü → ana şok).
    if (event && q.magnitude <= event.magnitude) continue;
    event = {
      id: q.id,
      provider: q.provider,
      title: q.title,
      magnitude: q.magnitude,
      depth: q.depth,
      lat: q.lat,
      lon: q.lon,
      date: q.date,
      region,
      detected_at: now,
      expires_at: time + majorEventDurationMs(region, q.magnitude)
    };
  }
  return event;
}

export function parseMajorEvent(raw: unknown, now: number): MajorEvent | null {
  if (typeof raw !== 'string' || !raw) return null;
  try {
    const event = JSON.parse(raw) as MajorEvent;
    return event?.id && Number(event.expires_at) > now ? event : null;
  } catch {
    return null;
  }
}

/// Analizi kendi API'mizden isteyerek üretir ve önbelleğe yazdırır. Gemini
/// anahtarı yalnızca API servisinde; bu servis yalnızca bir HTTP isteği atar.
export async function prewarmMajorEventAnalysis(event: MajorEvent, apiBaseURL: string): Promise<void> {
  await Promise.allSettled(['tr', 'en'].map(lang => axios.get(`${apiBaseURL}/ai`, {
    timeout: 45_000,
    params: {
      id: event.id,
      lang,
      mag: event.magnitude,
      depth: event.depth,
      lat: event.lat,
      lon: event.lon,
      place: event.title.slice(0, 120)
    }
  })));
}
