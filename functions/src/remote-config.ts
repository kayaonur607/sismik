// MARK: - Uzak yapılandırma
//
// Önemli bir olayda ya da bir hata görüldüğünde uygulama güncellemesi
// beklemeden müdahale etmek için tek belge: `_system/remote_config_v1`.
// Firebase konsolundan (ya da `Scripts/remote-config.mjs` ile) düzenlenir;
// kaydedildikten sonra en geç ~1 dk içinde sunucuda, ~2 dk içinde uygulamada
// etkili olur. Revizyon elle artırılmaz: içerikten hesaplanır.
//
// Belge iki bölümdür:
//   - `server`: sunucunun davranışı (tüm uygulama sürümlerini etkiler):
//     bildirimleri/tsunamiyi/X paylaşımını/Canlı Etkinliği duraklatma, büyük
//     olayı kapatma, bir kaynağı ya da hatalı bir depremi her yerden gizleme.
//   - `client`: uygulamanın (2.1.4+) davranışı: özellik anahtarları, kart ve
//     "deprem anı" eşikleri, yenileme aralığı, tekilleştirme eşikleri, liste
//     başı duyuru, zorunlu güncelleme.
//
// Maliyet: belgeyi yalnızca yayın yapan süreç (dakikalık tur) en fazla
// dakikada bir okur (+~1.440 okuma/gün). Değişince içerik, API örneklerinin
// zaten okuduğu canlı anlık görüntü belgesine (`_public/live_quakes_v1`)
// yansıtılır; kullanıcı sayısı kaç olursa olsun ek okuma yoktur. Uygulama
// revizyonu liste yanıtının `X-Sismik-Config-Revision` başlığından öğrenir ve
// yalnızca değişince `/app-config` çeker.
//
// Güvenlik: bilinmeyen alanlar atılır, sayılar makul aralığa kırpılır, hatalı
// tipte alan yok sayılır. Bozuk bir belge hiçbir zaman mevcut davranışı
// bozmaz; en kötü durumda o alan varsayılana döner.

import { createHash } from 'crypto';
import type { DocumentData, Firestore } from 'firebase-admin/firestore';
import type { Earthquake } from './worker-utils';

export const REMOTE_CONFIG_COLLECTION = '_system';
export const REMOTE_CONFIG_DOC = 'remote_config_v1';

export interface ServerRemoteConfig {
  /// Deprem bildirimlerini tamamen durdurur (yanlış bildirim fırtınası vb.).
  push_paused: boolean;
  /// Tsunami bildirimlerini durdurur.
  tsunami_paused: boolean;
  /// Otomatik X paylaşımını durdurur.
  twitter_paused: boolean;
  /// Canlı Etkinlik kanalı açma ve yayınlarını durdurur.
  live_activity_paused: boolean;
  /// Büyük olay kartını/kanalını tamamen kapatır.
  major_event_disabled: boolean;
  /// Bu kimliklerdeki büyük olay kapanır ve yeniden açılmaz.
  major_event_suppress: string[];
  /// Bu kaynakların kayıtları liste, harita, bildirim ve X'ten düşer
  /// (AFAD, KANDILLI, EMSC, USGS, NOA, JMA, CENC, BMKG, GEONET).
  disabled_sources: string[];
  /// Bu deprem kimlikleri her yerden gizlenir (hatalı/sahte kayıt).
  hidden_quakes: string[];
}

export type LocalizedText = Record<string, string>;

export interface ClientNotice {
  id: string;
  tint?: string;
  icon?: string;
  title: LocalizedText;
  body?: LocalizedText;
  url?: string;
  min_version?: string;
  max_version?: string;
  start_at?: string;
  end_at?: string;
  dismissible?: boolean;
}

export interface ClientRemoteConfig {
  /// Bu sürümden eski uygulama güncelleme ekranıyla açılır.
  min_version?: string;
  notice?: ClientNotice;
  features?: Record<string, boolean>;
  hidden_sources?: string[];
  felt_card?: Record<string, number>;
  strong_quake?: Record<string, number>;
  refresh?: Record<string, number>;
  dedupe?: Record<string, number>;
}

export interface RemoteConfig {
  server: ServerRemoteConfig;
  client: ClientRemoteConfig;
}

export const DEFAULT_SERVER_CONFIG: ServerRemoteConfig = Object.freeze({
  push_paused: false,
  tsunami_paused: false,
  twitter_paused: false,
  live_activity_paused: false,
  major_event_disabled: false,
  major_event_suppress: [],
  disabled_sources: [],
  hidden_quakes: []
}) as ServerRemoteConfig;

