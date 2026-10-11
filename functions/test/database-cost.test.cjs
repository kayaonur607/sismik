const test = require('node:test');
const assert = require('node:assert/strict');
const {
  deviceRegistrationNeedsWrite,
  deviceRegistrationHeartbeatDue,
  maintenanceTasksForInstant
} = require('../lib/worker-utils');

test('unchanged device registration skips a Firestore write', () => {
  const existing = {
    token: 'token-1',
    min_magnitude: 4,
    is_premium: true,
    updated_at: 123
  };

  assert.equal(deviceRegistrationNeedsWrite(existing, {
    token: 'token-1',
    min_magnitude: 4,
    is_premium: true
  }), false);
});

test('device heartbeat refreshes weekly without creating daily writes', () => {
  const now = Date.parse('2026-08-15T12:00:00.000Z');
  assert.equal(deviceRegistrationHeartbeatDue(now - 6 * 86400000, now), false);
  assert.equal(deviceRegistrationHeartbeatDue(now - 7 * 86400000, now), true);
  assert.equal(deviceRegistrationHeartbeatDue(undefined, now), true);
});

test('new, changed, or explicitly removed fields require a write', () => {
  assert.equal(deviceRegistrationNeedsWrite(undefined, { token: 'token-1' }), true);
  assert.equal(deviceRegistrationNeedsWrite({ token: 'old' }, { token: 'new' }), true);
  assert.equal(deviceRegistrationNeedsWrite(
    { token: 'token-1', premium_expires_at: 123 },
    { token: 'token-1' },
    ['premium_expires_at']
  ), true);
  assert.equal(deviceRegistrationNeedsWrite(
    { token: 'token-1' },
    { token: 'token-1' },
    ['premium_expires_at']
  ), false);
});

test('hourly maintenance runs the map on even hours and cleanup at 04:05 Istanbul', () => {
  assert.deepEqual(
    maintenanceTasksForInstant(Date.parse('2026-07-14T01:05:00Z')),
    { refreshMap: true, cleanup: true, weeklyDigest: false }
  );
  assert.deepEqual(
    maintenanceTasksForInstant(Date.parse('2026-07-14T02:05:00Z')),
    { refreshMap: false, cleanup: false, weeklyDigest: false }
  );
  assert.deepEqual(
    maintenanceTasksForInstant(Date.parse('2026-07-14T03:05:00Z')),
    { refreshMap: true, cleanup: false, weeklyDigest: false }
  );
  // 21 Eylül 2026 pazartesi, 09:05 İstanbul = 06:05 UTC.
  assert.equal(maintenanceTasksForInstant(Date.parse('2026-09-21T06:05:00Z')).weeklyDigest, true);
  assert.equal(maintenanceTasksForInstant(Date.parse('2026-09-21T07:05:00Z')).weeklyDigest, false);
  assert.equal(maintenanceTasksForInstant(Date.parse('2026-09-22T06:05:00Z')).weeklyDigest, false);
});


// --- Push cihaz önbelleği: delta senkronizasyon -----------------------------
// Eskiden teslimi etkileyen her ayar değişikliği TÜM premium cihaz
// koleksiyonunu yeniden okutuyordu (O(N) okuma). Delta yalnızca son
// senkronizasyondan sonra yazılan belgeleri okur.

const { applyPushDeviceDelta } = require('../lib/worker-utils');

test('delta only advances the sync boundary forward', () => {
  const cache = new Map([['a', { key: 'a' }]]);
  const next = applyPushDeviceDelta(cache, [
    { id: 'b', updatedAt: 500, device: { key: 'b' } },
    { id: 'c', updatedAt: 200, device: { key: 'c' } }
  ], 300);
  assert.equal(next, 500);
});

test('a device that stops qualifying is removed from the cache', () => {
  const cache = new Map([['a', { key: 'a' }], ['b', { key: 'b' }]]);
  applyPushDeviceDelta(cache, [
    { id: 'a', updatedAt: 900, device: null }
  ], 100);
  assert.deepEqual([...cache.keys()], ['b']);
});

test('a newly qualifying device is added and an existing one is replaced', () => {
  const cache = new Map([['a', { key: 'a', min: 4 }]]);
  applyPushDeviceDelta(cache, [
    { id: 'a', updatedAt: 900, device: { key: 'a', min: 2 } },
    { id: 'z', updatedAt: 950, device: { key: 'z', min: 5 } }
  ], 100);
  assert.equal(cache.get('a').min, 2);
  assert.equal(cache.get('z').min, 5);
  assert.equal(cache.size, 2);
});

