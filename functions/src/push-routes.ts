import { gzipSync, gunzipSync } from 'node:zlib';
import * as admin from 'firebase-admin';
import { DocumentData, DocumentReference, FieldValue, Filter, Firestore } from 'firebase-admin/firestore';
import {
  Earthquake,
  DevicePrefs,
  CachedPushDevice,
  selectFreshQuakes,
  selectFastestQuakes,
  orderQuakesForDelivery,
  placesFromDeviceData,
  legacyRulesFromDeviceData,
  notificationMatch,
  shouldDeliverDuplicate,
  findMagnitudeRevisions,
  magnitudeRevisionDecision,
  DeliveredQuakeSnapshot,
  MAGNITUDE_CORRECTION_WINDOW_MS,
  applyPushDeviceDelta,
  QuakeFingerprint,
  toQuakeFingerprint,
  isPushDuplicateOf,
  NotificationMatch,
  NotificationMatchReason,
  isTurkeyFastLaneQuake,
  notificationPlaceLabel,
  effectivePushPrefs,
  isPushCandidate,
  getDistanceKm
} from './worker-utils';
import {
  buildNotificationContent,
  NotificationContent,
  NotificationStyle,
  normalizeNotificationStyle,
  QUAKE_FEEDBACK_CATEGORY,
  STRONG_QUAKE_MAGNITUDE,
  TemplateKind
} from './notification-templates';
import {
  collectQuakes,
  collectRecentQuakesForPush,
  publishFreshQuakes,
  publishFullLiveSnapshot,
  publishScanQuakes,
  isProviderUnavailableForPush
} from './earthquake-routes';
import { SpatialGridIndex } from './spatial-index';
import {
  TsunamiAlert,
  TSUNAMI_ALERT_MAX_AGE_MS,
  alertsFromQuakes,
  buildTsunamiNotification,
  fetchNOAATsunamiAlerts,
  tsunamiAlertRadiusKm
} from './tsunami-alerts';
import {
  ApnsSendOutcome,
  apnsConfigured,
  apnsTargetOf,
  attachApnsTarget,
  sendApnsNotification,
  sendApnsNotifications
} from './apns';
export { attachApnsTarget, withApnsTarget } from './apns';
import { EMSCWebSocketIngestor, USGSRealtimePoller } from './realtime-ingestion';
import { filterPublicQuakes, refreshRemoteConfigFromSource, remoteServerConfig } from './remote-config';

// MARK: - Push bildirim rotaları ve zamanlanmış push görevi

const spatialGridIndex = new SpatialGridIndex();
let emscIngestor: EMSCWebSocketIngestor | null = null;
let usgsPoller: USGSRealtimePoller | null = null;

let deviceRegistryRef!: DocumentReference<DocumentData>;
let pushDeliveryStateRef!: DocumentReference<DocumentData>;
let pushDeviceSnapshotRef!: DocumentReference<DocumentData>;

/// Gerçek zamanlı alım YALNIZCA `scheduledPushCheck` servisinde başlatılır
/// (bkz. index.ts): tek örnekli, teslim durumu ve cihaz önbelleği zaten o
/// süreçte sıcak. Her HTTP/bakım örneğinde ayrı bir alıcı çalıştığında aynı
/// deprem üç serviste işleniyor, her soğuk açılış tüm premium cihazları
/// yeniden okuyordu.
export function startRealtimeIngestion(
  db: Firestore,
  /// Anlık gelen kayıt otomatik Twitter paylaşımına da verilir (en hızlı kaynak).
  onQuakes?: (quakes: Earthquake[], now: number) => Promise<void>
): () => void {
  if (emscIngestor || usgsPoller) {
    return () => {
      emscIngestor?.stop();
      emscIngestor = null;
      usgsPoller?.stop();
      usgsPoller = null;
    };
  }

  // 1. EMSC Gerçek Zamanlı WebSocket İstemcisi
  emscIngestor = new EMSCWebSocketIngestor();
  emscIngestor.onEarthquake(async (quake, isRevision) => {
    try {
      console.log(`[EMSC WebSocket Ingestion] Anlık deprem alındı: ${quake.id} (M${quake.magnitude}) - ${quake.title}`);
      if (!isRevision) void publishFreshQuakes([quake]);
      void onQuakes?.([quake], Date.now());
      await enqueuePushPass(db, [quake], isRevision, 'emsc-websocket');
      await flushPushDeliveryState();
    } catch (err: any) {
      console.error('EMSC WebSocket anlık push işleme hatası:', err?.message || err);
    }
  });
  emscIngestor.start();

  // 2. USGS Gerçek Zamanlı ETag Poller (15s aralıklı, 304 koşullu sıfır maliyet)
  usgsPoller = new USGSRealtimePoller(15_000);
  usgsPoller.onEarthquake(async (quake) => {
    try {
      console.log(`[USGS Realtime Poller] Anlık deprem alındı: ${quake.id} (M${quake.magnitude}) - ${quake.title}`);
      void publishFreshQuakes([quake]);
      void onQuakes?.([quake], Date.now());
      await enqueuePushPass(db, [quake], false, 'usgs-realtime');
      await flushPushDeliveryState();
    } catch (err: any) {
      console.error('USGS anlık push işleme hatası:', err?.message || err);
    }
  });
  usgsPoller.start();

  return () => {
    emscIngestor?.stop();
    emscIngestor = null;
    usgsPoller?.stop();
    usgsPoller = null;
  };
}

/// Teslim durumunu (`push_delivery_v1`) ve cihaz snapshot'ını yalnızca
/// dakikalık tur yazar. `fastPushScan` ayrı bir süreç: kendi bellek
/// defteriyle aynı belgeleri üzerine yazıyor, dakikalık turun işlenmiş
/// listesini ve büyüklük düzeltme kayıtlarını siliyordu. Hızlı tarama
/// belgeyi yalnızca soğuk açılışta okur; servisler arası tekrar koruması
/// ortak teslim defterinde (`claimQuakeEvent`).
let persistsPushState = true;

export function initPushRoutes(db: Firestore, options: { persistState?: boolean } = {}): void {
  persistsPushState = options.persistState ?? true;
  deviceRegistryRef = db.collection('_system').doc('device_registry_v1');
  pushDeliveryStateRef = db.collection('_system').doc('push_delivery_v1');
  pushDeviceSnapshotRef = db.collection('_system').doc('push_device_snapshot_v1');
}

// Deprem bildirimi gecikmiş biçimde teslim edilmemeli. Scheduler dakikada bir
// çalışır; on beş dakikadan eski kayıtlar kesinti sonrasında topluca
// gönderilmez. Beş dakikaydı; ancak AFAD bir olayı (özellikle büyüklük
// revizyonundan sonra) olay anından birkaç dakika sonra yayımlayabiliyor —
// sistemimiz o kaydı İLK KEZ gördüğünde deprem zaten 5 dakikadan eskiyse
// hiç bildirim gitmeden sessizce eleniyordu. On beş dakika, olağan sağlayıcı
// yayım gecikmesini kapsarken uzun kesinti sonrası toplu bildirim riskini
// hâlâ önlüyor.
const PUSH_MAX_EVENT_AGE_MS = 15 * 60 * 1000;
/// AFAD küçük depremleri çoğu zaman 15 dakikadan GEÇ yayımlıyor: kayıt
/// numaralarını yayım sırasıyla veriyor ve 10 Eylül'de 19 kaydın (M1.0+)
/// 15'i pencereye hiç girmeden kayboldu — Dulkadiroğlu M1.6 dahil (kayıtlı
/// yere 93 km). AFAD Türkiye'nin resmî kaynağı; geç de olsa bildirim gitmeli.
/// Şablon, olaydan 10 dakika sonra giden her bildirime "N dk önce" basıyor,
/// yani kullanıcı eski bir olayı "şimdi oldu" diye okumuyor. Diğer
/// sağlayıcılar dakikalar içinde yayımladığı için 15 dakikada kalır.
const PUSH_MAX_EVENT_AGE_MS_AFAD = 60 * 60 * 1000;

export function pushMaxEventAgeMs(quake: Pick<Earthquake, 'provider'>): number {
  return String(quake.provider).toUpperCase() === 'AFAD' ? PUSH_MAX_EVENT_AGE_MS_AFAD : PUSH_MAX_EVENT_AGE_MS;
}
const APNS_EVENT_EXPIRATION_SECONDS = 3 * 60;
export const IOS_NOTIFICATION_SOUND = 'bildirim.caf';
const FCM_BATCH_SIZE = 400;
/// Aynı anda gönderilen parti sayısı. 10 bin cihazlık bir depremde 25 parti
/// oluşur; 2 eşzamanlıda son parti ~15 sn gecikiyordu. İş ağ beklemesi,
/// işlemci değil.
const FCM_SEND_CONCURRENCY = 4;

/// Bu bildirim kritik uyarı olarak mı çalmalı?
///
/// Eskiden M5.0 ve üstündeki HER bildirim kritik uyarıydı. Artık kullanıcının
/// tercihi: her yer için ayrı eşik seçilir (ya da hiç seçilmez). Kritik uyarı
/// sessiz modu ve Odak'ı aşar; yalnızca iOS izni verilmiş, deprem bir yer
/// eşleşmesiyle gelmiş ve o yerin eşiğini geçmişse kullanılır. Dünya geneli,
/// artçı ve eski kural bildirimleri kritik uyarı üretmez.
export function isCriticalDelivery(
  prefs: Pick<DevicePrefs, 'criticalAlertsEnabled'>,
  q: Pick<Earthquake, 'magnitude'>,
  match: Pick<NotificationMatch, 'reason' | 'placeCriticalMagnitude'>
): boolean {
  return Boolean(prefs.criticalAlertsEnabled)
    && match.reason === 'place'
    && match.placeCriticalMagnitude !== undefined
    && q.magnitude >= match.placeCriticalMagnitude;
}

export function chunksOf<T>(items: T[], size = FCM_BATCH_SIZE): T[][] {
  const chunks: T[][] = [];
  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }
  return chunks;
}

// MARK: - Gönderim katmanı: doğrudan APNs, yedek FCM
//
// Mesajlar FCM biçiminde kurulur (`admin.messaging.Message`); APNs token'ı
// bilinen cihazın mesajına `attachApnsTarget` ile doğrudan hedef eklenir.
// `sendFcmBatches` bu mesajları FCM'e uğramadan Apple'a gönderir; APNs geçici
// hata verirse (ağ, 5xx, 429) aynı mesaj FCM token'ıyla FCM'den yeniden denenir.
// APNs token'ı geçersiz derse cihaz, FCM'in "kayıtlı değil" hatasıyla aynı
// yoldan temizlenir. Çağıranlar sonuç biçiminin farkında değildir.
type SendResponse = admin.messaging.SendResponse;

/// FCM'in APNs'e iletirken yaptığını yapar: `notification` başlığı/gövdesi
/// `aps.alert` yoksa ona dönüşür, `data` anahtarları yükün kök düzeyine eklenir.
export function toApnsPayload(message: admin.messaging.Message): Record<string, unknown> {
  const payload: Record<string, any> = JSON.parse(JSON.stringify(message.apns?.payload ?? {}));
  const aps: Record<string, any> = payload.aps ?? {};
  const notification = (message as any).notification as { title?: string; body?: string } | undefined;
  if (!aps.alert && notification && (notification.title || notification.body)) {
    aps.alert = { ...(notification.title ? { title: notification.title } : {}), ...(notification.body ? { body: notification.body } : {}) };
  }
  payload.aps = aps;
  const data = (message as any).data as Record<string, string> | undefined;
  if (data) for (const [key, value] of Object.entries(data)) if (!(key in payload)) payload[key] = value;
  return payload;
}

/// APNs'in geçersiz dediği token'lar (süreç ömrü). Cihaz silinmez: FCM
/// token'ı hâlâ geçerli olabilir (ör. yanlış ortam). Bu token'a bir daha APNs
/// denenmez; mesaj FCM'den gider, FCM de ölü derse cihaz o yoldan temizlenir.
const rejectedApnsTokens = new Set<string>();

let apnsStats = { sent: 0, fallback: 0, rejected: 0 };

