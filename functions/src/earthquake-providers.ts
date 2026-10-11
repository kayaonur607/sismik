import axios from 'axios';
import {
  Earthquake,
  optionalFiniteNumber,
  parseNOAEventText,
  parseNOAGeoJSON,
  getDistanceKm
} from './worker-utils';
import { describeNearest, isInTurkiye, nearestPlace } from './place-names';

// Axios Client with default settings
const client = axios.create({
  timeout: 10000,
  headers: {
    // Kaynak yöneticisi bir sorun görürse engellemek yerine ulaşabilsin.
    'User-Agent': 'Sismik/2.1 (+https://sismik-app.web.app; sismikapplication@gmail.com)'
  }
});

/// Geçici ağ hatalarına karşı tek yeniden deneme ile GET.
/// Dış kaynaklar (AFAD/EMSC/USGS/NOA) ara sıra anlık hata döndürür; tek retry
/// başarı oranını belirgin artırır, gecikmeyi en fazla ~600 ms uzatır.
async function getWithRetry(url: string, retries = 1, timeoutMs = 10000): Promise<any> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await client.get(url, { timeout: timeoutMs });
    } catch (error) {
      lastError = error;
      const status = Number((error as any)?.response?.status || 0);
      // 4xx yanıtlar geçici değildir. Özellikle FDSN 404 "veri yok"
      // anlamına gelir; aynı sorguyu yeniden göndererek kaynağı yormayız.
      if (status >= 400 && status < 500) break;
      if (attempt < retries) {
        await new Promise(resolve => setTimeout(resolve, 600));
      }
    }
  }
  throw lastError;
}

/// Push'un hızlı taraması için istek ayarı: kısa süre, yeniden deneme yok,
/// hata logu yok. Hızlı tarama dakikada dört kez çalışıyor; takılan bir
/// kaynağı yeniden denemek diğer kaynakların bildirimini bekletirdi, her
/// zaman aşımını loglamak da logları doldururdu. Aynı kaynak dakikada bir
/// tam taramada normal ayarlarla zaten deneniyor.
export interface ProviderRequestOptions {
  timeoutMs?: number;
  retries?: number;
  quiet?: boolean;
}

function validISODate(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null;
  const raw = String(value);
  const parsed = new Date(/[zZ]|[+-]\d\d:\d\d$/.test(raw) ? raw : `${raw}Z`);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : null;
}

// MARK: - Deprem Verisi Çekiciler

export async function fetchAFADRange(
  startISO: string,
  endISO: string,
  limit: number,
  minmag = 0,
  options: ProviderRequestOptions = {}
): Promise<Earthquake[]> {
  const fmt = (iso: string) => {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'UTC',
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
      hourCycle: 'h23'
    }).formatToParts(new Date(iso));
    const value = (type: string) => parts.find(part => part.type === type)?.value || '';
    return `${value('year')}-${value('month')}-${value('day')} ${value('hour')}:${value('minute')}:${value('second')}`;
  };

  const url = `https://deprem.afad.gov.tr/apiv2/event/filter?start=${encodeURIComponent(fmt(startISO))}&end=${encodeURIComponent(fmt(endISO))}&minmag=${minmag}&limit=${limit}`;
  try {
    const response = await getWithRetry(url, options.retries ?? 1, options.timeoutMs ?? 10000);
    const data = response.data;
    if (!Array.isArray(data)) return [];

    const quakes: Earthquake[] = [];
    for (const e of data) {
      const magnitude = Number(e.magnitude);
      const lat = Number(e.latitude);
      const lon = Number(e.longitude);
      if (!Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;

      const raw = String(e.date || '');
      const time = new Date(/[zZ]|[+-]\d\d:\d\d$/.test(raw) ? raw : raw + 'Z');
      if (isNaN(time.getTime())) continue;

      const depth = Number.isFinite(Number(e.depth)) ? Number(e.depth) : 0;

      quakes.push({
        id: `afad-${e.eventID || `${raw}-${lat}-${lon}`}`,
        provider: 'AFAD',
        title: e.location || 'Bilinmeyen Konum',
        magnitude,
        depth,
        lat,
        lon,
        date: time.toISOString(),
        closestCity: e.province || null,
        epiCenter: e.location || null,
        magType: e.type || null,
        district: e.district || null,
        country: e.country || null,
        updatedAt: validISODate(e.lastUpdateDate),
        code: e.eventID ? String(e.eventID) : null,
        eventType: 'earthquake',
        catalog: 'AFAD',
        sourceURL: e.eventID ? `https://deprem.afad.gov.tr/apiv2/event/filter?eventid=${encodeURIComponent(String(e.eventID))}` : 'https://deprem.afad.gov.tr/',
        revised: e.isEventUpdate === true
      });
    }
    return quakes;
  } catch (error) {
    if (!options.quiet) console.error('AFAD çekimi başarısız:', error);
    return [];
  }
}

