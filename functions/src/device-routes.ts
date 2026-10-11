import { createHash } from 'node:crypto';
import * as admin from 'firebase-admin';
import { FieldValue, Firestore } from 'firebase-admin/firestore';
import express from 'express';
import {
  RevenueCatEntitlement,
  decideDeviceEntitlement,
  deviceRegistrationHeartbeatDue,
  deviceRegistrationNeedsWrite,
  sanitizeDevicePlaces,
  isValidPushToken,
  normalizePushToken,
  isPushCandidate
} from './worker-utils';
import { VerifiedSubscription, verifyTransactionJWS } from './subscription-verification';
import { normalizedCriticalSound } from './push-routes';
import { normalizeNotificationStyle } from './notification-templates';
import { resolveRevenueCatEntitlement } from './subscription-routes';

// MARK: - Cihaz kayıtları (bildirimler için)

/// Log satırlarında cihaz kimliği yerine kısa bir parmak izi kullanılır.
/// Push token'ı (ve normalize edilmiş hâli olan `device_key`) kişisel veridir;
/// abonelik durumuyla birlikte loglanması yasak. SHA-256'nın ilk 12 hane'si
/// destek için aynı cihazın satırlarını eşleştirmeye yeter, token'ı geri
/// vermez.
function deviceLogId(deviceKey: string): string {
  return `dev_${createHash('sha256').update(deviceKey).digest('hex').slice(0, 12)}`;
}

async function optionalAuthenticatedUID(req: any): Promise<string | null> {
  const header = String(req.headers.authorization || '');
  if (!header.startsWith('Bearer ')) return null;
  try {
    return (await admin.auth().verifyIdToken(header.slice(7), true)).uid;
  } catch {
    return null;
  }
}

// MARK: - "Hissettim" raporları (Premium özellik)
//
// Anonim, kimliksiz sayaç: deprem başına tek belge, atomik artırma.
// Mükerrer koruması istemcide (UserDefaults) + IP rate limitinde; kritik
// olmayan sosyal bir sinyal olduğu için sunucuda kimlik tutulmaz.
//
// index.ts'ten taşındı (Task 10b): `/register`/`/unregister` ile aynı cihaz
// bağlamını kullandığı için buraya taşındı.
const feltCountCache = new Map<string, { count: number; notFeltCount: number; cells: { lat: number; lon: number; count: number }[]; at: number }>();