async function sendBatch(batch: admin.messaging.Message[], dryRun: boolean): Promise<admin.messaging.BatchResponse> {
  const responses: SendResponse[] = new Array(batch.length);
  const fcmIndexes: number[] = [];
  const direct = apnsConfigured() && !dryRun
    ? batch.map((message, index) => ({ index, target: apnsTargetOf(message) }))
      .filter(item => item.target && !rejectedApnsTokens.has(item.target.token))
    : [];
  if (direct.length) {
    const outcomes = await sendApnsNotifications(direct, item => {
      const apns = batch[item.index].apns;
      return sendApnsNotification(item.target!, (apns?.headers ?? {}) as Record<string, string>, toApnsPayload(batch[item.index]));
    });
    outcomes.forEach((outcome: ApnsSendOutcome, position) => {
      const { index, target } = direct[position];
      if (outcome.ok) {
        apnsStats.sent++;
        responses[index] = { success: true, messageId: 'apns' };
        return;
      }
      // Her APNs hatası FCM yedeğine düşer.
      if (outcome.unregistered) {
        // Uzun ömürlü süreçte sınırsız büyümesin; en eski kayıt düşer (o
        // token bir kez daha APNs'e denenir, sonra yine FCM'e düşer).
        if (rejectedApnsTokens.size >= 20_000) {
          const oldest = rejectedApnsTokens.values().next().value;
          if (oldest !== undefined) rejectedApnsTokens.delete(oldest);
        }
        rejectedApnsTokens.add(target!.token);
        apnsStats.rejected++;
      } else {
        apnsStats.fallback++;
      }
      fcmIndexes.push(index);
    });
  }
  const directIndexes = new Set(direct.map(item => item.index));
  batch.forEach((_, index) => { if (!directIndexes.has(index)) fcmIndexes.push(index); });
  if (fcmIndexes.length) {
    fcmIndexes.sort((a, b) => a - b);
    const fcm = await admin.messaging().sendEach(fcmIndexes.map(index => batch[index]), dryRun);
    fcm.responses.forEach((response, position) => { responses[fcmIndexes[position]] = response; });
  }
  const successCount = responses.filter(response => response?.success).length;
  return { responses, successCount, failureCount: batch.length - successCount };
}

/// Doğrudan APNs sayaçlarını loglayıp sıfırlar (tur sonunda tek satır).
export function flushApnsStats(): void {
  if (apnsStats.sent || apnsStats.fallback || apnsStats.rejected) {
    console.log(`Doğrudan APNs: ${apnsStats.sent} gönderildi, ${apnsStats.fallback} geçici hatayla FCM'e düştü, ${apnsStats.rejected} geçersiz token FCM'e düştü.`);
  }
  apnsStats = { sent: 0, fallback: 0, rejected: 0 };
}

// Bound concurrent HTTP/2 streams independently of audience size. Preserve
// batch ordering so individual failures still map to the correct device.
export async function sendFcmBatches(
  batches: admin.messaging.Message[][],
  dryRun = false
): Promise<PromiseSettledResult<admin.messaging.BatchResponse>[]> {
  const results: PromiseSettledResult<admin.messaging.BatchResponse>[] = new Array(batches.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(FCM_SEND_CONCURRENCY, batches.length) }, async () => {
    while (next < batches.length) {
      const index = next++;
      try {
        results[index] = { status: 'fulfilled', value: await sendBatch(batches[index], dryRun) };
      } catch (reason) {
        results[index] = { status: 'rejected', reason };
      }
    }
  }));
  return results;
}

interface FcmSendSummary {
  successCount: number;
  failureCount: number;
  errorCodes: Record<string, number>;
  deadTokenDeviceIds?: string[];
}

export async function sendFcmMessages(
  messages: admin.messaging.Message[],
  errorContext: string,
  deviceIds?: string[],
  dryRun = false
): Promise<FcmSendSummary> {
  const messageChunks = chunksOf(messages);
  // deviceIds, mesajlarla aynı sırada ve uzunlukta verildiyse, hangi belgenin
  // hangi mesaja karşılık geldiğini takip edip ölü token'ları geri raporlamak
  // için kullanılır (bkz. summary.deadTokenDeviceIds).
  const idChunks = deviceIds && deviceIds.length === messages.length ? chunksOf(deviceIds) : undefined;
  const results = await sendFcmBatches(messageChunks, dryRun);
  const summary: FcmSendSummary = { successCount: 0, failureCount: 0, errorCodes: {} };

  results.forEach((result, chunkIndex) => {
    if (result.status === 'rejected') {
      const failedCount = messageChunks[chunkIndex].length;
      summary.failureCount += failedCount;
      summary.errorCodes['messaging/batch-error'] =
        (summary.errorCodes['messaging/batch-error'] || 0) + failedCount;
      console.error(`${errorContext} batch send error:`, result.reason);
      return;
    }

    result.value.responses.forEach((response, indexInChunk) => {
      if (response.success) {
        summary.successCount++;
        return;
      }
      summary.failureCount++;
      const code = response.error?.code || 'messaging/unknown';
      summary.errorCodes[code] = (summary.errorCodes[code] || 0) + 1;
      if (code === 'messaging/registration-token-not-registered' && idChunks) {
        (summary.deadTokenDeviceIds ??= []).push(idChunks[chunkIndex][indexInChunk]);
      }
      console.error(`${errorContext} send error:`, response.error);
    });
  });

  return summary;
}
const IOS_NOTIFICATION_SOUNDS = new Set([
  IOS_NOTIFICATION_SOUND,
  'sismik_pulse.caf',
  'sismik_signal.caf',
  'sismik_deep.caf'
]);

/// Kritik uyarı sesleri (Scripts/generate-notification-sounds.py).
const IOS_CRITICAL_SOUNDS = new Set([
  'sismik_critical_alarm.caf',
  'sismik_critical_siren.caf',
  'sismik_critical_beacon.caf'
]);

/// Geçerli kritik ses adı ya da boş dize (istemci göndermediyse/tanınmıyorsa).
export function normalizedCriticalSound(value: unknown): string {
  const sound = String(value || '').trim();
  return IOS_CRITICAL_SOUNDS.has(sound) ? sound : '';
}

export function normalizedNotificationSound(value: unknown): string {
  const sound = String(value || '').trim();
  return IOS_NOTIFICATION_SOUNDS.has(sound) ? sound : IOS_NOTIFICATION_SOUND;
}