test('an empty delta leaves both the cache and the boundary untouched', () => {
  const cache = new Map([['a', { key: 'a' }]]);
  assert.equal(applyPushDeviceDelta(cache, [], 700), 700);
  assert.equal(cache.size, 1);
});

test('a missing or invalid updated_at never rewinds the boundary', () => {
  const cache = new Map();
  assert.equal(applyPushDeviceDelta(cache, [
    { id: 'a', updatedAt: 0, device: { key: 'a' } },
    { id: 'b', updatedAt: NaN, device: { key: 'b' } }
  ], 700), 700);
  assert.equal(cache.size, 2);
});

test('purging obsolete quiet hours fields triggers write once and then skips', () => {
  const obsoleteFields = ['quiet_hours', 'quiet_start', 'quiet_end'];
  const legacyDoc = {
    token: 'token-1',
    min_magnitude: 4,
    is_premium: true,
    quiet_hours: false,
    quiet_start: 0,
    quiet_end: 7
  };
  const cleanDesired = {
    token: 'token-1',
    min_magnitude: 4,
    is_premium: true
  };

  // Legacy doc has quiet_hours fields -> must write to delete them
  assert.equal(deviceRegistrationNeedsWrite(legacyDoc, cleanDesired, obsoleteFields), true);

  // Cleaned doc without quiet_hours fields -> skips write
  const cleanedDoc = { ...cleanDesired };
  assert.equal(deviceRegistrationNeedsWrite(cleanedDoc, cleanDesired, obsoleteFields), false);
});

test('POST /register identical payload within TTL hits memory cache and skips Firestore doc.get()', async () => {
  const { registerDeviceRoutes, clearDeviceRegistrationCache, getDeviceRegistrationCacheSize } = require('../lib/device-routes');
  clearDeviceRegistrationCache();
  const routes = new Map();
  let getCalls = 0;
  const mockDocRef = {
    get: async () => {
      getCalls++;
      return { exists: true, data: () => ({ is_premium: false, registered_at: 1000 }) };
    }
  };
  const mockDb = {
    collection: () => ({ doc: () => mockDocRef }),
    batch: () => ({
      update: () => {},
      commit: async () => {}
    })
  };
  registerDeviceRoutes(
    { post: (path, fn) => routes.set(path, fn), get: () => {} },
    mockDb,
    () => false,
    async () => {},
    v => v || 'bildirim.caf'
  );

  const reqBody = {
    token: 'test-token-at-least-20-chars-long',
    transport: 'fcm',
    lang: 'tr',
    tzOffset: 180,
    isPremium: false,
    places: [{ id: 'p1', name: 'Ev', lat: 40.0, lon: 29.0, radiusKm: 50, minMagnitude: 3.0 }]
  };

  const registerHandler = routes.get('/register');
  const res1 = { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };
  await registerHandler({ body: reqBody, headers: {} }, res1);
  assert.equal(res1.code, 200);
  assert.equal(getCalls, 1, 'İlk istekte Firestore get() çağrılmalı');
  assert.equal(getDeviceRegistrationCacheSize(), 1);

  // İkinci istek: Birebir aynı gövde
  const res2 = { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };
  await registerHandler({ body: reqBody, headers: {} }, res2);
  assert.equal(res2.code, 200);
  assert.equal(res2.body.cached, true, 'İkinci istek önbellekten dönmeli');
  assert.equal(getCalls, 1, 'İkinci istekte Firestore get() HİÇ ÇAĞRILMAMALI');
});

test('POST /unregister invalidates deviceRegistrationCache entry', async () => {
  const { registerDeviceRoutes, clearDeviceRegistrationCache, getDeviceRegistrationCacheSize } = require('../lib/device-routes');
  clearDeviceRegistrationCache();
  const routes = new Map();
  const mockDocRef = {
    get: async () => ({ exists: true, data: () => ({ is_premium: false, registered_at: 1000 }) })
  };
  const mockDb = {
    collection: () => ({ doc: () => mockDocRef }),
    getAll: async () => [{ exists: true, ref: {} }],
    batch: () => ({
      delete: () => {},
      update: () => {},
      commit: async () => {}
    })
  };
  registerDeviceRoutes(
    { post: (path, fn) => routes.set(path, fn), get: () => {} },
    mockDb,
    () => false,
    async () => {},
    v => v || 'bildirim.caf'
  );

  const reqBody = {
    token: 'test-token-at-least-20-chars-long-2',
    transport: 'fcm',
    lang: 'tr',
    tzOffset: 180,
    isPremium: false
  };

  const registerHandler = routes.get('/register');
  const res1 = { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };
  await registerHandler({ body: reqBody, headers: {} }, res1);
  assert.equal(getDeviceRegistrationCacheSize(), 1);

  const unregisterHandler = routes.get('/unregister');
  const res2 = { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };
  await unregisterHandler({ body: { token: 'test-token-at-least-20-chars-long-2' } }, res2);
  assert.equal(getDeviceRegistrationCacheSize(), 0, 'Unregister sonrası önbellek silinmeli');
});

