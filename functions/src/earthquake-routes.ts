import { DocumentData, DocumentReference, FieldValue, Firestore } from 'firebase-admin/firestore';
import { InfoCard, parseInfoCards, publicInfoCards } from './info-cards';
import express from 'express';
import * as path from 'path';
import * as fs from 'fs';
import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
import {
  Earthquake,
  getDistanceKm,
  uniqueQuakesByProviderId,
  toMapProjection,
  filterMapQuakes,
  isQuakeWithinTimeWindow,
  providerArchiveFallback,
  topTurkeyProvincesFromAFAD,
  RegionCount,
  isVersionOlder,
  selectAftershockSequence,
  dedupeAgencyCopies
} from './worker-utils';
import {
  fetchAFADRange,
  fetchAFADRecentRange,
  fetchUSGSRealtimeHour,
  fetchEMSCRange,
  fetchEMSCWindow,
  fetchNOARange,
  fetchUSGSWindow,
  fetchUSGSRange,
  fetchUSGSSpatialRange,
  fetchEMSCSpatialRange,
  fetchUSGSRealtimeDay,
  fetchKandilli,
  fetchBMKG,
  fetchGeoNet,
  fetchJMA,
  fetchCENC
} from './earthquake-providers';
import { fetchUSGSWithETag } from './realtime-ingestion';
import { applyGdacsAlertLevels, fetchGdacsEvents } from './gdacs';
import { createLiveChannels, endLiveActivity, publishLiveActivityUpdate } from './live-activity';
import { MajorEvent, nextMajorEvent, parseMajorEvent, prewarmMajorEventAnalysis } from './major-event';
import {
  absorbRemoteConfigMirror,
  filterPublicQuakes,
  isMajorEventSuppressed,
  refreshRemoteConfigFromSource,
  remoteClientConfig,
  remoteClientRevision,
  remoteConfigHash,
  remoteConfigMirrorFields,
  remoteServerConfig
} from './remote-config';

// MARK: - Deprem verisi ve istatistik rotaları
//
// index.ts'ten taşındı (Task 9): `/`, `/history`, `/map`, `/map-range`,
// `/aftershocks`, `/faults`, `/stats` uçları ve bunların paylaştığı toplama/
// önbellek durumu. `db`'ye bağlı referanslar (liveSnapshotRef,
// afadMapArchiveRef, noaMapArchiveRef ve bunlara bağlı
// arşiv yöneticileri) `registerEarthquakeRoutes(app, db)` içinde bir kez
// atanır; index.ts bu fonksiyonu diğer rotalardan önce, modül yüklenirken
// çağırır. `scheduledPushCheck` (push-routes.ts) ve `/health` (index.ts'te
// kalır) bu modülün dışa aktardığı fonksiyon ve erişimcileri kullanır —
// durum burada tek sahipte kalır, kopyalanmaz. `refreshMapArchiveIfDue`
// (harita arşivi tazeleme, Task 11'de index.ts'ten buraya taşındı)
// admin-routes.ts'teki `runMaintenanceSweep`'ten çağrılır.

// 30 sn bellek önbelleği: canlı uç için dış kaynak trafiğini ~3x azaltır;
// zamanlanmış görev zaten dakikada bir çalıştığı için tazelik etkilenmez.
const QUAKE_SNAPSHOT_TTL_MS = 30000;

let _cachedQuakes: Earthquake[] | null = null;
let _cachedQuakesAt = 0;

/// JSON gövdesini küçültür: null/undefined alanlar ve false bayraklar
/// (tsunami/revised) atılır — iOS istemcisi bu alanları decodeIfPresent ile
/// okuduğundan eksik anahtar sorun değildir. Sıkıştırma öncesi ~%20 tasarruf.
function stripNullish(q: Earthquake): Earthquake {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(q)) {
    if (value === null || value === undefined || value === false) continue;
    if ((key === 'maximumIntensity' || key === 'communityIntensity')
        && typeof value === 'number' && value <= 0) continue;
    out[key] = value;
  }
  return out as unknown as Earthquake;
}
let _publishedQuakes: Earthquake[] | null = null;
let _publishedQuakesAt = 0;
let _lastPublishedQuakeHash = '';
let _lastPublishedQuakeAt = 0;
let collectQuakesInFlight: Promise<Earthquake[]> | undefined;
let publishedSnapshotInFlight: Promise<Earthquake[] | null> | undefined;
/// `/` yanıtının hazır gövdesi ve ETag'i. Uç, her istekte listeyi bir kez
/// ETag için bir kez de yanıt için olmak üzere İKİ KEZ serileştiriyordu
/// (731 kayıt ≈ 300 KB) ve üstüne SHA-256 hesaplıyordu. Veri dakikada bir
/// değiştiği için bu iş istek başına değil, veri başına yapılır.
// MARK: - Kaynak görünümleri
//
// Liste 2.1.4 ile Kandilli, BMKG, GeoNet, JMA ve CENC'i de içeriyor. 2.1.3 ve
// öncesi bu kaynakları kaynak filtresinde tanımadığı için göstermez; onlara
// eski dört kaynaklı liste döner (gövde büyümez, CDN aktarım maliyeti
// artmaz). Yeni istemci `?sources=all` ister; CDN iki adresi ayrı önbellekler.
export const LEGACY_LIST_PROVIDERS = new Set(['AFAD', 'EMSC', 'USGS', 'NOA']);

type ListVariant = 'legacy' | 'all';

export function listVariantOf(req: express.Request): ListVariant {
  return String(req.query.sources || '').toLowerCase() === 'all' ? 'all' : 'legacy';
}

const legacyViews = new WeakMap<Earthquake[], Earthquake[]>();

/// Eski istemcinin gördüğü alt küme; aynı liste için bir kez hesaplanır.
export function quakesForVariant(allQuakes: Earthquake[], variant: ListVariant): Earthquake[] {
  // Uzak yapılandırmada gizlenen kaynak ve depremler (remote-config.ts).
  const quakes = filterPublicQuakes(allQuakes);
  if (variant === 'all') return quakes;
  let view = legacyViews.get(quakes);
  if (!view) {
    view = quakes.every(quake => LEGACY_LIST_PROVIDERS.has(String(quake.provider).toUpperCase()))
      ? quakes
      : quakes.filter(quake => LEGACY_LIST_PROVIDERS.has(String(quake.provider).toUpperCase()));
    legacyViews.set(quakes, view);
  }
  return view;
}

const _listResponses = new Map<ListVariant, { source: Earthquake[]; config: string; body: string; etag: string }>();

/// Verilen liste için hazır gövde/ETag çiftini döndürür; kaynak dizi
/// değişmediyse önbelleği kullanır (kimlik karşılaştırması yeterli — diziler
/// yerinde değiştirilmiyor, her yenilemede yenisi üretiliyor).
function listResponseFor(quakes: Earthquake[], variant: ListVariant = 'legacy'): { body: string; etag: string } {
  const cached = _listResponses.get(variant);
  const config = remoteConfigHash();
  if (cached?.source === quakes && cached.config === config) return cached;
  const body = JSON.stringify(quakesForVariant(quakes, variant));
  const prefix = variant === 'all' ? 'a' : '';
  const entry = { source: quakes, config, body, etag: `W/"${prefix}${createHash('sha256').update(body).digest('hex').slice(0, 24)}"` };
  _listResponses.set(variant, entry);
  return entry;
}

/// `/recent` penceresi: son 65 dakika. AFAD büyüklük düzeltmelerinin çoğu
/// ilk saatte gelir; daha eskileri istemcinin 10 dakikalık tam yenilemesi alır.
export const RECENT_WINDOW_MS = 65 * 60 * 1000;
const _recentResponses = new Map<ListVariant, { source: Earthquake[]; minute: number; config: string; body: string; etag: string }>();

/// Son saatin yanıtı; aynı liste, görünüm ve dakika için bir kez üretilir.
export function recentResponseFor(quakes: Earthquake[], now: number, variant: ListVariant = 'legacy'): { body: string; etag: string } {
  const minute = Math.floor(now / 60_000);
  const cached = _recentResponses.get(variant);
  const config = remoteConfigHash();
  if (cached?.source === quakes && cached.minute === minute && cached.config === config) return cached;
  const cutoff = now - RECENT_WINDOW_MS;
  const recent = quakesForVariant(quakes, variant).filter(quake => Date.parse(String(quake.date)) >= cutoff);
  const body = JSON.stringify(recent);
  const prefix = variant === 'all' ? 'ra' : 'r';
  const entry = { source: quakes, minute, config, body, etag: `W/"${prefix}${createHash('sha256').update(body).digest('hex').slice(0, 24)}"` };
  _recentResponses.set(variant, entry);
  return entry;
}

const LIVE_SNAPSHOT_MAX_AGE_MS = 3 * 60 * 1000;
// API örnekleri anlık görüntüyü en fazla bu kadar bellekte tutar. 60 sn'de
// yeni deprem listeye bir dakika geç giriyordu; 15 sn'de örnek başına en
// fazla 4 okuma/dk (trafik varken) — CDN önbelleği (s-maxage 15) önünde.
const LIVE_SNAPSHOT_MEMORY_TTL_MS = 15 * 1000;
// `db`'ye bağlı referanslar ve bunlara bağlı arşiv yöneticileri; index.ts
// import sırasında admin.initializeApp() henüz çalışmadığından modül
// yüklenirken hesaplanamazlar — registerEarthquakeRoutes(app, db) içinde
// bir kez atanır (bkz. dosya sonu).
let liveSnapshotRef!: DocumentReference<DocumentData>;
let afadMapArchiveRef!: DocumentReference<DocumentData>;
let noaMapArchiveRef!: DocumentReference<DocumentData>;

// MARK: - Yayındaki uygulama sürümü
//
// App Store'da yayında olduğu KESİN bilinen taban sürüm. Sonraki sürümler App
// Store Connect webhook'uyla öğrenilir (app-update.ts) ve canlı anlık görüntü
// belgesinin `latest_app_version` alanına yazılır. HTTP örnekleri o belgeyi
// liste için zaten dakikada bir okuduğundan sürüm ek okuma olmadan gelir.
export const BASELINE_APP_VERSION = '2.1.0';
let publishedLatestAppVersion = '';

export function latestAppVersion(): string {
  return publishedLatestAppVersion && isVersionOlder(BASELINE_APP_VERSION, publishedLatestAppVersion)
    ? publishedLatestAppVersion
    : BASELINE_APP_VERSION;
}

/// Anlık görüntünün bellekteki kopyası eskiyse (60 sn) tazeler; liste ucunun
/// kullandığı aynı okuma olduğu için ek maliyeti yok.
export async function refreshedLatestAppVersion(): Promise<string> {
  await readPublishedLiveSnapshot();
  return latestAppVersion();
}

// MARK: - Bilgi kartları (info-cards.ts)
//
// Kartlar aynı canlı anlık görüntü belgesinde durur; liste okuması onları da
// getirir. Kendi yayınını yapan (anlık görüntüyü okumayan) örnekte kartlar
// bayatlamasın diye `/info-cards` 5 dakikadan eski kopyayı tek okumayla tazeler.
const INFO_CARDS_MAX_AGE_MS = 5 * 60 * 1000;
let publishedInfoCards: InfoCard[] = [];
let publishedInfoRevision = 0;
let infoCardsReadAt = 0;

// MARK: - Büyük olay (bkz. major-event.ts)

/// Analiz ön üretimi için API'nin herkese açık adresi (BackendConfig.swift ile aynı).
const PUBLIC_API_BASE_URL = 'https://sismik-app-ea600.web.app/api';
let currentMajorEvent: MajorEvent | null = null;
let majorEventLoaded = false;

export function activeMajorEvent(now: number = Date.now()): MajorEvent | null {
  return currentMajorEvent && currentMajorEvent.expires_at > now && !isMajorEventSuppressed(currentMajorEvent.id)
    ? currentMajorEvent
    : null;
}

function absorbMajorEvent(data: FirebaseFirestore.DocumentData | undefined): void {
  currentMajorEvent = parseMajorEvent(data?.major_event, Date.now());
  majorEventLoaded = true;
}

function absorbInfoCards(data: FirebaseFirestore.DocumentData | undefined): void {
  if (!data) return;
  infoCardsReadAt = Date.now();
  const revision = Number(data.info_cards_revision || 0);
  if (!Number.isFinite(revision) || revision === publishedInfoRevision) return;
  publishedInfoRevision = revision;
  publishedInfoCards = parseInfoCards(data.info_cards);
}

export function infoCardsRevision(): number {
  return publishedInfoRevision;
}