/// Cihaz silmelerini push önbelleğine duyurur.
///
/// Eskiden her cihaz yazımı (kayıt, abonelik, konum değişimi) bu TEK belgeye
/// de yazıyordu. Firestore tek belgede saniyede ~1 sürekli yazımı kaldırıyor;
/// on binlerce cihazda sabah işe gidiş gibi toplu konum güncellemelerinde
/// batch'ler çekişmeye girip `/register` 503 dönüyordu. Değişiklikler artık
/// zamana bağlı delta okumasıyla alınır (`PUSH_DEVICE_DELTA_INTERVAL_MS`);
/// belgeye yalnızca silmede yazılır, çünkü silinen belge delta sorgusunda
/// görünmez. Silme dışı çağrılar yalnızca yerel önbelleği geçersiz kılar.
///
/// `deletion` YALNIZCA cihaz belgesi silindiğinde verilir. Delta
/// senkronizasyonu silinen belgeleri göremez — silinen doküman
/// `updated_at > x` sorgusuna hiç düşmez, dolayısıyla önbellekte hayalet
/// kayıt olarak kalır. Bu sayaç silmeyi önbelleğe duyurur ve
/// `loadPushDevices` sayacın değiştiğini görünce tam okumaya geçer. Böylece
/// "her N saatte bir tüm koleksiyonu oku" turuna gerek kalmaz: tam okuma
/// yalnızca gerçekten silme olduğunda yapılır.
export async function bumpDeviceRegistryRevision(
  options: { deletion?: boolean; writer?: FirebaseFirestore.WriteBatch | FirebaseFirestore.Transaction } = {}
): Promise<void> {
  invalidateDeviceRegistryCache();
  if (!options.deletion) return;
  const payload: DocumentData = {
    revision: `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    updated_at: Date.now(),
    deletions: FieldValue.increment(1)
  };
  if (options.writer) {
    // WriteBatch ve Transaction'ın `set` imzaları aynı; TypeScript birleşim
    // tipini doğrudan çağıramadığı için daraltılır.
    (options.writer as FirebaseFirestore.WriteBatch).set(deviceRegistryRef, payload, { merge: true });
  } else {
    await deviceRegistryRef.set(payload, { merge: true });
  }
}

/// Bildirim metni — onaylanan şablonlar `notification-templates.ts`'te.
///
/// Bu sarmalayıcı eşleşme sonucunu şablon girdisine çevirir.
export function buildNotificationText(
  langCode: string,
  params: {
    reason?: NotificationMatchReason | string;
    magnitude: number;
    /// Eski imzadan kalan alanlar; şablon büyüklüğü kendisi biçimler.
    mag?: string;
    estimatedMMI?: number;
    watchTitle?: string;
    place: string;
    depth: number;
    hhmm: string;
    provider: string;
    distanceKm?: number;
    placeName?: string;
    isNearbyMatch?: boolean;
    feltAtPlace?: boolean;
    watchMagnitude?: number;
    lateMinutes?: number;
    assemblyCta?: boolean;
    previousMagnitude?: number;
    hasSavedPlaces?: boolean;
    correction?: boolean;
    style?: NotificationStyle;
  }
): NotificationContent {
  const reason = String(params.reason || 'regular');
  const kind: TemplateKind = params.correction
    ? 'correction'
    : (['place', 'world_major', 'aftershock', 'felt'].includes(reason) ? reason as TemplateKind : 'regular');
  return buildNotificationContent(langCode, {
    kind,
    magnitude: params.magnitude,
    depth: params.depth,
    place: params.place,
    hhmm: params.hhmm,
    provider: params.provider,
    distanceKm: params.distanceKm,
    placeName: params.placeName,
    isNearbyMatch: params.isNearbyMatch,
    feltAtPlace: params.feltAtPlace,
    watchMagnitude: params.watchMagnitude,
    lateMinutes: params.lateMinutes,
    assemblyCta: params.assemblyCta,
    previousMagnitude: params.previousMagnitude,
    hasSavedPlaces: params.hasSavedPlaces,
    style: params.style
  });
}

// MARK: - Planlanmış Push Görevi (Cron - 1 dakikada bir)

// Tamamlanmış depremler tek sistem belgesinde tutulur. Böylece sıcak instance
// belleği kaybolsa bile her başarılı deprem için cihaz başına `notified`
// yazmak yerine yalnızca BİR Firestore yazımı yapılır.
const processedQuakeIds = new Set<string>();
/// İşlenmiş kimliğin olay zamanı. Bildirim yalnızca son 60 dakikadaki
/// depremler için gider (`pushMaxEventAgeMs`, AFAD); daha eski bir kimlik
/// `selectFreshQuakes`'e zaten hiç girmez. Defter bu yüzden 3 saatle sınırlı —
/// eskiden 1000 kimlik tutuluyor, belge her yazımda ~56 KB baştan yazılıyordu.
const processedQuakeTimes = new Map<string, number>();
const PROCESSED_QUAKE_RETENTION_MS = 3 * 60 * 60 * 1000;
const PROCESSED_QUAKES_MAX = 1000;
const HANDLED_QUAKE_FINGERPRINTS_MAX = 300;
const HANDLED_QUAKE_FINGERPRINT_MAX_AGE_MS = 6 * 60 * 60 * 1000;
let handledQuakeFingerprints: QuakeFingerprint[] = [];
/// Gönderilen depremlerin gönderildiği andaki hâli; büyüklük düzeltmesi
/// bunlarla karşılaştırılır (bkz. `findMagnitudeRevisions`).
const DELIVERED_SNAPSHOTS_MAX = 150;
let deliveredSnapshots: DeliveredQuakeSnapshot[] = [];
/// Teslim durumu süreç başına BİR KEZ (soğuk açılışta) okunur. Bu belgeye
/// yalnızca tek örnekli `scheduledPushCheck` süreci yazar ve bellekteki
/// defter kalıcı olanın üst kümesidir; her dakika zorla yeniden okumak
/// (günde 1440 okuma) yeni bilgi getirmiyordu. Başka bir süreçle çakışma
/// ihtimaline karşı asıl mükerrer koruması teslim kilidi
/// (`claimQuakeEvent`).
let pushDeliveryStateLoaded = false;
/// Kalıcılaştırılmamış teslim bilgisi var mı? Yalnızca gerçekten gönderim
/// (ya da büyüklük düzeltmesi) olduğunda kirlenir; hiçbir cihazla eşleşmeyen
/// depremler bellekte işlenmiş sayılır ama tek başına yazım üretmez — soğuk
/// açılışta yeniden değerlendirilmeleri zararsız (yine kimseyle eşleşmezler,
/// yeni kaydolan cihazı `registeredAt` korur). Eskiden her tur, çoğu dakika
/// eşleşmesiz dünya depremleri yüzünden dakikada 2-3 kez yazıyordu.
let pushDeliveryStateDirty = false;

export { CachedPushDevice };

/// Bir cihaz belgesini push önbelleği kaydına çevirir. Bildirimi kapalı ya
/// da hiçbir kuralı olmayan cihaz `null` döner. Ücretsiz cihaz da girer;
/// sınırları (1 yer, 50 km) teslim anında `effectivePushPrefs` uygular.
export function toCachedPushDevice(
  doc: FirebaseFirestore.DocumentSnapshot,
  now: number
): CachedPushDevice | null {
  const data = doc.data();
  if (!data || data.transport !== 'fcm' || typeof data.token !== 'string' || !data.token) return null;
  if (!isPushCandidate(data)) return null;
  const entitlementExpiry = Number(data.premium_expires_at || 0);
  const premium = data.is_premium === true && !(entitlementExpiry > 0 && entitlementExpiry <= now);
  // Belge ya yer modelinde ya eski kuralda (bkz. `deviceUsesPlaces`); ikisi
  // aynı anda dolu olmaz. Eski kural yer listesine çevrilmez — koordinatsız
  // "tüm bölgeler" kuralı yer olarak ifade edilemiyor.
  const device: CachedPushDevice = {
    key: doc.id,
    token: data.token,
    ...(typeof data.apns_token === 'string' && data.apns_token
      ? { apnsToken: data.apns_token, apnsEnv: data.apns_env === 'sandbox' ? 'sandbox' as const : 'prod' as const }
      : {}),
    ...(data.platform === 'android' ? { platform: 'android' as const } : {}),
    premium,
    premiumExpiresAt: entitlementExpiry,
    prefs: {
      places: placesFromDeviceData(data),
      legacy: legacyRulesFromDeviceData(data),
      tzOffset: Number.isFinite(Number(data.tz_offset)) ? Number(data.tz_offset) : 180,
      lang: data.lang || 'tr',
      registeredAt: data.registered_at,
      updatedAt: data.updated_at,
      notified: Array.isArray(data.notified) ? data.notified : [],
      criticalAlertsEnabled: Boolean(data.critical_alerts_enabled),
      worldMajorEnabled: Boolean(data.world_major_enabled),
      worldMajorThreshold: Number(data.world_major_threshold) || 6.5,
      notificationSound: normalizedNotificationSound(data.notification_sound),
      criticalNotificationSound: normalizedCriticalSound(data.critical_notification_sound),
      notificationStyle: normalizeNotificationStyle(data.notification_style),
      aftershockWatch: data.aftershock_watch && typeof data.aftershock_watch === 'object'
        ? data.aftershock_watch
        : undefined
    }
  };
  // Ücretsiz sınırlar içinde uygulanabilir bir kuralı kalmayan cihaz
  // (ör. yalnızca eski kural) önbelleğe girmez.
  return effectivePushPrefs(device, now) ? device : null;
}

/// Tek bir cihaz için deprem bildirimi.
///
/// `correction` verilirse aynı olayın DAHA ÖNCE gönderilmiş bildirimini
/// günceller: aynı `apns-collapse-id` iOS'ta eski bildirimin yerine geçer,
/// ses ve banner olmadan (`passive`) Bildirim Merkezi'ne düşer.
export function buildQuakeMessage(
  device: CachedPushDevice,
  q: Earthquake,
  match: NotificationMatch,
  now: number,
  correction?: { previousMagnitude: number }
): admin.messaging.Message {
  const quakeTime = new Date(q.date).getTime();
  const t = new Date(quakeTime + device.prefs.tzOffset * 60000);
  const hhmm = `${String(t.getUTCHours()).padStart(2, '0')}:${String(t.getUTCMinutes()).padStart(2, '0')}`;
  const lateMinutes = Number.isFinite(quakeTime) ? Math.floor((now - quakeTime) / 60000) : undefined;
  // Toplanma alanı verisi Türkiye'ye ait; başka yerde "dokun" demek yanlış olur.
  const assemblyCta = !correction && match.reason === 'place'
    && q.magnitude >= STRONG_QUAKE_MAGNITUDE && isTurkeyFastLaneQuake(q);
  const { title, subtitle, body } = buildNotificationText(device.prefs.lang, {
    reason: match.reason,
    magnitude: q.magnitude,
    place: notificationPlaceLabel(q),
    depth: q.depth,
    hhmm,
    provider: q.provider,
    distanceKm: match.distanceKm,
    placeName: match.placeName,
    isNearbyMatch: match.isNearbyMatch,
    feltAtPlace: match.feltAtPlace,
    watchMagnitude: device.prefs.aftershockWatch?.magnitude,
    lateMinutes: correction ? undefined : lateMinutes,
    assemblyCta,
    correction: Boolean(correction),
    previousMagnitude: correction?.previousMagnitude,
    hasSavedPlaces: !device.prefs.legacy && device.prefs.places.length > 0,
    style: device.prefs.notificationStyle
  });
  const sound = normalizedNotificationSound(device.prefs.notificationSound);

  const aps: Record<string, unknown> = {
    // Sade biçimde alt başlık yok; boş satır bırakılmaz.
    alert: subtitle ? { title, subtitle, body } : { title, body },
    // Ortak thread kimliği iOS'ta farklı depremleri tek yığın halinde
    // gösteriyordu. Her olay bağımsız görünür.
    'thread-id': q.id.slice(0, 64),
    'relevance-score': Math.min(1, q.magnitude / 8)
  };
  if (correction) {
    aps['interruption-level'] = 'passive';
  } else {
    // Kritik uyarı sessiz modu ve Rahatsız Etmeyin'i AŞAR; eşik kullanıcının
    // o yer için seçtiği değerdir (bkz. `isCriticalDelivery`).
    aps.sound = isCriticalDelivery(device.prefs, q, match)
      ? { critical: true, name: normalizedCriticalSound(device.prefs.criticalNotificationSound) || sound, volume: 1.0 }
      : sound;
    aps['interruption-level'] = q.magnitude >= 5 ? 'time-sensitive' : 'active';
    // "Hissettim / Hissetmedim" düğmeleri (istemci bu kategoriyi kaydeder;
    // eski sürümler tanımadığı kategoriyi yok sayar).
    aps.category = QUAKE_FEEDBACK_CATEGORY;
  }
  // Bildirim uzantısı yer simgesini çizip bildirimin sağına ekler.
  if (match.placeIcon) aps['mutable-content'] = 1;

  const message: admin.messaging.Message = {
    token: device.token,
    notification: { title, body },
    apns: {
      headers: {
        // Anlık teslim: yüksek öncelik. Üç dakika içinde iletilemeyen bildirim
        // düşer; cihaz yeniden çevrimiçi olduğunda eski olaylar topluca gelmez.
        // collapse-id aynı olayın tekrarını ve düzeltmesini tek bildirimde tutar.
        'apns-priority': correction ? '5' : '10',
        'apns-push-type': 'alert',
        'apns-expiration': String(Math.floor(now / 1000) + APNS_EVENT_EXPIRATION_SECONDS),
        'apns-collapse-id': q.id.slice(0, 64),
        'apns-topic': 'com.kayasoftware.sismik'
      },
      payload: {
        aps,
        magnitude: q.magnitude,
        quakeId: q.id,
        // Bildirime dokununca detay soğuk açılışta da açılabilsin diye deprem
        // verisi payload'da taşınır (uygulama bunu okuyor).
        quake: {
          id: q.id,
          provider: q.provider,
          title: q.title,
          magnitude: q.magnitude,
          depth: q.depth,
          lat: q.lat,
          lon: q.lon,
          date: q.date
        },
        ...(match.placeIcon ? { placeIcon: match.placeIcon } : {}),
        ...(assemblyCta ? { openTarget: 'assembly' } : {}),
        ...(correction ? { notificationKind: 'correction' } : {}),
        // Uçtan uca teslim gecikmesini ölçebilmek için sunucunun gönderim anı.
        sentAt: new Date(now).toISOString(),
        matchReason: match.reason
      }
    }
  };
  if (device.platform === 'android') {
    return withAndroidDelivery(message, {
      quake: { id: q.id, provider: q.provider, title: q.title, magnitude: q.magnitude, depth: q.depth, lat: q.lat, lon: q.lon, date: q.date },
      channelId: !correction && isCriticalDelivery(device.prefs, q, match) ? 'critical' : 'earthquakes',
      collapseKey: q.id.slice(0, 64),
      silent: Boolean(correction),
      ttlSeconds: APNS_EVENT_EXPIRATION_SECONDS,
      extra: {
        ...(match.placeIcon ? { placeIcon: match.placeIcon } : {}),
        ...(assemblyCta ? { openTarget: 'assembly' } : {}),
        ...(correction ? { notificationKind: 'correction' } : {}),
        sentAt: new Date(now).toISOString(),
        matchReason: String(match.reason ?? '')
      }
    });
  }
  return attachApnsTarget(message, device.apnsToken, device.apnsEnv);
}

/// Android cihazı için mesaja `android` bloğu ve düz metin `data` alanları
/// ekler (FCM data değerleri yalnızca string olabilir). iOS mesajı bu
/// fonksiyondan hiç geçmez; APNs hedefi eklenmez (Android'de yok).
export function withAndroidDelivery(
  message: admin.messaging.Message,
  options: {
    quake?: Record<string, unknown>;
    channelId: string;
    collapseKey?: string;
    silent?: boolean;
    ttlSeconds?: number;
    extra?: Record<string, string>;
  }
): admin.messaging.Message {
  const data: Record<string, string> = { ...(options.extra ?? {}) };
  if (options.quake) {
    data.quakeId = String(options.quake.id ?? '');
    data.quake = JSON.stringify(options.quake);
    data.magnitude = String(options.quake.magnitude ?? '');
  }
  return {
    ...message,
    data: { ...((message as any).data ?? {}), ...data },
    android: {
      priority: options.silent ? 'normal' : 'high',
      ...(options.ttlSeconds ? { ttl: options.ttlSeconds * 1000 } : {}),
      ...(options.collapseKey ? { collapseKey: options.collapseKey } : {}),
      notification: {
        channelId: options.channelId,
        ...(options.collapseKey ? { tag: options.collapseKey } : {}),
        icon: 'ic_stat_sismik',
        color: '#FF7A00',
        ...(options.silent ? { notificationCount: 0 } : {}),
        clickAction: 'OPEN_SISMIK'
      }
    }
  } as admin.messaging.Message;
}

// Push cihaz önbelleği. Anahtar → kayıt; sıralama teslim mantığını
// etkilemediği için Map yeterli.
let cachedPushDevices: Map<string, CachedPushDevice> | null = null;
/// Delta senkronizasyonun başlangıç noktası: bu ana kadar olan tüm cihaz
/// değişiklikleri önbellekte. Cihaz belgeleri `updated_at` alanını her
/// yazımda tazeler.
let cachedDevicesSyncedAt = 0;
/// Silmeler artık `deletions` sayacıyla anında bildiriliyor (bkz.
/// `bumpDeviceRegistryRevision`), bu yüzden periyodik tam okuma yalnızca bir
/// emniyet ağı: sayaç yazımının kaybolduğu uç durumlar için. 6 saatten 24
/// saate çıkarıldı — tam okuma TÜM premium cihaz koleksiyonunu okuyor ve
/// faturası cihaz sayısıyla doğrusal büyüyordu. Cloud Run örnekleri zaten
/// çok daha kısa yaşadığı için soğuk açılışta nasılsa tam okuma yapılıyor.
const PUSH_DEVICE_FULL_RESYNC_INTERVAL_MS = 24 * 60 * 60 * 1000;
let cachedDevicesFullSyncAt = 0;
/// Son delta okumasının anı. Değişiklikler registry revizyonuyla değil bu
/// aralıkla alınır (bkz. `bumpDeviceRegistryRevision`). Delta sorgusu
/// yalnızca taze deprem olan turlarda çalışır; boş sonuç tek okuma sayılır.
const PUSH_DEVICE_DELTA_INTERVAL_MS = 15_000;
let cachedDevicesDeltaAt = 0;
/// Önbelleğin gördüğü son silme sayacı. Kayıt defterindekinden farklıysa
/// arada en az bir cihaz silinmiştir ve delta yolu güvenilmezdir.
let cachedDeviceDeletions = -1;

// MARK: - Registry Okuma Önbelleği (30 saniye)
//
// Dakikalık zamanlayıcı turu sırasında 4 hızlı tarama ve 1 tam tarama
// çalışır. Aynı dakika içinde `device_registry_v1` belgesini tekrar tekrar
// okumak yerine 30 saniyelik bellek içi önbellek kullanılır. Yerel bir yazım
// olduğunda `invalidateDeviceRegistryCache()` ile anında geçersiz kılınır.
let cachedRegistryData: { revision: string; deletions: number; readAt: number } | null = null;
const REGISTRY_CACHE_TTL_MS = 30_000; // 30 saniye

export function invalidateDeviceRegistryCache(): void {
  cachedRegistryData = null;
}

export function resetPushDeviceCache(): void {
  cachedPushDevices = null;
  cachedDevicesSyncedAt = 0;
  cachedDevicesFullSyncAt = 0;
  cachedDevicesDeltaAt = 0;
  cachedDeviceDeletions = -1;
  cachedRegistryData = null;
}

/// Bu sürecin kendi sildiği (ölü token) cihazlar önbellekten doğrudan düşülür
/// ve silme sayacı yerelde bir ilerletilir (her silme partisi sayacı bir
/// artırır). Aksi hâlde sonraki okuma sayaç farkını görüp TÜM premium
/// cihazları yeniden okuyordu. Arada başka bir süreç de sildiyse sayaçlar yine
/// tutmaz ve güvenli yol olan tam okuma yapılır.
function forgetOwnDeletedPushDevices(keys: string[]): void {
  for (const key of keys) {
    cachedPushDevices?.delete(key);
    spatialGridIndex.removeDevice(key);
  }
  if (cachedDeviceDeletions >= 0) cachedDeviceDeletions += 1;
}

export function getPushDeviceCacheSize(): number {
  return cachedPushDevices ? cachedPushDevices.size : 0;
}

let lastSnapshotSavedAt = 0;

/// Firestore belge sınırı 1 MiB; her parça bunun altında kalır.
const SNAPSHOT_PART_MAX_BYTES = 900_000;
let lastSnapshotPartCount = 1;

function snapshotPartRef(index: number): DocumentReference<DocumentData> {
  return pushDeviceSnapshotRef.firestore.collection('_system').doc(`push_device_snapshot_v1_p${index}`);
}

/// Cihaz listesini, her biri sıkıştırılmış hâlde `maxBytes`'ı aşmayan
/// gzip'li JSON parçalarına böler. Soğuk açılış cihaz sayısından bağımsız
/// olarak parça sayısı kadar okuma yapar (binlerce cihazda birkaç okuma).
export function buildSnapshotParts(devices: CachedPushDevice[], maxBytes: number): Buffer[] {
  const parts: Buffer[] = [];
  const pack = (slice: CachedPushDevice[]) => gzipSync(Buffer.from(JSON.stringify(slice)), { level: 6 });
  let start = 0;
  while (start < devices.length) {
    // Parça boyutu tahmini: ilk denemede kalan cihazların tamamı, sığmazsa
    // oranla küçültülür (birkaç yinelemede yakınsar).
    let count = devices.length - start;
    let packed = pack(devices.slice(start, start + count));
    while (packed.length > maxBytes && count > 1) {
      count = Math.max(1, Math.floor(count * (maxBytes / packed.length) * 0.9));
      packed = pack(devices.slice(start, start + count));
    }
    parts.push(packed);
    start += count;
  }
  return parts;
}

async function savePushDeviceSnapshot(
  devices: Map<string, CachedPushDevice>,
  revision: string,
  deletions: number,
  syncedAt: number,
  now: number
): Promise<void> {
  if (!pushDeviceSnapshotRef || !persistsPushState) return;
  try {
    const parts = buildSnapshotParts(Array.from(devices.values()), SNAPSHOT_PART_MAX_BYTES);
    const previousParts = lastSnapshotPartCount;
    const batch = pushDeviceSnapshotRef.firestore.batch();
    batch.set(pushDeviceSnapshotRef, {
      schema_version: 2,
      revision,
      deletions,
      synced_at: syncedAt,
      device_count: devices.size,
      part_count: parts.length,
      payload: parts[0] ?? gzipSync(Buffer.from('[]')),
      updated_at: now
    });
    parts.slice(1).forEach((part, index) => {
      batch.set(snapshotPartRef(index + 1), { payload: part, updated_at: now });
    });
    // Küçülen snapshot'ın artık parçaları silinir; okunmazlar ama yer tutarlar.
    for (let index = parts.length; index < previousParts; index++) batch.delete(snapshotPartRef(index));
    await batch.commit();
    lastSnapshotPartCount = parts.length;
    lastSnapshotSavedAt = now;
    const bytes = parts.reduce((sum, part) => sum + part.length, 0);
    console.log(`Push cihaz snapshot kaydedildi: ${devices.size} cihaz, ${parts.length} parça, ${bytes} bytes.`);
  } catch (error: any) {
    console.warn('Push cihaz snapshot yazımı başarısız:', error?.message || error);
  }
}

export async function loadPushDevices(db: Firestore, now: number): Promise<CachedPushDevice[]> {
  let revision = '';
  let deletions = 0;

  if (cachedRegistryData && (now - cachedRegistryData.readAt < REGISTRY_CACHE_TTL_MS)) {
    revision = cachedRegistryData.revision;
    deletions = cachedRegistryData.deletions;
  } else {
    const registry = await deviceRegistryRef.get();
    const registryData = registry.data();
    revision = String(registryData?.revision || 'legacy');
    deletions = Number(registryData?.deletions || 0);
    cachedRegistryData = { revision, deletions, readAt: now };
  }

  // Teslim anındaki kurallar: premium'un süresi önbellek yaşarken dolduysa
  // cihaz susmaz, ücretsiz sınırlarla döner. `notified` dizisi aynı nesne
  // kalır ki geçici FCM hatası yedeği önbellekteki kayda yazsın.
  const activeDevices = () => Array.from(cachedPushDevices!.values()).flatMap(device => {
    const prefs = effectivePushPrefs(device, now);
    if (!prefs) return [];
    return prefs === device.prefs ? [device] : [{ ...device, prefs: { ...prefs, notified: device.prefs.notified } }];
  });

  // Sıcak önbellek: silme yoksa ve son delta okuması tazeyse Firestore'a
  // gidilmez. Yeni kaydolan/ayarını değiştiren cihaz en geç bir delta
  // aralığı sonra eşleştiriciye girer (eskiden registry önbelleği 30 sn idi).
  if (cachedPushDevices && cachedDeviceDeletions === deletions
      && now - cachedDevicesDeltaAt < PUSH_DEVICE_DELTA_INTERVAL_MS
      && now - cachedDevicesFullSyncAt < PUSH_DEVICE_FULL_RESYNC_INTERVAL_MS) {
    return activeDevices();
  }

  // Soğuk açılış: Önbellek henüz boşsa, tüm koleksiyonu baştan taramak yerine
  // sıkıştırılmış tek bir snapshot belgesini oku (_system/push_device_snapshot_v1).
  // Bu işlem soğuk açılış okuma faturasını %99.9 oranında düşürür.
  if (!cachedPushDevices && pushDeviceSnapshotRef) {
    try {
      const snapDoc = await pushDeviceSnapshotRef.get();
      if (snapDoc.exists) {
        const snapData = snapDoc.data();
        if (snapData?.payload) {
          const decode = (payload: any) => JSON.parse(
            gunzipSync(Buffer.isBuffer(payload) ? payload : Buffer.from(payload)).toString('utf8')
          ) as CachedPushDevice[];
          const partCount = Math.max(1, Number(snapData.part_count || 1));
          const extra = partCount > 1
            ? await pushDeviceSnapshotRef.firestore.getAll(
              ...Array.from({ length: partCount - 1 }, (_, index) => snapshotPartRef(index + 1))
            )
            : [];
          // Parçalardan biri eksikse (yazım yarıda kaldı) snapshot kullanılmaz;
          // aşağıdaki tam okuma doğru listeyi kurar.
          if (extra.some(part => !part.exists)) throw new Error('snapshot parçası eksik');
          lastSnapshotPartCount = partCount;
          const parsed = [decode(snapData.payload), ...extra.map(part => decode(part.data()?.payload))].flat();
          if (Array.isArray(parsed)) {
            const restoredMap = new Map<string, CachedPushDevice>();
            spatialGridIndex.clear();
            for (const dev of parsed) {
              restoredMap.set(dev.key, dev);
              spatialGridIndex.addOrUpdateDevice(dev);
            }
            cachedPushDevices = restoredMap;
            cachedDevicesSyncedAt = Number(snapData.synced_at || 0);
            cachedDeviceDeletions = Number(snapData.deletions || 0);
            cachedDevicesFullSyncAt = now;
            console.log(`Push cihaz önbelleği snapshot'tan yüklendi: ${cachedPushDevices.size} cihaz (${partCount} okuma).`);
          }
        }
      }
    } catch (err: any) {
      console.warn('Push cihaz snapshot yükleme hatası:', err?.message || err);
    }
  }

  // Silme olduysa delta yolu hayalet kayıt bırakır: bildirimini kapatan
  // kullanıcı önbellek tazelenene kadar bildirim almaya devam ederdi.
  const deletionSinceLastSync = cachedDeviceDeletions >= 0 && deletions !== cachedDeviceDeletions;
  const fullResyncDue = deletionSinceLastSync
    || now - cachedDevicesFullSyncAt >= PUSH_DEVICE_FULL_RESYNC_INTERVAL_MS;

  // Delta yolu: revizyon değişti ama önbellek sıcak (veya snapshot'tan yüklendi).
  // Yalnızca son senkronizasyondan sonra yazılan belgeler okunur.
  if (cachedPushDevices && cachedDevicesSyncedAt > 0 && !fullResyncDue) {
    try {
      const changed = await db.collection('devices')
        .where('updated_at', '>=', Math.max(0, cachedDevicesSyncedAt - 60_000))
        .get();
      const changes = changed.docs.map(doc => ({
        id: doc.id,
        updatedAt: Number(doc.data()?.updated_at || 0),
        device: toCachedPushDevice(doc, now)
      }));
      cachedDevicesSyncedAt = applyPushDeviceDelta(
        cachedPushDevices,
        changes,
        cachedDevicesSyncedAt
      );
      for (const change of changes) {
        if (change.device) {
          spatialGridIndex.addOrUpdateDevice(change.device);
        } else {
          spatialGridIndex.removeDevice(change.id);
        }
      }
      cachedDeviceDeletions = deletions;
      cachedDevicesDeltaAt = now;
      if (changed.size) console.log(`Push cihaz önbelleği delta ile güncellendi: ${changed.size} değişiklik, toplam ${cachedPushDevices.size}.`);

      if (changes.length >= 10 || now - lastSnapshotSavedAt > 30 * 60 * 1000) {
        void savePushDeviceSnapshot(cachedPushDevices, revision, deletions, cachedDevicesSyncedAt, now);
      }

      return activeDevices();
    } catch (error: any) {
      // İndeks henüz hazır değilse veya sorgu başarısızsa tam okumaya düş.
      console.error('Cihaz delta senkronizasyonu başarısız; tam okumaya düşülüyor:', error?.message || error);
    }
  }

  // Yalnızca sunucu eşleştirmesine giren cihazlar okunur (`push_candidate`),
  // bildirimi kapalı ya da kuralsız ücretsiz cihazlar okunmaz. `is_premium`
  // dalı, bu alan eklenmeden önce kaydolmuş premium cihazlar içindir; istemci
  // kaydı haftada bir tazelediği için zamanla gereksizleşir.
  const devicesSnapshot = await readPushCandidateDevices(db);
  const devices = new Map<string, CachedPushDevice>();
  let latestUpdatedAt = 0;
  spatialGridIndex.clear();
  devicesSnapshot.forEach(doc => {
    const updatedAt = Number(doc.data()?.updated_at || 0);
    if (updatedAt > latestUpdatedAt) latestUpdatedAt = updatedAt;
    const device = toCachedPushDevice(doc, now);
    if (device) {
      devices.set(doc.id, device);
      spatialGridIndex.addOrUpdateDevice(device);
    }
  });

  cachedPushDevices = devices;
  cachedDeviceDeletions = deletions;
  cachedDevicesSyncedAt = latestUpdatedAt;
  cachedDevicesFullSyncAt = now;
  cachedDevicesDeltaAt = now;
  console.log(`Push cihaz önbelleği tam okundu: ${devices.size} cihaz.`);

  void savePushDeviceSnapshot(devices, revision, deletions, latestUpdatedAt, now);

  return activeDevices();
}

