const test = require('node:test');
const assert = require('node:assert/strict');
const { resolveRevenueCatEntitlement } = require('../lib/subscription-routes');
const { registerDeviceRoutes } = require('../lib/device-routes');

const reply = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
const future = Date.now() + 86400000;

test('RevenueCat resolves SDK lookup key to opaque v2 ID and caches the catalogue', async t => {
  process.env.REVENUECAT_API_KEY = 'test-key';
  process.env.REVENUECAT_PROJECT_ID = 'project-catalogue-test';
  const calls = [];
  t.mock.method(global, 'fetch', async url => {
    calls.push(String(url));
    return String(url).includes('/customers/')
      ? reply({ items: [{ entitlement_id: 'entl_actual', expires_at: future }], next_page: null })
      : reply({ items: [{ id: 'entl_actual', lookup_key: 'premium' }], next_page: null });
  });
  assert.equal((await resolveRevenueCatEntitlement('user-a', Date.now())).isActive, true);
  assert.equal((await resolveRevenueCatEntitlement('user-b', Date.now())).isActive, true);
  assert.equal(calls.filter(url => !url.includes('/customers/')).length, 1);
});

test('malformed RevenueCat response preserves entitlement instead of revoking it', async t => {
  process.env.REVENUECAT_API_KEY = 'test-key';
  process.env.REVENUECAT_PROJECT_ID = 'project-malformed-test';
  t.mock.method(global, 'fetch', async url => String(url).includes('/customers/')
    ? reply({ unexpected: [] })
    : reply({ items: [{ id: 'entl_actual', lookup_key: 'premium' }] }));
  assert.equal(await resolveRevenueCatEntitlement('user-c', Date.now()), null);
});

test('RevenueCat configuration access failure is not a free entitlement', async t => {
  process.env.REVENUECAT_PROJECT_ID = 'project-denied-test';
  t.mock.method(global, 'fetch', async () => reply({}, 403));
  assert.equal(await resolveRevenueCatEntitlement('user-d', Date.now()), null);
});

function fixture() {
  const routes = new Map();
  const records = new Map();
  let failRead = false;
  let writes = 0;
  const ref = key => ({ key, get: async () => {
    if (failRead) { failRead = false; throw new Error('unavailable'); }
    return { exists: records.has(key), updateTime: 'test-version', data: () => records.get(key) };
  }});
  // Firestore, `FieldValue.delete()` işaretçisini YALNIZCA update() ve
  // merge'lü set() içinde kabul eder; create() bunu "geçersiz belge" diye
  // reddeder. Sahte batch bunu doğrulamadığı sürece, yeni cihazın kaydını
  // kıran hata testlerde görünmez kalıyordu.
  const rejectDeleteSentinels = (op, value) => {
    for (const [field, fieldValue] of Object.entries(value)) {
      if (fieldValue && typeof fieldValue === 'object'
          && /Delete/.test(fieldValue.constructor?.name || '')) {
        throw new Error(`Value for argument "data" is not a valid Firestore document. `
          + `Cannot use "FieldValue.delete()" as a property value in ${op}() (alan: ${field}).`);
      }
    }
  };
  const db = {
    collection: () => ({ doc: ref }),
    batch: () => {
      const pending = [];
      return {
        set: (r, value) => pending.push([r.key, value]),
        update: (r, value) => pending.push([r.key, value]),
        create: (r, value) => { rejectDeleteSentinels('create', value); pending.push([r.key, value]); },
        commit: async () => { for (const [key, value] of pending) {
          records.set(key, { ...records.get(key), ...value }); writes++;
        }}
      };
    }
  };
  registerDeviceRoutes({ post: (path, fn) => routes.set(path, fn), get: () => {} }, db,
    () => false, async () => {}, value => value || 'bildirim.caf');
  const request = async body => {
    const res = { code: 200, status(code) { this.code = code; return this; }, json(value) { this.body = value; } };
    await routes.get('/register')({ body, headers: {} }, res);
    return res;
  };
  return { records, request, failNextRead: () => { failRead = true; }, writes: () => writes };
}
const token = 'valid-FCM-token-at-least-20-characters';