export async function fetchAFADRecentRange(startISO: string, endISO: string, limit: number, minmag: number): Promise<Earthquake[]> {
  const absoluteStart = new Date(startISO);
  let cursor = new Date(endISO);
  let collected: Earthquake[] = [];
  const windowMs = 14 * 86_400_000;

  while (cursor > absoluteStart && collected.length < limit) {
    const windowStart = new Date(Math.max(absoluteStart.getTime(), cursor.getTime() - windowMs));
    const page = await fetchAFADRange(
      windowStart.toISOString(),
      cursor.toISOString(),
      // AFAD sonuçları eskiden yeniye sıralayabildiği için küçük bir API
      // limiti pencerenin en yeni kayıtlarını sessizce kesiyordu. Her 14
      // günlük pencereyi tam çekip toplam sonucu aşağıda tarihe göre kesiyoruz.
      10000,
      minmag
    );
    collected = collected.concat(page);
    cursor = new Date(windowStart.getTime() - 1000);
  }

  collected.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
  return collected.slice(0, limit);
}

export async function fetchEMSCRange(
  startISO: string,
  limit: number,
  minmag = 0,
  options: ProviderRequestOptions = {}
): Promise<Earthquake[]> {
  const url = `https://seismicportal.eu/fdsnws/event/1/query?limit=${limit}&format=json&starttime=${encodeURIComponent(startISO)}&minmagnitude=${minmag}`;
  try {
    const res = await getWithRetry(url, options.retries ?? 1, options.timeoutMs ?? 10000);
    return mapEMSCFeatures(res.data);
  } catch (error) {
    if (!options.quiet) console.error('EMSC range çekimi başarısız:', error);
    return [];
  }
}

export async function fetchEMSCWindow(endISO: string, limit: number, minmag = 0): Promise<Earthquake[]> {
  const url = `https://seismicportal.eu/fdsnws/event/1/query?limit=${limit}&format=json&endtime=${encodeURIComponent(endISO)}&minmagnitude=${minmag}`;
  try {
    const res = await getWithRetry(url);
    return mapEMSCFeatures(res.data);
  } catch (error) {
    console.error('EMSC window çekimi başarısız:', error);
    return [];
  }
}

/// Atina Ulusal Gözlemevi (NOA) FDSN servisi her istekte zaman sınırı ister.
/// Başlangıç ve bitişi birlikte göndermek, katalogda pahalı sınırsız sorguları
/// önler ve resmî servisin en az 60 saniyelik polling yönergesiyle uyumludur.
/// NOA canlı akışı süreç içinde 20 sn paylaşılır: hızlı taramalar (~15 sn)
/// ve tam tur aynı dakikada siteyi tekrar tekrar çekmez.
const noaLiveCache = new Map<number, { at: number; promise: Promise<Earthquake[]> }>();
function noaLiveFeed(interval: number, retries: number, timeoutMs: number): Promise<Earthquake[]> {
  const cached = noaLiveCache.get(interval);
  if (cached && Date.now() - cached.at < 20_000) return cached.promise;
  const promise = getWithRetry(`https://bbnet2.gein.noa.gr/data/${interval}`, retries, timeoutMs)
    .then(res => parseNOAGeoJSON(res.data));
  noaLiveCache.set(interval, { at: Date.now(), promise });
  promise.catch(() => noaLiveCache.delete(interval));
  return promise;
}

export async function fetchNOARange(
  startISO: string,
  endISO: string,
  limit: number,
  minmag = 0,
  timeoutMs = 10000,
  retries = 1,
  quiet = false
): Promise<Earthquake[]> {
  // Son 7 günün içindeki aralık NOA'nın canlı akışından gelir (FDSN
  // kataloğu boş dönüyor); akış başarısız ya da boşsa FDSN denenir.
  const startMs = Date.parse(startISO);
  const endMs = Date.parse(endISO);
  const ageDays = (Date.now() - startMs) / 86_400_000;
  if (Number.isFinite(startMs) && ageDays <= 7) {
    const interval = ageDays <= 1 ? 1 : ageDays <= 2 ? 2 : 7;
    try {
      const live = (await noaLiveFeed(interval, retries, timeoutMs)).filter(quake => {
        const time = Date.parse(quake.date);
        return time >= startMs && (!Number.isFinite(endMs) || time <= endMs) && quake.magnitude >= minmag;
      });
      if (live.length) return live.slice(0, limit);
    } catch (error: any) {
      if (!quiet) console.error('NOA canlı akış çekimi başarısız; FDSN deneniyor:', error?.message || error);
    }
  }
  const url = `https://eida.gein.noa.gr/fdsnws/event/1/query?format=text&orderby=time&starttime=${encodeURIComponent(startISO)}&endtime=${encodeURIComponent(endISO)}&minmagnitude=${minmag}&limit=${limit}&nodata=404`;
  try {
    const res = await getWithRetry(url, retries, timeoutMs);
    return parseNOAEventText(res.data).slice(0, limit);
  } catch (error: any) {
    // FDSN standardında 404, hata değil "eşleşen kayıt yok" anlamındadır.
    if (error?.response?.status === 404) return [];
    if (!quiet) console.error('NOA range çekimi başarısız:', error);
    return [];
  }
}