/// Tam okuma: yalnızca push adayları. `push_candidate` alanının tek alan
/// indeksi (firestore.indexes.json) yoksa ya da henüz kuruluyorsa sorgu
/// FAILED_PRECONDITION ile düşer; o durumda bildirim turu ASLA durmamalı —
/// tüm cihazlar okunur ve adaylar bellekte süzülür (`toCachedPushDevice`).
/// 22 Eyl 2026: indeks eksikken her tur başarısız oluyor, bildirim gitmiyordu.
async function readPushCandidateDevices(db: Firestore): Promise<FirebaseFirestore.QuerySnapshot> {
  try {
    return await db.collection('devices')
      .where(Filter.or(
        Filter.where('push_candidate', '==', true),
        Filter.where('is_premium', '==', true)
      ))
      .get();
  } catch (error: any) {
    if (Number(error?.code) !== 9 && !/FAILED_PRECONDITION|requires .*index/i.test(String(error?.message))) throw error;
    console.error('push_candidate sorgusu indekssiz; tüm cihazlar okunuyor:', error?.message || error);
    return db.collection('devices').get();
  }
}

function rememberProcessedId(id: string, time: number): void {
  processedQuakeIds.add(id);
  processedQuakeTimes.set(id, time);
  if (processedQuakeIds.size > PROCESSED_QUAKES_MAX) {
    for (const oldId of processedQuakeIds) {
      processedQuakeIds.delete(oldId);
      processedQuakeTimes.delete(oldId);
      if (processedQuakeIds.size <= PROCESSED_QUAKES_MAX) break;
    }
  }
}