async function freshInfoCards(): Promise<{ revision: number; cards: InfoCard[] }> {
  if (Date.now() - infoCardsReadAt > INFO_CARDS_MAX_AGE_MS) {
    try {
      const data = (await liveSnapshotRef.get()).data();
      absorbInfoCards(data);
      absorbMajorEvent(data);
      absorbRemoteConfigMirror(data);
    } catch (error: any) {
      console.error('Bilgi kartları okunamadı:', error?.message || error);
    }
  }
  return { revision: publishedInfoRevision, cards: publishedInfoCards };
}

export async function publishLatestAppVersion(version: string): Promise<void> {
  await liveSnapshotRef.set({ latest_app_version: version }, { merge: true });
  publishedLatestAppVersion = version;
}

let unavailablePushSources = new Set<string>();
/// Son tam toplamada hangi sağlayıcının yanıt verdiği. Yalnızca bellekte
/// tutulur: push yedek kaynağı kararı (`isProviderUnavailableForPush`) aynı
/// süreçte verilir. Eskiden `_public/source_health_v1` belgesine de
/// yazılıyordu (5 dakikada bir), ama o belgeyi okuyan hiçbir kod yoktu.
let latestProviderHealth: Record<string, { available: boolean; count: number }> = {};

/// `scheduledPushCheck` (index.ts) bildirim yedek kaynağı seçerken hangi
/// sağlayıcının şu an kullanılamaz olduğunu bu üzerinden okur.
export function isProviderUnavailableForPush(provider: string): boolean {
  return unavailablePushSources.has(provider);
}

// Deprem verisinin tek saklama/sorgulama sınırı. Firestore arşiv belgeleri,
// bellek önbelleği ve dış kaynak sorguları bu değerin ötesine geçmez.
export const EARTHQUAKE_RETENTION_DAYS = 34;
export const EARTHQUAKE_RETENTION_MS = EARTHQUAKE_RETENTION_DAYS * 86400000;
const AFAD_MAP_ARCHIVE_DAYS = EARTHQUAKE_RETENTION_DAYS;
// Arşiv iki saatte bir yenilenir. Scheduler gecikmesi sırasında istemcinin
// pahalı tam AFAD yedeğine düşmemesi için bir saat güvenlik payı bırakılır.
const AFAD_MAP_ARCHIVE_MAX_AGE_MS = 3 * 60 * 60 * 1000;
const AFAD_MAP_ARCHIVE_MEMORY_TTL_MS = 10 * 60 * 1000;
const NOA_MAP_ARCHIVE_DAYS = EARTHQUAKE_RETENTION_DAYS;
const NOA_MAP_ARCHIVE_MAX_AGE_MS = 3 * 60 * 60 * 1000;
const NOA_MAP_ARCHIVE_MEMORY_TTL_MS = 10 * 60 * 1000;


// MARK: - Deprem Verisi Kayıt ve Birleştirme

/// Kaynaklar arası tekilleştirme: 90 sn ve 90 km içindeki kayıtlar aynı
/// deprem sayılır; büyüklüğü en yüksek kayıt korunur.
///
/// Performans: eski sürüm her adayı tutulan TÜM kayıtlarla karşılaştırıyordu
/// (O(n²) — /stats için 3000+ kayıtta milyonlarca döngü). Yeni sürüm kayıtları
/// 90 saniyelik zaman kovalarına yerleştirir ve yalnızca komşu kovalardakilerle
/// karşılaştırır — sonuç birebir aynı, maliyet ~O(n).
export function deduplicateQuakes(quakes: Earthquake[]): Earthquake[] {
  const WINDOW_MS = 90 * 1000;
  const sorted = [...quakes].sort((a, b) => b.magnitude - a.magnitude);
  const result: Earthquake[] = [];
  const buckets = new Map<number, { time: number; lat: number; lon: number }[]>();

  for (const q of sorted) {
    const qTime = new Date(q.date).getTime();

    // Geçersiz tarihli kayıt hiçbir şeyle eşleşemez; olduğu gibi korunur.
    if (!Number.isFinite(qTime)) {
      result.push(q);
      continue;
    }

    const bucketKey = Math.floor(qTime / WINDOW_MS);
    let isDuplicate = false;

    for (let k = bucketKey - 1; k <= bucketKey + 1 && !isDuplicate; k++) {
      const list = buckets.get(k);
      if (!list) continue;
      for (const existing of list) {
        if (Math.abs(qTime - existing.time) <= WINDOW_MS &&
            getDistanceKm(q.lat, q.lon, existing.lat, existing.lon) <= 90) {
          isDuplicate = true;
          break;
        }
      }
    }

    if (!isDuplicate) {
      result.push(q);
      const entry = { time: qTime, lat: q.lat, lon: q.lon };
      const list = buckets.get(bucketKey);
      if (list) list.push(entry);
      else buckets.set(bucketKey, [entry]);
    }
  }

  return result.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
}

/// Push'un hızlı taraması: dört kaynaktan yalnızca son dakikaların kayıtları.
///
/// Tam toplama (`collectQuakes`) her kaynaktan 24 saati çekip EN YAVAŞINI
/// bekliyor; bulutta bir tur 7–12 sn sürüyordu ve NOA takıldığında 12 sn'lik
/// zaman aşımı bütün bildirimleri bekletiyordu. Burada her kaynak kısa bir
/// pencereyle, 4 sn süreyle ve yeniden denemesiz sorgulanır; takılan kaynak
/// diğerlerini geciktirmez (aynı kaynak dakikada bir tam taramada zaten
/// normal ayarlarla deneniyor). Pencereler bildirim tazelik sınırlarını
/// kapsar: AFAD 60 dk aday kalır (70 dk çekilir), diğerleri 15 dk (25 dk).
/// `realtimeCovered`: EMSC (WebSocket) ve USGS (15 sn yoklama) anlık akışla
/// geldiği için :15/:30/:45 ek taramaları yalnızca AFAD ve NOA'yı ister;
/// dakikanın +0 taraması dördünü de yedek olarak tarar.
const REGIONAL_SCAN_WAIT_MS = 800;

function softDeadline(work: Promise<Earthquake[]>): Promise<Earthquake[]> {
  let timer: NodeJS.Timeout | undefined;
  const deadline = new Promise<Earthquake[]>(resolve => { timer = setTimeout(() => resolve([]), REGIONAL_SCAN_WAIT_MS); });
  return Promise.race([work, deadline]).finally(() => clearTimeout(timer));
}

export async function collectRecentQuakesForPush(now: number = Date.now(), realtimeCovered = false): Promise<{
  quakes: Earthquake[];
  timings: Record<string, { ms: number; count: number }>;
}> {
  const options = { timeoutMs: 4000, retries: 0, quiet: true };
  const nowISO = new Date(now).toISOString();
  const shortStart = new Date(now - 25 * 60_000).toISOString();
  const afadStart = new Date(now - 70 * 60_000).toISOString();
  const timed = async (name: string, work: Promise<Earthquake[]>) => {
    const started = Date.now();
    const quakes = await work.catch(() => [] as Earthquake[]);
    return { name, quakes, ms: Date.now() - started };
  };
  const results = await Promise.all([
    timed('afad', fetchAFADRange(afadStart, nowISO, 500, 0, options)),
    ...(realtimeCovered ? [] : [
      timed('emsc', fetchEMSCRange(shortStart, 500, 0, options)),
      timed('usgs', fetchUSGSWithETag(options.timeoutMs).then(r => r.quakes).catch(() => fetchUSGSRealtimeHour(options)))
    ]),
    timed('noa', fetchNOARange(shortStart, nowISO, 500, 0, options.timeoutMs, 0, true)),
    // Bölgesel resmî kaynaklar: tek küçük liste, tarama ile tam toplama aynı
    // yanıtı paylaşır (bkz. `sharedFetch`). Kandilli Türkiye'de AFAD'ın
    // yanıt vermediği anlarda (24 Eyl 2026: 25 dk) ikinci yerli kaynak.
    timed('kandilli', fetchKandilli(options)),
    // Uzak bölgelerin kaynakları Türkiye bildirimini bekletmesin: en fazla
    // 0,8 sn beklenir; geç kalan yanıt paylaşılan önbellekte kalır ve bir
    // sonraki tarama (15 sn sonra) onu anında alır.
    timed('bmkg', softDeadline(fetchBMKG(options))),
    timed('geonet', softDeadline(fetchGeoNet(options))),
    timed('jma', softDeadline(fetchJMA(options))),
    timed('cenc', softDeadline(fetchCENC(options)))
  ]);
  const timings: Record<string, { ms: number; count: number }> = {};
  const quakes: Earthquake[] = [];
  for (const result of results) {
    timings[result.name] = { ms: result.ms, count: result.quakes.length };
    for (const q of result.quakes) {
      if (Number.isFinite(q.magnitude) && Number.isFinite(q.lat) && Math.abs(q.lat) <= 90
          && Number.isFinite(q.lon) && Math.abs(q.lon) <= 180
          && Number.isFinite(Date.parse(q.date)) && Date.parse(q.date) <= now + 60_000) {
        quakes.push(q);
      }
    }
  }
  return { quakes, timings };
}

// MARK: - Artımlı 24 saat (kaynak yükü)
//
// Tam toplama eskiden her dakika AFAD, EMSC ve NOA'dan SON 24 SAATİN
// TAMAMINI istiyordu: günde 1.440 ağır sorgu. NOA gibi küçük sunucular bunu
// kaldıramıyordu (haftada ~1.300 zaman aşımı, 22 Eyl 2026). Artık 24 saatin
// tamamı 15 dk'da bir çekilir; aradaki dakikalarda yalnızca son 3 saat
// istenip bellekteki güne işlenir. 3 saat, AFAD'ın ölçülen en geç yayınını
// (53 dk) ve ajansların olağan büyüklük düzeltmelerini kapsar; daha eskisi
// en geç 15 dk sonraki tam çekimde gelir.
const PROVIDER_FULL_REFRESH_MS = 15 * 60 * 1000;
const PROVIDER_INCREMENTAL_WINDOW_MS = 3 * 3600 * 1000;
const PROVIDER_DAY_MS = 24 * 3600 * 1000;

export interface ProviderDayCache {
  byId: Map<string, Earthquake>;
  fullAt: number;
  /// Kaynağın en son boş olmayan yanıt verdiği an (sağlık durumu için).
  lastNonEmptyAt: number;
}

/// Saf birleştirme: tam çekimde liste aynen alınır; artımlı çekimde pencere
/// içindeki kayıtlar yanıtla değiştirilir (ajansın sildiği kayıt düşer),
/// pencere dışındakiler korunur. Boş yanıt hata da olabilir (kaynak
/// fonksiyonları hatayı boş listeye çevirir): o zaman hiçbir kayıt silinmez.
export function mergeProviderDay(
  cache: ProviderDayCache | undefined,
  fresh: Earthquake[],
  full: boolean,
  now: number
): ProviderDayCache {
  const dayStart = now - PROVIDER_DAY_MS;
  const windowStart = now - PROVIDER_INCREMENTAL_WINDOW_MS;
  const inDay = (quake: Earthquake) => Date.parse(String(quake.date)) >= dayStart;
  const lastNonEmptyAt = fresh.length ? now : cache?.lastNonEmptyAt ?? 0;
  if (full && fresh.length) {
    return { byId: new Map(fresh.filter(inDay).map(quake => [quake.id, quake])), fullAt: now, lastNonEmptyAt };
  }
  const byId = new Map<string, Earthquake>();
  for (const [id, quake] of cache?.byId ?? []) {
    if (!inDay(quake)) continue;
    // Yanıt geldiyse pencere içi yanıttan kurulur; gelmediyse eldeki korunur.
    if (fresh.length && Date.parse(String(quake.date)) >= windowStart) continue;
    byId.set(id, quake);
  }
  for (const quake of fresh) if (inDay(quake)) byId.set(quake.id, quake);
  // Başarısız tam çekimde bir sonraki dakika yeniden tam çekim denenir.
  return { byId, fullAt: cache?.fullAt ?? 0, lastNonEmptyAt };
}

const providerDayCaches = new Map<string, ProviderDayCache>();

async function fetchProviderDay(
  name: string,
  fetchRange: (startISO: string, endISO: string) => Promise<Earthquake[]>,
  now: number
): Promise<{ quakes: Earthquake[]; available: boolean }> {
  const cache = providerDayCaches.get(name);
  const full = !cache || now - cache.fullAt >= PROVIDER_FULL_REFRESH_MS;
  const start = now - (full ? PROVIDER_DAY_MS : PROVIDER_INCREMENTAL_WINDOW_MS);
  const fresh = await fetchRange(new Date(start).toISOString(), new Date(now).toISOString()).catch(() => []);
  const next = mergeProviderDay(cache, fresh, full, now);
  providerDayCaches.set(name, next);
  // Artımlı pencere sessiz bir saatte boş dönebilir; kaynak son 30 dk içinde
  // yanıt verdiyse erişilebilir sayılır (eski kuralın yedek kaynak kararı).
  const available = next.byId.size > 0 && now - next.lastNonEmptyAt < 30 * 60 * 1000;
  return { quakes: [...next.byId.values()], available };
}