test('loadPushDevices on cold start restores from push_device_snapshot_v1 with 1 read', async () => {
  const { initPushRoutes, loadPushDevices, resetPushDeviceCache, getPushDeviceCacheSize } = require('../lib/push-routes');
  const { gzipSync } = require('node:zlib');
  resetPushDeviceCache();

  const fakeDevices = [
    { key: 'dev-1', prefs: {}, premiumExpiresAt: 0 },
    { key: 'dev-2', prefs: {}, premiumExpiresAt: 0 }
  ];
  const payloadGz = gzipSync(Buffer.from(JSON.stringify(fakeDevices)), { level: 6 });

  let snapshotReads = 0;
  let fullCollectionScans = 0;
  let deltaQueries = 0;

  const mockDb = {
    collection: (name) => {
      if (name === '_system') {
        return {
          doc: (id) => ({
            get: async () => {
              if (id === 'device_registry_v1') {
                return { exists: true, data: () => ({ revision: 'rev-1', deletions: 0 }) };
              }
              if (id === 'push_device_snapshot_v1') {
                snapshotReads++;
                return {
                  exists: true,
                  data: () => ({
                    schema_version: 1,
                    revision: 'rev-1',
                    deletions: 0,
                    synced_at: 1000,
                    payload: payloadGz
                  })
                };
              }
              return { exists: false, data: () => ({}) };
            },
            set: async () => {}
          })
        };
      }
      if (name === 'devices') {
        return {
          where: (field) => {
            if (field === 'is_premium') fullCollectionScans++;
            if (field === 'updated_at') deltaQueries++;
            return {
              get: async () => ({ docs: [], size: 0, forEach: () => {} })
            };
          }
        };
      }
      return { doc: () => ({ get: async () => ({ exists: false }) }) };
    }
  };

  initPushRoutes(mockDb);
  const devices = await loadPushDevices(mockDb, Date.now());

  assert.equal(snapshotReads, 1, 'Soğuk açılışta sıkıştırılmış snapshot belgesi okunmalı');
  assert.equal(fullCollectionScans, 0, 'Tüm koleksiyon taranmamalı ($O(N) okuma engellenmeli)');
  assert.equal(devices.length, 2, 'Snapshot içindeki cihazlar geri yüklenmeli');
  assert.equal(getPushDeviceCacheSize(), 2);
});

test('loadPushDevices caches deviceRegistryRef for 30 seconds during fast scans', async () => {
  const { initPushRoutes, loadPushDevices, resetPushDeviceCache } = require('../lib/push-routes');
  resetPushDeviceCache();

  let registryReads = 0;
  const mockDb = {
    collection: (name) => {
      if (name === '_system') {
        return {
          doc: (id) => ({
            get: async () => {
              if (id === 'device_registry_v1') {
                registryReads++;
                return { exists: true, data: () => ({ revision: 'rev-static', deletions: 0 }) };
              }
              return { exists: false, data: () => ({}) };
            },
            set: async () => {}
          })
        };
      }
      return {
        where: () => ({
          get: async () => ({ docs: [], size: 0, forEach: () => {} })
        })
      };
    }
  };

  initPushRoutes(mockDb);
  const now = 100000;

  // 1. çağrı: registry okunur
  await loadPushDevices(mockDb, now);
  assert.equal(registryReads, 1);

  // 2. ve 3. çağrı (15 sn ve 25 sn sonra, yani 30s TTL içinde): registry TEKRAR OKUNMAMALI
  await loadPushDevices(mockDb, now + 15000);
  await loadPushDevices(mockDb, now + 25000);
  assert.equal(registryReads, 1, '30 saniyelik TTL içinde registry tekrar okunmamalı');

  // 4. çağrı (35 sn sonra, TTL doldu): registry tekrar okunmalı
  await loadPushDevices(mockDb, now + 35000);
  assert.equal(registryReads, 2, '30 saniye geçtikten sonra registry tekrar okunmalı');
});