function pruneProcessedIds(now: number): void {
  const cutoff = now - PROCESSED_QUAKE_RETENTION_MS;
  for (const [id, time] of processedQuakeTimes) {
    if (time < cutoff) {
      processedQuakeTimes.delete(id);
      processedQuakeIds.delete(id);
    }
  }
}

function markQuakeProcessed(quake: Earthquake, rememberFingerprint = true): void {
  const time = new Date(quake.date).getTime();
  rememberProcessedId(quake.id, Number.isFinite(time) ? time : Date.now());

  // Parmak izi her bölge için tutulur: kopya elemesi artık dünya geneli.
  // Yalnızca Türkiye kutusunda tutulduğunda, kutu dışındaki bir olayın
  // birkaç dakika sonra gelen ikinci ajans kopyası sonraki turda "yeni"
  // sayılıyor ve yer modelindeki cihaz aynı depremi iki kez alıyordu.
  if (rememberFingerprint) {
    const fingerprint = toQuakeFingerprint(quake);
    if (fingerprint && !handledQuakeFingerprints.some(item => item.id === fingerprint.id)) {
      handledQuakeFingerprints.push(fingerprint);
    }
  }
}

async function loadProcessedQuakes(): Promise<void> {
  if (pushDeliveryStateLoaded) return;
  const snapshot = await pushDeliveryStateRef.get();
  const ids = snapshot.data()?.processed_quake_ids;
  if (Array.isArray(ids)) {
    // Belge olay zamanını taşımıyor; yüklenen kimlikler yükleme anından
    // itibaren saklama süresi kadar tutulur.
    const loadedAt = Date.now();
    ids.slice(-PROCESSED_QUAKES_MAX).forEach(id => {
      if (typeof id === 'string' && id && !processedQuakeIds.has(id)) rememberProcessedId(id, loadedAt);
    });
  }
  const fingerprints = snapshot.data()?.handled_quakes;
  if (Array.isArray(fingerprints)) {
    handledQuakeFingerprints = fingerprints.filter(item =>
      item && typeof item.id === 'string' && typeof item.provider === 'string'
      && Number.isFinite(item.time) && Number.isFinite(item.magnitude)
      && Number.isFinite(item.lat) && Number.isFinite(item.lon)
    ).slice(-HANDLED_QUAKE_FINGERPRINTS_MAX);
  }
  const tsunamiIds = snapshot.data()?.tsunami_alert_ids;
  if (Array.isArray(tsunamiIds)) {
    tsunamiIds.forEach(id => { if (typeof id === 'string' && id) sentTsunamiAlertIds.add(id); });
  }
  const delivered = snapshot.data()?.delivered_quakes;
  if (Array.isArray(delivered)) {
    deliveredSnapshots = delivered.filter(item =>
      item && typeof item.id === 'string' && Number.isFinite(item.magnitude)
      && Number.isFinite(item.sentAt) && Number.isFinite(item.lat) && Number.isFinite(item.lon)
    ).slice(-DELIVERED_SNAPSHOTS_MAX);
  }
  pushDeliveryStateLoaded = true;
}

/// Servisler arası ortak teslim defterinin kararı.
///
/// - `claimed`: bu olayı bu süreç gönderir.
/// - `duplicate`: aynı fiziksel depremin başka ajans kaydı daha önce
///   gönderildi (belki başka serviste); bu kopya yalnızca ilk kaydı
///   İSTEMEYEN cihazlara gider (`shouldDeliverDuplicate`).
/// - `taken`: aynı kimlik başka bir süreçte zaten gönderildi.
export type QuakeClaim =
  | { status: 'claimed' }
  | { status: 'duplicate'; original: QuakeFingerprint }
  | { status: 'taken'; entry: PushEventEntry };

export interface PushEventEntry extends QuakeFingerprint {
  claimedAt: number;
  /// Kopya olarak alındıysa asıl kaydın kimliği.
  duplicateOf?: string;
}

/// Bu sürecin aldığı olaylar (kimlik → kopyaysa asıl kaydın parmak izi).
/// Geçici FCM hatasından sonraki tur başarısız cihazlara yeniden denemek için
/// AYNI depremi tekrar ister; kendi kaydını "başkasının" sanıp depremi
/// düşürmemesi için defter okunmadan geçer.
const ownedQuakeClaims = new Map<string, QuakeFingerprint | null>();
const OWNED_QUAKE_CLAIMS_MAX = 1000;
/// Defterde tutulan süre: AFAD bildirimi olaydan 60 dk sonrasına kadar
/// gidebiliyor, yayım gecikmesiyle birlikte 3 saat yeterli.
const PUSH_EVENT_RETENTION_MS = 3 * 60 * 60 * 1000;
const PUSH_EVENT_LEDGER_MAX = 400;

function rememberOwnedClaim(quakeId: string, original: QuakeFingerprint | null): void {
  ownedQuakeClaims.set(quakeId, original);
  if (ownedQuakeClaims.size > OWNED_QUAKE_CLAIMS_MAX) {
    const oldest = ownedQuakeClaims.keys().next().value;
    if (oldest !== undefined) ownedQuakeClaims.delete(oldest);
  }
}

function sanitizePushEvents(value: unknown, now: number): PushEventEntry[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item: any) =>
    item && typeof item.id === 'string' && typeof item.provider === 'string'
    && Number.isFinite(item.time) && Number.isFinite(item.magnitude)
    && Number.isFinite(item.lat) && Number.isFinite(item.lon)
    && Number.isFinite(item.claimedAt) && now - item.claimedAt <= PUSH_EVENT_RETENTION_MS
  );
}

/// Fiziksel deprem başına teslim kilidi (`_system/push_events_v1`).
///
/// Eskiden kilit ajans KİMLİĞİ başınaydı (`_system_push_claims/<id>`) ve
/// ajanslar arası eşleştirme her servisin kendi belleğindeydi. Dakikalık tur
/// (`scheduledPushCheck`) ile :15/:30/:45 taramaları (`fastPushScan`) ayrı
/// süreçler olduğu için aynı depremi biri EMSC'den, diğeri AFAD'dan
/// gönderebiliyordu (23 Eyl 2026, Saimbeyli M2.8: iki bildirim). Artık tek
/// belgede, işlem (transaction) içinde hem kimlik hem zaman/konum/büyüklük
/// yakınlığı kontrol edilir; iki servis de aynı defteri görür.
///
/// Maliyet: yalnızca en az bir cihazla eşleşen deprem için 1 okuma + 1 yazım
/// (eski yol da deprem başına bir belge oluşturuyordu, üstüne TTL silmesi).
/// Firestore'a ulaşılamazsa bildirim ENGELLENMEZ: süreç içi defter yine
/// aynı süreçteki kopyaları eler.
export async function claimQuakeEvent(
  db: Firestore,
  quake: Earthquake,
  now: number = Date.now()
): Promise<QuakeClaim> {
  if (ownedQuakeClaims.has(quake.id)) {
    const original = ownedQuakeClaims.get(quake.id);
    return original ? { status: 'duplicate', original } : { status: 'claimed' };
  }
  const fingerprint = toQuakeFingerprint(quake);
  if (!fingerprint) return { status: 'claimed' };
  const ref = db.collection('_system').doc('push_events_v1');
  try {
    const claim = await db.runTransaction(async tx => {
      const snapshot = await tx.get(ref);
      const events = sanitizePushEvents(snapshot.data()?.events, now);
      const same = events.find(entry => entry.id === quake.id);
      if (same) return { status: 'taken', entry: same } as QuakeClaim;
      const original = events.find(entry => !entry.duplicateOf && isPushDuplicateOf(quake, entry));
      events.push({ ...fingerprint, claimedAt: now, ...(original ? { duplicateOf: original.id } : {}) });
      tx.set(ref, { events: events.slice(-PUSH_EVENT_LEDGER_MAX), updated_at: now });
      if (!original) return { status: 'claimed' } as QuakeClaim;
      const { id, provider, time, magnitude, lat, lon } = original;
      return { status: 'duplicate', original: { id, provider, time, magnitude, lat, lon } } as QuakeClaim;
    });
    if (claim.status === 'claimed') rememberOwnedClaim(quake.id, null);
    if (claim.status === 'duplicate') rememberOwnedClaim(quake.id, claim.original);
    return claim;
  } catch (error: any) {
    console.warn(`[claimQuakeEvent] Teslim defteri okunamadı (${quake.id}); bildirim engellenmiyor:`, error?.message || error);
    return { status: 'claimed' };
  }
}

/// Kirli teslim durumunu tek yazımla kalıcılaştırır. Dakikalık tur bunu
/// SONDA bir kez çağırır (tur başına en fazla bir yazım); gerçek zamanlı
/// alım kendi turundan sonra çağırır. Arada süreç ölürse aynı depremin
/// yeniden gönderilmesini teslim kilidi (`_system_push_claims`) engeller.
export async function flushPushDeliveryState(): Promise<void> {
  if (!pushDeliveryStateDirty) return;
  pushDeliveryStateDirty = false;
  if (!persistsPushState) {
    prunePushDeliveryState(Date.now());
    return;
  }
  try {
    await persistProcessedQuakes();
  } catch (error) {
    pushDeliveryStateDirty = true;
    throw error;
  }
}

function prunePushDeliveryState(now: number): void {
  pruneProcessedIds(now);
  const cutoff = now - HANDLED_QUAKE_FINGERPRINT_MAX_AGE_MS;
  handledQuakeFingerprints = handledQuakeFingerprints
    .filter(item => item.time >= cutoff)
    .slice(-HANDLED_QUAKE_FINGERPRINTS_MAX);
  const deliveredCutoff = now - MAGNITUDE_CORRECTION_WINDOW_MS;
  deliveredSnapshots = deliveredSnapshots
    .filter(item => item.sentAt >= deliveredCutoff)
    .slice(-DELIVERED_SNAPSHOTS_MAX);
}

async function persistProcessedQuakes(): Promise<void> {
  prunePushDeliveryState(Date.now());
  await pushDeliveryStateRef.set({
    processed_quake_ids: Array.from(processedQuakeIds).slice(-PROCESSED_QUAKES_MAX),
    handled_quakes: handledQuakeFingerprints,
    // Firestore `undefined` kabul etmez; kopya olmayan kayıtta alan hiç yazılmaz.
    delivered_quakes: deliveredSnapshots.map(item => JSON.parse(JSON.stringify(item))),
    tsunami_alert_ids: Array.from(sentTsunamiAlertIds).slice(-TSUNAMI_IDS_MAX),
    updated_at: Date.now()
  }, { merge: true });
}

/// Başka süreçte gönderilmiş depremi bu sürecin büyüklük düzeltmesi
/// defterine ekler: düzeltmeleri yalnızca dakikalık tur yapar, ama depremi
/// çoğu zaman :15/:30/:45 taraması gönderir. Gönderilen büyüklük defterdeki
/// kayıttan gelir.
function rememberForeignDelivery(q: Earthquake, entry: PushEventEntry): void {
  if (entry.duplicateOf || deliveredSnapshots.some(item => item.id === q.id)) return;
  pushDeliveryStateDirty = true;
  deliveredSnapshots.push({
    id: q.id,
    provider: entry.provider,
    magnitude: entry.magnitude,
    depth: q.depth,
    lat: entry.lat,
    lon: entry.lon,
    date: q.date,
    sentAt: entry.claimedAt,
    corrections: 0
  });
}

