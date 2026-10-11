import { withExecutionLease } from './execution-lease';
// Sismik Cloud Functions Backend Engine - Optimized v2.4 (Performance & Cost Efficient)
// Low-latency in-memory device registry caching, HTTP ETag & Gzip response compression.
import { onRequest } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { onTaskDispatched } from 'firebase-functions/v2/tasks';
import { getFunctions } from 'firebase-admin/functions';
import * as admin from 'firebase-admin';
import express from 'express';
import cors from 'cors';
import compressionMiddleware from 'compression';
import { registerSubscriptionRoutes } from './subscription-routes';
import { registerDeviceRoutes } from './device-routes';
import {
  isRateLimited,
  registerConfigRoute,
  runMaintenanceSweep
} from './admin-routes';
import { runPremiumEngagementCampaign } from './premium-campaign';
import {
  registerEarthquakeRoutes,
  isLiveSnapshotCached,
  getLiveSnapshotRef
} from './earthquake-routes';
import {
  initPushRoutes,
  bumpDeviceRegistryRevision,
  sendFcmMessages,
  normalizedNotificationSound,
  runScheduledPushCheck,
  runFastPushScan,
  startRealtimeIngestion
} from './push-routes';
import { registerAiRoutes } from './ai-routes';
import { registerAppUpdateRoutes } from './app-update';
import { runAutomaticTwitterPosting } from './twitter-posting';
import { initRemoteConfig } from './remote-config';
import { registerSafetyPlacesRoute } from './safety-places';

admin.initializeApp();
const db = admin.firestore();

const app = express();
// Firebase Hosting `/api/**` yeniden yazımı yolu ön ekiyle birlikte iletir.
// Aynı uygulama hem doğrudan Cloud Run URL'inde hem de CDN arkasında
// çalışabilsin diye ön ek burada soyulur; rota tanımları değişmez.
app.use((req, _res, next) => {
  if (req.url === '/api') req.url = '/';
  else if (req.url.startsWith('/api/')) req.url = req.url.slice(4);
  else if (req.url.startsWith('/api?')) req.url = '/' + req.url.slice(4);
  next();
});
app.use(cors({ origin: true }));
// Tüm yanıtlar gzip'lenir: 6,6 MB'lık /faults ~0,8 MB'a, ~300 KB'lık deprem
// JSON'ları ~35-40 KB'a iner. Çıkış trafiği (egress) en büyük maliyet
// kalemiydi; sıkıştırma tek başına ~%85 azaltır.
app.use(compressionMiddleware({ threshold: 1024 }));
app.use(express.json());

// MARK: - Deprem verisi ve istatistik rotaları (functions/src/earthquake-routes.ts)
// `/`, `/history`, `/map`, `/map-range`, `/aftershocks`, `/faults`, `/stats`.
// Uzak yapılandırma (functions/src/remote-config.ts): `_system/remote_config_v1`.
initRemoteConfig(db);
registerEarthquakeRoutes(app, db);

// MARK: - Push bildirim durumu (functions/src/push-routes.ts)
// `db`'ye bağlı push referanslarını (cihaz kaydı revizyonu, push teslim
// durumu) bir kez atar; `sendFcmMessages`, `bumpDeviceRegistryRevision`,
// `normalizedNotificationSound`, `buildNotificationText` ve
// `runScheduledPushCheck` bu modülden import edilir.
const functionTarget = String(process.env.FUNCTION_TARGET || process.env.K_SERVICE || '').toLowerCase();
// Teslim durumu ve cihaz snapshot'ı yalnızca dakikalık turda yazılır; hızlı
// tarama aynı belgeleri üzerine yazıp dakikalık turun defterini siliyordu.
initPushRoutes(db, { persistState: functionTarget !== 'fastpushscan' });
// Dört fonksiyon da aynı modülü yükler. Gerçek zamanlı alım (EMSC WebSocket +
// USGS yoklayıcı) yalnızca tek örnekli `scheduledPushCheck` servisinde
// çalışır: eskiden sismikApi'nin her örneği ve bakım servisi de kendi
// alıcısını açıyor, aynı depremi üç kez işliyor ve her soğuk açılışta tüm
// premium cihazları Firestore'dan yeniden okuyordu.
const isPushService = [process.env.FUNCTION_TARGET, process.env.K_SERVICE]
  .some(name => String(name || '').toLowerCase() === 'scheduledpushcheck');