export const KNOWN_SOURCES = ['AFAD', 'KANDILLI', 'EMSC', 'USGS', 'NOA', 'JMA', 'CENC', 'BMKG', 'GEONET'];

/// İstemcide açılıp kapatılabilen özellikler (varsayılan: açık).
export const CLIENT_FEATURES = [
  'felt_card',
  'live_activity',
  'ai_analysis',
  'strong_quake_screen',
  'felt_reports',
  'info_cards',
  'background_location',
  'major_event_card'
];

/// Sayısal ayarların izinli aralıkları. Aralık dışı değer kırpılır; sayı
/// değilse alan atılır ve uygulama kendi varsayılanını kullanır.
export const CLIENT_NUMBER_RANGES: Record<string, Record<string, [number, number]>> = {
  felt_card: {
    nearby_radius_km: [5, 200],
    nearby_min_magnitude: [1, 7],
    nearby_window_hours: [0.5, 48],
    felt_min_magnitude: [3, 9],
    felt_min_mmi: [2, 8],
    felt_window_hours: [1, 72]
  },
  strong_quake: {
    min_magnitude: [3, 9],
    max_distance_km: [10, 1000],
    max_age_hours: [0.25, 24]
  },
  refresh: {
    interval_seconds: [15, 600],
    full_interval_seconds: [120, 3600]
  },
  dedupe: {
    seconds: [10, 300],
    km: [5, 100],
    wide_seconds: [5, 120],
    wide_km: [10, 150]
  }
};

const NOTICE_TINTS = ['orange', 'green', 'blue', 'red', 'purple', 'teal', 'yellow'];
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const VERSION_PATTERN = /^\d+(\.\d+){0,2}$/;
const MAX_LIST = 200;

// MARK: Doğrulama

function bool(value: unknown): boolean {
  return value === true;
}

function idList(value: unknown, normalize: (item: string) => string = item => item): string[] {
  if (!Array.isArray(value)) return [];
  const out = new Set<string>();
  for (const item of value) {
    if (typeof item !== 'string') continue;
    const trimmed = normalize(item.trim());
    if (ID_PATTERN.test(trimmed)) out.add(trimmed);
    if (out.size >= MAX_LIST) break;
  }
  return [...out];
}

function localized(value: unknown, maxLength: number): LocalizedText | undefined {
  if (typeof value === 'string' && value.trim()) return { en: value.trim().slice(0, maxLength) };
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const out: LocalizedText = {};
  for (const [lang, text] of Object.entries(value as Record<string, unknown>)) {
    if (!/^[a-z]{2}(-[A-Za-z]{2,4})?$/.test(lang) || typeof text !== 'string' || !text.trim()) continue;
    out[lang] = text.trim().slice(0, maxLength);
  }
  return Object.keys(out).length ? out : undefined;
}

function version(value: unknown): string | undefined {
  return typeof value === 'string' && VERSION_PATTERN.test(value.trim()) ? value.trim() : undefined;
}

function isoDate(value: unknown): string | undefined {
  if (typeof value === 'string' && Number.isFinite(Date.parse(value))) return new Date(Date.parse(value)).toISOString();
  // Konsoldan girilen Firestore Timestamp.
  const seconds = (value as { seconds?: unknown; _seconds?: unknown } | null)?.seconds
    ?? (value as { _seconds?: unknown } | null)?._seconds;
  return typeof seconds === 'number' ? new Date(seconds * 1000).toISOString() : undefined;
}

function sanitizeNotice(value: unknown): ClientNotice | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const id = typeof raw.id === 'string' && ID_PATTERN.test(raw.id.trim()) ? raw.id.trim() : undefined;
  const title = localized(raw.title, 120);
  if (!id || !title) return undefined;
  const notice: ClientNotice = { id, title };
  const body = localized(raw.body, 600);
  if (body) notice.body = body;
  if (typeof raw.tint === 'string' && NOTICE_TINTS.includes(raw.tint)) notice.tint = raw.tint;
  if (typeof raw.icon === 'string' && /^[a-z0-9.]{1,64}$/.test(raw.icon)) notice.icon = raw.icon;
  if (typeof raw.url === 'string' && /^(https:\/\/|sismik:\/\/)\S{1,500}$/.test(raw.url.trim())) notice.url = raw.url.trim();
  const minVersion = version(raw.min_version);
  const maxVersion = version(raw.max_version);
  if (minVersion) notice.min_version = minVersion;
  if (maxVersion) notice.max_version = maxVersion;
  const startAt = isoDate(raw.start_at);
  const endAt = isoDate(raw.end_at);
  if (startAt) notice.start_at = startAt;
  if (endAt) notice.end_at = endAt;
  if (raw.dismissible === false) notice.dismissible = false;
  return notice;
}