function rememberDelivered(q: Earthquake, duplicateOf: QuakeFingerprint | undefined, now: number): void {
  pushDeliveryStateDirty = true;
  if (deliveredSnapshots.some(item => item.id === q.id)) return;
  deliveredSnapshots.push({
    id: q.id,
    provider: q.provider,
    magnitude: q.magnitude,
    depth: q.depth,
    lat: q.lat,
    lon: q.lon,
    date: q.date,
    sentAt: now,
    corrections: 0,
    ...(duplicateOf ? { duplicateOf } : {})
  });
}

/// Ajansın büyüklüğü belirgin biçimde değiştirdiği, daha önce gönderilmiş
/// depremler: ilk hâli alan cihazın bildirimi sessizce güncellenir; ilk
/// hâlde eşiğin altında kalıp revize hâlde eşiği geçen cihaz olayı ilk kez
/// normal bildirimle duyar (hâlâ taze sayılıyorsa).
async function deliverMagnitudeRevisions(
  revisions: Array<{ snapshot: DeliveredQuakeSnapshot; current: Earthquake }>,
  devices: CachedPushDevice[],
  now: number
): Promise<void> {
  for (const { snapshot, current } of revisions) {
    const stillFresh = now - new Date(current.date).getTime() < pushMaxEventAgeMs(current);
    const messages: admin.messaging.Message[] = [];
    let corrections = 0;
    let newlyMatched = 0;
    for (const device of devices) {
      const legacy = device.prefs.legacy;
      const ignoreSource = Boolean(legacy?.sourceFallbackEnabled) && isProviderUnavailableForPush(legacy!.source);
      const decision = magnitudeRevisionDecision(snapshot, current, device.prefs, now, ignoreSource);
      if (!decision) continue;
      if (decision.kind === 'correction') {
        messages.push(buildQuakeMessage(device, current, decision.match, now, { previousMagnitude: snapshot.magnitude }));
        corrections++;
      } else if (stillFresh) {
        messages.push(buildQuakeMessage(device, current, decision.match, now));
        newlyMatched++;
      }
    }
    // Aynı düzeltme bir sonraki turda tekrar gönderilmesin: gönderim
    // başarısız olsa bile anlık kayıt güncellenir (düzeltme bir sonraki
    // değişikliği bekler; kullanıcıyı çift bildirimle yormaz).
    snapshot.magnitude = current.magnitude;
    snapshot.depth = current.depth;
    snapshot.lat = current.lat;
    snapshot.lon = current.lon;
    snapshot.corrections += 1;
    pushDeliveryStateDirty = true;
    if (!messages.length) continue;
    const chunks = chunksOf(messages);
    const results = await sendFcmBatches(chunks);
    const failed = results.reduce((sum, result, index) => sum + (result.status === 'rejected'
      ? chunks[index].length : result.value.failureCount), 0);
    console.log(`Deprem ${current.id} büyüklük düzeltmesi: M${snapshot.magnitude} → ${corrections} güncelleme, ${newlyMatched} yeni bildirim, ${failed} hata.`);
  }
}

/// Tek bir teslim turu: verilen deprem listesinden taze adayları seçer,
/// eşleşen cihazlara gönderir ve teslim durumunu kirli işaretler (yazımı
/// `flushPushDeliveryState` yapar). Doğrudan çağrılmaz; `enqueuePushPass`
/// üzerinden SIRAYLA çalışır — iki tur aynı anda çalışsaydı ikisi de aynı
/// depremi "işlenmemiş" görüp çift bildirim atardı.
async function runPushPass(
  db: Firestore,
  allQuakes: Earthquake[],
  now: number,
  includeRevisions: boolean,
  label: string
): Promise<void> {
  try {
    // Uzak yapılandırma (remote-config.ts): en fazla dakikada bir okunur.
    // Duraklatılmışsa bu tur hiç bildirim göndermez; gizlenen kaynak ve
    // depremler bildirime girmez.
    await refreshRemoteConfigFromSource();
    if (remoteServerConfig().push_paused) {
      notePushPaused(label);
      return;
    }
    const quakes = filterPublicQuakes(allQuakes);
    // Kayıt henüz yüklenmediyse veya soğuk başlangıçta Firestore'dan yükle;
    // sıcak instance'ta her dakika gereksiz yere Firestore okuma faturası çıkarma.
    if (!pushDeliveryStateLoaded) {
      await loadProcessedQuakes();
    }


    // Liste ve harita sağlayıcıların yayımladığı tüm büyüklükleri gösterir;
    // kullanıcı bildirim ayarındaki en düşük eşik 1.0 (Tüm sarsıntılar) ile uyumlu.
    const notificationQuakes = quakes.filter(q => q.magnitude >= 1.0);
    // İşlenmiş kimlikler kotadan ÖNCE elenir: aksi hâlde zaten bildirilmiş
    // kayıtlar 12'lik adaylığı doldurup henüz bildirilmemiş bir depremi hiç
    // incelenmeden dışarıda bırakıyordu (bkz. `selectFreshQuakes`).
    const freshCandidates = selectFreshQuakes(
      notificationQuakes, now, pushMaxEventAgeMs, 12, processedQuakeIds
    );
    // Aynı fiziksel olayın farklı ajans kopyaları gruplanır: ilk yayımlanan
    // "asıl", sonrakiler "kopya" olur. Önceki turlarda işlenmiş asıllar
    // `handledQuakeFingerprints` defterinden gelir.
    const fastestSelection = selectFastestQuakes(freshCandidates, handledQuakeFingerprints);
    // Bastırılan kopyalar da teslim döngüsüne girer, ama yalnızca aynı olayın
    // ilk kaydını İSTEMEYEN cihazlara gider (`shouldDeliverDuplicate`). Hiçbir
    // cihaz aynı depremi iki kez almaz; kaynağı katı olan eski kuraldaki cihaz
    // da olayı başka ajans önce yayımladı diye kaçırmaz.
    const { duplicateOf } = fastestSelection;
    const fresh = [...fastestSelection.selected, ...fastestSelection.suppressed];

    // Düzeltme adayı olup olmadığı cihaz okumadan anlaşılır; cihazlar
    // yalnızca gerçekten bir düzeltme varsa okunur.
    const revisions = includeRevisions ? findMagnitudeRevisions(deliveredSnapshots, quakes, now) : [];

    if (!fresh.length) {
      if (revisions.length) {
        await deliverMagnitudeRevisions(revisions, await loadPushDevices(db, now), now);
      }
      return;
    }

    const devices = await loadPushDevices(db, now);
    // Gönderim döngüsündeki cihaz aramaları için O(1) erişim: büyük bir
    // depremde binlerce cihaz eşleşebilir; lineer devices.find() taramaları
    // tek çekirdekli (concurrency:1) instance'da O(N²) CPU'ya dönüşüyordu.
    const deviceByKey = new Map(devices.map(d => [d.key, d]));
    // Bastırılan kopya işlenmiş sayılır ama parmak izi DEFTERİNE eklenmez
    // (`rememberFingerprint = false`) — aksi hâlde kopya, kendisini bastıran
    // kaydın yerine geçip sonraki turları kirletirdi.
    const markHandled = (q: Earthquake) => markQuakeProcessed(q, !duplicateOf.has(q.id));
    // Eski kuraldaki cihaz: seçtiği sağlayıcı bu turda yanıt vermediyse ve
    // yedek kaynağa izin verdiyse kaynak filtresi o tur için kalkar (2.0.9
    // sunucusundaki davranış).
    const matchFor = (
      q: Earthquake,
      device: CachedPushDevice,
      original: QuakeFingerprint | undefined = duplicateOf.get(q.id)
    ): NotificationMatch | null => {
      const legacy = device.prefs.legacy;
      const ignoreSource = Boolean(legacy?.sourceFallbackEnabled)
        && isProviderUnavailableForPush(legacy!.source);
      return original
        ? shouldDeliverDuplicate(q, original, device.prefs, now, ignoreSource)
        : notificationMatch(q, device.prefs, now, ignoreSource);
    };

    if (!devices.length) {
      // registeredAt kontrolü sonradan kaydolan cihazlara eski depremi zaten
      // bildirmeyeceği için bu depremler güvenle işlenmiş sayılır.
      fresh.forEach(markHandled);
      console.log('Kayıtlı cihaz bulunamadı.');
      return;
    }

    console.log(`${fresh.length} adet taze deprem inceleniyor (${label})...`);

    // Normal teslimler tek push-state belgesine yazılır. Bu iki küme yalnızca
    // geçici FCM hatası yedeği ve geçersiz token temizliği için kullanılır.
    const dirtyDeviceKeys = new Set<string>();
    const invalidDeviceKeys = new Set<string>();
    // Bir cihaz bu scheduler turunda yalnızca bir bildirim alır; kalan
    // kayıtlar bildirim yağmuruna dönüşmez. Bu tek bildirimin turun en YENİ
    // değil en ÖNEMLİ olayı olması için teslim sırası büyüklüğe göre kurulur
    // (`orderQuakesForDelivery`): saf zaman sıralamasında saniyeler sonra
    // yayımlanan küçük bir artçı, ana şokun bildirimini bastırıp onu kalıcı
    // olarak "işlenmiş" işaretliyordu.
    const deliveredDeviceKeysThisRun = new Set<string>();

    for (const q of orderQuakesForDelivery(fresh)) {
      const quakeTime = new Date(q.date).getTime();
      let deferredByRunLimit = false;

      // Uzamsal ızgara: tüm cihazları (O(N)) gezmek yerine depremin
      // hücresindeki, eski kuraldaki ve dünya geneli dinleyen adaylara bakılır.
      // Adaylar `deviceByKey` üzerinden çözülür: yalnızca yetkisi süren
      // (`activeDevices`) cihazlar geçer ve `notified` güncellemesi önbellekteki
      // aynı nesneye yazılır. İndeks boşsa tüm cihazlara bakılır.
      const candidateDevices = spatialGridIndex.size > 0
        ? spatialGridIndex.queryCandidates(q.lat, q.lon, q.magnitude)
          .flatMap(candidate => deviceByKey.get(candidate.key) ?? [])
        : devices;

      let matchingDevices = candidateDevices.flatMap(device => {
        if (invalidDeviceKeys.has(device.key)) return [];
        if (deliveredDeviceKeysThisRun.has(device.key)) {
          // Bu cihaz depremi başka bir sebeple zaten istemiyorsa erteleme
          // sayılmamalı; aşağıdaki ana yolun aynı koşullarıyla gerçekten
          // eşleşiyor mu diye bakılır (`world_major` kanonik süzgeci dahil).
          const registeredAt = device.prefs.registeredAt || 0;
          if (quakeTime > registeredAt && !device.prefs.notified.includes(q.id)
              && matchFor(q, device)) {
            deferredByRunLimit = true;
          }
          return [];
        }
        // `registeredAt` eksikse (eski/bozuk kayıt) `now`'a düşmek cihazı HER
        // turda "az önce kaydoldu" gibi değerlendirir — quakeTime her zaman
        // geçmişte olduğundan bu, cihazı kalıcı ve sessizce tüm bildirimlerden
        // dışlardı. selectFreshQuakes zaten yalnızca PUSH_MAX_EVENT_AGE_MS
        // içindeki depremleri bu döngüye taşıdığı için 0'a düşmek eski deprem
        // yığını riski taşımaz.
        const registeredAt = device.prefs.registeredAt || 0;
        if (quakeTime <= registeredAt || device.prefs.notified.includes(q.id)) return [];
        const match = matchFor(q, device);
        return match ? [{ device, match }] : [];
      });

      if (!matchingDevices.length) {
        if (deferredByRunLimit) {
          // Bu depremi isteyen cihaz var; yalnızca tur başına tek bildirim
          // kuralına takıldı. İşlenmiş işaretlenirse bir daha hiç gönderilmez.
          console.log(`Deprem ${q.id} (${q.magnitude}) sonraki tura ertelendi.`);
          continue;
        }
        markHandled(q);
        continue;
      }

      // Servisler arası teslim defteri: aynı fiziksel depremi başka servis
      // (ya da başka ajans kaydıyla bu servis) zaten gönderdiyse cihaz
      // ikinci bildirimi almaz.
      const claim = await claimQuakeEvent(db, q);
      if (claim.status === 'taken') {
        console.log(`[Push Claim] Deprem ${q.id} (M${q.magnitude}) başka bir süreçte zaten iletildi (${label}).`);
        rememberForeignDelivery(q, claim.entry);
        markQuakeProcessed(q, !claim.entry.duplicateOf);
        continue;
      }
      if (claim.status === 'duplicate' && duplicateOf.get(q.id)?.id !== claim.original.id) {
        // Asıl kayıt başka serviste gönderilmiş; bu kopya yalnızca onu
        // istemeyen cihazlara gider.
        duplicateOf.set(q.id, claim.original);
        if (!handledQuakeFingerprints.some(item => item.id === claim.original.id)) {
          handledQuakeFingerprints.push(claim.original);
        }
        matchingDevices = matchingDevices.flatMap(({ device }) => {
          const match = matchFor(q, device, claim.original);
          return match ? [{ device, match }] : [];
        });
        if (!matchingDevices.length) {
          console.log(`[Push Claim] Deprem ${q.id} (M${q.magnitude}), ${claim.original.id} kaydının kopyası; ikinci bildirim engellendi (${label}).`);
          markQuakeProcessed(q, false);
          continue;
        }
      }

      // Olaydan gönderime geçen süre ve yakalayan tur: hızın tek ölçüsü.
      const lagSeconds = Math.round((Date.now() - quakeTime) / 1000);
      console.log(`Deprem ${q.id} (${q.magnitude}) için ${matchingDevices.length} eşleşen cihaz bulundu · olaydan ${lagSeconds} sn sonra · ${label}.`);

      const messages: admin.messaging.Message[] = [];
      const matchedDeviceKeys: string[] = [];

      for (const { device, match } of matchingDevices) {
        messages.push(buildQuakeMessage(device, q, match, Date.now()));
        matchedDeviceKeys.push(device.key);
      }

      let hadTransientFailure = false;
      const successfulDeviceKeys = new Set<string>();

      if (messages.length > 0) {
        const messageChunks = chunksOf(messages);
        const keyChunks = chunksOf(matchedDeviceKeys);
        const sendResults = await sendFcmBatches(messageChunks);

        sendResults.forEach((result, chunkIndex) => {
          if (result.status === 'rejected') {
            hadTransientFailure = true;
            console.error('Push batch gönderim hatası:', result.reason);
            return;
          }

          const chunkKeys = keyChunks[chunkIndex];
          console.log(`${messageChunks[chunkIndex].length} push bildirim işlendi.`);
          result.value.responses.forEach((response, index) => {
            const deviceKey = chunkKeys[index];
            const device = deviceByKey.get(deviceKey);
            if (response.success && device) {
              successfulDeviceKeys.add(deviceKey);
              deliveredDeviceKeysThisRun.add(deviceKey);
              return;
            }
            if (response.success) return;

            console.error('Cihaz push gönderim hatası:', response.error?.code);
            const code = response.error?.code;
            if (code === 'messaging/registration-token-not-registered') {
              invalidDeviceKeys.add(deviceKey);
            } else {
              hadTransientFailure = true;
            }
          });
        });
      }

      // Normal başarıda cihaz başına yazım yapma; depremi tek sistem belgesinde
      // tamamlandı olarak sakla. Yalnızca geçici FCM hatasında, başarılı cihazlar
      // retry sırasında mükerrer bildirim almasın diye eski `notified` yedeğini
      // devreye sokuyoruz.
      if (successfulDeviceKeys.size) rememberDelivered(q, duplicateOf.get(q.id), now);
      if (!hadTransientFailure) {
        markHandled(q);
      } else {
        successfulDeviceKeys.forEach(key => {
          const deviceObj = deviceByKey.get(key);
          if (!deviceObj || deviceObj.prefs.notified.includes(q.id)) return;
          deviceObj.prefs.notified.push(q.id);
          dirtyDeviceKeys.add(key);
        });
      }
    }

    // Nadir hata yolu: cihaz başına en fazla 1 retry-state update + silmeler.
    if (dirtyDeviceKeys.size > 0 || invalidDeviceKeys.size > 0) {
      const ops: { key: string; kind: 'update' | 'delete' }[] = [];
      for (const key of dirtyDeviceKeys) {
        if (!invalidDeviceKeys.has(key)) ops.push({ key, kind: 'update' });
      }
      for (const key of invalidDeviceKeys) {
        ops.push({ key, kind: 'delete' });
      }

      // Firestore batch sınırı 500 işlem: 450'lik parçalara böl.
      for (let i = 0; i < ops.length; i += 450) {
        const chunk = ops.slice(i, i + 450);
        const notifiedUpdate = (key: string) => {
          const deviceObj = deviceByKey.get(key);
          return deviceObj ? { notified: deviceObj.prefs.notified.slice(-300) } : null;
        };
        const batch = db.batch();
        for (const op of chunk) {
          const ref = db.collection('devices').doc(op.key);
          if (op.kind === 'delete') {
            batch.delete(ref);
          } else {
            const update = notifiedUpdate(op.key);
            if (update) batch.update(ref, update);
          }
        }
        const deletedKeys = chunk.filter(op => op.kind === 'delete').map(op => op.key);
        if (deletedKeys.length) {
          await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
        }
        try {
          await batch.commit();
        } catch (err: any) {
          // NOT_FOUND: yeniden deneme yedeği yazılacak cihaz bu arada kaydını
          // sildi (ör. /unregister). Eskiden tek bir silinmiş cihaz tüm partiyi
          // ve turu düşürüyor, ölü token silmeleri de kayboluyordu. Silmeler
          // ayrı partide, yedek güncellemeleri tek tek ve hatası yutularak yazılır.
          if (Number(err?.code) !== 5) {
            console.error('Birleştirilmiş cihaz yazımı hatası:', err);
            throw err;
          }
          console.warn('Cihaz yazımında silinmiş kayıt; parti ayrıştırılıyor.');
          if (deletedKeys.length) {
            const deletions = db.batch();
            deletedKeys.forEach(key => deletions.delete(db.collection('devices').doc(key)));
            await bumpDeviceRegistryRevision({ deletion: true, writer: deletions });
            await deletions.commit();
          }
          await Promise.all(chunk.filter(op => op.kind === 'update').map(op => {
            const update = notifiedUpdate(op.key);
            return update
              ? db.collection('devices').doc(op.key).update(update).catch(() => undefined)
              : undefined;
          }));
        }
        if (deletedKeys.length) forgetOwnDeletedPushDevices(deletedKeys);
      }
    }
    if (revisions.length) {
      await deliverMagnitudeRevisions(revisions, devices, now);
    }
  } catch (error) {
    // Bellekteki defter SİLİNMEZ: kalıcı belgenin üst kümesi ve henüz
    // yazılmamış teslimleri taşıyor. Silinip belgeden yeniden okunsaydı bu
    // turda gönderilmiş ama yazılmamış bir deprem yeniden gönderilirdi.
    console.error('Planlanmış push kontrolü çalışırken hata:', error);
    // Scheduler retry yapılandırmasının devreye girmesi için hatayı yutma.
    throw error;
  }
}