if (isPushService && process.env.NODE_ENV !== 'test' && process.env.ENABLE_REALTIME_INGESTION !== '0') {
  startRealtimeIngestion(db, runAutomaticTwitterPosting);
}

// MARK: - AI Analizi (functions/src/ai-routes.ts)
// `/ai`, `/ai/ask`, `/ai/stats-summary`.
registerAiRoutes(app, db, isRateLimited);

// MARK: - Toplanma alanları ve sağlık noktaları (functions/src/safety-places.ts)
// Hücre bazlı ortak önbellek: `/safety-places?lat=&lon=&radius=`.
registerSafetyPlacesRoute(app, db, isRateLimited);

// MARK: - Abonelik/entitlement rotaları (functions/src/subscription-routes.ts)
registerSubscriptionRoutes(app, db);

// MARK: - App Store Connect sürüm webhook'u (functions/src/app-update.ts)
registerAppUpdateRoutes(app, db);

// MARK: - Cihaz kayıtları (functions/src/device-routes.ts)
registerDeviceRoutes(app, db, isRateLimited, bumpDeviceRegistryRevision, normalizedNotificationSound);

// MARK: - Eski istemcilerin sürüm kontrolü (functions/src/admin-routes.ts)
registerConfigRoute(app);

// 9) Sağlık Kontrolü
app.get('/health', async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.query.deep !== '1') {
    res.json({
      status: 'healthy',
      snapshotCached: isLiveSnapshotCached(),
      timestamp: new Date().toISOString()
    });
    return;
  }
  try {
    const startTime = Date.now();
    await getLiveSnapshotRef().get();
    const duration = Date.now() - startTime;
    res.json({
      status: 'healthy',
      dbLatencyMs: duration,
      timestamp: new Date().toISOString()
    });
  } catch (error: any) {
    res.status(500).json({ status: 'unhealthy', error: error.message });
  }
});

/// Doğrudan APNs ve Canlı Etkinlik yayın kanalı sırları (apns.ts). Push
/// gönderen her fonksiyona verilir; yoksa gönderim FCM'den yapılır.
const APNS_SECRETS = ['APNS_AUTH_KEY', 'APNS_KEY_ID', 'APNS_TEAM_ID'];

// V2 HTTP Cloud Function
// minInstances:0 boşta instance ücretini kaldırır. Düşük trafikli uygulamada
// olası kısa soğuk başlangıç, sürekli çalışan instance maliyetinden daha uygundur.
export const sismikApi = onRequest({
  cors: true,
  // Twitter sırları yalnızca otomatik paylaşımı yapan scheduledPushCheck'te.
  secrets: ['GEMINI_API_KEY', 'REVENUECAT_API_KEY', 'REVENUECAT_WEBHOOK_SECRET', 'REVENUECAT_PROJECT_ID', 'ASC_WEBHOOK_SECRET', ...APNS_SECRETS],
  minInstances: 0,
  // Büyük depremde tüm kullanıcılar aynı dakikada uygulamayı açar; CDN
  // ıskaları ve kişiye özel uçlar (kayıt, hissettim, AI) için tavan geniş.
  // Örnek yalnızca kullanıldığında faturalanır.
  maxInstances: 40,
  // Ölçülen günlük p99 bellek ~%35 (~360 MB, 22 Eyl 2026): bellek içi deprem
  // arşivi, harita önbelleği ve 20 eşzamanlı istek. 512 MiB'de pay ~%30'a
  // iner; büyük bir depremdeki trafik sıçramasında taşma riski yüzünden
  // 1 GiB'de tutuluyor.
  memory: '1GiB',
  // Cloud Run eşzamanlılık > 1 için tam vCPU şart koşuyor; `gcf_gen1` 1 GiB'de
  // 0.583 vCPU veriyordu ve deploy reddediliyordu. Tam çekirdeğin saniye
  // ücreti bir miktar yüksek, ama tek instance 20 isteği karşıladığı için
  // toplam instance-saati kat kat düşüyor.
  cpu: 1,
  // `concurrency: 1` her eşzamanlı isteğe ayrı bir 1 GiB instance ayırıyordu:
  // Cloud Run instance-saati kullanıcı sayısıyla doğrusal büyüyor, üstelik
  // maxInstances 3 ile aynı anda yalnızca 3 istek işlenebiliyordu. Bellek içi
  // önbellekler modül düzeyinde ve salt-okunur paylaşıldığı için tek instance
  // çok isteği güvenle karşılar.
  concurrency: 20
}, app);