export async function fetchUSGSWindow(endISO: string, limit: number, minmag = 0): Promise<Earthquake[]> {
  const url = `https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&orderby=time&minmagnitude=${minmag}&limit=${limit}&endtime=${encodeURIComponent(endISO)}`;
  try {
    const res = await getWithRetry(url);
    return mapUSGSFeatures(res.data);
  } catch (error) {
    console.error('USGS window çekimi başarısız:', error);
    return [];
  }
}

export async function fetchUSGSRange(startISO: string, limit: number, minmag: number): Promise<Earthquake[]> {
  const url = `https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&orderby=time&minmagnitude=${minmag}&limit=${limit}&starttime=${encodeURIComponent(startISO)}`;
  try {
    const res = await getWithRetry(url);
    return mapUSGSFeatures(res.data);
  } catch (error) {
    console.error('USGS range çekimi başarısız:', error);
    return [];
  }
}

/// Büyük bir ana şokun artçı dizisini genel dünya kataloğunun 20.000 kayıt
/// sınırından bağımsız getirir. USGS sorgusu daha kaynağında merkez çevresine
/// daraltıldığı için eski ana şokların ilk günleri sonuçtan düşmez.
export async function fetchUSGSSpatialRange(
  startISO: string,
  endISO: string,
  latitude: number,
  longitude: number,
  radiusKm: number,
  minmag: number
): Promise<Earthquake[]> {
  const params = new URLSearchParams({
    format: 'geojson',
    orderby: 'time',
    starttime: startISO,
    endtime: endISO,
    latitude: String(latitude),
    longitude: String(longitude),
    maxradiuskm: String(radiusKm),
    minmagnitude: String(minmag),
    limit: '20000'
  });
  try {
    const res = await getWithRetry(`https://earthquake.usgs.gov/fdsnws/event/1/query?${params.toString()}`);
    return mapUSGSFeatures(res.data);
  } catch (error: any) {
    if (error?.response?.status === 404) return [];
    console.error('USGS mekânsal artçı sorgusu başarısız:', error?.message || error);
    return [];
  }
}

export async function fetchEMSCSpatialRange(
  startISO: string,
  endISO: string,
  latitude: number,
  longitude: number,
  radiusKm: number,
  minmag: number
): Promise<Earthquake[]> {
  const maxradiusDeg = (radiusKm / 111.19).toFixed(3);
  const params = new URLSearchParams({
    format: 'json',
    orderby: 'time',
    starttime: startISO,
    endtime: endISO,
    lat: String(latitude),
    lon: String(longitude),
    maxradius: String(maxradiusDeg),
    minmag: String(minmag),
    limit: '20000'
  });
  try {
    const res = await getWithRetry(`https://www.seismicportal.eu/fdsnws/event/1/query?${params.toString()}`);
    return mapEMSCFeatures(res.data);
  } catch (error: any) {
    if (error?.response?.status === 404) return [];
    console.error('EMSC mekânsal artçı sorgusu başarısız:', error?.message || error);
    return [];
  }
}

// USGS, otomatik uygulamalar için sorgu API'si yerine CDN destekli gerçek
// zamanlı GeoJSON özet akışını öneriyor. Akış dakikada bir yenilenir ve sabit
// URL olduğu için katalog sorgusundan daha düşük gecikmeli/kararlı çalışır.
export async function fetchUSGSRealtimeDay(): Promise<Earthquake[]> {
  const url = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson';
  try {
    const res = await getWithRetry(url);
    return mapUSGSFeatures(res.data);
  } catch (error) {
    console.error('USGS gerçek zamanlı akış çekimi başarısız:', error);
    return [];
  }
}

/// Son saatin akışı (~8 KB; günlük akış ~185 KB). Push'un hızlı taraması
/// yalnızca son dakikalara bakar.
export async function fetchUSGSRealtimeHour(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  const url = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson';
  try {
    const res = await getWithRetry(url, options.retries ?? 1, options.timeoutMs ?? 10000);
    return mapUSGSFeatures(res.data);
  } catch (error) {
    if (!options.quiet) console.error('USGS saatlik akış çekimi başarısız:', error);
    return [];
  }
}

