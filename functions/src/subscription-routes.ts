import express from 'express';
import { FieldValue, Firestore } from 'firebase-admin/firestore';
import {
  RevenueCatEntitlement,
  entitlementFromActiveEntitlements,
  revenueCatEventUserIds,
  isRevenueCatTestEvent,
  entitlementDeviceFieldsFor
} from './worker-utils';
import {
  VerifiedSubscription,
  verifyServerNotification,
  verifyTransactionJWS
} from './subscription-verification';

// MARK: - StoreKit abonelik doğrulama ve yaşam döngüsü

function entitlementDeviceFields(subscription: VerifiedSubscription): Record<string, any> {
  return {
    is_premium: subscription.isActive,
    entitlement_source: 'apple_jws',
    subscription_id: subscription.originalTransactionId,
    subscription_product_id: subscription.productId,
    // Ömür boyu satın almada bitiş yok (0): alan yazılmaz, `toCachedPushDevice`
    // yokluğu "süresiz" sayar ve saatlik süre sonu taraması belgeyi hiç görmez.
    premium_expires_at: subscription.isActive && subscription.expiresDate > 0
      ? subscription.expiresDate
      : FieldValue.delete(),
    entitlement_verified_at: Date.now()
  };
}

async function updateLinkedDevices(db: Firestore, subscription: VerifiedSubscription, eventAt: number): Promise<void> {
  const originalTxId = typeof subscription.originalTransactionId === 'string'
    ? subscription.originalTransactionId.trim()
    : '';
  if (!originalTxId) return;
  const snapshot = await db.collection('devices')
    .where('subscription_id', '==', originalTxId).limit(400).get();
  if (snapshot.empty) return;
  await db.runTransaction(async transaction => {
    const current = await transaction.getAll(...snapshot.docs.map(doc => doc.ref));
    let count = 0;
    for (const doc of current) {
      const data = doc.data();
      // RevenueCat owns migrated subscribers, including grace periods and transfers.
      if (!data || data.entitlement_source === 'revenuecat'
          || Number(data.apple_event_at || 0) >= eventAt) continue;
      transaction.update(doc.ref, {
        ...entitlementDeviceFields(subscription), apple_event_at: eventAt, updated_at: Date.now()
      });
      count++;
    }
    return count;
  });
}

// Aynı imzalı abonelik durumu (premium kullanıcı her ön plana gelişte aynı
// JWS'i gönderir) için tekrar tekrar Firestore transaction açmayı önleyen
// bellek içi küme. Transaction içindeki stateUnchanged/previousEventAt
// korumaları zaten no-op yapıyordu; bu önbellek okumanın kendisini de keser.
// Instance'lar arası paylaşılmaz: en kötü durum fazladan tek transactional
// okuma, asla atlanmış yazma değildir.
const SUBSCRIPTION_EVENT_CACHE_MAX = 2000;
const persistedSubscriptionEvents = new Map<string, number>();

function subscriptionEventCacheKey(s: VerifiedSubscription, eventAt: number): string {
  return [
    s.originalTransactionId, eventAt, s.transactionId,
    s.status, s.isActive, s.expiresDate
  ].join(':');
}

/// Apple imzalı bir işlemden cihaz yetkisini günceller.
///
/// Eskiden ayrıca bir `subscriptions` koleksiyonuna abonelik geçmişi
/// yazılıyordu. O veri RevenueCat'te zaten tam olarak tutuluyor; iki yerde
/// tutmak hem maliyet hem de iki kaynağın birbirinden ayrışma riski
/// demekti. Firestore artık yalnızca push yönlendirmesi için gereken
/// cihaz alanlarını taşıyor.
///
/// Sıralama koruması (eski bir JWS'in yeni EXPIRED'ı geri alması) burada
/// gerekmiyor: yetki, JWS'in kendi bitiş tarihinden türetiliyor, dolayısıyla
/// bayat bir JWS kendi süresinin ötesinde premium veremez.
export async function persistVerifiedSubscription(
  db: Firestore,
  subscription: VerifiedSubscription,
  eventType: string,
  eventAt: number
): Promise<boolean> {
  const eventCacheKey = subscriptionEventCacheKey(subscription, eventAt);
  if (persistedSubscriptionEvents.has(eventCacheKey)) return false;

  await updateLinkedDevices(db, subscription, eventAt);
  persistedSubscriptionEvents.set(eventCacheKey, Date.now());
  while (persistedSubscriptionEvents.size > SUBSCRIPTION_EVENT_CACHE_MAX) {
    const oldestKey = persistedSubscriptionEvents.keys().next().value;
    if (oldestKey === undefined) break;
    persistedSubscriptionEvents.delete(oldestKey);
  }

  console.log(`Apple yetki olayı: ${eventType} (${subscription.status})`);
  return true;
}