export async function collectQuakes(): Promise<Earthquake[]> {
  if (collectQuakesInFlight) return collectQuakesInFlight;
  collectQuakesInFlight = collectQuakesOnce();
  try { return await collectQuakesInFlight; }
  finally { collectQuakesInFlight = undefined; }
}

async function collectQuakesOnce(): Promise<Earthquake[]> {
  const now = Date.now();
  if (_cachedQuakes && now - _cachedQuakesAt < QUAKE_SNAPSHOT_TTL_MS) {
    return _cachedQuakes;
  }

  // Dört kaynak da SON 24 SAATİ kapsar. AFAD, EMSC ve NOA artımlı çekilir
  // (bkz. fetchProviderDay); USGS'in günlük akışı CDN'de duran statik bir
  // dosya, her dakika tamamı alınır.
  const dayStartISO = new Date(now - 24 * 3600 * 1000).toISOString();
  const regional = (load: () => Promise<Earthquake[]>) => load()
    .then(quakes => ({ quakes, available: quakes.length > 0 }))
    .catch(() => ({ quakes: [] as Earthquake[], available: false }));
  const gdacsEvents = fetchGdacsEvents(now).catch(() => []);
  const [afadRes, emscRes, usgsRes, noaRes, kandilliRes, bmkgRes, geonetRes, jmaRes, cencRes] = await Promise.all([
    fetchProviderDay('afad', (start, end) => fetchAFADRange(start, end, 5000, 0), now),
    fetchProviderDay('emsc', start => fetchEMSCRange(start, 5000, 0), now),
    fetchUSGSRealtimeDay().then(quakes => ({ quakes, available: quakes.length > 0 })).catch(() => ({ quakes: [] as Earthquake[], available: false })),
    fetchProviderDay('noa', (start, end) => fetchNOARange(start, end, 5000, 0, 12000, 0), now),
    regional(() => fetchKandilli()),
    regional(() => fetchBMKG()),
    regional(() => fetchGeoNet()),
    regional(() => fetchJMA()),
    regional(() => fetchCENC())
  ]);

  latestProviderHealth = {
    afad: { available: afadRes.available, count: afadRes.quakes.length },
    emsc: { available: emscRes.available, count: emscRes.quakes.length },
    usgs: { available: usgsRes.available, count: usgsRes.quakes.length },
    noa: { available: noaRes.available, count: noaRes.quakes.length },
    kandilli: { available: kandilliRes.available, count: kandilliRes.quakes.length },
    bmkg: { available: bmkgRes.available, count: bmkgRes.quakes.length },
    geonet: { available: geonetRes.available, count: geonetRes.quakes.length },
    jma: { available: jmaRes.available, count: jmaRes.quakes.length },
    cenc: { available: cencRes.available, count: cencRes.quakes.length }
  };
  unavailablePushSources = new Set(
    Object.entries(latestProviderHealth).filter(([, value]) => !value.available).map(([provider]) => provider)
  );

  let allQuakes: Earthquake[] = [];
  const liveAfad = afadRes.quakes;
  const afadQuakes = liveAfad.length ? liveAfad : providerArchiveFallback(
    liveAfad, await readAfadMapArchive() ?? [], new Date(dayStartISO).getTime(), 0
  );
  allQuakes = allQuakes.concat(afadQuakes);
  allQuakes = allQuakes.concat(emscRes.quakes);
  allQuakes = allQuakes.concat(usgsRes.quakes);
  const liveNoa = noaRes.quakes;
  let noaQuakes = liveNoa;
  if (!liveNoa.length) {
    const archivedNoa = await readNoaMapArchive() ?? [];
    noaQuakes = providerArchiveFallback(liveNoa, archivedNoa, new Date(dayStartISO).getTime(), 0);
    if (noaQuakes.length) {
      console.warn(`NOA anlık isteği boş kaldı; Firestore arşivinden ${noaQuakes.length} kayıt kullanıldı.`);
    }
  }
  allQuakes = allQuakes.concat(noaQuakes);
  // Bölgesel listeler "son N deprem" verir; 24 saatten eskisi atılır.
  const dayStart = now - PROVIDER_DAY_MS;
  for (const result of [kandilliRes, bmkgRes, geonetRes, jmaRes, cencRes]) {
    allQuakes = allQuakes.concat(result.quakes.filter(q => Date.parse(q.date) >= dayStart));
  }

  const filteredQuakes = allQuakes.filter(q => Number.isFinite(q.magnitude)
    && Number.isFinite(q.lat) && Math.abs(q.lat) <= 90
    && Number.isFinite(q.lon) && Math.abs(q.lon) <= 180
    && Number.isFinite(Date.parse(q.date)) && Date.parse(q.date) <= now + 60_000);
  // Uygulama kaynakları sonradan filtrelediği için AFAD/EMSC/USGS/NOA kayıtları
  // burada çapraz tekilleştirilmez. Aksi halde örneğin EMSC kaydı aynı olayı
  // daha büyük raporladığında AFAD filtresinden gerçek AFAD kaydı kayboluyordu.
  //
  // Sınırdan önce tarihe göre sıralanır: üç kaynak art arda eklendiği için
  // sıralamadan kesmek son eklenen kaynağın (USGS) kayıtlarını rastgele
  // düşürüyordu. Artık sınır aşılırsa yalnızca EN ESKİ kayıtlar düşer.
  // GDACS alarm seviyesi (turuncu/kırmızı) ilgili kayda işlenir.
  const finalQuakes = applyGdacsAlertLevels(uniqueQuakesByProviderId(filteredQuakes), await gdacsEvents)
    .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
    .map(stripNullish);
  _cachedQuakes = finalQuakes;
  _cachedQuakesAt = Date.now();

  return finalQuakes;
}

let earthquakesArchive: Earthquake[] = [];
let isPopulating = false;

async function populateArchiveFromApis(): Promise<void> {
  if (earthquakesArchive.length > 0 || isPopulating) return;
  isPopulating = true;
  try {
    console.log(`[Memory DB] Pre-populating in-memory archive from free API feeds (last ${EARTHQUAKE_RETENTION_DAYS} days)...`);
    const now = new Date();
    const startISO = new Date(now.getTime() - EARTHQUAKE_RETENTION_MS).toISOString();

    const [emsc, usgs, afad, noa] = await Promise.all([
      fetchEMSCRange(startISO, 2000, 2.0).catch(() => []),
      fetchUSGSRange(startISO, 2000, 2.0).catch(() => []),
      fetchAFADRecentRange(startISO, now.toISOString(), 2000, 2.0).catch(() => []),
      readNoaMapArchive().then(value => value ?? []).catch(() => [])
    ]);

    const combined = [...emsc, ...usgs, ...afad, ...noa];
    const unique = new Map<string, Earthquake>();
    for (const q of combined) {
      unique.set(q.id, q);
    }

    earthquakesArchive = deduplicateQuakes(Array.from(unique.values()))
      .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
      .slice(0, 4000);

    console.log(`[Memory DB] Pre-population complete. Loaded ${earthquakesArchive.length} earthquakes.`);
  } catch (err) {
    console.error("[Memory DB] Failed to pre-populate in-memory archive:", err);
  } finally {
    isPopulating = false;
  }
}

/// Saf bellek içi birleştirme — populateArchiveFromApis tetiklemez, await
/// gerektirmez. Sıcak istek yolunda güvenle çağrılabilir.
function mergeIntoArchive(quakes: Earthquake[]): void {
  if (!quakes.length) return;

  const cutoff = Date.now() - EARTHQUAKE_RETENTION_MS;
  const unique = new Map<string, Earthquake>();
  for (const q of quakes) {
    if (new Date(q.date).getTime() >= cutoff) unique.set(q.id, q);
  }
  for (const q of earthquakesArchive) {
    if (new Date(q.date).getTime() >= cutoff && !unique.has(q.id)) {
      unique.set(q.id, q);
    }
  }

  earthquakesArchive = Array.from(unique.values())
    .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
    .slice(0, 4000);
}

/// Bu süreçte anlık görüntüye en son yansıtılan uzak yapılandırma. Soğuk
/// açılışta boş: ilk yazım yansımayı bir kez taşır (ek yazım yok, zaten yapılan
/// yazıma eklenir).
let mirroredConfigHash = '';

export async function publishLiveSnapshot(quakes: Earthquake[]): Promise<void> {
  if (!quakes.length) return;
  const serialized = JSON.stringify(quakes);
  const hash = createHash('sha256').update(serialized).digest('hex').slice(0, 24);

  // Büyük olay: yeni süreç önce kayıtlı olayı okur (aksi hâlde aynı olayı
  // yeniden "tespit edip" süresini ve analiz ön üretimini tekrarlardı).
  if (!majorEventLoaded) {
    try { absorbMajorEvent((await liveSnapshotRef.get()).data()); } catch { majorEventLoaded = true; }
  }
  // Uzak yapılandırma (remote-config.ts): yayın yapan süreç kaynağı en fazla
  // dakikada bir okur; değişince aşağıdaki yazımla anlık görüntüye yansır.
  await refreshRemoteConfigFromSource();
  const configChanged = mirroredConfigHash !== remoteConfigHash();
  // Gizlenen kaynak/depremler büyük olay ve Canlı Etkinlik kararına girmez.
  // Yük (payload) filtrelenmez: gizleme kaldırılınca liste hemen geri gelir.
  const visibleQuakes = filterPublicQuakes(quakes);
  const previousEvent = currentMajorEvent;
  let nextEvent = nextMajorEvent(activeMajorEvent(), visibleQuakes, Date.now());
  if (nextEvent && isMajorEventSuppressed(nextEvent.id)) nextEvent = null;
  const majorEventChanged = nextEvent !== previousEvent;
  // Yeni olay: Canlı Etkinlik yayın kanalı aynı yazımla kaydedilir.
  if (nextEvent && nextEvent.id !== previousEvent?.id && !nextEvent.live_channels
      && !remoteServerConfig().live_activity_paused) {
    const channels = await createLiveChannels().catch(() => null);
    if (channels) nextEvent = { ...nextEvent, live_channels: channels };
  }

  // Unchanged data still needs a freshness heartbeat. Otherwise a quiet
  // period ages the shared snapshot out and every instance polls all APIs.
  if (!majorEventChanged && !configChanged && _lastPublishedQuakeHash === hash && Date.now() - _lastPublishedQuakeAt < 120_000) return;

  // Ham dizi yerine gzip'li tek alan (~300 KB → ~40 KB): Firestore depolama,
  // yazma bant genişliği ve her instance ısınmasındaki okuma boyutu ~8x düşer.
  // `mergeFields`: yalnızca bu alanlar değişir; bakım turunun yazdığı
  // `latest_app_version` korunur. Eski şemanın 'quakes' dizisi silinir.
  const updatedAt = Date.now();
  const snapshotFields = {
    schema_version: 2,
    payload: gzipSync(Buffer.from(serialized), { level: 6 }),
    hash,
    count: quakes.length,
    updated_at: updatedAt,
    quakes: FieldValue.delete(),
    ...(majorEventChanged
      ? { major_event: nextEvent ? JSON.stringify(nextEvent) : FieldValue.delete() }
      : {}),
    ...(configChanged ? remoteConfigMirrorFields() : {})
  };
  await liveSnapshotRef.set(snapshotFields, { mergeFields: Object.keys(snapshotFields) });
  if (configChanged) mirroredConfigHash = remoteConfigHash();
  if (majorEventChanged) {
    currentMajorEvent = nextEvent;
    if (previousEvent?.live_channels && previousEvent.id !== nextEvent?.id) {
      void endLiveActivity(previousEvent, quakes).catch(() => undefined);
    }
    if (nextEvent && nextEvent.id !== previousEvent?.id) {
      console.log(`Büyük olay açıldı: ${nextEvent.id} M${nextEvent.magnitude} ${nextEvent.title} (${nextEvent.region}).`);
      void prewarmMajorEventAnalysis(nextEvent, PUBLIC_API_BASE_URL).catch(() => undefined);
    } else if (!nextEvent) {
      console.log(`Büyük olay kapandı: ${previousEvent?.id}.`);
    }
  }
  // Artçı sayısı değiştiyse Canlı Etkinlik tek yayınla güncellenir.
  if (!remoteServerConfig().live_activity_paused) {
    void publishLiveActivityUpdate(activeMajorEvent(), visibleQuakes).catch(() => undefined);
  }
  _lastPublishedQuakeHash = hash;
  _lastPublishedQuakeAt = updatedAt;
  _publishedQuakes = quakes;
  _publishedQuakesAt = updatedAt;
}

