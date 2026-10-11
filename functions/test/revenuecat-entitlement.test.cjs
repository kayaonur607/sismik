const test = require('node:test');
const assert = require('node:assert/strict');
const {
  entitlementFromActiveEntitlements,
  revenueCatEventUserIds,
  isRevenueCatTestEvent,
  entitlementDeviceFieldsFor,
  decideDeviceEntitlement
} = require('../lib/worker-utils');

const NOW = Date.UTC(2026, 8, 3, 12, 0, 0);
const ENTITLEMENT = 'premium';

/// RevenueCat v2 `active_entitlements` yanıt şekli.
function activeEntitlements(...items) {
  return { object: 'list', items, next_page: null };
}

function premiumExpiring(expiresAt) {
  return activeEntitlements({
    object: 'customer.active_entitlement',
    entitlement_id: 'premium',
    expires_at: expiresAt,
    product_id: 'com.kayasoftware.sismik.monthly'
  });
}

test('gelecekteki bitiş tarihi aktif yetki verir', () => {
  const expires = Date.UTC(2026, 9, 3, 12, 0, 0);
  const e = entitlementFromActiveEntitlements(premiumExpiring(expires), ENTITLEMENT, NOW);
  assert.equal(e.isActive, true);
  assert.equal(e.expiresAt, expires);
  assert.equal(e.productId, 'com.kayasoftware.sismik.monthly');
});

// v2 yalnızca aktif yetkileri listeliyor, ama listeleme anı ile bizim
// saatimiz arasındaki sınır durumunda yanlış tarafta kalmayalım diye
// `expires_at` ayrıca kontrol ediliyor.
test('geçmiş bitiş tarihi yetkiyi kapatır', () => {
  const e = entitlementFromActiveEntitlements(
    premiumExpiring(Date.UTC(2026, 7, 3, 12, 0, 0)), ENTITLEMENT, NOW
  );
  assert.equal(e.isActive, false);
});

test('expires_at null ise ömür boyu yetki', () => {
  const e = entitlementFromActiveEntitlements(premiumExpiring(null), ENTITLEMENT, NOW);
  assert.equal(e.isActive, true);
  assert.equal(e.expiresAt, 0);
});

// Asıl korunmak istenen hata: RevenueCat'te CANCELLATION olayı yalnızca
// otomatik yenilemenin kapatıldığı anlamına gelir. Kullanıcı dönem sonuna
// kadar premium kalmalı; olay tipine bakıp yetkiyi kesmek para ödeyen
// kullanıcının bildirimlerini erkenden susturur.
test('iptal edilmiş ama süresi dolmamış abonelik premium kalır', () => {
  const e = entitlementFromActiveEntitlements(
    premiumExpiring(Date.UTC(2026, 8, 20, 12, 0, 0)), ENTITLEMENT, NOW
  );
  assert.equal(e.isActive, true);
});

test('başka bir entitlement premium yetkisi vermez', () => {
  const body = activeEntitlements({
    object: 'customer.active_entitlement',
    entitlement_id: 'pro_plus',
    expires_at: Date.UTC(2026, 9, 3, 12, 0, 0)
  });
  assert.equal(entitlementFromActiveEntitlements(body, ENTITLEMENT, NOW).isActive, false);
});

test('birden fazla yetki arasından doğrusu seçilir', () => {
  const expires = Date.UTC(2026, 9, 3, 12, 0, 0);
  const body = activeEntitlements(
    { entitlement_id: 'pro_plus', expires_at: Date.UTC(2027, 0, 1) },
    { entitlement_id: 'premium', expires_at: expires }
  );
  const e = entitlementFromActiveEntitlements(body, ENTITLEMENT, NOW);
  assert.equal(e.isActive, true);
  assert.equal(e.expiresAt, expires);
});

test('boş liste veya bozuk gövde yetki vermez', () => {
  assert.equal(entitlementFromActiveEntitlements(activeEntitlements(), ENTITLEMENT, NOW).isActive, false);
  assert.equal(entitlementFromActiveEntitlements({}, ENTITLEMENT, NOW).isActive, false);
  assert.equal(entitlementFromActiveEntitlements(null, ENTITLEMENT, NOW).isActive, false);
});

test('sayı olmayan bitiş tarihi yetki vermez', () => {
  assert.equal(
    entitlementFromActiveEntitlements(premiumExpiring('yarin'), ENTITLEMENT, NOW).isActive,
    false
  );
});

test('takma adlar ve transfer kimlikleri toplanır', () => {
  const ids = revenueCatEventUserIds({
    event: {
      app_user_id: 'A',
      original_app_user_id: 'B',
      aliases: ['A', 'C'],
      transferred_from: ['D'],
      transferred_to: ['E']
    }
  });
  assert.deepEqual(ids.sort(), ['A', 'B', 'C', 'D', 'E']);
});