// MARK: - RevenueCat yetki kaynağı
//
// Abone verisi RevenueCat'te tutulur; Firestore yalnızca push yönlendirmesi
// için `is_premium` + `premium_expires_at` taşır. Yetki iki yoldan gelir:
// webhook (abonelik değiştiğinde) ve cihaz kaydı (yeni kurulum/yeni token).
// İkincisi olmadan yeniden kurulan cihaz hiç olay almaz ve sessizce bildirim
// almayı keserdi — webhook yalnızca abonelik olaylarında tetikleniyor.

const REVENUECAT_ENTITLEMENT_ID = 'premium';

// SDK lookup key (`premium`) is not the v2 opaque entitlement ID (`entl…`).
let entitlementCatalog: { project: string; id: string; at: number } | undefined;
let entitlementCatalogRequest: Promise<string> | undefined;

async function readRevenueCatList(url: string, apiKey: string): Promise<any[]> {
  const items: any[] = [];
  const visited = new Set<string>();
  while (url) {
    const target = new URL(url, 'https://api.revenuecat.com');
    if (target.origin !== 'https://api.revenuecat.com' || visited.has(target.href) || visited.size >= 20) {
      throw new Error('Invalid RevenueCat pagination');
    }
    visited.add(target.href);
    const response = await fetch(target, {
      headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(8000)
    });
    if (!response.ok) throw new Error(`RevenueCat list failed: ${response.status}`);
    const body: any = await response.json();
    if (!Array.isArray(body?.items)) throw new Error('Invalid RevenueCat list response');
    items.push(...body.items);
    url = body.next_page || '';
  }
  return items;
}

async function resolvePremiumEntitlementID(project: string, apiKey: string, now: number): Promise<string> {
  if (entitlementCatalog?.project === project && now - entitlementCatalog.at < 3600_000) {
    return entitlementCatalog.id;
  }
  if (entitlementCatalogRequest) return entitlementCatalogRequest;
  entitlementCatalogRequest = (async () => {
    const items = await readRevenueCatList(
      `https://api.revenuecat.com/v2/projects/${encodeURIComponent(project)}/entitlements?limit=100`, apiKey
    );
    const match = items.find(item => item.lookup_key === REVENUECAT_ENTITLEMENT_ID && item.state !== 'archived');
    if (!match?.id) throw new Error('RevenueCat premium entitlement configuration missing');
    entitlementCatalog = { project, id: String(match.id), at: now };
    return entitlementCatalog.id;
  })();
  try { return await entitlementCatalogRequest; }
  finally { entitlementCatalogRequest = undefined; }
}

/// Webhook'u hemen izleyen cihaz kaydı gibi arka arkaya gelen çözümlemeleri
/// tek HTTP isteğine indirir.
const RC_ENTITLEMENT_TTL_MS = 60_000;
const rcEntitlementCache = new Map<string, { at: number; value: RevenueCatEntitlement }>();
const RC_ENTITLEMENT_CACHE_MAX = 5000;