// MARK: - Taze depremler listeye anında
//
// Liste eskiden yalnızca 24 saatlik TAM toplamadan sonra yayımlanıyordu
// (dakikada bir, dört kaynağın en yavaşını bekleyerek 7–12 sn). Hızlı tarama
// ve gerçek zamanlı akış (EMSC WebSocket, USGS) yeni depremi saniyeler içinde
// görse de yalnızca bildirim için kullanıyordu; deprem listeye bir sonraki
// tam turda giriyordu. Artık bu yollardan gelen YENİ kimlikler anında
// eklenir. Yazım yalnızca gerçekten yeni kayıt varsa ve en sık 10 sn'de bir
// olur. Tam toplamada kaynağı o an yanıt vermeyen taze kayıt 30 dk boyunca
// korunur; liste "gelip giden" depremle titremez.
const FRESH_RETENTION_MS = 30 * 60 * 1000;
const FRESH_PUBLISH_MIN_GAP_MS = 10 * 1000;
const LIST_WINDOW_MS = 24 * 3600 * 1000;
const freshQuakes = new Map<string, { quake: Earthquake; seenAt: number }>();
let freshPending: Earthquake[] = [];
let freshTimer: NodeJS.Timeout | undefined;
let lastFreshPublishAt = 0;
let publishChain: Promise<void> = Promise.resolve();

function isListable(quake: Earthquake, now: number): boolean {
  const time = Date.parse(String(quake.date));
  return Number.isFinite(time) && time >= now - LIST_WINDOW_MS && time <= now + 60_000
    && Number.isFinite(quake.magnitude) && Number.isFinite(quake.lat) && Number.isFinite(quake.lon);
}

/// Yeni kimlikleri listeye ekler; mevcut kayıtlara dokunmaz (büyüklük
/// düzeltmeleri ve zenginleştirilmiş alanlar tam turdan gelir). Değişiklik
/// yoksa `null`.
export function mergeFreshIntoList(base: Earthquake[], fresh: Earthquake[], now: number): Earthquake[] | null {
  const known = new Set(base.map(quake => quake.id));
  const added: Earthquake[] = [];
  for (const quake of fresh) {
    if (known.has(quake.id) || !isListable(quake, now)) continue;
    known.add(quake.id);
    added.push(stripNullish(quake));
  }
  if (!added.length) return null;
  return base.concat(added).sort((a, b) => Date.parse(String(b.date)) - Date.parse(String(a.date)));
}

/// Tam turun listesine, o turun kaçırdığı taze kayıtları geri katar.
export function withRecentFreshQuakes(quakes: Earthquake[], now: number = Date.now()): Earthquake[] {
  for (const [id, entry] of freshQuakes) {
    if (now - entry.seenAt > FRESH_RETENTION_MS) freshQuakes.delete(id);
  }
  if (!freshQuakes.size) return quakes;
  return mergeFreshIntoList(quakes, [...freshQuakes.values()].map(entry => entry.quake), now) ?? quakes;
}

/// Anlık görüntü yazımları sıraya girer: hızlı ekleme ile tam tur aynı anda
/// yazıp birbirinin sonucunu ezmesin.
function serializedPublish(build: () => Earthquake[] | null): Promise<void> {
  publishChain = publishChain.then(async () => {
    const list = build();
    if (list) await publishLiveSnapshot(list);
  }).catch(error => {
    console.error('Canlı anlık görüntü yayımlanamadı:', error?.message || error);
  });
  return publishChain;
}

/// Tam tur listesi: taze kayıtlarla birleştirilip sırayla yazılır.
export function publishFullLiveSnapshot(quakes: Earthquake[]): Promise<void> {
  return serializedPublish(() => withRecentFreshQuakes(quakes));
}

/// Hızlı tarama ve gerçek zamanlı akış buraya verir. Yalnızca bu süreçte
/// yayımlanmış bir liste varsa çalışır (tam tur henüz bitmediyse onu bekler;
/// taze kayıtlar hatırlanır ve tam turla birlikte yazılır).
export function publishFreshQuakes(quakes: Earthquake[]): Promise<void> {
  const now = Date.now();
  for (const [id, entry] of freshQuakes) {
    if (now - entry.seenAt > FRESH_RETENTION_MS) freshQuakes.delete(id);
  }
  for (const quake of quakes) {
    if (!isListable(quake, now)) continue;
    if (!freshQuakes.has(quake.id)) freshQuakes.set(quake.id, { quake, seenAt: now });
    freshPending.push(quake);
  }
  if (!freshPending.length || !_publishedQuakes) return Promise.resolve();
  const wait = lastFreshPublishAt + FRESH_PUBLISH_MIN_GAP_MS - now;
  if (wait > 0) {
    freshTimer ??= setTimeout(() => { freshTimer = undefined; void flushFreshQuakes(); }, wait);
    return Promise.resolve();
  }
  return flushFreshQuakes();
}

function flushFreshQuakes(): Promise<void> {
  const pending = freshPending;
  freshPending = [];
  return serializedPublish(() => {
    if (!_publishedQuakes) return null;
    const merged = mergeFreshIntoList(_publishedQuakes, pending, Date.now());
    if (merged) {
      lastFreshPublishAt = Date.now();
      console.log(`Listeye anında eklendi: ${merged.length - _publishedQuakes.length} yeni deprem.`);
    }
    return merged;
  });
}

/// Ayrı tarama örneği (`fastPushScan`, :15/:30/:45) için: o örnekte
/// yayımlanmış liste yok. Yalnızca bu örneğin henüz listede görmediği bir
/// kimlik varsa belge okunur (1 okuma); yeni kayıt varsa belge, okunduğu
/// andaki sürümü değişmemişse yazılır. Arada ana tur yazdıysa bu yazım
/// atlanır — ana turun değişikliği ezilmez, kayıt bir sonraki taramada
/// yeniden denenir.
const scanKnownIds = new Set<string>();
export async function publishScanQuakes(quakes: Earthquake[]): Promise<void> {
  const now = Date.now();
  const candidates = filterPublicQuakes(quakes).filter(quake => isListable(quake, now) && !scanKnownIds.has(quake.id));
  if (!candidates.length) return;
  try {
    const snapshot = await liveSnapshotRef.get();
    const data = snapshot.data();
    if (!data?.payload || !snapshot.updateTime) return;
    const bytes = Buffer.isBuffer(data.payload) ? data.payload : Buffer.from(data.payload);
    const parsed = JSON.parse(gunzipSync(bytes).toString('utf8'));
    if (!Array.isArray(parsed)) return;
    const base = (parsed as Earthquake[]).map(stripNullish);
    if (scanKnownIds.size > 20_000) scanKnownIds.clear();
    base.forEach(quake => scanKnownIds.add(quake.id));
    const merged = mergeFreshIntoList(base, candidates, now);
    if (!merged) return;
    const serialized = JSON.stringify(merged);
    await liveSnapshotRef.update({
      schema_version: 2,
      payload: gzipSync(Buffer.from(serialized), { level: 6 }),
      hash: createHash('sha256').update(serialized).digest('hex').slice(0, 24),
      count: merged.length,
      updated_at: Date.now()
    }, { lastUpdateTime: snapshot.updateTime });
    candidates.forEach(quake => scanKnownIds.add(quake.id));
    console.log(`Listeye anında eklendi (tarama): ${merged.length - base.length} yeni deprem.`);
  } catch (error: any) {
    // Ön koşul tutmadı (ana tur az önce yazdı) ya da okuma hatası: sonraki tarama dener.
    if (Number(error?.code) !== 9 && Number(error?.code) !== 10) {
      console.error('Tarama kaydı listeye eklenemedi:', error?.message || error);
    }
  }
}

async function readPublishedLiveSnapshot(): Promise<Earthquake[] | null> {
  if (publishedSnapshotInFlight) return publishedSnapshotInFlight;
  publishedSnapshotInFlight = readPublishedLiveSnapshotOnce();
  try { return await publishedSnapshotInFlight; }
  finally { publishedSnapshotInFlight = undefined; }
}

/// Anlık görüntü bayat/boş ya da okunamadıysa bu süre boyunca yeniden
/// okunmaz. Yayıncı tur durduğunda (ör. scheduledPushCheck hata veriyor) her
/// liste isteği belgeyi yeniden okuyup sonra yine dış kaynaklara düşüyordu:
/// 40 örnek × 20 eşzamanlı istekte boşa giden okuma faturası.
const LIVE_SNAPSHOT_MISS_TTL_MS = 10 * 1000;
let liveSnapshotMissAt = 0;

async function readPublishedLiveSnapshotOnce(): Promise<Earthquake[] | null> {
  const now = Date.now();
  if (_publishedQuakes && now - _publishedQuakesAt < LIVE_SNAPSHOT_MEMORY_TTL_MS) {
    return _publishedQuakes;
  }
  if (now - liveSnapshotMissAt < LIVE_SNAPSHOT_MISS_TTL_MS) return null;

  try {
    const snapshot = await liveSnapshotRef.get();
    const data = snapshot.data();
    const updatedAt = Number(data?.updated_at || 0);
    if (typeof data?.latest_app_version === 'string') publishedLatestAppVersion = data.latest_app_version;
    absorbInfoCards(data);
    absorbMajorEvent(data);
    absorbRemoteConfigMirror(data);
    if (data?.hash) {
      _lastPublishedQuakeHash = String(data.hash);
      _lastPublishedQuakeAt = updatedAt;
    }

    // v2: gzip'li payload; v1 (geçiş dönemi): ham 'quakes' dizisi.
    let quakes: Earthquake[] = [];
    if (data?.payload) {
      const bytes = Buffer.isBuffer(data.payload) ? data.payload : Buffer.from(data.payload);
      const parsed = JSON.parse(gunzipSync(bytes).toString('utf8'));
      if (Array.isArray(parsed)) quakes = parsed as Earthquake[];
    } else if (Array.isArray(data?.quakes)) {
      quakes = data.quakes as Earthquake[];
    }

    // Eski backend sürümünün `null` MMI/CDI alanlarını 0'a dönüştürdüğü
    // snapshot'ları da okuma anında temizle; yeni yayın gelmesini bekletme.
    quakes = quakes.map(stripNullish);

    if (quakes.length && now - updatedAt <= LIVE_SNAPSHOT_MAX_AGE_MS) {
      _publishedQuakes = quakes;
      _publishedQuakesAt = now;
      return quakes;
    }
  } catch (error) {
    console.error('Canlı snapshot okunamadı; dış kaynak yedeğine geçiliyor:', error);
  }
  liveSnapshotMissAt = Date.now();
  return null;
}

/// AFAD ve NOA'nın 34 günlük sorguları kullanıcı istek yolunda çalıştırılmaz.
/// İki saatlik bakım diliminde bir kez oluşturulur; harita, geçmiş ve
/// istatistik uçları sıkıştırılmış tek Firestore belgesini okur. İki
/// sağlayıcı da aynı üret/yayımla/oku desenini paylaştığı için tek bir
/// jenerik yönetici burada kurulup her sağlayıcı yalnızca kendi getirme ve
/// büyüklük filtresi mantığını sağlar.
interface MapArchiveConfig {
  provider: string;
  ref: DocumentReference<DocumentData>;
  days: number;
  maxAgeMs: number;
  memoryTtlMs: number;
  fetchRange(startISO: string, nowISO: string): Promise<Earthquake[]>;
  keepQuake(q: Earthquake): boolean;
  readFallbackNote: string;
}

/// Arşiv belgesi yoksa/bayatsa ya da okunamadıysa aynı örnek bu süre boyunca
/// belgeyi yeniden okumaz (çağıran dış kaynak yedeğine düşer).
const MAP_ARCHIVE_MISS_TTL_MS = 60 * 1000;

