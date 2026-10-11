import axios from 'axios';
import { Earthquake, optionalFiniteNumber } from './worker-utils';

/// EMSC resmi gerçek zamanlı WebSocket uç noktası
export const EMSC_WEBSOCKET_URL = 'wss://www.seismicportal.eu/standing_order/websocket';

export interface IngestionOptions {
  emscWebSocketUrl?: string;
  autoReconnect?: boolean;
  maxReconnectDelayMs?: number;
}

export type EarthquakeHandler = (quake: Earthquake, isRevision: boolean) => Promise<void> | void;

/**
 * EMSC WebSocket GeoJSON Feature parser.
 * Tek bir GeoJSON Feature nesnesini Sismik Earthquake modeline dönüştürür.
 */
export function parseEMSCFeature(feature: any): Earthquake | null {
  if (!feature || typeof feature !== 'object') return null;
  const props = feature.properties;
  const geom = feature.geometry;
  if (!props || !geom || !Array.isArray(geom.coordinates)) return null;

  const magnitude = Number(props.mag);
  const lat = Number(geom.coordinates[1]);
  const lon = Number(geom.coordinates[0]);
  if (!Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) return null;

  const depth = Number.isFinite(Number(props.depth))
    ? Number(props.depth)
    : (Number.isFinite(Number(geom.coordinates[2])) ? Number(geom.coordinates[2]) : 0);
  const time = props.time ? new Date(props.time) : null;
  if (!time || isNaN(time.getTime())) return null;

  const rawLastUpdate = props.lastupdate ? new Date(props.lastupdate) : null;
  const updatedAt = rawLastUpdate && !isNaN(rawLastUpdate.getTime()) ? rawLastUpdate.toISOString() : null;

  return {
    id: `emsc-${feature.id || props.source_id || props.unid}`,
    provider: 'EMSC',
    title: props.flynn_region || 'Bilinmeyen Bölge',
    magnitude,
    depth,
    lat,
    lon,
    date: time.toISOString(),
    closestCity: null,
    epiCenter: null,
    magType: props.magtype || null,
    updatedAt,
    sourceURL: props.unid ? `https://www.emsc-csem.org/Earthquake_information/earthquake.php?id=${encodeURIComponent(String(props.unid))}` : null,
    network: props.auth || null,
    code: props.source_id || feature.id || null,
    eventType: props.evtype || 'earthquake',
    author: props.auth || null,
    catalog: props.source_catalog || 'EMSC',
    revised: false
  };
}

/**
 * EMSC WebSocket Gerçek Zamanlı Ingestion İstemcisi.
 * Node.js 22 built-in WebSocket API'sini kullanarak EMSC'den gelen anlık depremleri dinler.
 * Kopma durumunda eksponansiyel backoff ile otomatik olarak yeniden bağlanır.
 */
export class EMSCWebSocketIngestor {
  private ws: any = null;
  private isRunning = false;
  private reconnectAttempts = 0;
  private reconnectTimer: any = null;
  private heartbeatWatchdog: any = null;
  private url: string;
  private autoReconnect: boolean;
  private maxReconnectDelayMs: number;
  private handlers: Set<EarthquakeHandler> = new Set();
  private seenQuakes: Map<string, { magnitude: number; at: number }> = new Map();

  constructor(options: IngestionOptions = {}) {
    this.url = options.emscWebSocketUrl || EMSC_WEBSOCKET_URL;
    this.autoReconnect = options.autoReconnect !== false;
    this.maxReconnectDelayMs = options.maxReconnectDelayMs || 30_000;
  }

  onEarthquake(handler: EarthquakeHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    this.connect();
  }

  stop(): void {
    this.isRunning = false;
    this.clearTimers();
    if (this.ws) {
      try {
        this.ws.close();
      } catch {}
      this.ws = null;
    }
  }

  get connected(): boolean {
    return this.ws !== null && this.ws.readyState === 1; // 1 = OPEN
  }