// V2 Scheduled Cloud Function
//
// Gövdesi functions/src/push-routes.ts'teki `runScheduledPushCheck`'e
// taşındı (Task 10a); export adı ve tetikleyici yapılandırması burada,
// değişmeden kalır. Otomatik Twitter/X paylaşımı (functions/src/twitter-posting.ts'teki
// `runAutomaticTwitterPosting`) push mantığından bağımsız bir bağımlılık
// olarak geçirilir.
/// Dakikalık tur bu saniyeye kadar açık kalır (0: kapalı).
const SCHEDULED_HOLD_OPEN_SECOND = 0;

export const scheduledPushCheck = onSchedule({
  schedule: 'every 1 minutes',
  timeoutSeconds: 180,
  timeZone: 'Europe/Istanbul',
  retryCount: 2,
  minBackoffSeconds: 10,
  maxBackoffSeconds: 30,
  maxDoublings: 1,
  maxInstances: 1,
  // 512 MiB: 256 MiB'de günlük p99 bellek %91–96'ya çıkıyordu (22 Eyl 2026
  // ölçümü, tepe ~245 MB) — taşma bu turu, dolayısıyla bildirimleri
  // düşürürdü. 512 MiB'de pay ~%50; ek maliyet ayda ~0,20 $ (gcf_gen1 ile
  // 0,333 vCPU). 1 GiB gereksiz: işlemci de 0,583'e çıkıp ~3 $/ay tutar.
  memory: '512MiB',
  cpu: 'gcf_gen1',
  concurrency: 1,
  secrets: ['TWITTER_API_KEY', 'TWITTER_API_SECRET', 'TWITTER_ACCESS_TOKEN', 'TWITTER_ACCESS_SECRET', ...APNS_SECRETS]
}, async () => {
  // Tur dakikanın 56. saniyesine kadar açık kalır: canlı alım CPU kısıtına
  // takılmaz (bkz. push-routes.ts `holdOpen`). Kapatmak için 0 yapılır;
  // o zaman :15/:30/:45 taramaları yine ayrı çağrılara devredilir.
  await withExecutionLease(db, 'scheduled_push_lease_v1', 240_000,
    () => runScheduledPushCheck(db, runAutomaticTwitterPosting,
      SCHEDULED_HOLD_OPEN_SECOND ? undefined : scheduleFastPushScan, SCHEDULED_HOLD_OPEN_SECOND));
});