function createMapArchiveManager(config: MapArchiveConfig) {
  let cached: Earthquake[] | null = null;
  let cachedAt = 0;
  let missAt = 0;
  // Eşzamanlı ıskalar tek okumada birleşir: belge ~850 KB'a kadar gzip'li
  // ve açılınca birkaç MB JSON. Önbellek süresi dolduğunda 20 eşzamanlı istek
  // aynı belgeyi 20 kez okuyup 20 kez açıyor, bellek ve okuma faturası
  // sıçrıyordu.
  let inFlight: Promise<Earthquake[] | null> | undefined;

  async function build(): Promise<Earthquake[]> {
    const now = new Date();
    const start = new Date(now.getTime() - config.days * 86400000);
    const quakes = await config.fetchRange(start.toISOString(), now.toISOString());
    const startMs = start.getTime();
    return uniqueQuakesByProviderId(quakes).filter(q => {
      const time = new Date(q.date).getTime();
      return Number.isFinite(time) && time >= startMs && config.keepQuake(q);
    });
  }

  async function publish(): Promise<number> {
    const quakes = await build();
    if (!quakes.length) throw new Error(`${config.provider} ${EARTHQUAKE_RETENTION_DAYS} günlük arşivi boş döndü`);

    const json = JSON.stringify(quakes);
    const updatedAt = Date.now();
    // Önce belgeyi okuyup içerik aynı mı diye bakmak bir okuma harcıyor ama
    // yazımı kurtarmıyordu (aynı içerikte de tazelik zamanı yazılıyordu);
    // arşiv her iki saatte zaten değişiyor. Doğrudan yazılır.
    const payload = gzipSync(Buffer.from(json), { level: 6 });
    // Firestore belge sınırına yaklaşılırsa sessiz veri kesmek yerine görev
    // açıkça hata versin; normal 34 günlük arşiv bunun çok altındadır.
    if (payload.length > 850000) {
      throw new Error(`${config.provider} sıkıştırılmış arşivi güvenli belge sınırını aştı: ${payload.length} bayt`);
    }
    await config.ref.set({
      schema_version: 1,
      provider: config.provider,
      days: config.days,
      min_magnitude: 0,
      count: quakes.length,
      payload,
      updated_at: updatedAt,
      oldest_at: quakes.at(-1)?.date || null,
      newest_at: quakes[0]?.date || null
    });

    cached = quakes;
    cachedAt = updatedAt;
    missAt = 0;
    return quakes.length;
  }

  async function read(): Promise<Earthquake[] | null> {
    const now = Date.now();
    if (cached && now - cachedAt < config.memoryTtlMs) {
      return cached;
    }
    if (now - missAt < MAP_ARCHIVE_MISS_TTL_MS) return null;
    if (inFlight) return inFlight;
    inFlight = readOnce(now).finally(() => { inFlight = undefined; });
    return inFlight;
  }

  async function readOnce(now: number): Promise<Earthquake[] | null> {
    const result = await readFromFirestore(now);
    if (!result) missAt = Date.now();
    return result;
  }

  async function readFromFirestore(now: number): Promise<Earthquake[] | null> {
    try {
      const snapshot = await config.ref.get();
      const data = snapshot.data();
      const updatedAt = Number(data?.updated_at || 0);
      if (!data?.payload || now - updatedAt > config.maxAgeMs) return null;

      const bytes = Buffer.isBuffer(data.payload)
        ? data.payload
        : Buffer.from(data.payload);
      const parsed = JSON.parse(gunzipSync(bytes).toString('utf8'));
      if (!Array.isArray(parsed) || !parsed.length) return null;

      const retentionCutoff = now - EARTHQUAKE_RETENTION_MS;
      cached = (parsed as Earthquake[]).filter(q =>
        new Date(q.date).getTime() >= retentionCutoff
      );
      cachedAt = now;
      return cached;
    } catch (error) {
      console.error(`${config.provider} harita arşivi okunamadı; ${config.readFallbackNote}:`, error);
      return null;
    }
  }

  return { publish, read };
}

let afadMapArchiveManager!: ReturnType<typeof createMapArchiveManager>;
let noaMapArchiveManager!: ReturnType<typeof createMapArchiveManager>;

async function publishAfadMapArchive(): Promise<number> {
  return afadMapArchiveManager.publish();
}

async function readAfadMapArchive(): Promise<Earthquake[] | null> {
  return afadMapArchiveManager.read();
}

async function publishNoaMapArchive(): Promise<number> {
  return noaMapArchiveManager.publish();
}

async function readNoaMapArchive(): Promise<Earthquake[] | null> {
  return noaMapArchiveManager.read();
}

async function refreshMapArchive(): Promise<void> {
  const [afadResult, noaResult] = await Promise.allSettled([
    publishAfadMapArchive(),
    publishNoaMapArchive()
  ]);

  if (afadResult.status === 'fulfilled') {
    console.log(`AFAD ${EARTHQUAKE_RETENTION_DAYS} günlük harita arşivi güncellendi: ${afadResult.value} kayıt.`);
  } else {
    console.error('AFAD harita arşivi güncellenemedi:', afadResult.reason);
  }
  if (noaResult.status === 'fulfilled') {
    console.log(`NOA ${EARTHQUAKE_RETENTION_DAYS} günlük harita arşivi güncellendi: ${noaResult.value} kayıt.`);
  } else {
    console.error('NOA harita arşivi güncellenemedi:', noaResult.reason);
  }

  if (afadResult.status === 'rejected' && noaResult.status === 'rejected') {
    throw new Error('AFAD ve NOA harita arşivleri güncellenemedi');
  }
}

/// Bakım penceresi geldiyse (iki saatte bir) harita arşivini tazeler.
/// Eskiden her soğuk açılışta "arşiv hiç tohumlanmamış mı" diye iki büyük
/// belge (~175 KB) okunuyordu; arşivler oluştuktan sonra bu kontrolün işlevi
/// kalmamıştı. Boş bir projede ilk arşiv ilk bakım penceresinde oluşur,
/// o zamana kadar okuyucular dış kaynağa düşer.
export async function refreshMapArchiveIfDue(scheduledRefresh: boolean): Promise<void> {
  if (!scheduledRefresh) return;
  await refreshMapArchive();
}

/// `/health` (index.ts) derin kontrolde canlı snapshot belgesini doğrudan
/// okumak için bu referansı kullanır.
export function getLiveSnapshotRef(): DocumentReference<DocumentData> {
  return liveSnapshotRef;
}

/// `/health` (index.ts) sığ kontrolde canlı snapshot'ın bellekte önbelleğe
/// alınmış olup olmadığını bu üzerinden okur.
export function isLiveSnapshotCached(): boolean {
  return Boolean(_publishedQuakes?.length);
}

// Ülke çıkarım yardımcıları
function inferCountry(title: string, provider: string): string | null {
  if (String(provider).toUpperCase() === 'AFAD') return 'Türkiye';
  const parts = String(title || '').split(',').map(part => part.trim()).filter(Boolean);
  if (parts.length > 1) return parts[parts.length - 1].slice(0, 80);
  return null;
}

function normalizeCountry(value: string | null): string | null {
  const raw = String(value || '').trim();
  if (!raw || raw.toLowerCase() === 'unknown') return null;
  const key = raw.toUpperCase();
  const unitedStatesRegions = new Set([
    'ALASKA', 'HAWAII', 'CALIFORNIA', 'CA', 'NEVADA', 'NV', 'OREGON', 'OR',
    'WASHINGTON', 'WA', 'UTAH', 'UT', 'IDAHO', 'ID', 'MONTANA', 'MT',
    'WYOMING', 'WY', 'ARIZONA', 'AZ', 'NEW MEXICO', 'NM', 'TEXAS', 'TX',
    'OKLAHOMA', 'OK', 'KANSAS', 'KS', 'COLORADO', 'CO', 'PUERTO RICO'
  ]);
  if (unitedStatesRegions.has(key)) return key === 'PUERTO RICO' ? 'Puerto Rico' : 'United States';
  return raw
    .toLowerCase()
    .split(/\s+/)
    .map(word => word ? word[0].toUpperCase() + word.slice(1) : word)
    .join(' ');
}

// MARK: - Express API Uç Noktaları

/// Hızlı ve düşük maliyetli sıcak yol:
/// 1) Dakikalık görev tarafından yayımlanan tek dokümanlık anlık görüntü
///    55 saniye bellekte tutulur. Böylece her uygulama açılışında üç dış
///    kaynağın yeniden çağrılması önlenir.
/// 2) Anlık görüntü eksik veya 3 dakikadan eskiyse AFAD/EMSC/USGS/NOA doğrudan
///    çağrılır; tümü başarısız olursa bellek içi arşiv yedek olur.
/// Arşiv burada yalnızca zaten doluysa (senkron, ucuz) güncellenir: yanıt
/// sonrası arka plan promise'i Cloud Run CPU kısıtlamasına takılır ve soğuk
/// instance'larda 34 günlük ön doldurmayı sıcak yolda tetiklerdi. Boş arşivi
/// /history, /map ve /stats kendi ihtiyacında zaten dolduruyor.
/// Son 24 saatin deprem listesi: önce liste ucunun kullandığı anlık görüntü
/// (60 sn bellek, en fazla bir okuma), yoksa dış kaynaklar.
export async function recentLiveQuakes(): Promise<Earthquake[]> {
  return getQuakesOptimized();
}

async function getQuakesOptimized(): Promise<Earthquake[]> {
  const published = await readPublishedLiveSnapshot();
  if (published?.length) return published;

  try {
    const liveQuakes = await collectQuakes();
    if (liveQuakes.length > 0) {
      if (earthquakesArchive.length > 0) {
        mergeIntoArchive(liveQuakes);
      }
      return liveQuakes;
    }
  } catch (err) {
    console.error('Canlı kaynak toplama hatası, hafıza yedeğine geçiliyor:', err);
  }

  // Yedek: dış kaynaklar boş/başarısız — arşivden son kayıtlar.
  if (earthquakesArchive.length === 0) {
    await populateArchiveFromApis();
  }
  return earthquakesArchive.slice(0, 150);
}

// MARK: - Harita önbelleği

// /map ağır bir uç: AFAD 34 günlük verisi tek sıkıştırılmış Firestore
// belgesinden, diğer kaynaklar kendi API'lerinden gelir. Bellek önbelleği ve
// istek birleştirme aynı instance'a gelen çağrıların hesabı paylaşmasını sağlar.
interface MapCacheEntry {
  data: Earthquake[];
  timestamp: number;
  json: string;
  gzip: Buffer;
}
const mapCache = new Map<string, MapCacheEntry>();
const inFlightMap = new Map<string, Promise<MapCacheEntry>>();
// 5 dk: istemci de harita verisini 5 dk kendi tarafında önbelleğe aldığı
// için daha kısa TTL yalnızca gereksiz Firestore okuması üretiyordu.
const MAP_CACHE_TTL_MS = 5 * 60 * 1000;

/// Haftalık özet için son 7 günün M2.0+ depremleri, ajanslar arası
/// kopyalar birleştirilmiş (bkz. weekly-digest.ts).
export async function collectDigestQuakes(): Promise<Earthquake[]> {
  return deduplicateQuakes(await computeMapData(7, 2));
}

async function computeMapData(days: number, minmag: number): Promise<Earthquake[]> {
  const now = new Date();
  const startISO = new Date(now.getTime() - days * 86400000).toISOString();
  const startMs = new Date(startISO).getTime();

  const [emscRes, usgsRes, noaRes, afadArchiveRes, liveSnapshotRes] = await Promise.allSettled([
    fetchEMSCRange(startISO, 20000, minmag > 0 ? minmag : -10),
    fetchUSGSRange(startISO, 20000, minmag > 0 ? minmag : -10),
    readNoaMapArchive(),
    readAfadMapArchive(),
    readPublishedLiveSnapshot()
  ]);

  let afad: Earthquake[] = [];
  if (afadArchiveRes.status === 'fulfilled' && afadArchiveRes.value) {
    afad = afadArchiveRes.value;
  }
  // İlk kurulumda veya arşiv iki saatten eskiyse doğruluktan ödün verme:
  // resmî AFAD API'sinden tüm pencereyi getir, sonraki zamanlanmış çalışma
  // bunu sıkıştırılmış Firestore belgesine dönüştürür.
  if (!afad.length) {
    afad = await fetchAFADRecentRange(startISO, now.toISOString(), 20000, 0);
  }
  if (liveSnapshotRes.status === 'fulfilled' && liveSnapshotRes.value) {
    afad = afad.concat(liveSnapshotRes.value.filter(q => q.provider === 'AFAD'));
  }

  let emsc = emscRes.status === 'fulfilled' ? emscRes.value : [];
  let usgs = usgsRes.status === 'fulfilled' ? usgsRes.value : [];
  let noa = noaRes.status === 'fulfilled' && noaRes.value ? noaRes.value : [];
  if (liveSnapshotRes.status === 'fulfilled' && liveSnapshotRes.value) {
    noa = noa.concat(liveSnapshotRes.value.filter(q => q.provider === 'NOA'));
  }
  // İlk NOA arşivi henüz oluşmadıysa yalnızca seçili kısa pencereyi dene;
  // uzun arşiv isteği kullanıcı yolunda çalıştırılmaz.
  if (!noa.length) {
    noa = await fetchNOARange(
      startISO,
      now.toISOString(),
      20000,
      minmag > 0 ? minmag : -10,
      30000,
      0
    );
  }

  // Dış kaynaklardan biri anlık hata verirse mevcut bellek arşivindeki aynı
  // sağlayıcıyı yedek olarak kullan; kaynaklar birbirine karıştırılmaz.
  if ((!emsc.length || !usgs.length) && earthquakesArchive.length === 0) {
    await populateArchiveFromApis();
  }
  if (!emsc.length) emsc = earthquakesArchive.filter(q => q.provider === 'EMSC');
  if (!usgs.length) usgs = earthquakesArchive.filter(q => q.provider === 'USGS');
  if (!noa.length) noa = earthquakesArchive.filter(q => q.provider === 'NOA');

  const all = filterMapQuakes([...afad, ...emsc, ...usgs, ...noa], startMs, minmag);

  if (!all.length) throw new Error('No map data available from any source');

  // İstemcide artık tek kaynağa filtreleme yok (harita her zaman tüm
  // kaynakları gösterir), bu yüzden aynı fiziksel olayı farklı kaynaklardan
  // tekrar göstermemek için çapraz sağlayıcı tekilleştirmesi burada güvenle
  // uygulanabilir; 1500'lük global kesme uygulanmaz.
  return deduplicateQuakes(uniqueQuakesByProviderId(all)).map(stripNullish);
}