function sanitizeNumbers(value: unknown, ranges: Record<string, [number, number]>): Record<string, number> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const out: Record<string, number> = {};
  for (const [key, [min, max]] of Object.entries(ranges)) {
    const number = (value as Record<string, unknown>)[key];
    if (typeof number !== 'number' || !Number.isFinite(number)) continue;
    out[key] = Math.min(max, Math.max(min, number));
  }
  return Object.keys(out).length ? out : undefined;
}

export function sanitizeServerConfig(value: unknown): ServerRemoteConfig {
  const raw = (value && typeof value === 'object' && !Array.isArray(value) ? value : {}) as Record<string, unknown>;
  return {
    push_paused: bool(raw.push_paused),
    tsunami_paused: bool(raw.tsunami_paused),
    twitter_paused: bool(raw.twitter_paused),
    live_activity_paused: bool(raw.live_activity_paused),
    major_event_disabled: bool(raw.major_event_disabled),
    major_event_suppress: idList(raw.major_event_suppress),
    disabled_sources: idList(raw.disabled_sources, item => item.toUpperCase())
      .filter(source => KNOWN_SOURCES.includes(source)),
    hidden_quakes: idList(raw.hidden_quakes)
  };
}

export function sanitizeClientConfig(value: unknown): ClientRemoteConfig {
  const raw = (value && typeof value === 'object' && !Array.isArray(value) ? value : {}) as Record<string, unknown>;
  const client: ClientRemoteConfig = {};
  const minVersion = version(raw.min_version);
  if (minVersion) client.min_version = minVersion;
  const notice = sanitizeNotice(raw.notice);
  if (notice) client.notice = notice;
  if (raw.features && typeof raw.features === 'object' && !Array.isArray(raw.features)) {
    const features: Record<string, boolean> = {};
    for (const key of CLIENT_FEATURES) {
      const flag = (raw.features as Record<string, unknown>)[key];
      if (typeof flag === 'boolean') features[key] = flag;
    }
    if (Object.keys(features).length) client.features = features;
  }
  const hidden = idList(raw.hidden_sources, item => item.toUpperCase()).filter(source => KNOWN_SOURCES.includes(source));
  if (hidden.length) client.hidden_sources = hidden;
  for (const [section, ranges] of Object.entries(CLIENT_NUMBER_RANGES)) {
    const numbers = sanitizeNumbers(raw[section], ranges);
    if (numbers) (client as Record<string, unknown>)[section] = numbers;
  }
  return client;
}

export function sanitizeRemoteConfig(data: DocumentData | undefined): RemoteConfig {
  return {
    server: sanitizeServerConfig(data?.server),
    client: sanitizeClientConfig(data?.client)
  };
}