test('AI routes reject out-of-bounds coordinates without querying Firestore', async () => {
  const { registerAiRoutes } = require('../lib/ai-routes');
  const routes = new Map();
  let firestoreReads = 0;
  const mockDb = {
    collection: () => ({
      doc: () => ({
        get: async () => { firestoreReads++; return { exists: false }; }
      })
    })
  };

  registerAiRoutes(
    { get: (path, fn) => routes.set(path, fn) },
    mockDb,
    () => false
  );

  const aiHandler = routes.get('/ai');
  const badRes = { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };

  // Geçersiz enlem (99 > 90)
  await aiHandler({ query: { id: 'q1', lat: '99', lon: '29', mag: '4.0', depth: '10' } }, badRes);
  assert.equal(badRes.code, 400);
  assert.equal(firestoreReads, 0, 'Geçersiz koordinatta Firestore sorgulanmamalı');
});



test('concurrent identical AI misses share one Firestore read and one Gemini call', async t => {
  const axios = require('axios');
  const { registerAiRoutes } = require('../lib/ai-routes');
  const routes = new Map();
  let reads = 0;
  let writes = 0;
  const db = {
    collection: () => ({
      doc: () => ({
        get: async () => { reads++; await new Promise(r => setTimeout(r, 5)); return { exists: false }; },
        set: async () => { writes++; }
      })
    })
  };
  let geminiCalls = 0;
  t.mock.method(axios, 'post', async () => {
    geminiCalls++;
    await new Promise(r => setTimeout(r, 5));
    return { data: { candidates: [{ content: { parts: [{ text: 'Kısa not.' }] } }] } };
  });
  const previousKey = process.env.GEMINI_API_KEY;
  process.env.GEMINI_API_KEY = 'test-key';
  try {
    registerAiRoutes({ get: (path, fn) => routes.set(path, fn) }, db, () => false);
    const ask = routes.get('/ai/ask');
    const query = { id: 'afad-herd', lat: '38.2', lon: '38.9', mag: '6.1', depth: '10', q: 'Artçı olur mu?', lang: 'tr' };
    const responses = Array.from({ length: 25 }, () => ({
      code: 200, headers: {}, setHeader(k, v) { this.headers[k] = v; },
      status(c) { this.code = c; return this; }, json(b) { this.body = b; }
    }));
    await Promise.all(responses.map(res => ask({ query }, res)));
    assert.equal(geminiCalls, 1);
    assert.equal(reads, 1);
    assert.equal(writes, 1);
    assert.ok(responses.every(res => res.code === 200 && res.body.answer === 'Kısa not.'));
  } finally {
    if (previousKey === undefined) delete process.env.GEMINI_API_KEY;
    else process.env.GEMINI_API_KEY = previousKey;
  }
});

// --- "Hissettim" sayacı parçaları -------------------------------------------
// Büyük depremde tek belgeye artırım Firestore çekişmesine takılıyordu;
// yazımlar parçalara dağılır, okuma eski ana belge + parçaları toplar.
const { FELT_SHARD_COUNT, feltShardId, sumFeltCounters, feltCellKey } = require('../lib/device-routes');

test('felt counters sum the legacy document and every shard', () => {
  assert.ok(FELT_SHARD_COUNT >= 5);
  assert.equal(feltShardId('afad-123', 3), 'afad-123__s3');
  assert.deepEqual(
    sumFeltCounters([{ count: 4, not_felt_count: 1 }, undefined, { count: 2 }, { not_felt_count: 5 }]),
    { count: 6, notFeltCount: 6, cells: [] }
  );
  assert.deepEqual(sumFeltCounters([]), { count: 0, notFeltCount: 0, cells: [] });
});

test('felt map cells are coarse, summed across shards and sorted by count', () => {
  assert.equal(feltCellKey(38.4321, 27.1499), '384_271');
  assert.equal(feltCellKey(-33.46, -70.66), '-335_-707');
  assert.equal(feltCellKey(undefined, 27), null);
  assert.equal(feltCellKey(95, 27), null);
  const { cells } = sumFeltCounters([
    { count: 3, cells: { '384_271': 2, '390_270': 1 } },
    { count: 2, cells: { '384_271': 2 } }
  ]);
  assert.deepEqual(cells, [{ lat: 38.4, lon: 27.1, count: 4 }, { lat: 39, lon: 27, count: 1 }]);
});