function feltDocId(id: string): string {
  return id.replace(/\//g, '_').slice(0, 200);
}

/// Büyük bir depremde binlerce kullanıcı dakikalar içinde "Hissettim"e
/// basar. Tek belgeye artırım Firestore'un belge başına ~1 yazım/sn sınırına
/// takılıyor, istekler çekişmeden 503 dönüyordu. Yazımlar `FELT_SHARD_COUNT`
/// parça belgeye rastgele dağıtılır; okuma ana belge (eski sayaçlar) + parçaları
/// toplar ve 60 sn önbelleklenir.
export const FELT_SHARD_COUNT = 10;

export function feltShardId(key: string, shard: number): string {
  return `${key}__s${shard}`;
}

/// "Hissettim haritası" hücresi: 0,1° (~11 km) ızgara. Kişinin konumu
/// saklanmaz; yalnızca hücrenin sayacı artar. Anahtar Firestore alan yolunda
/// kullanıldığı için nokta içermez: "384_271" = 38,4°K 27,1°D.
export function feltCellKey(lat: unknown, lon: unknown): string | null {
  const la = Number(lat);
  const lo = Number(lon);
  if (lat == null || lon == null || !Number.isFinite(la) || !Number.isFinite(lo)
      || Math.abs(la) > 90 || Math.abs(lo) > 180) return null;
  return `${Math.round(la * 10)}_${Math.round(lo * 10)}`;
}

export interface FeltCell { lat: number; lon: number; count: number }

/// Deprem başına en fazla bu kadar hücre döner (en kalabalıklar).
const FELT_CELLS_MAX = 400;

export function sumFeltCounters(docs: Array<Record<string, any> | undefined>): { count: number; notFeltCount: number; cells: FeltCell[] } {
  let count = 0;
  let notFeltCount = 0;
  const cells = new Map<string, number>();
  for (const data of docs) {
    count += Number(data?.count || 0);
    notFeltCount += Number(data?.not_felt_count || 0);
    const stored = data?.cells;
    if (stored && typeof stored === 'object') {
      for (const [key, value] of Object.entries(stored)) {
        cells.set(key, (cells.get(key) || 0) + Number(value || 0));
      }
    }
  }
  const list = [...cells.entries()].flatMap(([key, cellCount]) => {
    const [la, lo] = key.split('_').map(Number);
    return Number.isFinite(la) && Number.isFinite(lo) && cellCount > 0
      ? [{ lat: la / 10, lon: lo / 10, count: cellCount }]
      : [];
  }).sort((a, b) => b.count - a.count).slice(0, FELT_CELLS_MAX);
  return { count, notFeltCount, cells: list };
}

// MARK: - Cihaz Kayıt Bellek İçi Önbelleği (Maliyet Azaltma)
//
// İstemciler her ön plana geldiğinde, token yenilendiğinde veya aralıklarla
// aynı ayarları içeren `/register` istekleri gönderir. Aynı cihazdan gelen
// ve yük hash'i değişmeyen isteklerde Firestore `docRef.get()` okumasını
// atlayarak okuma maliyetini %80-90 oranında düşürür.
interface CachedRegistration {
  inputHash: string;
  isPremium: boolean;
  cachedAt: number;
}

const deviceRegistrationCache = new Map<string, CachedRegistration>();
const MAX_DEVICE_REGISTRATION_CACHE_SIZE = 10_000;
const DEVICE_REGISTRATION_CACHE_TTL_MS = 15 * 60 * 1000; // 15 dakika

export function clearDeviceRegistrationCache(): void {
  deviceRegistrationCache.clear();
}

export function invalidateDeviceRegistration(deviceKey: string): void {
  deviceRegistrationCache.delete(deviceKey);
}

export function getDeviceRegistrationCacheSize(): number {
  return deviceRegistrationCache.size;
}

function computeRegistrationInputHash(
  deviceKey: string,
  body: any,
  authorizationHeader: string
): string {
  const normalized = {
    deviceKey,
    token: String(body.token || '').trim(),
    transport: body.transport === 'fcm' ? 'fcm' : 'apns',
    tzOffset: Number.isFinite(Number(body.tzOffset)) ? Math.max(-720, Math.min(840, Number(body.tzOffset))) : 180,
    lang: String(body.lang || 'tr').toLowerCase(),
    env: String(body.env || 'prod'),
    earthquakeNotificationsEnabled: body.earthquakeNotificationsEnabled === undefined ? true : Boolean(body.earthquakeNotificationsEnabled),
    productUpdatesEnabled: Boolean(body.productUpdatesEnabled),
    criticalAlertsEnabled: Boolean(body.criticalAlertsEnabled),
    worldMajorEnabled: Boolean(body.worldMajorEnabled),
    worldMajorThreshold: Math.min(8, Math.max(5, Number(body.worldMajorThreshold) || 6.5)),
    notificationSound: String(body.notificationSound || ''),
    criticalNotificationSound: String(body.criticalNotificationSound || ''),
    weeklyDigestEnabled: body.weeklyDigestEnabled,
    appVersion: String(body.appVersion || body.version || ''),
    places: Array.isArray(body.places) ? body.places : null,
    minMagnitude: body.minMagnitude,
    source: body.source,
    sourceFallbackEnabled: body.sourceFallbackEnabled,
    nearbyOnly: body.nearbyOnly,
    radius: body.radius,
    minimumEstimatedMMI: body.minimumEstimatedMMI,
    latitude: body.latitude,
    longitude: body.longitude,
    aftershockWatch: body.aftershockWatch || null,
    appUserId: String(body.appUserId || '').trim().slice(0, 200),
    isPremium: Boolean(body.isPremium),
    signedTransaction: body.signedTransaction ? String(body.signedTransaction) : null,
    authorizationHeader,
    legacyToken: body.legacyToken || null,
    apnsToken: normalizedApnsToken(body.apnsToken),
    legacyTokens: Array.isArray(body.legacyTokens) ? body.legacyTokens : null
  };
  return createHash('sha256').update(JSON.stringify(normalized)).digest('hex');
}

/// APNs cihaz token'ı: 64+ haneli onaltılık. Geçersizse boş dize.
export function normalizedApnsToken(value: unknown): string {
  const token = String(value || '').trim().toLowerCase();
  return /^[0-9a-f]{64,200}$/.test(token) ? token : '';
}

function setDeviceRegistrationCache(deviceKey: string, inputHash: string, isPremium: boolean): void {
  deviceRegistrationCache.set(deviceKey, { inputHash, isPremium, cachedAt: Date.now() });
  if (deviceRegistrationCache.size > MAX_DEVICE_REGISTRATION_CACHE_SIZE) {
    const oldestKey = deviceRegistrationCache.keys().next().value;
    if (oldestKey !== undefined) deviceRegistrationCache.delete(oldestKey);
  }
}

/// `/register`, `/unregister` ve `/felt` rotalarını kaydeder.
///
/// `isRateLimited`, `bumpDeviceRegistryRevision` ve `normalizedNotificationSound`
/// `index.ts`'te tanımlı kalır (orada başka rotalarca da kullanılıyor) ve buraya
/// parametre olarak geçirilir — `index.ts`'i geri import etmek yeni bir dairesel
/// bağımlılık yaratırdı.
export function registerDeviceRoutes(
  app: express.Express,
  db: Firestore,
  isRateLimited: (req: express.Request, scope: string, limit: number, windowMs: number) => boolean,
  bumpDeviceRegistryRevision: (options?: { deletion?: boolean; writer?: FirebaseFirestore.WriteBatch | FirebaseFirestore.Transaction }) => Promise<void>,
  normalizedNotificationSound: (value: unknown) => string
): void {
  clearDeviceRegistrationCache();
  const deviceQueues = new Map<string, Promise<any>>();

  app.post('/register', async (req, res) => {
    const body = req.body || {};
    const token = String(body.token || '').trim();
    const transport = body.transport === 'fcm' ? 'fcm' : 'apns';

    if (!token || !isValidPushToken(token, transport)) {
      res.status(400).json({ error: 'Invalid push token' });
      return;
    }

    const deviceKey = normalizePushToken(token, transport);

    // Fast-path: Aynı cihazdan aynı ayarlarla gelen mükerrer kayıtlar
    // (uygulama ön plana geldiğinde, token tazelemesinde vs.) Firestore'da
    // ne okuma ne yazma, ne de kimlik/JWS doğrulaması gerektirir. Hash ham
    // yetki başlığını içerdiği için aynı başlık önceden doğrulanmış demektir.
    // Rate limit'ten ÖNCE: büyük depremde aynı operatör IP'sindeki (CGNAT)
    // yüzlerce kullanıcının değişmeyen kaydı limiti doldurmasın.
    const authorizationHeader = String(req.headers.authorization || '');
    const inputHash = computeRegistrationInputHash(deviceKey, body, authorizationHeader);
    const cachedReg = deviceRegistrationCache.get(deviceKey);
    if (cachedReg && (Date.now() - cachedReg.cachedAt < DEVICE_REGISTRATION_CACHE_TTL_MS) && cachedReg.inputHash === inputHash) {
      res.status(200).json({ success: true, cached: true });
      return;
    }

    // Sahte kayıt/yazma taşmasına fren. Operatör NAT'ı arkasında çok sayıda
    // gerçek kullanıcı aynı IP'yi paylaştığı için geniş tutuldu.
    if (isRateLimited(req, 'register', 300, 600000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }

    const authenticatedUserUID = await optionalAuthenticatedUID(req);

    let verifiedSubscription: VerifiedSubscription | null = null;
    if (body.signedTransaction) {
      try {
        verifiedSubscription = await verifyTransactionJWS(String(body.signedTransaction));
      } catch (error: any) {
        console.error('Cihaz kaydındaki StoreKit JWS doğrulanamadı:', error?.message);
        res.status(401).json({ error: 'Invalid StoreKit transaction' });
        return;
      }
    }

    // RevenueCat yolu. Yeniden kurulan cihaz yeni bir push token (dolayısıyla
    // yeni bir belge) alıyor ve aboneliğinde değişiklik olmadığı için webhook
    // hiç tetiklenmiyor; ilk yetkiyi bu yüzden kayıt anında çözüyoruz.
    //
    // Sorgu istemci premium olduğunu bildirdiğinde YA DA geçerli bir Apple JWS
    // geldiğinde yapılır: ücretsiz kullanıcılar cihaz sayısı kadar boşuna
    // RevenueCat isteği üretmesin ve kayıt yanıtı ağ gecikmesiyle yavaşlamasın.
    // JWS aktifken de sorgulanması gerekir: aksi hâlde kurtarma dalı RevenueCat
    // yanıtı olmadan çalışır ve `unmigrated` teşhis sinyali üretilemez.
    //
    // İstemcinin "premium değilim" iddiası ise ARTIK olduğu gibi kabul
    // edilmiyor: iddia yanlış olabiliyor (RevenueCat'e aktarılmamış abonede
    // SDK geçici olarak "yetki yok" diyebiliyor) ve yanlış iddia cihazı push
    // hedefinden çıkarıyordu. Bu durumda sorgu belge okunduktan sonra, yalnızca
    // sunucu kaydı premium diyorsa yapılır (bkz. `negative_claim_unverified`) —
    // gerçekten ücretsiz kullanıcıya hâlâ tek bir RevenueCat isteği bile
    // gitmiyor.
    const appUserId = String(body.appUserId || '').trim().slice(0, 200);
    let revenueCatEntitlement: RevenueCatEntitlement | null = null;
    const clientClaimsPremium = Boolean(body.isPremium);

    const currentQueue = deviceQueues.get(deviceKey) || Promise.resolve();
    const nextQueue = currentQueue.catch(() => undefined).then(async () => {
      const docRef = db.collection('devices').doc(deviceKey);
      const userAgent = String(req.headers['user-agent'] || '');
      const uaMatch = userAgent.match(/Sismik\/(\d+\.\d+(?:\.\d+)?)/i);
      const appVersion = uaMatch ? uaMatch[1] : String(body.appVersion || body.version || '1.0.0').trim();

      // Bildirim kuralı iki biçimden biridir (bkz. `deviceUsesPlaces`):
      //
      //  - Yer modeli: istemci `places` dizisini gönderir (boş olabilir —
      //    "yer yok" demektir). Eski kuralın alanları aynı yazımda silinir.
      //  - Eski kural: 2.0.9 ve öncesi, ya da yeni sürümde henüz yer
      //    kaydetmemiş kullanıcı. İstemci `source/minMagnitude/...` gönderir;
      //    alanlar 2.0.9'u işleten sunucudaki gibi yazılır, `places` silinir.
      //
      // İkisini birden taşıyan belge oluşmaz; eşleştirici hangi kuralın geçerli
      // olduğunu tahmin etmek zorunda kalmaz. Gövde ikisini de taşımıyorsa
      // kural alanlarına dokunulmaz.
      const usesPlaces = Array.isArray(body.places);
      const sendsLegacyRules = !usesPlaces
        && (body.minMagnitude !== undefined || body.source !== undefined || body.nearbyOnly !== undefined);
      // Alt sınır 5.0: kullanıcı kayıtlı yeri olmayan bölgelerde de kayda
      // değer olayları duyabilsin diye eski 6.0 tabanı gevşetildi.
      const worldMajorThreshold = Math.min(8, Math.max(5, Number(body.worldMajorThreshold) || 6.5));
      const payload: any = {
        token: token,
        transport: transport,
        tz_offset: Number.isFinite(Number(body.tzOffset)) ? Math.max(-720, Math.min(840, Number(body.tzOffset))) : 180,
        lang: String(body.lang || 'tr').toLowerCase(),
        environment: String(body.env || 'prod'),
        earthquake_notifications_enabled: body.earthquakeNotificationsEnabled === undefined
          ? true
          : Boolean(body.earthquakeNotificationsEnabled),
        product_updates_enabled: Boolean(body.productUpdatesEnabled),
        critical_alerts_enabled: Boolean(body.criticalAlertsEnabled),
        world_major_enabled: Boolean(body.worldMajorEnabled),
        world_major_threshold: worldMajorThreshold,
        notification_sound: normalizedNotificationSound(body.notificationSound),
        // Haftalık özet: yalnızca alanı gönderen (2.2+) istemci için yazılır.
        ...(typeof body.weeklyDigestEnabled === 'boolean'
          ? { weekly_digest_enabled: body.weeklyDigestEnabled }
          : {}),
        // Bildirim biçimi yalnızca alanı gönderen (2.1.3+) istemci için yazılır.
        ...(typeof body.notificationStyle === 'string'
          ? { notification_style: normalizeNotificationStyle(body.notificationStyle) }
          : {}),
        // Eski istemci göndermez; alan yazılmaz, kritik uyarı olağan sesle çalar.
        ...(normalizedCriticalSound(body.criticalNotificationSound)
          ? { critical_notification_sound: normalizedCriticalSound(body.criticalNotificationSound) }
          : {}),
        app_version: appVersion,
        // Doğrudan APNs hedefi (2.1.4+ istemci). Eski istemci göndermez; alan
        // yazılmaz ve cihaz FCM'den almaya devam eder.
        ...(normalizedApnsToken(body.apnsToken)
          ? { apns_token: normalizedApnsToken(body.apnsToken), apns_env: body.env === 'sandbox' ? 'sandbox' : 'prod' }
          : {})
      };
      // Android istemcisi: bildirim `android` bloğu ve veri alanlarıyla
      // gönderilir. iOS istemcisi alanı göndermez, belgesine hiç yazılmaz.
      if (body.platform === 'android') payload.platform = 'android';
      if (usesPlaces) payload.places = sanitizeDevicePlaces(body.places);
      if (sendsLegacyRules) {
        const nearbyOnly = Boolean(body.nearbyOnly);
        const requestedSource = String(body.source || 'afad').toLowerCase();
        const minimumEstimatedMMI = [0, 3, 4, 5].includes(Number(body.minimumEstimatedMMI))
          ? Number(body.minimumEstimatedMMI)
          : 0;
        Object.assign(payload, {
          source: ['afad', 'emsc', 'usgs', 'noa'].includes(requestedSource) ? requestedSource : 'afad',
          source_fallback_enabled: body.sourceFallbackEnabled !== false,
          min_magnitude: Math.min(9, Math.max(1, Number(body.minMagnitude) || 4.0)),
          major_threshold: Math.min(9, Math.max(2, Number(body.majorThreshold) || 5.0)),
          nearby_only: nearbyOnly,
          radius: Math.min(2000, Math.max(10, Number(body.radius) || 250)),
          minimum_estimated_mmi: minimumEstimatedMMI
        });
      }
      const requestedWatch = body.aftershockWatch;
      if (requestedWatch && typeof requestedWatch === 'object') {
        const watch = {
          mainshockId: String(requestedWatch.mainshockId || '').slice(0, 160),
          title: String(requestedWatch.title || '').slice(0, 180),
          magnitude: Number(requestedWatch.magnitude) || 0,
          latitude: Number(requestedWatch.latitude),
          longitude: Number(requestedWatch.longitude),
          startedAt: Number(requestedWatch.startedAt),
          expiresAt: Number(requestedWatch.expiresAt),
          radiusKm: Math.min(250, Math.max(25, Number(requestedWatch.radiusKm) || 150)),
          minimumMagnitude: Math.min(6, Math.max(1, Number(requestedWatch.minimumMagnitude) || 2.5))
        };
        if (watch.mainshockId && Number.isFinite(watch.latitude) && Number.isFinite(watch.longitude)
            && Number.isFinite(watch.startedAt) && watch.expiresAt > Date.now()
            && watch.expiresAt <= Date.now() + 48 * 60 * 60 * 1000) {
          payload.aftershock_watch = watch;
        }
      }
      if (authenticatedUserUID) payload.user_uid = authenticatedUserUID;
      const fieldsToDelete: string[] = [];
      // 2.1.2 öncesi test sürümünün yazdığı, artık okunmayan alan.
      fieldsToDelete.push('turkey_major_enabled');
      if (!payload.aftershock_watch) fieldsToDelete.push('aftershock_watch');
      // Sessiz saatler üründen kaldırıldı (istemcide arayüzü yok) ve bildirim
      // şema sürümü artık dallanmıyor — her istemci v2 anlamına göre işlenir.
      // Bu alanlar eski kayıtlarda kalmış ölü veridir; ilk kayıtta silinir.
      // `device_key` belge kimliğinin kopyasıydı ve hiçbir yerde okunmuyordu.
      fieldsToDelete.push(
        'quiet_hours', 'quiet_start', 'quiet_end', 'update_topics', 'notification_schema_version',
        'device_key'
      );
      if (usesPlaces) {
        fieldsToDelete.push(
          'nearby_only', 'radius', 'latitude', 'longitude',
          'min_magnitude', 'major_threshold', 'minimum_estimated_mmi',
          'source', 'source_fallback_enabled'
        );
      } else if (sendsLegacyRules) {
        fieldsToDelete.push('places');
        // Koordinat, 2.0.9 sunucusundaki kuralla yazılır: yalnızca konuma
        // dayalı bir filtre (yakınlık ya da MMI) açıkken tutulur. Filtre
        // açıkken koordinatın gelmemesi geçici bir istemci durumudur (izin
        // yeni verildi, ilk konum gecikti); saklı koordinat korunur, aksi
        // hâlde yakınlık dalı her depremi eleyip kullanıcıyı susturur.
        const latitude = Number(body.latitude);
        const longitude = Number(body.longitude);
        const locationFilterActive = payload.nearby_only || payload.minimum_estimated_mmi > 0;
        const coordinateSupplied = body.latitude != null && body.longitude != null
          && Number.isFinite(latitude) && Math.abs(latitude) <= 90
          && Number.isFinite(longitude) && Math.abs(longitude) <= 180;
        if (locationFilterActive && coordinateSupplied) {
          payload.latitude = latitude;
          payload.longitude = longitude;
        } else if (!locationFilterActive) {
          fieldsToDelete.push('latitude', 'longitude');
        }
      }

      if (appUserId) payload.app_user_id = appUserId;

      const doc = await docRef.get();
      const existingData = doc.data();

      // Push görevinin tam okuması yalnızca bu bayrağı taşıyan cihazları
      // okur. Kural alanları bu yazımda değişmiyorsa (gövde taşımıyor) mevcut
      // belgedeki değerlerle hesaplanır.
      const mergedRules = { ...existingData, ...payload };
      fieldsToDelete.forEach(field => { delete mergedRules[field]; });
      payload.push_candidate = isPushCandidate(mergedRules);

      // Sunucuda zaten RevenueCat kaynaklı, aktif ve süresi dolmamış bir yetki kayıtlıysa
      // ve istemci de premium olduğunu bildiriyorsa, RevenueCat API'sine her kayıtta
      // tekrar dış HTTP çağrısı yapmaya gerek yoktur. Webhook değişiklikleri zaten anında yansıtır.
      const alreadyConfirmedActive = doc.exists
        && existingData?.is_premium === true
        && existingData?.app_user_id === appUserId
        && (!existingData?.premium_expires_at || existingData.premium_expires_at > Date.now() + 60_000)
        && clientClaimsPremium
        && !verifiedSubscription?.isActive;

      if (alreadyConfirmedActive) {
        revenueCatEntitlement = {
          isActive: true,
          expiresAt: Number(existingData.premium_expires_at || 0),
          productId: String(existingData.subscription_product_id || '')
        };
      } else if (appUserId && (clientClaimsPremium || verifiedSubscription?.isActive)) {
        revenueCatEntitlement = await resolveRevenueCatEntitlement(appUserId, Date.now());
      }

      // Yetki kararı belge okunduktan SONRA verilir: doğrulanmamış bir
      // "premium değilim" iddiasının kayıtlı yetkiyi silmemesi için karar
      // fonksiyonunun `storedIsPremium`'a ihtiyacı var.
      let decision = decideDeviceEntitlement({
        appUserId,
        clientClaimsPremium,
        revenueCat: revenueCatEntitlement,
        appleJws: verifiedSubscription ?? null,
        storedIsPremium: existingData?.is_premium === true,
        now: Date.now()
      });

      // Çelişki: istemci "premium değilim" diyor, sunucu kaydı premium diyor.
      // Ancak burada RevenueCat'e sormaya değer — ücretsiz kullanıcıların her
      // kaydında değil, yalnızca bu nadir durumda tek bir istek. Kesin cevap
      // gelirse gerçekten süresi dolmuş abone düşürülür; cevap gelmezse yetki
      // korunur.
      if (decision.action === 'preserve' && decision.reason === 'negative_claim_unverified') {
        revenueCatEntitlement = await resolveRevenueCatEntitlement(appUserId, Date.now());
        if (revenueCatEntitlement) {
          decision = decideDeviceEntitlement({
            appUserId,
            clientClaimsPremium,
            revenueCat: revenueCatEntitlement,
            appleJws: verifiedSubscription ?? null,
            storedIsPremium: existingData?.is_premium === true,
            now: Date.now()
          });
        }
      }

      if (decision.action === 'preserve') {
        // Alanlar payload'a hiç konmaz; merge yazımı önceki değeri korur.
        console.warn(`Yetki korunuyor (${decision.reason}): ${deviceLogId(deviceKey)}`);
      } else {
        Object.assign(payload, decision.set);
        decision.unset.forEach(field => fieldsToDelete.push(field));
        if (decision.unmigrated) {
          // Teşhis: RevenueCat bu aboneyi tanımıyor ama Apple aktif diyor.
          console.warn(`Apple aktif, RevenueCat tanımıyor — aktarılmamış abone: ${deviceLogId(deviceKey)}`);
        }
      }
      const isDevicePremium = decision.action === 'preserve'
        ? existingData?.is_premium === true
        : decision.set?.is_premium === true;

      // Doğrulanamayan geçici yetki belirsizliklerinde (örn. kanıtsız premium iddiası)
      // istemci 503 alsın ve tekrar denesin. Normal ücretsiz veya doğrulanmış kayıtlar devam eder.
      if (decision.action === 'preserve' && (!doc.exists || !isDevicePremium)) {
        throw new Error('Entitlement verification temporarily unavailable');
      }

      // Tercih kaydı: Hem premium hem ücretsiz kullanıcıların bildirim tercihleri
      // Firestore `devices` koleksiyonunda saklanır. Böylece kullanıcı ayarları kaybolmaz
      // ve kullanıcı daha sonra premium olduğunda webhook aynı cihazı anında günceller.


      if (!doc.exists || !existingData?.registered_at) {
        payload.registered_at = Date.now();
      }
      // `notified` yalnızca geçici FCM hatasında yazılır (push turu); her yeni
      // cihaza boş dizi yazmak belgeyi büyütüyor, okuyan her yerde boş diziye
      // düşülüyordu.

      // `entitlement_verified_at` her doğrulamada doğal olarak değişir. Gerçek
      // entitlement/tercih aynıysa bunu tek başına yazma sebebi saymayız.
      const comparablePayload = { ...payload };
      delete comparablePayload.entitlement_verified_at;
      const needsWrite = deviceRegistrationNeedsWrite(
        existingData,
        comparablePayload,
        fieldsToDelete
      );
      // İstemci tercihleri değişmese bile haftalık doğrulama `updated_at` alanını
      // tazeler. Böylece gerçekten aktif cihazlar 60 günlük inaktivite temizliğine
      // takılmaz; silinen sunucu kaydı da istemci tarafından yeniden kurulabilir.
      const registrationHeartbeatDue = deviceRegistrationHeartbeatDue(existingData?.updated_at);

      if (needsWrite || registrationHeartbeatDue) {
        payload.updated_at = Date.now();
        const batch = db.batch();
        // A webhook/another instance may have renewed or revoked this
        // entitlement since our read. Fail retryably instead of overwriting it.
        if (doc.exists) {
          // `FieldValue.delete()` YALNIZCA update() (ve merge'lü set()) içinde
          // geçerlidir. Yeni belgede silinecek eski alan zaten yoktur; silme
          // işaretçisini create() payload'una koymak Firestore tarafından
          // "geçersiz belge" diye reddediliyor, istek 503'e düşüyor ve istemci
          // sonsuz yeniden deniyordu — temiz kurulan ya da push token'ı
          // yenilenen cihaz sunucuda hiç oluşmuyor, dolayısıyla ayarları hiç
          // kaydedilmiyor ve hiç bildirim alamıyordu.
          fieldsToDelete.forEach(field => { payload[field] = FieldValue.delete(); });
          batch.update(docRef, payload, { lastUpdateTime: doc.updateTime! });
        } else {
          batch.create(docRef, payload);
        }
        // Push görevi değişikliği `updated_at` üzerinden delta okumasıyla
        // alır; ortak registry belgesine yazılmaz (bkz. bumpDeviceRegistryRevision).
        await batch.commit();

      } else {
        console.log(`Cihaz kaydı değişmedi; Firestore yazımı atlandı: ${deviceLogId(deviceKey)}`);
      }


      // Remove old APNs/rotated FCM records only AFTER the new record is saved.
      const legacyTokens = [body.legacyToken, ...(Array.isArray(body.legacyTokens) ? body.legacyTokens.slice(0, 5) : [])]
        .filter((value): value is string => typeof value === 'string' && value.length > 0 && value.length <= 4096);
      const legacyKeys = [...new Set(legacyTokens.flatMap(value => [
        normalizePushToken(value, 'apns'), normalizePushToken(value, 'fcm')
      ]))].filter(key => key !== deviceKey && !key.includes('/'));
      if (legacyKeys.length) {
        const docs = await db.getAll(...legacyKeys.map(key => db.collection('devices').doc(key)));
        const existing = docs.filter(doc => doc.exists);
        if (existing.length) {
          const batch = db.batch();
          existing.forEach(doc => batch.delete(doc.ref));
          await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
          await batch.commit();
        }
      }
      return isDevicePremium;
    });

    deviceQueues.set(deviceKey, nextQueue);
    const clearQueue = () => {
      if (deviceQueues.get(deviceKey) === nextQueue) {
        deviceQueues.delete(deviceKey);
      }
    };
    void nextQueue.then(clearQueue, clearQueue);

    try {
      const isDevicePremium = await nextQueue;
      setDeviceRegistrationCache(deviceKey, inputHash, Boolean(isDevicePremium));
      res.status(200).json({ success: true });
    } catch (error: any) {
      // Hata eskiden tamamen yutuluyordu: istemci sonsuz 503 alıyor, sunucu
      // tarafında ise HİÇBİR iz kalmıyordu. Kayıt kırıldığında cihaz hiç
      // oluşmadığı için bildirim de gelmez; bunun sessiz kalması kabul
      // edilemez. Token kişisel veridir, yerine log parmak izi yazılır.
      console.error(`Cihaz kaydı başarısız (${deviceLogId(deviceKey)}): ${error?.message || error}`);
      res.status(503).json({ error: 'Registration temporarily unavailable' });
    }
  });

  // 8) Cihaz Kayıt Silme
  app.post('/unregister', async (req, res) => {
    const token = String(req.body?.token || '').trim();
    if (!isValidPushToken(token, 'fcm') && !isValidPushToken(token, 'apns')) {
      res.status(400).json({ error: 'Token required' });
      return;
    }

    const keys = Array.from(new Set([
      normalizePushToken(token, 'apns'),
      normalizePushToken(token, 'fcm')
    ]));

    keys.forEach(key => invalidateDeviceRegistration(key));

    try {
      // Silinmiş bir cihaz uygulama her açıldığında tekrar unregister gönderebilir.
      // Var olmayan belgeyi tekrar tekrar silmek yerine önce okuyup yalnızca gerçek
      // kayıtları siliyoruz; böylece ücretli delete + registry write oluşmuyor.
      const pending = keys.map(key => deviceQueues.get(key) || Promise.resolve());
      const unregisterQueue = Promise.all(pending.map(queue => queue.catch(() => undefined))).then(async () => {
        const refs = keys.map(key => db.collection('devices').doc(key));
        const snapshots = await db.getAll(...refs);
        const existing = snapshots.filter(snapshot => snapshot.exists);
        if (existing.length) {
          const batch = db.batch();
          existing.forEach(snapshot => batch.delete(snapshot.ref));
          await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
          await batch.commit();
        }
        return existing.length;
      });
      keys.forEach(key => deviceQueues.set(key, unregisterQueue));
      const clearUnregisterQueue = () => {
        keys.forEach(key => {
          if (deviceQueues.get(key) === unregisterQueue) deviceQueues.delete(key);
        });
      };
      void unregisterQueue.then(clearUnregisterQueue, clearUnregisterQueue);

      const deletedCount = await unregisterQueue;
      res.status(200).json({ success: true, deletedCount });
    } catch (error: any) {
      res.status(500).json({ error: 'Unregistration failed', message: error.message });
    }
  });

  app.get('/felt', async (req, res) => {
    const id = String(req.query.id || '').slice(0, 120);
    if (!id) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }
    const key = feltDocId(id);
    const now = Date.now();
    const cached = feltCountCache.get(key);
    if (cached && now - cached.at < 60_000) {
      res.setHeader('Cache-Control', 'public, max-age=30, s-maxage=60');
      res.json({ count: cached.count, notFeltCount: cached.notFeltCount, cells: cached.cells });
      return;
    }
    try {
      const collection = db.collection('felt_reports');
      const snapshots = await db.getAll(
        collection.doc(key),
        ...Array.from({ length: FELT_SHARD_COUNT }, (_, shard) => collection.doc(feltShardId(key, shard)))
      );
      const { count, notFeltCount, cells } = sumFeltCounters(snapshots.map(snapshot => snapshot.data()));
      feltCountCache.set(key, { count, notFeltCount, cells, at: now });
      if (feltCountCache.size > 500) {
        const oldest = feltCountCache.keys().next().value;
        if (oldest !== undefined) feltCountCache.delete(oldest);
      }
      res.setHeader('Cache-Control', 'public, max-age=30, s-maxage=60');
      res.json({ count, notFeltCount, cells });
    } catch (error: any) {
      res.status(500).json({ error: 'Felt count failed', message: error.message });
    }
  });

  app.post('/felt', async (req, res) => {
    // Türkiye'de mobil operatörler binlerce aboneyi aynı çıkış IP'sinde
    // topluyor (CGNAT). Büyük depremde aynı IP'den yüzlerce gerçek rapor
    // gelir; mükerrer koruması zaten istemcide (deprem başına bir rapor).
    if (isRateLimited(req, 'felt', 600, 600_000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }
    const id = String(req.body?.id || '').slice(0, 120);
    if (!id) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }
    const key = feltDocId(id);
    // Bildirimdeki "Hissetmedim" düğmesi ayrı sayaca yazar; aynı belgeye tek
    // artırım olduğundan maliyet "Hissettim" ile aynı (rapor başına 1 yazım).
    const counterField = req.body?.kind === 'not_felt' ? 'not_felt_count' : 'count';
    // Harita yalnızca "hissettim" raporlarını gösterir; konum isteğe bağlı.
    const cell = counterField === 'count' ? feltCellKey(req.body?.lat, req.body?.lon) : null;
    let attempts = 0;
    while (attempts < 3) {
      try {
        // Her denemede farklı parça: çekişilen parça yeniden seçilmez.
        const shard = Math.floor(Math.random() * FELT_SHARD_COUNT);
        await db.collection('felt_reports').doc(feltShardId(key, shard)).set({
          quake_id: id,
          [counterField]: FieldValue.increment(1),
          ...(cell ? { cells: { [cell]: FieldValue.increment(1) } } : {}),
          updated_at: Date.now(),
          expire_at: new Date(Date.now() + 34 * 86400000)
        }, { merge: true });
        feltCountCache.delete(key);
        res.json({ success: true });
        return;
      } catch (error: any) {
        attempts++;
        if (attempts >= 3) {
          console.warn(`[Felt] Firestore çekişme/hata (${id}):`, error?.message);
          res.status(503).json({ error: 'Felt report could not be saved' });
          return;
        }
        await new Promise(r => setTimeout(r, 50 * attempts + Math.floor(Math.random() * 50)));
      }
    }
  });
}