function createMapCacheEntry(data: Earthquake[]): MapCacheEntry {
  // Harita yükü kayıt başına yalnızca çizim ve baloncuk alanlarını taşır.
  const json = JSON.stringify(
    data.map(quake => stripNullish(toMapProjection(quake) as Earthquake))
  );
  return {
    data,
    timestamp: Date.now(),
    json,
    gzip: gzipSync(Buffer.from(json), { level: 6 })
  };
}

function sendMapCacheEntry(req: express.Request, res: express.Response, entry: MapCacheEntry, cacheControl: string): void {
  res.setHeader('Cache-Control', cacheControl);
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Vary', 'Accept-Encoding');
  if (/\bgzip\b/i.test(String(req.headers['accept-encoding'] || ''))) {
    res.setHeader('Content-Encoding', 'gzip');
    res.send(entry.gzip);
  } else {
    res.send(entry.json);
  }
}

interface SpatialRangeRequest {
  latitude: number;
  longitude: number;
  radiusKm: number;
  minMagnitude: number;
  start: Date;
  end: Date;
  /// Belirtilirse yalnızca bu kaynak sorgulanır (ör. çember modu: yalnızca EMSC).
  source?: string;
}

interface SpatialRangeCacheEntry {
  data: Earthquake[];
  timestamp: number;
}

const spatialRangeCache = new Map<string, SpatialRangeCacheEntry>();
const spatialRangeInFlight = new Map<string, Promise<Earthquake[]>>();
const SPATIAL_RANGE_CACHE_TTL_MS = 5 * 60 * 1000;
const SPATIAL_RANGE_CACHE_MAX = 60;

async function collectSpatialRange(request: SpatialRangeRequest): Promise<Earthquake[]> {
  const { latitude, longitude, radiusKm, minMagnitude, start, end, source } = request;
  const startISO = start.toISOString();
  const endISO = end.toISOString();
  const startMs = start.getTime();
  const endMs = end.getTime();
  const includesRecentArchive = endMs >= Date.now() - EARTHQUAKE_RETENTION_MS;

  // `source` verilirse yalnızca o sağlayıcıya istek atılır (isteğe bağlı,
  // şu an istemci tarafından kullanılmıyor — çember tüm kaynakları
  // tekilleştirerek gösteriyor).
  // Kandilli'nin listesi son ~2 günü kapsar; Türkiye bölgesinde ve pencere
  // bu aralığa değiyorsa artçı adaylarına eklenir (paylaşılan önbellekten).
  const inTurkiyeRegion = latitude >= 34 && latitude <= 43.5 && longitude >= 24 && longitude <= 46;
  const wantsKandilli = (!source || source === 'kandilli') && inTurkiyeRegion && endMs >= Date.now() - 2 * 86_400_000;
  const [usgsResult, emscResult, afadResult, noaResult, liveResult, kandilliResult] = await Promise.allSettled([
    !source || source === 'usgs'
      ? fetchUSGSSpatialRange(startISO, endISO, latitude, longitude, radiusKm, minMagnitude)
      : Promise.resolve([]),
    !source || source === 'emsc'
      ? fetchEMSCSpatialRange(startISO, endISO, latitude, longitude, radiusKm, minMagnitude)
      : Promise.resolve([]),
    includesRecentArchive && (!source || source === 'afad') ? readAfadMapArchive() : Promise.resolve([]),
    includesRecentArchive && (!source || source === 'noa') ? readNoaMapArchive() : Promise.resolve([]),
    includesRecentArchive && !source ? readPublishedLiveSnapshot() : Promise.resolve([]),
    wantsKandilli ? fetchKandilli({ timeoutMs: 6000, retries: 0, quiet: true }) : Promise.resolve([])
  ]);

  let candidates: Earthquake[] = usgsResult.status === 'fulfilled' ? usgsResult.value : [];
  if (emscResult.status === 'fulfilled' && emscResult.value) candidates.push(...emscResult.value);
  if (afadResult.status === 'fulfilled' && afadResult.value) candidates.push(...afadResult.value);
  if (noaResult.status === 'fulfilled' && noaResult.value) candidates.push(...noaResult.value);
  if (liveResult.status === 'fulfilled' && liveResult.value) candidates.push(...liveResult.value);
  if (kandilliResult.status === 'fulfilled' && kandilliResult.value) candidates.push(...kandilliResult.value);

  const filtered = uniqueQuakesByProviderId(candidates).filter(q => {
    const time = new Date(q.date).getTime();
    return Number.isFinite(time)
      && time >= startMs
      && time <= endMs
      && q.magnitude >= minMagnitude
      && getDistanceKm(latitude, longitude, q.lat, q.lon) <= radiusKm;
  });

  // Aynı depremin ajans kopyaları tek kayda iner (tarih/yarıçap filtresinden
  // SONRA). Genel `deduplicateQuakes` (90 sn / 90 km) BURADA KULLANILMAZ:
  // aktif artçı dizisinde dakikada birkaç ayrı deprem olur ve o kural onları
  // birbirinin kopyası sayıp artçı sayısını düşürüyordu; ayrıca resmî ajans
  // yerine en büyük büyüklüğü tutuyordu.
  return dedupeAgencyCopies(filtered)
    .sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());
}

function spatialRangeCacheKey(request: SpatialRangeRequest): string {
  return [
    request.start.toISOString(),
    request.end.toISOString(),
    request.latitude.toFixed(3),
    request.longitude.toFixed(3),
    Math.round(request.radiusKm),
    request.minMagnitude.toFixed(1),
    request.source ?? 'all'
  ].join(':');
}

function setSpatialRangeCache(key: string, data: Earthquake[]): void {
  spatialRangeCache.set(key, { data, timestamp: Date.now() });
  if (spatialRangeCache.size > SPATIAL_RANGE_CACHE_MAX) {
    const oldestKey = spatialRangeCache.keys().next().value;
    if (oldestKey !== undefined) spatialRangeCache.delete(oldestKey);
  }
}

function parseSpatialRangeRequest(
  req: express.Request,
  maximumRadiusKm: number,
  maximumMinMagnitude: number,
  enforceRetention: boolean
): SpatialRangeRequest | null {
  const latitude = Number(req.query.lat);
  const longitude = Number(req.query.lon);
  const radiusKm = Math.min(
    maximumRadiusKm,
    Math.max(10, Number(req.query.radius) || 150)
  );
  const minMagnitude = Math.min(
    maximumMinMagnitude,
    Math.max(0, Number(req.query.minmag) || 0)
  );
  const start = new Date(String(req.query.start || ''));
  const requestedEnd = new Date(String(req.query.end || ''));
  const now = new Date();
  const rawSource = String(req.query.source || '').toLowerCase();
  const source = SUPPORTED_SPATIAL_SOURCES.has(rawSource) ? rawSource : undefined;

  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)
      || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180
      || !Number.isFinite(start.getTime())) {
    return null;
  }

  const end = Number.isFinite(requestedEnd.getTime()) && requestedEnd < now
    ? requestedEnd
    : now;
  if (end.getTime() <= start.getTime()) {
    return null;
  }
  if (enforceRetention
      && (end.getTime() - start.getTime() > EARTHQUAKE_RETENTION_MS
        || start.getTime() < now.getTime() - EARTHQUAKE_RETENTION_MS)) {
    return null;
  }

  return { latitude, longitude, radiusKm, minMagnitude, start, end, source };
}

const SUPPORTED_SPATIAL_SOURCES = new Set(['afad', 'emsc', 'usgs', 'noa', 'kandilli']);

// 4) Fay Hatları (GeoJSON)
function sendFaultsFile(req: express.Request, res: express.Response, filePath: string): void {
  const stat = fs.statSync(filePath);
  const etag = `W/"${stat.size}-${Math.floor(stat.mtimeMs)}"`;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'public, max-age=86400, s-maxage=604800');
  res.setHeader('ETag', etag);
  res.setHeader('Vary', 'Accept-Encoding');

  if (req.headers['if-none-match'] === etag) {
    res.status(304).end();
    return;
  }

  const gzipPath = `${filePath}.gz`;
  if (/\bgzip\b/i.test(String(req.headers['accept-encoding'] || '')) && fs.existsSync(gzipPath)) {
    res.setHeader('Content-Encoding', 'gzip');
    fs.createReadStream(gzipPath).pipe(res);
    return;
  }
  fs.createReadStream(filePath).pipe(res);
}

// 5) İstatistikler
function cleanCountryName(country: string): string {
  let name = country.trim();
  // Remove prefixes like "off the coast of", "near the coast of", "border region", "south of" etc.
  name = name.replace(/^(off the coast of|near the coast of|near the border of|south of|north of|east of|west of|central|southern|northern|eastern|western)\s+/i, '');
  name = name.replace(/\s+(region)$/i, '');
  return name.trim();
}



interface StatsDataset {
  quakes: Earthquake[];
  turkeyTopProvinces: RegionCount[];
}

interface TopQuakeStat {
  id: string;
  provider: string;
  magnitude: number;
  place: string;
  time: string;
  lat: number;
  lon: number;
  depth: number;
}

interface StatisticsResponse {
  updatedAt: string;
  rangeHours: number;
  total7d: number;
  last24h: number;
  felt24h: number;
  maxMagnitude: number;
  strongestTitle: string;
  strongestTime: string | null;
  m45plus: number;
  m60plus: number;
  avgMagnitude: number;
  avgDepth: number;
  medianMagnitude: number;
  medianDepth: number;
  magnitudeStdDev: number;
  totalEnergyJoules: number;
  bucketStarts: string[];
  dailyCounts: number[];
  dailyMaxMag: number[];
  magDist: { micro: number; light: number; moderate: number; strong: number; major: number };
  depthDist: { shallow: number; intermediate: number; deep: number };
  topQuakes: TopQuakeStat[];
  topCountries: RegionCount[];
  sourceCounts: { afad: number; emsc: number; usgs: number; noa: number };
}

async function collectStatsQuakes(start: Date, isTurkey: boolean): Promise<StatsDataset> {
  const startISO = start.toISOString();
  const nowISO = new Date().toISOString();
  const startMs = start.getTime();

  if (earthquakesArchive.length === 0) {
    await populateArchiveFromApis();
  }
  const archived = earthquakesArchive.filter(q => new Date(q.date).getTime() >= startMs);

  const limit = 2000;
  // En aktif iller seçilen uzun aralıkta da kesilmesin. AFAD çekicisi
  // 14 günlük pencerelerle ilerlediğinden bu yüksek sınır katalog sorgusunu
  // tek seferde büyütmeden tam tarih aralığını kapsar.
  const afadStatsLimit = isTurkey ? 10000 : limit;
  const [emscRes, usgsRes, afadRes, noaRes] = await Promise.allSettled([
    fetchEMSCRange(startISO, limit, 2.1),
    fetchUSGSRange(startISO, limit, 2.1),
    isTurkey ? fetchAFADRecentRange(startISO, nowISO, afadStatsLimit, 2.1) : Promise.resolve([]),
    readNoaMapArchive()
  ]);

  const fulfilledQuakes: Earthquake[] = [emscRes, usgsRes, afadRes, noaRes].flatMap(result =>
    result.status === 'fulfilled'
      ? (result.value || []).filter((quake): quake is Earthquake => quake !== null)
      : []
  );
  const all = archived.concat(fulfilledQuakes);

  const fetchedAfad = afadRes.status === 'fulfilled' ? afadRes.value : [];
  const afadForProvinceStats = fetchedAfad.length
    ? fetchedAfad
    : all.filter(q => q.provider.toUpperCase() === 'AFAD');
  const turkeyTopProvinces = isTurkey
    ? topTurkeyProvincesFromAFAD(afadForProvinceStats, startMs, 2.0, 8)
    : [];

  const unique = new Map<string, Earthquake>();
  for (const q of all) {
    // NOA 34 günlük sıkıştırılmış arşivden okunur; her istatistik isteğinde
    // yalnızca kullanıcının seçtiği tarih penceresindeki bölümü hesaba kat.
    if (!isQuakeWithinTimeWindow(q, startMs)) continue;
    if (q.magnitude <= 2.0) continue;
    if (isTurkey) {
      const prov = String(q.provider || '').toLowerCase();
      const country = String(q.country || '').toLowerCase();
      const title = String(q.title || '').toLowerCase();

      const inTurkey = prov === 'afad' ||
                       country === 'türkiye' ||
                       country === 'turkey' ||
                       title.includes('turkey') ||
                       title.includes('turkiye') ||
                       (q.lat >= 34.5 && q.lat <= 43.5 && q.lon >= 24.5 && q.lon <= 45.5);
      if (!inTurkey) continue;
    } else {
      const prov = String(q.provider || '').toLowerCase();
      if (prov === 'afad') continue; // Global stats use EMSC, USGS and NOA
    }
    unique.set(q.id, q);
  }

  const candidates = Array.from(unique.values());
  return {
    quakes: deduplicateQuakes(candidates),
    turkeyTopProvinces
  };
}