test('kimliksiz gövde boş liste döner', () => {
  assert.deepEqual(revenueCatEventUserIds({}), []);
  assert.deepEqual(revenueCatEventUserIds({ event: { app_user_id: '  ' } }), []);
});

test('TEST olayı tanınır', () => {
  assert.equal(isRevenueCatTestEvent({ event: { type: 'TEST' } }), true);
  assert.equal(isRevenueCatTestEvent({ event: { type: 'RENEWAL' } }), false);
});

test('aktif yetki bitiş tarihini yazar', () => {
  const { set, unset } = entitlementDeviceFieldsFor(
    { isActive: true, expiresAt: 123, productId: 'p' }, NOW
  );
  assert.equal(set.is_premium, true);
  assert.equal(set.premium_expires_at, 123);
  assert.deepEqual(unset, []);
});

test('pasif yetki bitiş alanını siler', () => {
  const { set, unset } = entitlementDeviceFieldsFor(
    { isActive: false, expiresAt: 0, productId: '' }, NOW
  );
  assert.equal(set.is_premium, false);
  assert.deepEqual(unset, ['premium_expires_at']);
});

// Ömür boyu yetkide bitiş alanı yazılmamalı: `toCachedPushDevice` alanın
// yokluğunu "süresiz" sayıyor, 0 yazılsaydı süresi dolmuş gibi görünürdü.
test('ömür boyu yetki bitiş alanı yazmaz', () => {
  const { set, unset } = entitlementDeviceFieldsFor(
    { isActive: true, expiresAt: 0, productId: 'p' }, NOW
  );
  assert.equal(set.is_premium, true);
  assert.equal(set.premium_expires_at, undefined);
  assert.deepEqual(unset, ['premium_expires_at']);
});

const ACTIVE_JWS = {
  isActive: true,
  expiresDate: NOW + 7 * 86_400_000,
  productId: 'com.kayasoftware.sismik.premium.monthly',
  status: 'active',
  originalTransactionId: '200001'
};
const RC_ACTIVE = {
  isActive: true, expiresAt: NOW + 30 * 86_400_000,
  productId: 'com.kayasoftware.sismik.premium.monthly'
};
const RC_NONE = { isActive: false, expiresAt: 0, productId: '' };

test('RevenueCat aktif yetki verirse kaynak RevenueCat olur', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: true,
    revenueCat: RC_ACTIVE, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, true);
  assert.equal(decision.set.entitlement_source, 'revenuecat');
});

test('RevenueCat erişilemezse mevcut yetkiye dokunulmaz', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: true,
    revenueCat: null, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'preserve');
});

test('RevenueCat yetki yok derken geçerli Apple JWS aboneyi kurtarır', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: true,
    revenueCat: RC_NONE, appleJws: ACTIVE_JWS, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, true);
  assert.equal(decision.set.entitlement_source, 'apple_jws');
  assert.equal(decision.set.premium_expires_at, ACTIVE_JWS.expiresDate);
  assert.equal(decision.unmigrated, true);
});

test('iki kaynak da yetki vermiyorsa premium kaldırılır', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: false,
    revenueCat: RC_NONE, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, false);
  assert.ok(decision.unset.includes('premium_expires_at'));
});

test('süresi dolmuş Apple JWS kurtarma yapmaz', () => {
  const expired = { ...ACTIVE_JWS, isActive: false, status: 'expired' };
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: true,
    revenueCat: RC_NONE, appleJws: expired, now: NOW
  });
  assert.equal(decision.set.is_premium, false);
});

test('appUserId yokken Apple JWS tek başına yetki verir', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: true,
    revenueCat: null, appleJws: ACTIVE_JWS, now: NOW
  });
  assert.equal(decision.set.entitlement_source, 'apple_jws');
  assert.equal(decision.set.is_premium, true);
});

// appUserId de imzalı Apple işlemi de yokken istemcinin "premium'um" iddiası
// tek başına kanıt değildir — ne yeni bir yetki icat eder ne de var olanı
// siler. Bu, eski bir App Store sürümünde kalmış gerçek bir abonenin her
// register çağrısında `is_premium: false` yazılıp bildirimlerini kaybetmesini
// önleyen düzeltmedir (bkz. fix round 1, item 1).
test('appUserId ve JWS yokken kanıtsız premium iddiası yetkiye dokunmaz (preserve)', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: true,
    revenueCat: null, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'preserve');
});

// Regresyon: az önce eklenmiş premium yetkisi olan bir cihaz, appUserId ve
// JWS göndermeyen bir istemciden tekrar register olursa, o var olan yetki
// SİLİNMEMELİ. `decideDeviceEntitlement` yalnızca kararı üretir (Firestore'a
// dokunmaz); burada "preserve" kararının merge yazımında hiçbir alanı
// değiştirmediği doğrulanıyor — bu da önceki `write`'ın (`is_premium: true`)
// olduğu gibi kalacağı anlamına gelir.
test('mevcut premium cihaz kanıtsız istemciden register olunca is_premium silinmez', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: true,
    revenueCat: null, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'preserve');
  assert.equal('set' in decision, false);
  assert.equal('unset' in decision, false);
});