/// Anahtar sırasından bağımsız JSON (konsol alanları farklı sırayla
/// kaydedebilir; aynı içerik aynı revizyonu vermeli).
function stableStringify(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value as object).sort()
      .map(key => `${JSON.stringify(key)}:${stableStringify((value as Record<string, unknown>)[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export function configHash(value: unknown): string {
  return createHash('sha256').update(stableStringify(value)).digest('hex').slice(0, 12);
}

// MARK: Süreç içi durum

let dbRef: Firestore | undefined;
let current: RemoteConfig = { server: DEFAULT_SERVER_CONFIG, client: {} };
let currentHash = configHash(current);
let clientRevision = configHash(current.client);
/// Kaynak belgenin bu süreçte en son okunduğu an (0: bu süreç okumuyor,
/// yalnızca anlık görüntüdeki yansımayı kullanıyor).
let sourceReadAt = 0;
let sourceInFlight: Promise<void> | undefined;
const SOURCE_TTL_MS = 60_000;

export function initRemoteConfig(db: Firestore): void {
  dbRef = db;
}

function apply(next: RemoteConfig, origin: string): void {
  const hash = configHash(next);
  if (hash === currentHash) return;
  const previous = current.server;
  current = next;
  currentHash = hash;
  clientRevision = configHash(next.client);
  logServerChanges(previous, next.server, origin);
}

function logServerChanges(previous: ServerRemoteConfig, next: ServerRemoteConfig, origin: string): void {
  const changes: string[] = [];
  for (const key of Object.keys(next) as Array<keyof ServerRemoteConfig>) {
    if (stableStringify(previous[key]) !== stableStringify(next[key])) {
      changes.push(`${key}=${JSON.stringify(next[key])}`);
    }
  }
  console.log(`Uzak yapılandırma güncellendi (${origin}, ${currentHash})${changes.length ? `: ${changes.join(', ')}` : '.'}`);
}

/// Yayın yapan süreçler için: kaynak belgeyi en fazla dakikada bir okur.
/// Okuma başarısızsa bilinen son yapılandırma geçerli kalır.
export async function refreshRemoteConfigFromSource(force = false): Promise<void> {
  if (!dbRef) return;
  if (!force && Date.now() - sourceReadAt < SOURCE_TTL_MS) return;
  if (sourceInFlight) return sourceInFlight;
  sourceInFlight = (async () => {
    try {
      const snapshot = await dbRef!.collection(REMOTE_CONFIG_COLLECTION).doc(REMOTE_CONFIG_DOC).get();
      apply(sanitizeRemoteConfig(snapshot.data()), 'belge');
    } catch (error: any) {
      console.error('Uzak yapılandırma okunamadı; son bilinen değer geçerli:', error?.message || error);
    } finally {
      sourceReadAt = Date.now();
      sourceInFlight = undefined;
    }
  })();
  return sourceInFlight;
}

/// Anlık görüntüye yazılacak yansıma alanları.
export function remoteConfigMirrorFields(): { remote_config: string; remote_config_hash: string } {
  return { remote_config: JSON.stringify(current), remote_config_hash: currentHash };
}

/// API örnekleri: anlık görüntüdeki yansımayı alır. Kaynağı kendisi okuyan
/// süreçte (yakın zamanda) yansıma yok sayılır — yansıma o süreçten eski olabilir.
export function absorbRemoteConfigMirror(data: DocumentData | undefined): void {
  if (!data || typeof data.remote_config !== 'string') return;
  if (sourceReadAt && Date.now() - sourceReadAt < 5 * SOURCE_TTL_MS) return;
  if (data.remote_config_hash === currentHash) return;
  try {
    const parsed = JSON.parse(data.remote_config);
    apply({ server: sanitizeServerConfig(parsed?.server), client: sanitizeClientConfig(parsed?.client) }, 'yansıma');
  } catch (error: any) {
    console.error('Uzak yapılandırma yansıması çözülemedi:', error?.message || error);
  }
}

export function remoteServerConfig(): ServerRemoteConfig {
  return current.server;
}

export function remoteClientConfig(): ClientRemoteConfig {
  return current.client;
}

export function remoteConfigHash(): string {
  return currentHash;
}

export function remoteClientRevision(): string {
  return clientRevision;
}

/// Testler için: süreç durumunu verilen yapılandırmaya ayarlar.
export function setRemoteConfigForTesting(raw: DocumentData | undefined): void {
  sourceReadAt = 0;
  apply(sanitizeRemoteConfig(raw), 'test');
}

// MARK: Uygulama

const filteredViews = new WeakMap<readonly Earthquake[], { hash: string; view: Earthquake[] }>();

/// Gizlenen kaynak ve depremleri düşürür. Filtre yoksa aynı diziyi döndürür;
/// aynı dizi ve yapılandırma için bir kez hesaplanır.
export function filterPublicQuakes<T extends Pick<Earthquake, 'id' | 'provider'>>(quakes: T[]): T[] {
  const { disabled_sources: sources, hidden_quakes: hidden } = current.server;
  if (!sources.length && !hidden.length) return quakes;
  const cached = filteredViews.get(quakes as unknown as Earthquake[]);
  if (cached?.hash === currentHash) return cached.view as unknown as T[];
  const sourceSet = new Set(sources);
  const hiddenSet = new Set(hidden);
  const view = quakes.filter(quake =>
    !hiddenSet.has(String(quake.id)) && !sourceSet.has(String(quake.provider || '').toUpperCase()));
  filteredViews.set(quakes as unknown as Earthquake[], { hash: currentHash, view: view as unknown as Earthquake[] });
  return view;
}

export function isMajorEventSuppressed(id: string | undefined | null): boolean {
  const server = current.server;
  return server.major_event_disabled || Boolean(id && server.major_event_suppress.includes(id));
}
