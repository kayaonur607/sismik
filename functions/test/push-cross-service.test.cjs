const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const { initPushRoutes, enqueuePushPass, resetPushDeviceCache } = require('../lib/push-routes');

// 23 Eyl 2026, Saimbeyli M2.8: dakikalık tur EMSC kaydını, 35 sn sonra hızlı
// tarama (ayrı süreç) AFAD kaydını gönderdi — cihaz iki bildirim aldı.
// Ortak teslim defteri başka süreçte gönderilen asıl kaydı görür.
test('başka serviste gönderilmiş depremin diğer ajans kopyası ikinci bildirim üretmez', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-cross-service' });
  const sent = [];
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    sent.push(...batch.map(message => message.apns.payload.quakeId));
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  const now = Date.parse('2026-09-23T07:56:47Z');
  t.mock.method(Date, 'now', () => now);
  try {
    const systemDocs = {
      device_registry_v1: { revision: 'r', deletions: 0 },
      // Diğer servisin (dakikalık tur) 07:56:12'de aldığı EMSC kaydı.
      push_events_v1: { events: [{
        id: 'emsc-20260923_0000087', provider: 'EMSC', time: Date.parse('2026-09-23T07:44:53Z'),
        magnitude: 2.8, lat: 37.798, lon: 36.1827, claimedAt: now - 35_000
      }] }
    };
    const device = {
      id: 'adana', data: () => ({
        transport: 'fcm', token: 'token-adana', is_premium: true, registered_at: 0, updated_at: 1,
        push_candidate: true, places: [{ id: 'p', name: 'Ev', lat: 37.99, lon: 36.09, radiusKm: 50, minMagnitude: 2 }]
      })
    };
    const systemDoc = id => ({
      id,
      get: async () => ({ exists: Boolean(systemDocs[id]), data: () => systemDocs[id] }),
      set: async value => { systemDocs[id] = value; }
    });
    const db = {
      runTransaction: async work => work({ get: ref => ref.get(), set: (ref, value) => ref.set(value) }),
      collection: name => {
        if (name === '_system') return { doc: systemDoc };
        return { where: () => ({ get: async () => ({ docs: [device], size: 1, forEach: fn => [device].forEach(fn) }) }) };
      }
    };
    resetPushDeviceCache();
    initPushRoutes(db, { persistState: false });

    const afad = {
      id: 'afad-729426', provider: 'AFAD', title: 'Saimbeyli (Adana)', magnitude: 2.9, depth: 7,
      lat: 37.83, lon: 36.16, date: '2026-09-23T07:44:55.000Z'
    };
    await enqueuePushPass(db, [afad], false, 'hızlı tarama');
    assert.deepEqual(sent, [], 'aynı deprem ikinci kez gönderilmemeli');
    assert.equal(systemDocs.push_events_v1.events.at(-1).duplicateOf, 'emsc-20260923_0000087');

    // Gerçekten ayrı bir deprem ise gider.
    await enqueuePushPass(db, [{ ...afad, id: 'afad-729500', magnitude: 3.4, date: '2026-09-23T07:52:10.000Z' }], false, 'hızlı tarama');
    assert.deepEqual(sent, ['afad-729500']);
  } finally {
    await app.delete();
  }
});