/// RevenueCat'ten yetkiyi çözer.
///
/// Hata durumunda `null` döner — ASLA "yetki yok" değil. Çağıranlar bunu
/// "dokunma" olarak yorumlar: RevenueCat'e ulaşılamadığı için para ödeyen
/// kullanıcının deprem bildirimleri kesilmemeli.
export async function resolveRevenueCatEntitlement(
  appUserId: string,
  now: number,
  options: { bypassCache?: boolean } = {}
): Promise<RevenueCatEntitlement | null> {
  // Webhook yolu önbelleği ATLAR: iptal/iade olayı, aynı dakika içinde bir
  // `/register` tarafından doldurulmuş "aktif" girdiyi okursa süresi dolmuş
  // yetkiyi geri yazardı ve RevenueCat 2xx aldığı için olayı bir daha
  // göndermezdi — iade edilen abone dönem sonuna kadar premium kalırdı.
  if (options.bypassCache) {
    rcEntitlementCache.delete(appUserId);
  } else {
    const cached = rcEntitlementCache.get(appUserId);
    if (cached && now - cached.at < RC_ENTITLEMENT_TTL_MS) return cached.value;
  }

  const apiKey = process.env.REVENUECAT_API_KEY;
  const projectId = process.env.REVENUECAT_PROJECT_ID;
  if (!apiKey || !projectId) {
    console.error('REVENUECAT_API_KEY veya REVENUECAT_PROJECT_ID tanımsız; yetki çözümlenemedi.');
    return null;
  }

  try {
    const entitlementId = await resolvePremiumEntitlementID(projectId, apiKey, now);
    const response = await fetch(
      `https://api.revenuecat.com/v2/projects/${encodeURIComponent(projectId)}`
        + `/customers/${encodeURIComponent(appUserId)}/active_entitlements`,
      { headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(8000) }
    );
    // v2'de 404, "bu müşteri yok" demek — yani yetkisi yok. v1'in aksine
    // müşteri oluşturmuyor, bu yüzden güvenle yazılabilir.
    //
    // Yanlış `REVENUECAT_PROJECT_ID` veya geçersiz/yetkisiz anahtar bu uçta
    // 404 DEĞİL, `authentication_error`/`authorization_error` (401/403)
    // döndürür — o dal aşağıda `null` ile "yetkiye dokunma"ya çevrilir.
    // Dolayısıyla 404'ü kesin cevap saymak güvenlidir.
    if (response.status === 404) {
      const none: RevenueCatEntitlement = { isActive: false, expiresAt: 0, productId: '' };
      rememberEntitlement(appUserId, none, now);
      return none;
    }
    if (!response.ok) {
      if (response.status === 401 || response.status === 403) {
        // Yapılandırma hatası: sessizce "yetkisiz" saymak bütün abonelerin
        // cihaz kaydını silerdi. Yetkiye dokunulmaz, log yüksek sesle uyarır.
        console.error(
          `RevenueCat yetkilendirme hatası (${response.status}): REVENUECAT_API_KEY bir v2 `
          + 'secret anahtarı mı ve REVENUECAT_PROJECT_ID ile eşleşiyor mu kontrol edin. '
          + 'Yetkiye dokunulmuyor.'
        );
      } else {
        console.error(`RevenueCat abone sorgusu başarısız: ${response.status}`);
      }
      return null;
    }
    const body: any = await response.json();
    if (!Array.isArray(body?.items)) throw new Error('Invalid RevenueCat active entitlements response');
    if (body.next_page) body.items.push(...await readRevenueCatList(body.next_page, apiKey));
    if (body.items.some((item: any) => !item || !Object.hasOwn(item, 'expires_at')
        || (item.expires_at !== null && !Number.isFinite(Number(item.expires_at))))) {
      throw new Error('Invalid RevenueCat expiry');
    }
    const entitlement = entitlementFromActiveEntitlements(body, entitlementId, now);
    rememberEntitlement(appUserId, entitlement, now);
    return entitlement;
  } catch (error: any) {
    console.error('RevenueCat abone sorgusu hatası:', error?.message || error);
    return null;
  }
}

function rememberEntitlement(appUserId: string, value: RevenueCatEntitlement, now: number): void {
  rcEntitlementCache.delete(appUserId);
  rcEntitlementCache.set(appUserId, { at: now, value });
  while (rcEntitlementCache.size > RC_ENTITLEMENT_CACHE_MAX) {
    const oldest = rcEntitlementCache.keys().next().value;
    if (oldest === undefined) break;
    rcEntitlementCache.delete(oldest);
  }
}

/// Bir RevenueCat kullanıcısına bağlı tüm cihazlara yetkiyi yazar. Aynı kişi
/// birden fazla cihazda olabilir (iPhone + iPad); hepsi güncellenmeli.
async function applyEntitlementToDevices(
  db: Firestore,
  appUserIds: string[],
  entitlement: RevenueCatEntitlement,
  now: number
): Promise<number> {
  if (!appUserIds.length) return 0;

  const { set, unset } = entitlementDeviceFieldsFor(entitlement, now);
  const fields: Record<string, any> = { ...set };
  unset.forEach(field => { fields[field] = FieldValue.delete(); });

  let updated = 0;

  const validAppUserIds = Array.from(new Set(
    appUserIds
      .map(id => typeof id === 'string' ? id.trim() : '')
      .filter(id => id.length > 0)
  ));
  if (!validAppUserIds.length) return 0;

  for (const appUserId of validAppUserIds) {
    const snapshot = await db.collection('devices')
      .where('app_user_id', '==', appUserId)
      .limit(50)
      .get();
    if (snapshot.empty) continue;

    const batch = db.batch();
    let batchUpdates = 0;
    snapshot.docs.forEach(doc => {
      // Yalnızca gerçekten değişen belgeler yazılır: aynı yetkiyi tekrar
      // yazmak push önbelleğini gereksiz yere geçersiz kılardı.
      const data = doc.data();
      const sameFlag = Boolean(data.is_premium) === entitlement.isActive;
      const sameExpiry = Number(data.premium_expires_at || 0) === (entitlement.isActive ? entitlement.expiresAt : 0);
      if (sameFlag && sameExpiry) return;
      batch.set(doc.ref, { ...fields, updated_at: now }, { merge: true });
      updated += 1;
      batchUpdates++;
    });
    if (batchUpdates) {
      await batch.commit();
    }
  }

  return updated;
}