// Doğrulanmamış olumsuz iddia (fix round 2, I1).
//
// `/register` istemci "premium değilim" dediğinde RevenueCat'e hiç sormuyordu:
// karar `revenueCat: null` ile veriliyor ve koşulsuz `is_premium: false`
// yazılıyordu. Bu, istemci YANILDIĞINDA (RevenueCat'e aktarılmamış aboneye
// SDK'nın geçici olarak "yetki yok" demesi) ödeme yapan aboneyi push
// hedefinden çıkarıyordu. Artık sunucu kaydı premium diyorsa olumsuz iddia
// tek başına yetkiyi silemez; çağıran RevenueCat'e sorup yeniden karar verir.
test('sunucu premium kayıtlıyken doğrulanmamış "premium değilim" iddiası yetkiyi silmez', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: false,
    revenueCat: null, appleJws: null, storedIsPremium: true, now: NOW
  });
  assert.equal(decision.action, 'preserve');
  assert.equal(decision.reason, 'negative_claim_unverified');
  assert.equal('set' in decision, false);
  assert.equal('unset' in decision, false);
});

// Kesin cevap geldiğinde düşürme YİNE çalışır: gerçekten süresi dolmuş abone
// push hedefinde kalmamalı. (Rotada bu, `negative_claim_unverified` görülünce
// yapılan RevenueCat sorgusunun ardından verilen ikinci karardır.)
test('RevenueCat kesin "yetki yok" derse premium kayıtlı cihaz da düşürülür', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: false,
    revenueCat: RC_NONE, appleJws: null, storedIsPremium: true, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, false);
  assert.equal(decision.set.entitlement_source, 'revenuecat');
  assert.ok(decision.unset.includes('premium_expires_at'));
});

// Sunucu kaydı zaten premium DEĞİLSE olumsuz iddia serbestçe yazılır:
// ücretsiz kullanıcı için fazladan RevenueCat isteği doğmaz.
test('sunucu kaydı premium değilken olumsuz iddia doğrudan yazılır', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: false,
    revenueCat: null, appleJws: null, storedIsPremium: false, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, false);
});

// `storedIsPremium` yalnızca SİLMEYİ engeller; yetki VERMEZ. İstemci premium
// iddia etse bile kanıtsız (appUserId'siz, JWS'siz) istek yetki üretemez.
test('storedIsPremium tek başına yeni yetki üretmez', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: true,
    revenueCat: null, appleJws: null, storedIsPremium: true, now: NOW
  });
  assert.equal(decision.action, 'preserve');
  assert.equal(decision.reason, 'no_evidence_client_claims_premium');
});

// Kayıtlı premium + olumsuz iddia + appUserId YOKSA eski davranış korunur:
// appUserId olmadan RevenueCat'e sorulamaz, kimlik de yoktur; bu istemciye
// kendi kendini düşürme hakkı verilmeye devam eder.
test('appUserId yokken olumsuz iddia premium kayıtlı cihazı yine düşürür', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: false,
    revenueCat: null, appleJws: null, storedIsPremium: true, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, false);
  assert.equal(decision.set.entitlement_source, 'legacy_client');
});

// Aktif Apple JWS taşıyan istek, istemci "premium değilim" dese bile
// kurtarılır — sunucu istemcinin bayrağına değil imzaya bakar.
test('olumsuz iddiaya rağmen aktif Apple JWS yetkiyi korur', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: false,
    revenueCat: RC_NONE, appleJws: ACTIVE_JWS, storedIsPremium: true, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, true);
  assert.equal(decision.set.entitlement_source, 'apple_jws');
});

test('appUserId ve JWS yokken istemci kendini premium değil ilan ederse düşürülür', () => {
  const decision = decideDeviceEntitlement({
    appUserId: '', clientClaimsPremium: false,
    revenueCat: null, appleJws: null, now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, false);
  assert.equal(decision.set.entitlement_source, 'legacy_client');
  assert.ok(decision.unset.includes('premium_expires_at'));
});

test('ömür boyu Apple JWS süresiz premium yazar (bitiş alanı yok)', () => {
  const decision = decideDeviceEntitlement({
    appUserId: 'user-1', clientClaimsPremium: true,
    revenueCat: RC_NONE,
    appleJws: {
      isActive: true, expiresDate: 0,
      productId: 'com.kayasoftware.sismik.lifetime',
      status: 'active', originalTransactionId: '300001'
    },
    now: NOW
  });
  assert.equal(decision.action, 'write');
  assert.equal(decision.set.is_premium, true);
  assert.equal('premium_expires_at' in decision.set, false);
  assert.ok(decision.unset.includes('premium_expires_at'));
});