interface StatsCacheEntry {
  stats: StatisticsResponse;
  timestamp: number;
}

const statsCache = new Map<string, StatsCacheEntry>();
const inFlightStats = new Map<string, Promise<StatisticsResponse>>();
// 10 dk: istatistikler dakikalık hassasiyet gerektirmez; her cache
// kaçırması dış kaynaklardan 3×2000 kayıt + Firestore okuması demek.
const CACHE_TTL_MS = 10 * 60 * 1000;

function median(values: number[]): number {
  if (!values.length) return 0;
  values.sort((a, b) => a - b);
  const middle = Math.floor(values.length / 2);
  return values.length % 2
    ? values[middle]
    : (values[middle - 1] + values[middle]) / 2;
}

function calculateStatistics(
  dataset: StatsDataset,
  rangeHours: number,
  isTurkey: boolean,
  startMs: number,
  bucketMs: number,
  bucketStarts: string[]
): StatisticsResponse {
  const quakes = dataset.quakes;
  const bucketCount = bucketStarts.length;
  const calculationTime = Date.now();
  const stats: StatisticsResponse = {
    updatedAt: new Date(calculationTime).toISOString(),
    rangeHours,
    total7d: quakes.length,
    last24h: 0,
    felt24h: 0,
    maxMagnitude: 0,
    strongestTitle: '',
    strongestTime: null,
    m45plus: 0,
    m60plus: 0,
    avgMagnitude: 0,
    avgDepth: 0,
    medianMagnitude: 0,
    medianDepth: 0,
    magnitudeStdDev: 0,
    totalEnergyJoules: 0,
    bucketStarts,
    dailyCounts: Array(bucketCount).fill(0),
    dailyMaxMag: Array(bucketCount).fill(0),
    magDist: { micro: 0, light: 0, moderate: 0, strong: 0, major: 0 },
    depthDist: { shallow: 0, intermediate: 0, deep: 0 },
    topQuakes: [],
    topCountries: [],
    sourceCounts: { afad: 0, emsc: 0, usgs: 0, noa: 0 }
  };

  let magnitudeSum = 0;
  let depthSum = 0;
  let depthCount = 0;
  const magnitudes: number[] = [];
  const depths: number[] = [];
  const regionCounts = new Map<string, number>();
  const topQuakesByEvent = new Map<string, TopQuakeStat>();

  for (const quake of quakes) {
    const magnitude = Number(quake.magnitude);
    const time = new Date(quake.date).getTime();

    if (calculationTime - time < 86400000) {
      stats.last24h++;
      if (quake.felt && Number(quake.felt) > 0) stats.felt24h++;
    }

    if (magnitude >= stats.maxMagnitude) {
      stats.maxMagnitude = magnitude;
      stats.strongestTitle = quake.title || '';
      stats.strongestTime = new Date(time).toISOString();
    }

    if (magnitude >= 6.0) stats.m60plus++;
    if (magnitude >= 4.5) stats.m45plus++;

    magnitudeSum += magnitude;
    magnitudes.push(magnitude);
    stats.totalEnergyJoules += Math.pow(10, 1.5 * magnitude + 4.8);

    const depth = Number(quake.depth);
    if (Number.isFinite(depth)) {
      depthSum += depth;
      depthCount++;
      depths.push(depth);
      if (depth < 70) stats.depthDist.shallow++;
      else if (depth < 300) stats.depthDist.intermediate++;
      else stats.depthDist.deep++;
    }

    if (magnitude < 3.0) stats.magDist.micro++;
    else if (magnitude < 4.5) stats.magDist.light++;
    else if (magnitude < 6.0) stats.magDist.moderate++;
    else if (magnitude < 7.0) stats.magDist.strong++;
    else stats.magDist.major++;

    const bucketIndex = Math.min(bucketCount - 1, Math.floor((time - startMs) / bucketMs));
    if (bucketIndex >= 0) {
      stats.dailyCounts[bucketIndex]++;
      stats.dailyMaxMag[bucketIndex] = Math.max(stats.dailyMaxMag[bucketIndex], magnitude);
    }

    const provider = String(quake.provider || '').toLowerCase();
    if (provider === 'afad') stats.sourceCounts.afad++;
    else if (provider === 'emsc') stats.sourceCounts.emsc++;
    else if (provider === 'usgs') stats.sourceCounts.usgs++;
    else if (provider === 'noa') stats.sourceCounts.noa++;

    if (!isTurkey) {
      const country = normalizeCountry(quake.country || inferCountry(quake.title, quake.provider));
      const regionName = country ? cleanCountryName(country) : '';
      if (regionName) regionCounts.set(regionName, (regionCounts.get(regionName) || 0) + 1);
    }

    const resolvedProvider = quake.provider || (
      quake.id?.startsWith('usgs-') ? 'USGS' :
      quake.id?.startsWith('emsc-') ? 'EMSC' :
      quake.id?.startsWith('afad-') ? 'AFAD' :
      quake.id?.startsWith('noa-') ? 'NOA' : 'USGS'
    );
    const item: TopQuakeStat = {
      id: quake.id,
      provider: resolvedProvider,
      magnitude,
      place: quake.title || '',
      time: new Date(time).toISOString(),
      lat: Number(quake.lat) || 0,
      lon: Number(quake.lon) || 0,
      depth: Number(quake.depth) || 0
    };
    const timeSlot = Math.floor(time / 300000);
    const placeKey = item.place.slice(0, 15).toLowerCase().replace(/[^a-z0-9]/g, '');
    const eventKey = `${timeSlot}_${placeKey}`;
    const current = topQuakesByEvent.get(eventKey);
    if (!current || current.magnitude < magnitude) topQuakesByEvent.set(eventKey, item);
  }

  stats.avgMagnitude = quakes.length ? Math.round(magnitudeSum / quakes.length * 10) / 10 : 0;
  stats.avgDepth = depthCount ? Math.round(depthSum / depthCount * 10) / 10 : 0;
  stats.medianMagnitude = Math.round(median(magnitudes) * 100) / 100;
  stats.medianDepth = Math.round(median(depths) * 10) / 10;
  const exactMagnitudeMean = magnitudes.length ? magnitudeSum / magnitudes.length : 0;
  const magnitudeVariance = magnitudes.length
    ? magnitudes.reduce((sum, value) => sum + Math.pow(value - exactMagnitudeMean, 2), 0) / magnitudes.length
    : 0;
  stats.magnitudeStdDev = Math.round(Math.sqrt(magnitudeVariance) * 100) / 100;
  stats.topQuakes = Array.from(topQuakesByEvent.values())
    .sort((a, b) => b.magnitude - a.magnitude || new Date(b.time).getTime() - new Date(a.time).getTime())
    .slice(0, 8);
  stats.topCountries = isTurkey
    ? dataset.turkeyTopProvinces
    : Array.from(regionCounts.entries())
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
        .slice(0, 8)
        .map(([name, count]) => ({ name, count }));

  return stats;
}