// MARK: - Süresi dolan yetkilerin kapatılması (saatlik bakım turu)
//
// index.ts'ten taşındı (Task 11): admin-routes.ts'teki `runMaintenanceSweep`
// tarafından çağrılır. Push teslimi süre sonunu zaten okuma anında süzüyor
// (`activeDevices`), ama otomasyon ve kampanya hedefleri `is_premium`
// eşitliğiyle sorgulanıyor — o bayrak tazelenmezse süresi dolmuş kullanıcı
// "premium kitle"de kalırdı.

/// Süresi geçmiş `premium_expires_at` alanına sahip cihazları `is_premium:
/// false` yapar. Kapatılan cihaz sayısını döndürür (çağıran taraf
/// loglar/raporlar).
export async function expirePremiumEntitlements(db: Firestore, now: number): Promise<number> {
  const deviceSnapshot = await db.collection('devices')
    .where('premium_expires_at', '<=', now)
    .limit(400)
    .get();
  if (deviceSnapshot.empty) return 0;

  // Belge SİLİNMEZ, yalnızca yetki kapatılır.
  //
  // Silme, ödemesi gecikip sonra geçen aboneyi sunucuda görünmez yapıyordu:
  // `applyEntitlementToDevices` yalnızca VAR OLAN belgeleri güncelliyor
  // (`if (snapshot.empty) continue`), dolayısıyla kart yenilendiğinde gelen
  // RENEWAL webhook'unun yazacağı bir belge kalmıyordu. İstemci `/register`'ı
  // yük hash'i değişmediyse 7 güne kadar atladığı için, ödeme yapan kullanıcı
  // o süre boyunca sessizce deprem bildirimi alamıyordu.
  //
  // Belgenin gerçekten silinmesi 60 günlük `updated_at` temizliğinin işi.
  // Re-read inside the transaction: a renewal may have landed after the
  // expiry query. Never overwrite that newer entitlement with stale data.
  return db.runTransaction(async transaction => {
    const current = await transaction.getAll(...deviceSnapshot.docs.map(doc => doc.ref));
    let expired = 0;
    for (const doc of current) {
      const data = doc.data();
      const expiry = Number(data?.premium_expires_at);
      if (!data || !Number.isFinite(expiry) || expiry > now) continue;
      transaction.update(doc.ref, {
        is_premium: false,
        entitlement_verified_at: now,
        updated_at: now,
        premium_expires_at: FieldValue.delete()
      });
      expired++;
    }
    return expired;
  });
}