  private connect(): void {
    if (!this.isRunning) return;
    this.clearTimers();

    try {
      // Node.js 22 built-in global WebSocket
      if (typeof WebSocket === 'undefined') {
        console.error('EMSC WebSocket: Global WebSocket runtime desteği bulunamadı');
        return;
      }

      this.ws = new WebSocket(this.url);

      this.ws.onopen = () => {
        this.reconnectAttempts = 0;
        this.resetHeartbeat();
        console.log(`EMSC Gerçek zamanlı WebSocket bağlantısı açıldı: ${this.url}`);
      };

      this.ws.onmessage = (event: any) => {
        this.resetHeartbeat();
        this.handleMessage(event.data);
      };

      this.ws.onerror = (err: any) => {
        console.warn('EMSC WebSocket hata:', err?.message || err);
      };

      this.ws.onclose = () => {
        this.ws = null;
        if (this.isRunning && this.autoReconnect) {
          this.scheduleReconnect();
        }
      };
    } catch (error: any) {
      console.error('EMSC WebSocket bağlantı denemesi başarısız:', error?.message || error);
      if (this.isRunning && this.autoReconnect) {
        this.scheduleReconnect();
      }
    }
  }

  private handleMessage(rawData: any): void {
    try {
      const text = typeof rawData === 'string' ? rawData : rawData.toString();
      const payload = JSON.parse(text);

      const action = payload.action;
      const data = payload.data;
      if (!data) return;

      const quake = parseEMSCFeature(data);
      if (!quake) return;

      const now = Date.now();
      const existing = this.seenQuakes.get(quake.id);
      let isRevision = action === 'update';

      if (existing) {
        const magDelta = Math.abs(quake.magnitude - existing.magnitude);
        // Son 10 dakika içinde aynı veya neredeyse aynı büyüklükte (< 0.3) gelen mükerrer EMSC paketini yut
        if (now - existing.at < 10 * 60 * 1000 && magDelta < 0.3) {
          return;
        }
        // Eğer büyüklük belirgin biçimde değiştiyse (>= 0.3) gerçek bir revizyondur
        if (magDelta >= 0.3) {
          isRevision = true;
        }
      }

      this.seenQuakes.set(quake.id, { magnitude: quake.magnitude, at: now });
      if (this.seenQuakes.size > 1000) {
        const cutoff = now - 15 * 60 * 1000;
        for (const [id, item] of this.seenQuakes) {
          if (item.at < cutoff || this.seenQuakes.size > 800) {
            this.seenQuakes.delete(id);
          }
        }
      }

      for (const handler of this.handlers) {
        try {
          const res = handler(quake, isRevision);
          if (res && typeof res.catch === 'function') {
            res.catch(err => console.error('Deprem dinleyici işleme hatası:', err));
          }
        } catch (handlerErr) {
          console.error('Deprem dinleyici senkron hatası:', handlerErr);
        }
      }
    } catch (parseErr) {
      // Heartbeat veya format dışı mesajları sessizce karşıla
    }
  }

  private resetHeartbeat(): void {
    if (this.heartbeatWatchdog) clearTimeout(this.heartbeatWatchdog);
    // 90 saniye içinde mesaj gelmezse bağlantıyı tazelemek için kapatır
    this.heartbeatWatchdog = setTimeout(() => {
      if (this.isRunning && this.ws) {
        console.warn('EMSC WebSocket watchdog zaman aşımı (90s hareketsizlik), yeniden bağlanılıyor...');
        try { this.ws.close(); } catch {}
      }
    }, 90_000);
  }

  private scheduleReconnect(): void {
    this.reconnectAttempts++;
    const delay = Math.min(1000 * Math.pow(1.5, this.reconnectAttempts - 1), this.maxReconnectDelayMs);
    this.reconnectTimer = setTimeout(() => {
      if (this.isRunning) this.connect();
    }, delay);
  }

  private clearTimers(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.heartbeatWatchdog) {
      clearTimeout(this.heartbeatWatchdog);
      this.heartbeatWatchdog = null;
    }
  }
}