/// `/`, `/history`, `/map`, `/map-range`, `/aftershocks`, `/faults`, `/stats`
/// uçlarını kaydeder. `db`'ye bağlı referanslar ve arşiv yöneticileri burada,
/// bir kez kurulur; index.ts bu fonksiyonu diğer rota kayıtlarından önce
/// çağırır (bkz. hazard notu, dosya başı).
export function registerEarthquakeRoutes(app: express.Express, db: Firestore): void {
  liveSnapshotRef = db.collection('_public').doc('live_quakes_v1');
  // Yeni belge referansı: önceki referansın ıskası bunu engellemesin.
  liveSnapshotMissAt = 0;
  afadMapArchiveRef = db.collection('_public').doc('afad_map_90d_v1');
  noaMapArchiveRef = db.collection('_public').doc('noa_map_90d_v1');

  afadMapArchiveManager = createMapArchiveManager({
    provider: 'AFAD',
    ref: afadMapArchiveRef,
    days: AFAD_MAP_ARCHIVE_DAYS,
    maxAgeMs: AFAD_MAP_ARCHIVE_MAX_AGE_MS,
    memoryTtlMs: AFAD_MAP_ARCHIVE_MEMORY_TTL_MS,
    fetchRange: (startISO, nowISO) => fetchAFADRecentRange(startISO, nowISO, 20000, 0),
    keepQuake: q => q.magnitude >= 0,
    readFallbackNote: 'doğrudan API yedeğine geçiliyor'
  });

  noaMapArchiveManager = createMapArchiveManager({
    provider: 'NOA',
    ref: noaMapArchiveRef,
    days: NOA_MAP_ARCHIVE_DAYS,
    maxAgeMs: NOA_MAP_ARCHIVE_MAX_AGE_MS,
    memoryTtlMs: NOA_MAP_ARCHIVE_MEMORY_TTL_MS,
    fetchRange: (startISO, nowISO) => fetchNOARange(startISO, nowISO, 20000, -10, 120000, 0),
    keepQuake: q => Number.isFinite(q.magnitude),
    readFallbackNote: 'kısa aralık yedeğine geçiliyor'
  });

  // 1) Canlı depremler
  app.get('/', async (req, res) => {
    try {
      const quakes = await getQuakesOptimized();
      res.setHeader('Cache-Control', 'public, max-age=5, s-maxage=15, stale-while-revalidate=10');
      // 2.1.1+ istemcisi ana sayfa güncelleme banner'ını bu başlıktan açar:
      // zaten yaptığı liste isteğine biner, ayrı sürüm kontrolü yok.
      res.setHeader('X-Sismik-Latest-Version', latestAppVersion());
      // Bilgi kartı revizyonu: istemci yalnızca değişince /info-cards çeker.
      res.setHeader('X-Sismik-Info-Revision', String(infoCardsRevision()));
      // Uzak yapılandırma revizyonu: istemci yalnızca değişince /app-config çeker.
      res.setHeader('X-Sismik-Config-Revision', remoteClientRevision());
      const majorEvent = activeMajorEvent();
      if (majorEvent) res.setHeader('X-Sismik-Major-Event', majorEvent.id);
      if (!quakes.length) {
        res.json(quakes);
        return;
      }
      const { body, etag } = listResponseFor(quakes, listVariantOf(req));
      res.setHeader('ETag', etag);
      if (req.headers['if-none-match'] === etag) {
        res.status(304).end();
        return;
      }
      res.type('application/json').send(body);
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 1a') Büyük olay — istemci liste başlığında yeni kimlik görünce çeker.
  app.get('/major-event', async (_req, res) => {
    try {
      await getQuakesOptimized();
      res.setHeader('Cache-Control', 'public, max-age=15, s-maxage=15');
      res.json({ event: activeMajorEvent() });
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 1a'') Uzak yapılandırma (remote-config.ts) — istemci liste başlığındaki
  // revizyon değişince çeker. Bellekten döner; kendi yayınını yapan örnekte
  // yansıma bayatlamasın diye bilgi kartlarıyla aynı 5 dk'lık tazeleme.
  app.get('/app-config', async (_req, res) => {
    try {
      await freshInfoCards();
      res.setHeader('Cache-Control', 'public, max-age=30, s-maxage=60');
      res.json({ revision: remoteClientRevision(), config: remoteClientConfig() });
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 1a) Bilgi kartları — revizyon değiştiğinde istemci çeker. Bellekten
  // döner; CDN önbelleği ile örnek başına bile istek sayısı küçük kalır.
  app.get('/info-cards', async (_req, res) => {
    try {
      const { revision, cards } = await freshInfoCards();
      res.setHeader('Cache-Control', 'public, max-age=60, s-maxage=120');
      res.json({ revision, cards: publicInfoCards(cards) });
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 1b) Son saat — uygulamanın 90 sn'lik otomatik yenilemesi bunu çeker ve
  // elindeki listeyle birleştirir; tam liste (~45 KB) yalnızca açılışta,
  // çekerek yenilemede ve 10 dakikada bir istenir. Tek adres olduğundan CDN
  // önbelleği aynı verimle çalışır; yanıt ~2-3 KB.
  app.get('/recent', async (req, res) => {
    try {
      const quakes = await getQuakesOptimized();
      res.setHeader('Cache-Control', 'public, max-age=5, s-maxage=15, stale-while-revalidate=10');
      res.setHeader('X-Sismik-Latest-Version', latestAppVersion());
      // Bilgi kartı revizyonu: istemci yalnızca değişince /info-cards çeker.
      res.setHeader('X-Sismik-Info-Revision', String(infoCardsRevision()));
      res.setHeader('X-Sismik-Config-Revision', remoteClientRevision());
      const recentMajorEvent = activeMajorEvent();
      if (recentMajorEvent) res.setHeader('X-Sismik-Major-Event', recentMajorEvent.id);
      const { body, etag } = recentResponseFor(quakes, Date.now(), listVariantOf(req));
      res.setHeader('ETag', etag);
      if (req.headers['if-none-match'] === etag) {
        res.status(304).end();
        return;
      }
      res.type('application/json').send(body);
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 2) Geçmiş
  app.get('/history', async (req, res) => {
    const beforeParam = req.query.before as string;
    const before = beforeParam ? new Date(beforeParam) : new Date();
    if (isNaN(before.getTime())) {
      res.status(400).json({ error: 'Invalid before date' });
      return;
    }

    const limit = Math.min(200, Math.max(20, parseInt(req.query.limit as string || '100', 10) || 100));
    const source = (req.query.source as string || '').toLowerCase();
    const beforeMs = before.getTime();
    const retentionCutoffMs = Date.now() - EARTHQUAKE_RETENTION_MS;

    // 34 günlük sınırdan eski sayfalarda dış sağlayıcılara dahi sorgu gönderme.
    if (beforeMs <= retentionCutoffMs) {
      res.setHeader('Cache-Control', 'public, max-age=300, s-maxage=1800');
      res.json([]);
      return;
    }

    try {
      const isAfadSource = source === 'afad' || source === 'turkiye';
      const isNoaSource = source === 'noa';
      const noaArchive = isNoaSource ? await readNoaMapArchive() : null;
      if (!isAfadSource && !noaArchive?.length && earthquakesArchive.length === 0) {
        await populateArchiveFromApis();
      }
      // Ortak bellek arşivi istatistik odaklı olarak 2.0+ tutuluyor. AFAD
      // seçildiğinde 0.0+ kayıtların kaybolmaması için doğrudan resmî arşiv
      // kullanılır; diğer kaynaklar ortak arşivden yararlanmaya devam eder.
      let all: Earthquake[] = isAfadSource
        ? []
        : (noaArchive?.length ? noaArchive : earthquakesArchive)
            .filter(q => {
              const time = new Date(q.date).getTime();
              return time >= retentionCutoffMs && time < beforeMs;
            });
      if (source) {
        const providerName = source === 'turkiye' ? 'AFAD' : source.toUpperCase();
        all = all.filter(q => q.provider === providerName);
      }

      // Seçili kaynağın kendi arşivi yedek olarak çağrılır
      const endISO = before.toISOString();
      const fallbackStartISO = new Date(Math.max(
        retentionCutoffMs,
        beforeMs - 14 * 86400000
      )).toISOString();
      if (isAfadSource || all.length < limit) {
        if (isAfadSource) {
          all = all.concat(await fetchAFADRecentRange(fallbackStartISO, endISO, limit, 0));
        } else if (source === 'emsc') {
          all = all.concat(await fetchEMSCWindow(endISO, limit, -10));
        } else if (source === 'usgs') {
          all = all.concat(await fetchUSGSWindow(endISO, limit, -10));
        } else if (source === 'noa') {
          all = all.concat(await fetchNOARange(
            fallbackStartISO,
            endISO,
            limit,
            -10,
            15000,
            0
          ));
        } else {
          const [emscRes, usgsRes, noaRes] = await Promise.allSettled([
            fetchEMSCWindow(endISO, limit, -10),
            fetchUSGSWindow(endISO, limit, -10),
            fetchNOARange(
              fallbackStartISO,
              endISO,
              limit,
              -10,
              15000,
              0
            )
          ]);
          if (emscRes.status === 'fulfilled') all = all.concat(emscRes.value);
          if (usgsRes.status === 'fulfilled') all = all.concat(usgsRes.value);
          if (noaRes.status === 'fulfilled') all = all.concat(noaRes.value);
        }
      }

      const unique = new Map<string, Earthquake>();
      for (const q of all) {
        const time = new Date(q.date).getTime();
        if (Number.isFinite(q.magnitude) && time >= retentionCutoffMs && time < beforeMs) {
          unique.set(`${q.provider}:${q.id}`, q);
        }
      }

      const filtered = Array.from(unique.values());
      // Kaynak seçilmişse o sağlayıcının kayıt kimlikleri zaten tekildir;
      // mekânsal tekilleştirme yakın zamanlı ayrı AFAD mikro depremlerini silebilir.
      const deduped = source
        ? filtered.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
        : deduplicateQuakes(filtered);

      // Geçmiş veriler değişmez (immutable): uzun CDN önbelleği güvenlidir ve
      // sonsuz kaydırma isteklerinin çoğunu Firestore'a hiç değdirmeden karşılar.
      res.setHeader('Cache-Control', 'public, max-age=300, s-maxage=1800');
      res.json(filterPublicQuakes(deduped).slice(0, limit).map(stripNullish));
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // 3) Harita Verileri
  app.get('/map', async (req, res) => {
    const days = Math.min(
      EARTHQUAKE_RETENTION_DAYS,
      Math.max(1, parseInt(req.query.days as string || '30', 10) || 30)
    );
    const requestedMinmag = Number(req.query.minmag);
    const minmag = Number.isFinite(requestedMinmag) ? Math.max(0, requestedMinmag) : 0;
    // Uzak yapılandırma değişince (gizlenen deprem/kaynak) önbellek anahtarı da değişir.
    const cacheKey = `v3-${days}-${minmag}-${remoteConfigHash()}`;
    const now = Date.now();

    // Taze önbellek: dış kaynaklara hiç gitme.
    const cached = mapCache.get(cacheKey);
    if (cached && (now - cached.timestamp) < MAP_CACHE_TTL_MS) {
      sendMapCacheEntry(req, res, cached, 'public, max-age=120, s-maxage=600');
      return;
    }

    try {
      let promise = inFlightMap.get(cacheKey);
      if (!promise) {
        promise = computeMapData(days, minmag)
          .then(data => {
            const entry = createMapCacheEntry(filterPublicQuakes(data));
            mapCache.set(cacheKey, entry);
            // Önbellek boyutunu sınırla (en eski girdiler düşer).
            if (mapCache.size > 20) {
              const firstKey = mapCache.keys().next().value;
              if (firstKey !== undefined) mapCache.delete(firstKey);
            }
            return entry;
          })
          .finally(() => inFlightMap.delete(cacheKey));
        inFlightMap.set(cacheKey, promise);
      }

      const entry = await promise;
      sendMapCacheEntry(req, res, entry, 'public, max-age=120, s-maxage=600');
    } catch (error: any) {
      // Hata: süresi dolmuş önbellek varsa boş dönmek yerine onu servis et.
      if (cached) {
        console.error('/map hesaplaması başarısız, stale önbellek servis ediliyor:', error?.message);
        sendMapCacheEntry(req, res, cached, 'public, max-age=30, s-maxage=60');
        return;
      }
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // Harita bölge oynatımı için seçilen tarih aralığını ve çemberi sunucuda
  // sorgular. AFAD/NOA Firestore arşivleri, canlı belge ve küresel FDSN
  // katalogları tekilleştirilmiş tek kronolojik sonuçta birleşir.
  app.get('/map-range', async (req, res) => {
    const request = parseSpatialRangeRequest(req, 2_000, 8, false);
    if (!request) {
      res.status(400).json({
        error: 'Bad request',
        message: 'Geçerli konum ve tarih aralığı gerekli.'
      });
      return;
    }

    const cacheKey = spatialRangeCacheKey(request);
    const cached = spatialRangeCache.get(cacheKey);
    if (cached && Date.now() - cached.timestamp < SPATIAL_RANGE_CACHE_TTL_MS) {
      res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
      res.json(filterPublicQuakes(cached.data).map(stripNullish));
      return;
    }

    try {
      let promise = spatialRangeInFlight.get(cacheKey);
      if (!promise) {
        promise = collectSpatialRange(request)
          .finally(() => spatialRangeInFlight.delete(cacheKey));
        spatialRangeInFlight.set(cacheKey, promise);
      }
      const data = await promise;
      setSpatialRangeCache(cacheKey, data);
      res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
      res.json(filterPublicQuakes(data).map(stripNullish));
    } catch (error: any) {
      if (cached) {
        res.setHeader('Cache-Control', 'public, max-age=30, s-maxage=60');
        res.json(filterPublicQuakes(cached.data).map(stripNullish));
        return;
      }
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });

  // Ana şoka özel artçı adayları. Genel `/map` verisinden farklı olarak dünya
  // kataloğunu koordinat yarıçapıyla sorgular; yoğun dönemlerdeki kayıt limiti
  // artçı dizisinin başını kesemez.
  app.get('/aftershocks', async (req, res) => {
    const request = parseSpatialRangeRequest(req, 500, 5, false);
    if (!request) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }

    const data = filterPublicQuakes(await collectSpatialRange(request));
    // Sayım istenen geniş çemberde değil, ana şokun artçı alanında yapılır
    // (bkz. worker-utils `selectAftershockSequence`).
    const sequence = selectAftershockSequence(data, {
      lat: request.latitude,
      lon: request.longitude,
      start: request.start.getTime(),
      requestedRadiusKm: request.radiusKm
    });
    res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
    res.setHeader('X-Sismik-Aftershock-Radius-Km', String(sequence.radiusKm));
    res.json(sequence.quakes.reverse().map(stripNullish));
  });

  app.get('/faults', (req, res) => {
    const filePath = path.join(__dirname, 'gem_faults_world.geojson');
    if (fs.existsSync(filePath)) {
      sendFaultsFile(req, res, filePath);
    } else {
      const fallbackPath = path.join(__dirname, '..', 'gem_faults_world.geojson');
      if (fs.existsSync(fallbackPath)) {
        sendFaultsFile(req, res, fallbackPath);
      } else {
        res.status(404).json({ error: 'Faults data not found' });
      }
    }
  });

  // 5) İstatistikler
  app.get('/stats', async (req, res) => {
    try {
      const allowedHours = [1, 24, 168, 720];
      const requestedHours = Number.parseInt(req.query.hours as string || '168', 10);
      const rangeHours = allowedHours.includes(requestedHours) ? requestedHours : 168;
      const now = Date.now();
      const durationMs = rangeHours * 3600000;
      const start = new Date(now - durationMs);
      const bucketMs = rangeHours <= 24 ? 3600000 : 86400000;
      const bucketCount = Math.max(1, Math.ceil(durationMs / bucketMs));
      const bucketStarts = Array.from(
        { length: bucketCount },
        (_, index) => new Date(start.getTime() + index * bucketMs).toISOString()
      );

      const isTurkey = req.query.region === 'TR';
      const regionKey = isTurkey ? 'TR' : 'GL';
      const cacheKey = `${rangeHours}-${regionKey}`;
      const isForce = !!req.query.r;

      // Check Memory Cache first
      if (!isForce) {
        const entry = statsCache.get(cacheKey);
        if (entry && (now - entry.timestamp) < CACHE_TTL_MS) {
          res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
          res.json(entry.stats);
          return;
        }
      }

      // Coalesce multiple concurrent requests for the same stats
      let fetchPromise = inFlightStats.get(cacheKey);
      if (!fetchPromise) {
        fetchPromise = (async () => {
          const dataset = await collectStatsQuakes(start, isTurkey);
          const stats = calculateStatistics(
            dataset,
            rangeHours,
            isTurkey,
            start.getTime(),
            bucketMs,
            bucketStarts
          );

          statsCache.set(cacheKey, { stats, timestamp: Date.now() });
          return stats;
        })().finally(() => {
          if (inFlightStats.get(cacheKey) === fetchPromise) inFlightStats.delete(cacheKey);
        });

        inFlightStats.set(cacheKey, fetchPromise);
      }

      try {
        const result = await fetchPromise;
        res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=600');
        res.json(result);
      } catch (statsError: any) {
        // Hesaplama başarısız: süresi dolmuş önbellek varsa onu servis et
        // (uygulama boş ekran yerine biraz eski istatistik görür).
        const stale = statsCache.get(cacheKey);
        if (stale) {
          console.error('/stats hesaplaması başarısız, stale önbellek servis ediliyor:', statsError?.message);
          res.setHeader('Cache-Control', 'public, max-age=30, s-maxage=60');
          res.json(stale.stats);
        } else {
          throw statsError;
        }
      }
    } catch (error: any) {
      res.status(500).json({ error: 'Internal Server Error', message: error.message });
    }
  });
}