/// Dakikanın :15, :30 ve :45 taramaları için görev ekler. Görev kimliği o saniyeye bağlıdır:
/// zamanlayıcı turu yeniden denese de aynı tarama iki kez kuyruğa girmez.
async function scheduleFastPushScan(at: number): Promise<boolean> {
  try {
    await getFunctions().taskQueue('fastPushScan').enqueue(
      { at },
      { scheduleTime: new Date(at), id: `fast-${at}`, dispatchDeadlineSeconds: 60 }
    );
    return true;
  } catch (error: any) {
    if (error?.code === 'functions/task-already-exists') return true;
    // Kuyruk yoksa/izin eksikse tarama turun içinde yapılır (eski davranış).
    console.warn('Hızlı tarama görevi eklenemedi; tur içinde taranacak:', error?.message || error);
    return false;
  }
}

// MARK: - Dakikanın :15/:30/:45 hızlı taramaları (Cloud Tasks)
//
// Eskiden dakikalık tur :30'daki ikinci taramayı açık istekte ~25 sn bekleyerek
// yapıyordu; bekleme de faturalanıyordu (turun ~%80'i). Artık tur ~5 sn'de
// biter, :30 taraması bu kısa çağrıda yapılır. Gecikmiş görev (ör. kuyruk
// tıkanması) taranmaz: bir sonraki dakikalık tur zaten başlamıştır.
export const fastPushScan = onTaskDispatched<{ at?: number }>({
  retryConfig: { maxAttempts: 1 },
  rateLimits: { maxConcurrentDispatches: 1 },
  memory: '256MiB',
  cpu: 'gcf_gen1',
  maxInstances: 1,
  concurrency: 1,
  timeoutSeconds: 60,
  secrets: APNS_SECRETS
}, async (request) => {
  const scheduledFor = Number(request.data?.at) || Date.now();
  if (Date.now() - scheduledFor > 20_000) {
    console.warn('Geç kalan hızlı tarama atlandı:', Math.round((Date.now() - scheduledFor) / 1000), 'sn');
    return;
  }
  await runFastPushScan(db);
});

// MARK: - İzinli Premium özellik tanıtımları
//
// Apple 4.5.4 gereği yalnızca uygulama içinde açıkça izin veren, aktif Premium
// hakkı bulunmayan cihazlar hedeflenir. Ayrı scheduler, pazarlama gönderiminin
// deprem ve abonelik doğrulama görevlerini hiçbir koşulda yavaşlatmamasını
// sağlar. Gövdesi functions/src/premium-campaign.ts'te.
export const premiumEngagementCampaign = onSchedule({
  schedule: '0 18 * * 0',
  timeZone: 'Europe/Istanbul',
  retryCount: 0,
  maxInstances: 1,
  timeoutSeconds: 540,
  memory: '256MiB',
  cpu: 'gcf_gen1',
  concurrency: 1,
  secrets: APNS_SECRETS
}, async () => {
  await runPremiumEngagementCampaign(db);
});

// MARK: - Saatlik bakım turu
//
// Tek bir Scheduler işi birden fazla bakım görevini sırayla yürütür: süresi
// dolan yetkileri kapatır, otomasyonları ve sürüm kuralını çalıştırır, harita
// arşivini (iki saatte bir) ve günlük temizliği (04:05) tetikler. Ayrı işler
// açmamak bilinçli — her biri kendi Cloud Run örneğini ayağa kaldırırdı.
// Görevlerin hiçbiri 15 dakikalık sıklık gerektirmiyordu: süresi dolan
// abonelik bildirim anında zaten eleniyor, harita iki saatte, temizlik günde
// bir çalışıyor. Saatlik tur çağrıları ve boş sorguları dörtte birine indirir.
// Gövdesi functions/src/admin-routes.ts'teki `runMaintenanceSweep`.
export const maintenanceSweep = onSchedule({
  schedule: '5 * * * *',
  timeZone: 'Europe/Istanbul',
  maxInstances: 1,
  memory: '256MiB',
  cpu: 'gcf_gen1',
  concurrency: 1,
  timeoutSeconds: 180,
  secrets: APNS_SECRETS
}, async () => {
  await runMaintenanceSweep(db, sendFcmMessages, Date.now());
});