/**
 * Koşullu (ETag / If-Modified-Since) USGS saatlik veri çekicisi.
 * Sunucu 304 döndüğünde veri transferini ve CPU ayrıştırmasını sıfırlar.
 */
let usgsLastETag: string | null = null;
let usgsLastModified: string | null = null;
/// Son 200 yanıtının listesi. ETag durumu süreç genelinde ortak: anlık
/// yoklayıcı değişikliği önce görünce hızlı tarama 304 alıp BOŞ liste
/// görüyordu (USGS depremleri yalnızca tam turda yakalanıyordu).
let usgsLastQuakes: Earthquake[] = [];

export async function fetchUSGSWithETag(timeoutMs = 5000): Promise<{ notModified: boolean; quakes: Earthquake[] }> {
  const url = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson';
  const headers: Record<string, string> = {
    'User-Agent': 'Sismik/2.1 (+https://sismik-app.web.app; sismikapplication@gmail.com)'
  };
  if (usgsLastETag) headers['If-None-Match'] = usgsLastETag;
  if (usgsLastModified) headers['If-Modified-Since'] = usgsLastModified;

  try {
    const response = await axios.get(url, {
      timeout: timeoutMs,
      headers,
      validateStatus: status => (status >= 200 && status < 300) || status === 304
    });

    if (response.status === 304) {
      return { notModified: true, quakes: usgsLastQuakes };
    }

    if (response.headers.etag) usgsLastETag = response.headers.etag;
    if (response.headers['last-modified']) usgsLastModified = response.headers['last-modified'];

    const data = response.data;
    if (!data || !Array.isArray(data.features)) return { notModified: false, quakes: [] };

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
        title: props.place || 'Bilinmeyen Bölge',
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
        eventType: props.type || 'earthquake',
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

    usgsLastQuakes = quakes;
    return { notModified: false, quakes };
  } catch (error: any) {
    return { notModified: false, quakes: [] };
  }
}

/**
 * USGS Gerçek Zamanlı Ingestion Poller.
 * USGS resmi bir public WebSocket sunmadığı için, USGS'in önerdiği resmi yöntem olan
 * saatlik GeoJSON feed'ini HTTP ETag / If-None-Match koşullu başlıklarıyla 15 saniyede bir
 * sorgular. Veri değişmediğinde sunucu 304 Not Modified döner ve sıfır bant genişliği tüketir.
 * Yeni bir deprem tespit edildiğinde dinleyicilere anında iletilir.
 */
export class USGSRealtimePoller {
  private timer: any = null;
  private isRunning = false;
  private intervalMs: number;
  private seenQuakeIds: Set<string> = new Set();
  private handlers: Set<EarthquakeHandler> = new Set();

  constructor(intervalMs = 15_000) {
    this.intervalMs = intervalMs;
  }

  onEarthquake(handler: EarthquakeHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  start(): void {
    if (this.isRunning) return;
    this.isRunning = true;
    this.poll();
  }

  stop(): void {
    this.isRunning = false;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  get running(): boolean {
    return this.isRunning;
  }

  async poll(): Promise<void> {
    if (!this.isRunning) return;
    try {
      const res = await fetchUSGSWithETag(4000);
      if (!res.notModified && res.quakes.length > 0) {
        for (const q of res.quakes) {
          if (!this.seenQuakeIds.has(q.id)) {
            this.seenQuakeIds.add(q.id);
            if (this.seenQuakeIds.size > 1000) {
              const oldest = Array.from(this.seenQuakeIds).slice(0, 200);
              for (const id of oldest) this.seenQuakeIds.delete(id);
            }
            for (const handler of this.handlers) {
              try {
                const r = handler(q, false);
                if (r && typeof r.catch === 'function') r.catch(() => {});
              } catch (err) {
                console.error('USGS poller dinleyici hatası:', err);
              }
            }
          }
        }
      }
    } catch {
      // Ağ hatalarında sessizce devam et
    } finally {
      if (this.isRunning) {
        this.timer = setTimeout(() => this.poll(), this.intervalMs);
      }
    }
  }
}