test('failed device queue recovers on the next registration', async () => {
  const f = fixture();
  f.records.set(token, { is_premium: true, registered_at: 1 });
  const body = { token, transport: 'fcm', isPremium: true, notificationSchemaVersion: 2 };
  f.failNextRead();
  assert.equal((await f.request(body)).code, 503);
  assert.equal((await f.request(body)).code, 200);
  assert.equal(f.records.get(token).is_premium, true);
});

test('unverified new premium device is retryable and never acknowledged as registered', async () => {
  const f = fixture();
  assert.equal((await f.request({ token, transport: 'fcm', isPremium: true })).code, 503);
  assert.equal(f.records.size, 0);
});

test('unchanged structured watch does not rewrite the device', async () => {
  const f = fixture();
  f.records.set(token, { is_premium: true, registered_at: 1 });
  const body = { token, transport: 'fcm', isPremium: true, notificationSchemaVersion: 2,
    aftershockWatch: { mainshockId: 'q', title: 'test', latitude: 38, longitude: 27,
      startedAt: Date.now(), expiresAt: Date.now() + 3600000 } };
  assert.equal((await f.request(body)).code, 200);
  const count = f.writes();
  assert.equal((await f.request(JSON.parse(JSON.stringify(body)))).code, 200);
  assert.equal(f.writes(), count);
});

/// Hiç kaydı olmayan yeni bir cihaz (temiz kurulum ya da yeni FCM token'ı)
/// ilk kaydında 200 almalı. Yeni belgede silinecek eski alan YOKTUR; silme
/// işaretçisini `create()` payload'una koymak Firestore tarafından
/// reddediliyor, istek 503'e düşüyor ve istemci sonsuz yeniden deniyordu —
/// yani cihaz sunucuda hiç oluşmuyor, ayar değişiklikleri hiç kaydedilmiyordu.
test('kaydı olmayan yeni cihaz ilk isteğinde başarıyla oluşturulur', async () => {
  const f = fixture();
  const res = await f.request({
    token, transport: 'fcm', tzOffset: 180, lang: 'tr', env: 'prod', isPremium: false,
    earthquakeNotificationsEnabled: true,
    places: [{ id: 'p1', name: 'Ev', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 2 }]
  });
  assert.equal(res.code, 200);
  const stored = f.records.get(token);
  assert.ok(stored, 'cihaz belgesi oluşmalı');
  assert.equal(stored.places.length, 1);
  assert.equal(stored.places[0].name, 'Ev');
  assert.equal(stored.places[0].minMagnitude, 2);
  assert.ok(stored.registered_at > 0);
});

/// Var olan cihazda ayar değişikliği yazılmaya devam etmeli.
test('var olan cihazda ayar değişikliği Firestore\'a yazılır', async () => {
  const f = fixture();
  const place = { id: 'p1', name: 'Ev', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 4 };
  f.records.set(token, { is_premium: true, registered_at: 1, places: [place], notified: [] });
  const before = f.writes();
  const res = await f.request({
    token, transport: 'fcm', isPremium: true, tzOffset: 180, lang: 'tr', env: 'prod',
    earthquakeNotificationsEnabled: true,
    places: [{ ...place, minMagnitude: 3 }]
  });
  assert.equal(res.code, 200);
  assert.ok(f.writes() > before, 'değişen eşik yazım üretmeli');
  assert.equal(f.records.get(token).places[0].minMagnitude, 3);
});

test('eski istemci places göndermezse boş dizi yazılmaz ve eski alanlar durur', async () => {
  const f = fixture();
  f.records.set(token, {
    is_premium: true,
    registered_at: 1,
    nearby_only: false,
    latitude: 40.99,
    longitude: 29.03,
    radius: 250,
    min_magnitude: 4
  });
  const res = await f.request({
    token, transport: 'fcm', isPremium: true, tzOffset: 180, lang: 'tr', env: 'prod',
    earthquakeNotificationsEnabled: true
  });
  assert.equal(res.code, 200);
  const stored = f.records.get(token);
  assert.equal(stored.places, undefined);
  assert.equal(stored.latitude, 40.99);
  assert.equal(stored.min_magnitude, 4);
});