// MARK: - Tsunami uyarısı teslimi (bkz. tsunami-alerts.ts)
//
// Tsunami bir can güvenliği uyarısıdır: ücretsiz/premium ayrımı yapılmaz ve
// kullanıcının deprem eşiklerine bakılmaz. Cihazın kayıtlı yerlerinden (ya da
// eski kuraldaki konumundan) biri uyarı merkezine seviyenin yarıçapı içindeyse
// gönderilir. Aynı uyarı bir kez gider; kimlikler teslim durumu belgesinde,
// mevcut yazımla birlikte saklanır (ek yazım yok).
const sentTsunamiAlertIds = new Set<string>();
const TSUNAMI_IDS_MAX = 60;

function deviceCoordinates(device: CachedPushDevice): Array<{ lat: number; lon: number }> {
  const legacy = device.prefs.legacy;
  if (legacy) {
    return Number.isFinite(legacy.latitude) && Number.isFinite(legacy.longitude)
      ? [{ lat: legacy.latitude!, lon: legacy.longitude! }]
      : [];
  }
  return device.prefs.places.filter(place => Number.isFinite(place.lat) && Number.isFinite(place.lon));
}

export function tsunamiRecipients(devices: CachedPushDevice[], alert: TsunamiAlert): Array<{ device: CachedPushDevice; distanceKm: number }> {
  const radius = tsunamiAlertRadiusKm(alert.level);
  const recipients: Array<{ device: CachedPushDevice; distanceKm: number }> = [];
  for (const device of devices) {
    let nearest = Infinity;
    for (const point of deviceCoordinates(device)) {
      nearest = Math.min(nearest, getDistanceKm(alert.lat, alert.lon, point.lat, point.lon));
    }
    if (nearest <= radius) recipients.push({ device, distanceKm: nearest });
  }
  return recipients;
}

export function buildTsunamiMessage(device: CachedPushDevice, alert: TsunamiAlert, now: number): admin.messaging.Message {
  const { title, body } = buildTsunamiNotification(alert, device.prefs.lang);
  const urgent = alert.level === 'warning' || alert.level === 'threat';
  const sound = normalizedNotificationSound(device.prefs.notificationSound);
  const aps: Record<string, unknown> = {
    alert: { title, body },
    'thread-id': alert.id.slice(0, 64),
    'interruption-level': urgent && device.prefs.criticalAlertsEnabled ? 'critical' : 'time-sensitive',
    'relevance-score': 1,
    sound: urgent && device.prefs.criticalAlertsEnabled
      ? { critical: true, name: normalizedCriticalSound(device.prefs.criticalNotificationSound) || sound, volume: 1.0 }
      : sound
  };
  const message: admin.messaging.Message = {
    token: device.token,
    notification: { title, body },
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-push-type': 'alert',
        'apns-expiration': String(Math.floor(now / 1000) + 30 * 60),
        'apns-collapse-id': alert.id.slice(0, 64),
        'apns-topic': 'com.kayasoftware.sismik'
      },
      payload: {
        aps,
        // Eski istemci tanımadığı türe dokununca boş deprem detayı açıyordu;
        // `admin_manual`'ı tanır (açıkken de banner gösterir, dokununca ana
        // sayfa). 2.1.4+ `tsunami` alanını görünce toplanma alanlarını açar.
        notificationKind: 'admin_manual',
        tsunami: { agency: alert.agency, level: alert.level, region: alert.region, lat: alert.lat, lon: alert.lon },
        sentAt: new Date(now).toISOString()
      }
    }
  };
  return attachApnsTarget(message, device.apnsToken, device.apnsEnv);
}

/// Yeni tsunami uyarılarını teslim eder. Uyarı yoksa cihaz okunmaz.
export async function deliverTsunamiAlerts(db: Firestore, alerts: TsunamiAlert[], now: number): Promise<void> {
  if (!pushDeliveryStateLoaded) await loadProcessedQuakes();
  const pending = alerts.filter(alert => !sentTsunamiAlertIds.has(alert.id)
    && now - alert.issuedAt <= TSUNAMI_ALERT_MAX_AGE_MS && alert.issuedAt <= now + 60_000);
  if (!pending.length) return;
  const devices = await loadPushDevices(db, now);
  for (const alert of pending) {
    sentTsunamiAlertIds.add(alert.id);
    pushDeliveryStateDirty = true;
    const recipients = tsunamiRecipients(devices, alert);
    if (!recipients.length) {
      console.log(`Tsunami uyarısı ${alert.id} (${alert.agency} ${alert.level}): yakında kayıtlı cihaz yok.`);
      continue;
    }
    const messages = recipients.map(({ device }) => buildTsunamiMessage(device, alert, now));
    const summary = await sendFcmMessages(messages, `tsunami:${alert.id}`);
    console.log(`Tsunami uyarısı ${alert.id} (${alert.agency} ${alert.level}, ${alert.region}): ${summary.successCount} gönderildi, ${summary.failureCount} hata.`);
  }
  while (sentTsunamiAlertIds.size > TSUNAMI_IDS_MAX) {
    sentTsunamiAlertIds.delete(sentTsunamiAlertIds.values().next().value as string);
  }
}

/// Tüm teslim turlarının (dakikalık taramalar ve gerçek zamanlı alım) tek
/// sırası. Gerçek zamanlı alıcı eskiden turları doğrudan, zamanlanmış
/// turlarla EŞZAMANLI çalıştırıyordu: iki tur aynı cihaz önbelleğini aynı anda
/// tazeleyip çift delta okuması yapıyor, aynı depremi iki kez değerlendirip
/// yalnızca teslim kilidine yaslanıyordu.
let pushPassChain: Promise<void> = Promise.resolve();

/// Duraklatma günlüğü dakikada en fazla bir kez yazılır.
let pushPausedLoggedAt = 0;
function notePushPaused(label: string): void {
  if (Date.now() - pushPausedLoggedAt < 60_000) return;
  pushPausedLoggedAt = Date.now();
  console.warn(`Bildirimler uzak yapılandırmayla duraklatıldı (push_paused); tur atlandı: ${label}.`);
}

