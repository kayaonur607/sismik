const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const { initPushRoutes, enqueuePushPass, flushPushDeliveryState, resetPushDeviceCache } = require('../lib/push-routes');

// Teslim turu uçtan uca: cihaz önbelleği → ızgara adayları → FCM → teslim
// durumu. Firestore ve FCM sahte; sayılan şey okuma/yazım ve alıcılar.

function deviceDoc(id, data) {
  return {
    id,
    data: () => ({ transport: 'fcm', token: `token-${id}`, is_premium: true, registered_at: 0, updated_at: 1, ...data })
  };
}

function mockDb(deviceDocs) {
  const state = { writes: [], claims: [], deliveryReads: 0, queries: {}, deviceDocs };
  const registry = { revision: 'r1', deletions: 0 };
  const systemDocs = { device_registry_v1: registry };
  const systemDoc = id => ({
    id,
    get: async () => {
      if (id === 'push_delivery_v1') state.deliveryReads++;
      return { exists: Boolean(systemDocs[id]), data: () => systemDocs[id] };
    },
    set: async value => {
      if (id === 'push_events_v1') {
        systemDocs[id] = value;
        state.claims = value.events.map(event => event.id);
        return;
      }
      state.writes.push(id);
    }
  });
  state.db = {
    collection: name => {
      if (name === '_system') return { doc: systemDoc };
      if (name === 'devices') {
        return {
          doc: id => ({ id }),
          where: field => ({
            get: async () => {
              // Tam okuma `Filter.or(push_candidate, is_premium)` nesnesiyle gelir.
              const key = typeof field === 'string' ? field : 'full';
              state.queries[key] = (state.queries[key] || 0) + 1;
              const docs = state.deviceDocs;
              return { docs, size: docs.length, forEach: fn => docs.forEach(fn) };
            }
          })
        };
      }
      throw new Error(`unexpected collection ${name}`);
    },
    runTransaction: async work => work({ get: ref => ref.get(), set: (ref, value) => ref.set(value) }),
    batch: () => {
      const ops = [];
      return {
        delete: ref => ops.push(() => { state.deviceDocs = state.deviceDocs.filter(doc => doc.id !== ref.id); }),
        update: () => {},
        // Kayıt defteri revizyonu: `deletions` bir FieldValue.increment(1).
        set: (ref, payload) => ops.push(() => {
          if (ref.id !== 'device_registry_v1') return;
          registry.revision = payload.revision;
          if (payload.deletions) registry.deletions += 1;
        }),
        commit: async () => ops.forEach(op => op())
      };
    }
  };
  state.deliveryWrites = () => state.writes.filter(id => id === 'push_delivery_v1').length;
  return state;
}

function afadQuake(id, overrides = {}) {
  return {
    id,
    provider: 'AFAD',
    title: 'Pütürge (Malatya)',
    magnitude: 3.6,
    depth: 7,
    lat: 38.2,
    lon: 38.87,
    date: new Date(Date.now() - 60_000).toISOString(),
    ...overrides
  };
}