test('dolu places gelince yeni yer listesi yazılır', async () => {
  const f = fixture();
  f.records.set(token, {
    is_premium: true,
    registered_at: 1,
    nearby_only: true,
    latitude: 40.99,
    longitude: 29.03,
    radius: 75,
    min_magnitude: 3
  });
  const res = await f.request({
    token, transport: 'fcm', isPremium: true, tzOffset: 180, lang: 'tr', env: 'prod',
    earthquakeNotificationsEnabled: true,
    places: [{ id: 'p1', name: 'Ev', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 2 }]
  });
  assert.equal(res.code, 200);
  const stored = f.records.get(token);
  assert.equal(stored.places.length, 1);
  assert.equal(stored.places[0].name, 'Ev');
  for (const field of ['source', 'min_magnitude', 'nearby_only', 'latitude', 'radius']) {
    assert.ok(isDeleted(stored[field]), `${field} silinmeli`);
  }
});

// Sahte batch update() değerini birleştirerek saklar; silinen alan orada
// FieldValue.delete() işaretçisi olarak kalır.
const isDeleted = value => Boolean(value && typeof value === 'object'
  && /Delete/.test(value.constructor?.name || ''));

/// 2.0.9'un gövdesi. Sunucu yenilense de bu istemcinin ayar değişikliği
/// eskisi gibi yazılmalı; yoksa güncellememiş kullanıcının eşiği/kaynağı
/// sunucuda donar.
const legacyBody = extra => ({
  token, transport: 'fcm', isPremium: true, tzOffset: 180, lang: 'tr', env: 'prod',
  notificationSchemaVersion: 2, source: 'afad', sourceFallbackEnabled: true,
  minMagnitude: 3, majorThreshold: 5, quietHours: false, minimumEstimatedMMI: 0,
  worldMajorEnabled: false, worldMajorThreshold: 6.5, earthquakeNotificationsEnabled: true,
  nearbyOnly: false, radius: 250, ...extra
});

test('2.0.9 gövdesi eski kural alanlarını yazar', async () => {
  const f = fixture();
  f.records.set(token, { is_premium: true, registered_at: 1, source: 'afad', min_magnitude: 4 });
  assert.equal((await f.request(legacyBody({ source: 'usgs', minMagnitude: 2.5 }))).code, 200);
  const stored = f.records.get(token);
  assert.equal(stored.source, 'usgs');
  assert.equal(stored.min_magnitude, 2.5);
  assert.ok(stored.places === undefined || isDeleted(stored.places));
});

test('eski kurala dönen belgede artık places kalmaz (tek kural değişmezi)', async () => {
  const f = fixture();
  f.records.set(token, {
    is_premium: true, registered_at: 1, source: 'afad', min_magnitude: 4,
    places: [{ id: 'legacy', name: '', lat: 40.99, lon: 29.03, radiusKm: 250, minMagnitude: 4 }]
  });
  assert.equal((await f.request(legacyBody())).code, 200);
  assert.ok(isDeleted(f.records.get(token).places));
});

test('yer modeline geçen istemci boş listeyle bile eski kuralı siler', async () => {
  const f = fixture();
  f.records.set(token, { is_premium: true, registered_at: 1, source: 'afad', min_magnitude: 4, nearby_only: false });
  const res = await f.request({
    token, transport: 'fcm', isPremium: true, tzOffset: 180, lang: 'tr', env: 'prod',
    earthquakeNotificationsEnabled: true, places: []
  });
  assert.equal(res.code, 200);
  const stored = f.records.get(token);
  assert.deepEqual(stored.places, []);
  assert.ok(isDeleted(stored.source));
  assert.ok(isDeleted(stored.min_magnitude));
});

test('2.0.9 yakınlık kuralında koordinat gelmezse saklı koordinat korunur', async () => {
  const f = fixture();
  f.records.set(token, { is_premium: true, registered_at: 1, nearby_only: true, latitude: 38.4, longitude: 27.1 });
  assert.equal((await f.request(legacyBody({ nearbyOnly: true }))).code, 200);
  assert.equal(f.records.get(token).latitude, 38.4);
});