export function enqueuePushPass(
  db: Firestore,
  quakes: Earthquake[],
  includeRevisions: boolean,
  label: string
): Promise<void> {
  const pass = pushPassChain.then(() => runPushPass(db, quakes, Date.now(), includeRevisions, label));
  pushPassChain = pass.catch(() => undefined);
  return pass;
}

/// Tsunami kontrolü: NOAA akışı teslim sırasının DIŞINDA okunur (yavaş bir
/// istek deprem bildirimlerini bekletmesin); yalnızca teslim sıraya girer.
export async function runTsunamiCheck(db: Firestore, quakes: Earthquake[]): Promise<void> {
  try {
    await refreshRemoteConfigFromSource();
    if (remoteServerConfig().tsunami_paused) return;
    const alerts = [...await fetchNOAATsunamiAlerts(), ...alertsFromQuakes(filterPublicQuakes(quakes))];
    if (!alerts.length) return;
    const pass = pushPassChain.then(() => deliverTsunamiAlerts(db, alerts, Date.now()));
    pushPassChain = pass.catch(() => undefined);
    await pass;
  } catch (error: any) {
    console.error('Tsunami kontrolü başarısız:', error?.message || error);
  }
}

/// Hızlı taramaların dakika içindeki sabit saniyeleri (duvar saati). Tur
/// başlar başlamaz bir kez tarar, ardından kalan saniyelerde devam eder.
///
/// Cloud Scheduler dakikayı 2–25 sn gecikmeyle tetikliyor (ölçüldü). Taramalar
/// turun başlangıcına göre planlandığında :16'da başlayan tur bir sonraki
/// dakikanın tetiklemesiyle çakışıyor (tek örnek, eşzamanlılık 1 → tetikleme
/// düşüyor), geç başlayan turda ise yalnızca iki tarama sığıyordu. Sabit
/// saniyeler taramalar arası boşluğu her durumda ~15 sn'de tutar; son tarama
/// en geç :50'de başladığı için tur dakika bitmeden biter.
// Maliyeti ücretsiz kota sınırları içinde tutmak ve bildirim gecikmesini dengeli kılmak
// için dakikada 2 hızlı tarama yapılır: başlangıç anı (0. sn) ve 30. saniye.
// Tur ~32. saniyede biter; Cloud Functions'ın 55 saniye boyunca boşta uyanık kalması engellenir.
// AFAD ve NOA'nın gerçek zamanlı akışı yok; yeni kayıt yalnızca taramayla
// görülür. 15 sn aralık: AFAD'da yayımlanan deprem en geç ~15 sn içinde
// bildirime ve listeye girer (eskiden :00 ve :30, en geç ~30 sn). Her ek
// tarama ayrı kısa bir Cloud Tasks çağrısıdır (~2–4 sn, 256 MiB).
const FAST_SCAN_SECONDS = [15, 30, 45];
/// İlk (anında) taramaya bu kadar yakın sabit saniye atlanır.
const FAST_SCAN_MIN_GAP_MS = 8_000;

/// Görev kuyruğundan gelen tek hızlı tarama (dakikanın :30'u). Yalnızca son
/// dakikaları tarar ve teslim eder; tam toplama, anlık görüntü ve Twitter
/// dakikalık turda kalır. Aynı deprem iki kez gönderilmez: deprem başına
/// teslim defteri (`claimQuakeEvent`) servisler arasında ortaktır.
export async function runFastPushScan(db: Firestore): Promise<void> {
  try {
    // EMSC ve USGS de taranır. Eskiden "anlık akış karşılıyor" diye
    // atlanıyordu; ama akış dakikalık turun sürecinde ve Cloud Run istek
    // dışında CPU vermiyor — EMSC fiilen dakikada bir görülüyordu.
    const recent = await collectRecentQuakesForPush(Date.now());
    const slow = Object.entries(recent.timings)
      .filter(([, value]) => value.ms >= 3000)
      .map(([name, value]) => `${name} ${value.ms}ms`);
    if (slow.length) console.warn(`Hızlı taramada yavaş kaynak — ek tarama: ${slow.join(', ')}`);
    if (recent.quakes.length) {
      // Bildirim önce; liste güncellemesi bildirimi geciktirmez.
      await enqueuePushPass(db, recent.quakes, false, 'hızlı tarama');
      await publishScanQuakes(recent.quakes);
    }
  } finally {
    await flushPushDeliveryState().catch(error => {
      console.error('Push teslim durumu yazılamadı; sonraki turda yeniden denenecek:', error?.message || error);
    });
    flushApnsStats();
  }
}

/// Canlı alım (EMSC WebSocket, USGS yoklayıcı) bu servisin sürecinde çalışır;
/// ama Cloud Run istek dışında CPU'yu kısar. 24 Eylül 2026 Şanlıurfa
/// depreminde WebSocket kaydı 10:43:25'te geldi, cihaz sorgusu ise ancak bir
/// sonraki tur başlayınca (10:44:02) sürebildi: 37 sn. Tur dakikanın sonuna
/// kadar açık tutulunca süreç hep bir istek içinde olur ve CPU kısılmaz;
/// canlı gelen deprem saniyeler içinde işlenir. :15/:30/:45 taramaları da
/// ayrı çağrıya devredilmeden turun içinde yapılır (süreç zaten uyanık).
/// Bedeli: tur ~25 sn yerine ~56 sn faturalanır.
async function holdOpen(until: number): Promise<void> {
  const wait = until - Date.now();
  if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait));
}

/// Dakikalık zamanlayıcı turu.
///
/// - Hızlı tarama (2 kez: +0 sn ve :30): kaynaklardan yalnızca son dakikalar,
///   kısa süreyle (`collectRecentQuakesForPush`). Takılan kaynak diğerlerini
///   bekletmez.
/// - Tam tarama (1 kez): 24 saatlik toplama arka planda sürer; bittiğinde
///   liste anlık görüntüsü, Twitter ve büyüklük düzeltmeleri ile birlikte bir
///   teslim turu daha çalışır. Hızlı taramanın kaçırdığı bir kayıt (ör. kaynak
///   o an yanıt vermedi) burada yakalanır; işlenmiş deprem defteri ikinci
///   gönderimi engeller.
///
/// Turlar gerçek zamanlı alımla aynı kuyrukta sırayla işlenir
/// (`enqueuePushPass`); teslim durumu tur sonunda tek yazımla kalıcılaşır.
export async function runScheduledPushCheck(
  db: Firestore,
  runAutomaticTwitterPosting: (quakes: Earthquake[], now: number) => Promise<void>,
  /// :30 taramasını ayrı, kısa bir çağrıya devreder (Cloud Tasks). `true`
  /// dönerse bu tur o saniyeyi beklemez; yoksa/başarısızsa tarama eskisi
  /// gibi turun içinde yapılır — hiçbir koşulda tarama kaybolmaz.
  scheduleFastScan?: (at: number) => Promise<boolean>,
  /// Tur, dakikanın bu saniyesine kadar açık tutulur (bkz. `holdOpen`).
  holdOpenUntilSecond?: number
): Promise<void> {
  const startedAt = Date.now();
  const tweetJobs: Promise<void>[] = [];
  /// Tsunami ve Canlı Etkinlik gibi teslimi bloklamayan yan işler.
  const sideJobs: Promise<void>[] = [];
  let bookkeepingWork: Promise<unknown> | undefined;
  let passQueue: Promise<void> = Promise.resolve();
  let failedPasses = 0;
  let totalPasses = 0;
  let fullQuakeCount = -1;

  const enqueue = (label: string, quakes: Earthquake[], includeRevisions: boolean) => {
    totalPasses++;
    passQueue = enqueuePushPass(db, quakes, includeRevisions, label)
      .catch(error => {
        failedPasses++;
        console.error(`Push turu başarısız (${label}):`, error?.message || error);
      });
    return passQueue;
  };

  // Tam toplama beklenmeden başlar; hazır olunca kendi turunu kuyruğa ekler.
  const fullWork = collectQuakes().then(quakes => {
    fullQuakeCount = quakes.length;
    if (!quakes.length) return;
    const now = Date.now();
    // Canlı anlık görüntü ve Twitter bildirim kararına girmez; bağımsız
    // başlar, `finally`'de beklenir.
    // Hızlı yoldan eklenmiş ama bu turda kaynağı yanıt vermemiş taze
    // kayıtlar korunur; yazımlar sıraya girer (bkz. publishFullLiveSnapshot).
    bookkeepingWork = publishFullLiveSnapshot(quakes);
    tweetJobs.push(runAutomaticTwitterPosting(quakes, now));
    sideJobs.push(runTsunamiCheck(db, quakes));
    return enqueue('tam', quakes, true);
  }).catch(error => {
    fullQuakeCount = 0;
    console.error('Tam deprem toplaması başarısız:', error?.message || error);
  });

  try {
    const slowScans: string[] = [];
    const minuteStart = Math.floor(startedAt / 60_000) * 60_000;
    const laterScans = FAST_SCAN_SECONDS
      .map(second => minuteStart + second * 1000)
      .filter(time => time >= startedAt + FAST_SCAN_MIN_GAP_MS);
    // Sonraki taramalar ayrı kısa çağrılara devredilir: tur :30'u beklerken
    // açık kalan istek, faturalanan sürenin ~%80'iydi (tur ~28 sn sürüyordu).
    // Görev ekleme ilk taramayla paralel başlar; ilk taramayı geciktirmez.
    const delegation = scheduleFastScan && laterScans.length
      ? Promise.all(laterScans.map(at => scheduleFastScan(at).catch(() => false)))
      : Promise.resolve(laterScans.map(() => false));
    const scanTimes = [startedAt, ...laterScans];
    const lastStart = minuteStart + FAST_SCAN_SECONDS[FAST_SCAN_SECONDS.length - 1] * 1000;
    let delegated: boolean[] | undefined;
    for (const [index, scanAt] of scanTimes.entries()) {
      if (index > 0) {
        delegated ??= await delegation;
        if (delegated[index - 1]) continue;
      }
      const wait = scanAt - Date.now();
      if (wait > 0) await new Promise(resolve => setTimeout(resolve, wait));
      // Önceki tarama uzadıysa geç kalan tarama atlanır; tur dakikayı aşmaz.
      if (Date.now() > Math.max(lastStart, startedAt) + 2_000) break;
      const offset = Math.round((scanAt - startedAt) / 1000) * 1000;
      const recent = await collectRecentQuakesForPush();
      const slow = Object.entries(recent.timings)
        .filter(([, value]) => value.ms >= 3000)
        .map(([name, value]) => `${name} ${value.ms}ms`);
      if (slow.length) slowScans.push(`+${offset / 1000}s: ${slow.join(', ')}`);
      if (recent.quakes.length) {
        // Yeni depremler tam turu beklemeden listeye girer (yalnızca yeni
        // kimlik varsa yazılır).
        void publishFreshQuakes(recent.quakes);
        // Twitter da tam turu beklemez: ilk görülen ajans kaydı paylaşılır.
        tweetJobs.push(runAutomaticTwitterPosting(recent.quakes, Date.now()));
        await enqueue(`hızlı +${offset / 1000}s`, recent.quakes, false);
      }
    }
    await fullWork;
    await passQueue;
    if (holdOpenUntilSecond) {
      await holdOpen(Math.floor(startedAt / 60_000) * 60_000 + holdOpenUntilSecond * 1000);
      // Açık kalırken canlı akıştan gelen turlar da bitsin.
      await passQueue;
    }
    // Yavaş kaynak dakikada tek satır: hangi ajansın gecikme yarattığı görünür.
    if (slowScans.length) console.warn(`Hızlı taramada yavaş kaynak — ${slowScans.join(' | ')}`);
    // Zamanlayıcının yeniden deneme yapılandırması: her şey boş döndüyse ya da
    // turların tamamı başarısızsa hata fırlatılır.
    if (fullQuakeCount === 0 && totalPasses === 0) {
      throw new Error('Canlı deprem kaynaklarının tamamı boş döndü');
    }
    if (totalPasses > 0 && failedPasses === totalPasses) {
      throw new Error('Push turlarının tamamı başarısız');
    }
  } finally {
    // Teslimi bloklamayan yan işler burada toplanır: sunucusuz yürütme
    // fonksiyon dönünce dondurulduğu için yarım kalmalarına izin verilmez.
    // Teslim durumu turun sonunda TEK yazımla kalıcılaştırılır.
    await Promise.allSettled([
      ...tweetJobs,
      ...sideJobs,
      bookkeepingWork,
      flushPushDeliveryState().catch(error => {
        console.error('Push teslim durumu yazılamadı; sonraki turda yeniden denenecek:', error?.message || error);
      })
    ]);
    flushApnsStats();
  }
}