test('push pass reaches legacy all-region devices and defers the state write to one flush', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-push-state' });
  const sentTokens = [];
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    batch.forEach(message => sentTokens.push(message.token));
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  try {
    const firestore = mockDb([
      // Eski kural, koordinatsız "tüm bölgeler" (üretimdeki çoğunluk).
      deviceDoc('legacy-all', { source: 'afad', min_magnitude: 3 }),
      // Yer modeli, İzmir'de 50 km — Malatya depremiyle eşleşmemeli.
      deviceDoc('izmir-place', { places: [{ id: 'p', name: 'Ev', lat: 38.42, lon: 27.14, radiusKm: 50, minMagnitude: 2 }] })
    ]);
    resetPushDeviceCache();
    initPushRoutes(firestore.db);

    // Kimseyle eşleşmeyen deprem: bellekte işlenir, yazım üretmez.
    await enqueuePushPass(firestore.db, [afadQuake('afad-quiet', { magnitude: 1.2 })], false, 'test');
    await flushPushDeliveryState();
    assert.equal(firestore.deliveryWrites(), 0, 'eşleşmesiz deprem teslim durumu yazmamalı');
    assert.deepEqual(sentTokens, []);

    await enqueuePushPass(firestore.db, [afadQuake('afad-felt')], false, 'test');
    assert.deepEqual(sentTokens, ['token-legacy-all']);
    assert.deepEqual(firestore.claims, ['afad-felt']);
    assert.equal(firestore.deliveryWrites(), 0, 'yazım tur içinde değil sonda yapılmalı');

    await flushPushDeliveryState();
    await flushPushDeliveryState();
    assert.equal(firestore.deliveryWrites(), 1, 'kirli durum tek yazımla kalıcılaşmalı');

    // Aynı deprem tekrar gelirse (gerçek zamanlı + tarama) ikinci bildirim yok.
    await enqueuePushPass(firestore.db, [afadQuake('afad-felt')], false, 'test');
    assert.deepEqual(sentTokens, ['token-legacy-all']);
    assert.equal(firestore.deliveryReads, 1, 'teslim durumu süreç başına bir kez okunmalı');
  } finally {
    await app.delete();
  }
});

test('concurrent passes run one after another', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-push-queue' });
  let active = 0;
  let maximum = 0;
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    active++;
    maximum = Math.max(maximum, active);
    await new Promise(resolve => setTimeout(resolve, 5));
    active--;
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  try {
    const firestore = mockDb([deviceDoc('legacy-queue', { source: 'afad', min_magnitude: 2 })]);
    resetPushDeviceCache();
    initPushRoutes(firestore.db);
    await Promise.all([
      enqueuePushPass(firestore.db, [afadQuake('afad-q1')], false, 'a'),
      enqueuePushPass(firestore.db, [afadQuake('afad-q2', { lat: 39.9, lon: 32.8 })], false, 'b')
    ]);
    assert.equal(maximum, 1);
  } finally {
    await app.delete();
  }
});

test('a dead token deleted by the push pass does not force a full device re-read', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-dead-token' });
  const sentTokens = [];
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    batch.forEach(message => sentTokens.push(message.token));
    return {
      successCount: batch.filter(m => m.token !== 'token-dead').length,
      failureCount: batch.filter(m => m.token === 'token-dead').length,
      responses: batch.map(m => m.token === 'token-dead'
        ? { success: false, error: { code: 'messaging/registration-token-not-registered' } }
        : { success: true })
    };
  });
  try {
    const firestore = mockDb([
      deviceDoc('dead', { source: 'afad', min_magnitude: 2 }),
      deviceDoc('alive', { source: 'afad', min_magnitude: 2 })
    ]);
    resetPushDeviceCache();
    initPushRoutes(firestore.db);

    await enqueuePushPass(firestore.db, [afadQuake('afad-dead-1')], false, 'test');
    assert.deepEqual(sentTokens.sort(), ['token-alive', 'token-dead']);
    assert.equal(firestore.queries.full, 1);
    assert.deepEqual(firestore.deviceDocs.map(doc => doc.id), ['alive']);

    sentTokens.length = 0;
    await enqueuePushPass(firestore.db, [afadQuake('afad-dead-2', { lat: 39.9, lon: 32.8 })], false, 'test');
    assert.deepEqual(sentTokens, ['token-alive']);
    assert.equal(firestore.queries.full, 1, 'kendi silmemiz tüm push adaylarını yeniden okutmamalı');
    // Önbellek delta aralığı (15 sn) içinde taze: ne tam ne delta okuma.
    assert.equal(firestore.queries.updated_at ?? 0, 0, 'delta aralığı dolmadan okuma yapılmamalı');
  } finally {
    await app.delete();
  }
});