/// Abonelik/entitlement ile ilgili Express rotalarını ve Firestore/scheduler
/// tetikleyicilerini kaydeder. `revenueCatDeliveryCreated` ve
/// `revenueCatDeliveryRetry` export'ları Firebase'in onları keşfedebilmesi
/// için `index.ts`'te kalır; gövdeleri buradaki `processRevenueCatDelivery`'yi
/// çağırır.
export function registerSubscriptionRoutes(app: express.Express, db: Firestore): void {
  app.post('/subscription/sync', async (req, res) => {
    try {
      const signedTransaction = String(req.body?.signedTransaction || '');
      const subscription = await verifyTransactionJWS(signedTransaction);
      await persistVerifiedSubscription(db, subscription, 'CLIENT_SYNC', subscription.signedDate);
      res.status(200).json({
        success: true,
        status: subscription.status,
        expiresAt: subscription.expiresDate
      });
    } catch (error: any) {
      console.error('StoreKit abonelik senkronizasyonu reddedildi:', error?.message);
      res.status(401).json({ error: 'Invalid StoreKit transaction' });
    }
  });

  app.post('/app-store/notifications', async (req, res) => {
    try {
      const signedPayload = String(req.body?.signedPayload || '');
      const verified = await verifyServerNotification(signedPayload);
      const payload = verified.payload;
      const notificationType = String(payload.notificationType || 'UNKNOWN');
      const eventAt = Number(payload.signedDate || Date.now());

      let subscription: VerifiedSubscription | null = null;
      if (payload.data?.signedTransactionInfo) {
        subscription = await verifyTransactionJWS(payload.data.signedTransactionInfo);

        if (notificationType === 'REFUND' || notificationType === 'REVOKE') {
          subscription = { ...subscription, isActive: false, status: 'revoked' };
        } else if (notificationType === 'EXPIRED' || notificationType === 'GRACE_PERIOD_EXPIRED') {
          subscription = { ...subscription, isActive: false, status: 'expired' };
        }

        await persistVerifiedSubscription(db, subscription, notificationType, eventAt);
      }

      // Apple Server Notifications artık doğrudan RevenueCat panosundaki webhook URL'ine
      // aktarıldığı için (Source of Truth = RevenueCat), Firestore'da outbox
      // (revenuecat_deliveries) veya bildirim arşivi (app_store_notifications) biriktirilmez.
      res.status(200).json({ success: true });
    } catch (error: any) {
      // Apple 4xx yanıtlarında bildirimi tekrar denemeyebilir. Geçici doğrulama
      // ve Firestore hatalarında yeniden teslim alabilmek için 500 döndürülür.
      console.error('App Store Server Notification işlenemedi:', error?.message);
      res.status(500).json({ error: 'Notification processing failed' });
    }
  });

  /// RevenueCat webhook'u. Panoda ayarlanan Authorization başlığıyla doğrulanır.
  ///
  /// Olay tipine göre karar VERİLMEZ: gövdedeki tipler yetkiyi doğrudan
  /// anlatmıyor (`CANCELLATION` yalnızca otomatik yenilemenin kapandığı, kişinin
  /// dönem sonuna kadar hâlâ premium olduğu anlamına gelir). Her olayda abone
  /// RevenueCat'ten yeniden okunup tek doğru kaynak yazılır.
  app.post('/revenuecat/webhook', async (req, res) => {
    const expected = process.env.REVENUECAT_WEBHOOK_SECRET;
    if (!expected) {
      console.error('REVENUECAT_WEBHOOK_SECRET tanımsız; webhook reddedildi.');
      res.status(503).json({ error: 'Webhook not configured' });
      return;
    }
    if (String(req.headers.authorization || '') !== expected) {
      console.warn('RevenueCat webhook yetkisiz istek.');
      res.status(401).json({ error: 'Unauthorized' });
      return;
    }

    const body = req.body;
    if (isRevenueCatTestEvent(body)) {
      console.log('RevenueCat bağlantı testi alındı.');
      res.status(200).json({ ok: true, test: true });
      return;
    }

    const appUserIds = revenueCatEventUserIds(body);
    if (!appUserIds.length) {
      // 200 dönülür: RevenueCat 2xx almazsa aynı olayı tekrar tekrar gönderir.
      console.warn('RevenueCat webhook olayında kullanıcı kimliği yok.');
      res.status(200).json({ ok: true, skipped: 'no_user_id' });
      return;
    }

    const eventType = String(body?.event?.type || 'UNKNOWN');
    const now = Date.now();

    // Yetki, olayın taşıdığı kimlik üzerinden çözülür. Transfer olaylarında
    // taraflar farklı yetkilere sahip olabileceği için her kimlik ayrı çözülür.
    let totalUpdated = 0;
    try {
    for (const appUserId of appUserIds) {
      const entitlement = await resolveRevenueCatEntitlement(appUserId, now, { bypassCache: true });
      if (!entitlement) {
        // Çözümlenemedi: mevcut yetkiye dokunulmaz. RevenueCat 2xx almazsa
        // olayı yeniden gönderir, bir sonraki denemede düzelir.
        console.error(`RevenueCat yetkisi çözümlenemedi (${appUserId}); olay yeniden denenecek.`);
        res.status(500).json({ error: 'Entitlement lookup failed' });
        return;
      }
      totalUpdated += await applyEntitlementToDevices(db, [appUserId], entitlement, now);
    }

    console.log(JSON.stringify({
      event: 'revenuecat_webhook',
      type: eventType,
      users: appUserIds.length,
      devicesUpdated: totalUpdated
    }));
    res.status(200).json({ ok: true, devicesUpdated: totalUpdated });
    } catch (error: any) {
      console.error('RevenueCat device update failed:', error?.message);
      res.status(500).json({ error: 'Device update failed' });
    }
  });
}