function mapEMSCFeatures(data: any): Earthquake[] {
  if (!data || !data.features) return [];
  const quakes: Earthquake[] = [];
  for (const f of data.features) {
    const props = f.properties;
    const geom = f.geometry;
    if (!props || !geom || !Array.isArray(geom.coordinates)) continue;

    const magnitude = Number(props.mag);
    const lat = Number(geom.coordinates[1]);
    const lon = Number(geom.coordinates[0]);
    if (!Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;

    const depth = Number.isFinite(Number(props.depth)) ? Number(props.depth) : 0;
    const time = props.time ? new Date(props.time) : null;
    if (!time || isNaN(time.getTime())) continue;

    quakes.push({
      id: `emsc-${f.id || props.source_id}`,
      provider: 'EMSC',
      title: props.flynn_region || 'Unknown Region',
      magnitude,
      depth,
      lat,
      lon,
      date: time.toISOString(),
      closestCity: null,
      epiCenter: null,
      magType: props.magtype || null,
      updatedAt: validISODate(props.lastupdate),
      sourceURL: props.unid ? `https://www.emsc-csem.org/Earthquake_information/earthquake.php?id=${encodeURIComponent(String(props.unid))}` : null,
      network: props.auth || null,
      code: props.source_id || f.id || null,
      eventType: props.evtype || null,
      author: props.auth || null,
      catalog: props.source_catalog || 'EMSC',
      revised: false
    });
  }
  return quakes;
}

function mapUSGSFeatures(data: any): Earthquake[] {
  if (!data || !data.features) return [];
  const quakes: Earthquake[] = [];
  for (const f of data.features) {
    const props = f.properties;
    const geom = f.geometry;
    if (!props || !geom || !Array.isArray(geom.coordinates)) continue;

    const magnitude = Number(props.mag);
    const lat = Number(geom.coordinates[1]);
    const lon = Number(geom.coordinates[0]);
    if (!Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;

    const depth = Number.isFinite(Number(geom.coordinates[2])) ? Number(geom.coordinates[2]) : 0;
    const time = props.time ? new Date(props.time) : null;
    if (!time || isNaN(time.getTime())) continue;

    quakes.push({
      id: `usgs-${f.id}`,
      provider: 'USGS',
      title: props.place || 'Unknown Region',
      magnitude,
      depth,
      lat,
      lon,
      date: time.toISOString(),
      closestCity: null,
      epiCenter: null,
      magType: props.magType || null,
      status: props.status || null,
      tsunami: props.tsunami === 1,
      felt: optionalFiniteNumber(props.felt),
      updatedAt: Number.isFinite(Number(props.updated)) ? new Date(Number(props.updated)).toISOString() : null,
      sourceURL: props.url || null,
      detailURL: props.detail || null,
      network: props.net || null,
      code: props.code || f.id || null,
      eventType: props.type || null,
      significance: optionalFiniteNumber(props.sig),
      stationCount: optionalFiniteNumber(props.nst),
      minimumDistance: optionalFiniteNumber(props.dmin),
      rms: optionalFiniteNumber(props.rms),
      gap: optionalFiniteNumber(props.gap),
      communityIntensity: optionalFiniteNumber(props.cdi),
      maximumIntensity: optionalFiniteNumber(props.mmi),
      alertLevel: props.alert || null,
      catalog: 'USGS ComCat'
    });
  }
  return quakes;
}

// MARK: - Bölgesel resmî kaynaklar (Kandilli, BMKG, GeoNet, JMA, CENC)
//
// Bu kaynakların tarih aralığı sorgusu yok: her biri "son N deprem" listesi
// yayımlıyor. Hızlı tarama (dakikada 4 kez) ve tam toplama (dakikada 1) aynı
// listeyi isteyeceği için yanıt süreç içinde kısa süre paylaşılır
// (`sharedFetch`): kaynağa dakikada en fazla ~4 istek gider, çift istek olmaz.
// Hiçbiri Firestore'a dokunmaz.

const sharedFetches = new Map<string, { at: number; value: Promise<Earthquake[]> }>();

/// `ttlMs` içinde aynı kaynağa yeniden istek atmaz; eşzamanlı çağrılar aynı
/// isteği bekler. Hata boş listeye çevrilir ve paylaşılmaz.
function sharedFetch(name: string, ttlMs: number, load: () => Promise<Earthquake[]>): Promise<Earthquake[]> {
  const now = Date.now();
  const cached = sharedFetches.get(name);
  if (cached && now - cached.at < ttlMs) return cached.value;
  const value = load().catch(() => [] as Earthquake[]);
  sharedFetches.set(name, { at: now, value });
  void value.then(list => { if (!list.length) sharedFetches.delete(name); });
  return value;
}

/// Yalnızca testler için.
export function resetSharedFetchesForTesting(): void {
  sharedFetches.clear();
}

/// Kandilli Türkiye bildirimleri için kritik: hızlı taramanın aralığı (15 sn)
/// altında paylaşılır, her tarama taze veri görür. Diğer bölgesel listeler
/// 25 sn paylaşılır: kaynak başına dakikada ~2 istek.
const KANDILLI_SHARE_MS = 12_000;
const REGIONAL_SHARE_MS = 25_000;

/// Koordinattan İngilizce yer adı (JMA/CENC/BMKG başlıkları Japonca, Çince ve
/// Endonezce). Aynı olay dakikada birkaç kez gelir; ad bir kez hesaplanır.
const nearestTitleCache = new Map<string, string>();
function englishPlaceTitle(key: string, lat: number, lon: number, fallback: string): string {
  const cached = nearestTitleCache.get(key);
  if (cached) return cached;
  const place = nearestPlace(lat, lon);
  const title = place ? `${describeNearest(place)}, ${place.region}` : fallback;
  if (nearestTitleCache.size > 5000) nearestTitleCache.clear();
  nearestTitleCache.set(key, title);
  return title;
}

/// Sabit ofsetli yerel saati ("2026.09.24 10:40:55", UTC+3) ISO'ya çevirir.
function zonedISO(year: number, month: number, day: number, hour: number, minute: number, second: number, offsetHours: number): string | null {
  const ms = Date.UTC(year, month - 1, day, hour, minute, second) - offsetHours * 3600_000;
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

// Kandilli (KOERI): http://www.koeri.boun.edu.tr/scripts/lst0.asp — son 500
// deprem, sabit genişlikli metin, windows-1254, Türkiye saati (UTC+3).
// "İlksel" otomatik çözüm, "REVIZE01 (orijinal zaman)" revizyon. Kimlik orijinal
// zamandan üretilir: revizyon aynı kimliği korur (bildirim tekrarlanmaz).
const KANDILLI_LINE = /^(\d{4})\.(\d{2})\.(\d{2}) (\d{2}):(\d{2}):(\d{2})\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(-?\d+(?:\.\d+)?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+?)\s{2,}(\S.*)$/;

function kandilliMagnitude(value: string): number | null {
  const number = Number(value);
  return value !== '-.-' && Number.isFinite(number) && number > 0 ? number : null;
}

/// "PINARBASI-(SANLIURFA)" → "Pinarbasi (Sanliurfa)". Kandilli ASCII yazar;
/// Türkçe harfler tahmin edilmez.
function kandilliTitle(raw: string): { title: string; district: string | null; city: string | null } {
  const cleaned = raw.replace(/-\(/g, ' (').replace(/\s+/g, ' ').trim();
  const titled = cleaned.toLowerCase().replace(/(^|[\s(\-])([a-z])/g, (_, prefix, letter) => prefix + letter.toUpperCase());
  const city = /\(([^)]+)\)/.exec(titled)?.[1] ?? null;
  const district = titled.replace(/\s*\([^)]*\)\s*/g, '').trim() || null;
  return { title: titled, district, city };
}

export function parseKandilliList(text: string): Earthquake[] {
  const quakes: Earthquake[] = [];
  for (const rawLine of text.split(/\r?\n/)) {
    const match = KANDILLI_LINE.exec(rawLine.trim());
    if (!match) continue;
    const [, y, mo, d, h, mi, se, latText, lonText, depthText, mdText, mlText, mwText, place, status] = match;
    const lat = Number(latText);
    const lon = Number(lonText);
    const md = kandilliMagnitude(mdText);
    const ml = kandilliMagnitude(mlText);
    const mw = kandilliMagnitude(mwText);
    const magnitude = mw ?? ml ?? md;
    const date = zonedISO(+y, +mo, +d, +h, +mi, +se, 3);
    if (magnitude === null || !date || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    // Revizyonda parantez içi orijinal zaman kimliği sabit tutar.
    const original = /\((\d{4})\.(\d{2})\.(\d{2}) (\d{2}):(\d{2}):(\d{2})\)/.exec(status);
    const idStamp = original ? original.slice(1).join('') : `${y}${mo}${d}${h}${mi}${se}`;
    const { title, district, city } = kandilliTitle(place);
    const revised = /^REVIZE/i.test(status.trim());
    quakes.push({
      id: `kandilli-${idStamp}`,
      provider: 'KANDILLI',
      title,
      magnitude,
      depth: Number.isFinite(Number(depthText)) ? Number(depthText) : 0,
      lat,
      lon,
      date,
      closestCity: city,
      epiCenter: null,
      district,
      country: isInTurkiye(lat, lon) ? 'Türkiye' : null,
      magType: mw !== null ? 'Mw' : ml !== null ? 'ML' : 'MD',
      status: revised ? 'reviewed' : 'automatic',
      revised,
      sourceURL: 'http://www.koeri.boun.edu.tr/scripts/lst0.asp',
      network: 'KOERI',
      eventType: 'earthquake',
      catalog: 'KOERI'
    });
  }
  return quakes;
}

export function fetchKandilli(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  return sharedFetch('kandilli', KANDILLI_SHARE_MS, async () => {
    try {
      const response = await client.get('http://www.koeri.boun.edu.tr/scripts/lst0.asp', {
        timeout: options.timeoutMs ?? 10000,
        responseType: 'arraybuffer'
      });
      const text = new TextDecoder('windows-1254').decode(Buffer.from(response.data));
      return parseKandilliList(text);
    } catch (error: any) {
      if (!options.quiet) console.error('Kandilli çekimi başarısız:', error?.message || error);
      return [];
    }
  });
}

// BMKG (Endonezya): son deprem, son 15 M5+ ve son 15 hissedilen deprem.
// Tsunami potansiyeli ("Berpotensi tsunami") kayıtta `tsunami` olarak taşınır.
export function parseBMKGList(data: any): Earthquake[] {
  const raw = data?.Infogempa?.gempa;
  const items: any[] = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const quakes: Earthquake[] = [];
  for (const item of items) {
    const [latText, lonText] = String(item?.Coordinates || '').split(',');
    const lat = Number(latText);
    const lon = Number(lonText);
    const magnitude = Number(item?.Magnitude);
    const time = Date.parse(String(item?.DateTime || ''));
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(magnitude) || !Number.isFinite(time)) continue;
    const potensi = String(item?.Potensi || '');
    const region = String(item?.Wilayah || '').trim();
    const id = `bmkg-${Math.floor(time / 1000)}`;
    quakes.push({
      id,
      provider: 'BMKG',
      title: englishPlaceTitle(id, lat, lon, region || 'Indonesia'),
      magnitude,
      depth: parseFloat(String(item?.Kedalaman || '0')) || 0,
      lat,
      lon,
      date: new Date(time).toISOString(),
      epiCenter: region || null,
      closestCity: null,
      country: 'Indonesia',
      magType: 'M',
      tsunami: /berpotensi tsunami/i.test(potensi) && !/tidak berpotensi/i.test(potensi),
      sourceURL: 'https://www.bmkg.go.id/gempabumi/gempabumi-terkini',
      network: 'BMKG',
      eventType: 'earthquake',
      catalog: 'BMKG'
    });
  }
  return quakes;
}

/// BMKG'nin canlı akışı (InaTEWS `live30event.xml`): son ~200 onaylı deprem,
/// tüm büyüklükler. TEWS JSON dosyaları yalnızca M5+ ve hissedilen depremleri
/// verdiğinden listede günde birkaç BMKG kaydı kalıyordu. Akış bölge dışı
/// büyük depremleri de içerir (ör. Türkiye M5.3); yalnızca Endonezya ve
/// çevresi alınır — bölge dışını kendi ajansları verir. `waktu` UTC'dir.
export const BMKG_REGION = { minLat: -15, maxLat: 8, minLon: 90, maxLon: 145 };

export function parseBMKGLiveXML(xml: string): Earthquake[] {
  const quakes: Earthquake[] = [];
  const field = (block: string, tag: string) => (new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(block)?.[1] ?? '').trim();
  for (const [, block] of String(xml || '').matchAll(/<gempa>([\s\S]*?)<\/gempa>/g)) {
    const lat = Number(field(block, 'lintang'));
    const lon = Number(field(block, 'bujur'));
    const magnitude = Number(field(block, 'mag'));
    const match = /^(\d{4})\/(\d{2})\/(\d{2})\s+(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)$/.exec(field(block, 'waktu'));
    if (!match || !Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(magnitude) || magnitude <= 0) continue;
    if (lat < BMKG_REGION.minLat || lat > BMKG_REGION.maxLat || lon < BMKG_REGION.minLon || lon > BMKG_REGION.maxLon) continue;
    const [, y, mo, d, h, mi, se] = match;
    const time = Date.UTC(+y, +mo - 1, +d, +h, +mi, 0) + Math.round(Number(se) * 1000);
    // Kimlik TEWS kayıtlarıyla aynı şema (saniye): aynı deprem tek kayıt olur.
    const id = `bmkg-${Math.round(time / 1000)}`;
    const area = field(block, 'area');
    quakes.push({
      id,
      provider: 'BMKG',
      title: englishPlaceTitle(id, lat, lon, area || 'Indonesia'),
      magnitude,
      depth: Number(field(block, 'dalam')) || 0,
      lat,
      lon,
      date: new Date(time).toISOString(),
      epiCenter: area || null,
      closestCity: null,
      country: 'Indonesia',
      magType: 'M',
      status: field(block, 'status') === 'confirmed' ? 'reviewed' : 'automatic',
      sourceURL: 'https://www.bmkg.go.id/gempabumi/gempabumi-terkini',
      network: 'BMKG',
      eventType: 'earthquake',
      catalog: 'BMKG'
    });
  }
  return quakes;
}

export function fetchBMKG(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  return sharedFetch('bmkg', REGIONAL_SHARE_MS, async () => {
    const base = 'https://data.bmkg.go.id/DataMKG/TEWS/';
    const files = ['autogempa.json', 'gempaterkini.json', 'gempadirasakan.json'];
    const results = await Promise.all(files.map(file =>
      client.get(base + file, { timeout: options.timeoutMs ?? 10000 })
        .then(response => parseBMKGList(response.data))
        .catch(error => {
          if (!options.quiet) console.error(`BMKG ${file} çekimi başarısız:`, error?.message || error);
          return [] as Earthquake[];
        })
    ));
    const live = await client.get('https://bmkg-content-inatews.storage.googleapis.com/live30event.xml', {
      timeout: options.timeoutMs ?? 10000,
      responseType: 'text'
    })
      .then(response => parseBMKGLiveXML(String(response.data)))
      .catch(error => {
        if (!options.quiet) console.error('BMKG live30event çekimi başarısız:', error?.message || error);
        return [] as Earthquake[];
      });
    const byId = new Map<string, Earthquake>();
    // Son deprem ilk sırada: ayrıntısı (tsunami potansiyeli) korunur.
    for (const quake of results.flat()) {
      const existing = byId.get(quake.id);
      byId.set(quake.id, existing ? { ...quake, ...existing, tsunami: Boolean(existing.tsunami || quake.tsunami) } : quake);
    }
    // Canlı akış: TEWS'te aynı deprem (±3 sn, 50 km) varsa TEWS kaydı kalır.
    const tews = [...byId.values()];
    for (const quake of live) {
      if (byId.has(quake.id)) continue;
      const time = Date.parse(quake.date);
      const duplicate = tews.some(other => Math.abs(Date.parse(other.date) - time) <= 3000
        && getDistanceKm(other.lat, other.lon, quake.lat, quake.lon) <= 50);
      if (!duplicate) byId.set(quake.id, quake);
    }
    return [...byId.values()];
  });
}

// GeoNet (Yeni Zelanda): son ~100 deprem, GeoJSON.
export function parseGeoNetList(data: any): Earthquake[] {
  const features: any[] = Array.isArray(data?.features) ? data.features : [];
  const quakes: Earthquake[] = [];
  for (const feature of features) {
    const props = feature?.properties;
    const coords = feature?.geometry?.coordinates;
    if (!props || !Array.isArray(coords) || props.quality === 'deleted') continue;
    const lat = Number(coords[1]);
    const lon = Number(coords[0]);
    const magnitude = Number(props.magnitude);
    const time = Date.parse(String(props.time || ''));
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(magnitude) || !Number.isFinite(time)) continue;
    const locality = String(props.locality || '').trim();
    quakes.push({
      id: `geonet-${props.publicID}`,
      provider: 'GEONET',
      title: locality ? `${locality}, New Zealand` : 'New Zealand',
      magnitude: Math.round(magnitude * 10) / 10,
      depth: Number.isFinite(Number(props.depth)) ? Math.round(Number(props.depth) * 10) / 10 : 0,
      lat,
      lon,
      date: new Date(time).toISOString(),
      closestCity: null,
      epiCenter: locality || null,
      country: 'New Zealand',
      status: props.quality === 'best' ? 'reviewed' : 'automatic',
      maximumIntensity: optionalFiniteNumber(props.mmi),
      sourceURL: `https://www.geonet.org.nz/earthquake/${encodeURIComponent(String(props.publicID))}`,
      network: 'NZ',
      code: String(props.publicID),
      eventType: 'earthquake',
      catalog: 'GeoNet'
    });
  }
  return quakes;
}

export function fetchGeoNet(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  return sharedFetch('geonet', REGIONAL_SHARE_MS, async () => {
    try {
      const response = await client.get('https://api.geonet.org.nz/quake?MMI=-1', {
        timeout: options.timeoutMs ?? 10000,
        headers: { Accept: 'application/vnd.geo+json;version=2' }
      });
      return parseGeoNetList(response.data);
    } catch (error: any) {
      if (!options.quiet) console.error('GeoNet çekimi başarısız:', error?.message || error);
      return [];
    }
  });
}

// JMA (Japonya) ve CENC (Çin): Wolfx'in yayımladığı resmî listeler
// (api.wolfx.jp). JMA saati UTC+9, CENC saati UTC+8.
function parseSlashDateTime(value: string, offsetHours: number): string | null {
  const match = /(\d{4})[\/-](\d{2})[\/-](\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/.exec(value);
  if (!match) return null;
  const [, y, mo, d, h, mi, se] = match;
  return zonedISO(+y, +mo, +d, +h, +mi, +(se ?? 0), offsetHours);
}

function wolfxItems(data: any): any[] {
  if (!data || typeof data !== 'object') return [];
  return Object.keys(data).filter(key => /^No\d+$/.test(key)).map(key => data[key]);
}

export function parseJMAList(data: any): Earthquake[] {
  const quakes: Earthquake[] = [];
  for (const item of wolfxItems(data)) {
    const lat = Number(item?.latitude);
    const lon = Number(item?.longitude);
    const magnitude = Number(item?.magnitude);
    const date = parseSlashDateTime(String(item?.time_full || item?.time || ''), 9);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(magnitude) || magnitude <= 0 || !date) continue;
    const location = String(item?.location || '').trim();
    const info = String(item?.info || '');
    const id = `jma-${item?.EventID || date}`;
    quakes.push({
      id,
      provider: 'JMA',
      title: englishPlaceTitle(id, lat, lon, 'Japan'),
      magnitude,
      depth: parseFloat(String(item?.depth || '0')) || 0,
      lat,
      lon,
      date,
      closestCity: null,
      epiCenter: location || null,
      country: 'Japan',
      magType: 'Mj',
      // "津波の心配はありません" = tsunami yok; uyarı/ihtiyat metni varsa işaretlenir.
      tsunami: /津波警報|津波注意報|大津波/.test(info),
      maximumIntensity: null,
      sourceURL: 'https://www.jma.go.jp/bosai/map.html#contents=earthquake_map',
      network: 'JMA',
      code: item?.EventID ? String(item.EventID) : null,
      eventType: 'earthquake',
      catalog: 'JMA'
    });
  }
  return quakes;
}

export function parseCENCList(data: any): Earthquake[] {
  const quakes: Earthquake[] = [];
  for (const item of wolfxItems(data)) {
    const lat = Number(item?.latitude);
    const lon = Number(item?.longitude);
    const magnitude = Number(item?.magnitude);
    const date = parseSlashDateTime(String(item?.time || ''), 8);
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(magnitude) || magnitude <= 0 || !date) continue;
    // CENC otomatik → resmî geçişte olay kimliğini değiştirir; kimlik
    // orijin zamanından üretilir ki aynı deprem iki kayıt olmasın.
    const id = `cenc-${date.replace(/\D/g, '').slice(0, 14)}`;
    const location = String(item?.placeName || item?.location || '').trim();
    quakes.push({
      id,
      provider: 'CENC',
      title: englishPlaceTitle(id, lat, lon, 'China'),
      magnitude,
      depth: parseFloat(String(item?.depth || '0')) || 0,
      lat,
      lon,
      date,
      closestCity: null,
      epiCenter: location || null,
      magType: 'M',
      status: item?.type === 'reviewed' ? 'reviewed' : 'automatic',
      sourceURL: 'https://news.ceic.ac.cn/',
      network: 'CENC',
      eventType: 'earthquake',
      catalog: 'CENC'
    });
  }
  return quakes;
}

function fetchWolfxList(name: string, file: string, parse: (data: any) => Earthquake[], options: ProviderRequestOptions): Promise<Earthquake[]> {
  return sharedFetch(name, REGIONAL_SHARE_MS, async () => {
    try {
      const response = await client.get(`https://api.wolfx.jp/${file}`, { timeout: options.timeoutMs ?? 10000 });
      return parse(response.data);
    } catch (error: any) {
      if (!options.quiet) console.error(`${name.toUpperCase()} çekimi başarısız:`, error?.message || error);
      return [];
    }
  });
}

export function fetchJMA(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  return fetchWolfxList('jma', 'jma_eqlist.json', parseJMAList, options);
}

export function fetchCENC(options: ProviderRequestOptions = {}): Promise<Earthquake[]> {
  return fetchWolfxList('cenc', 'cenc_eqlist.json', parseCENCList, options);
}
