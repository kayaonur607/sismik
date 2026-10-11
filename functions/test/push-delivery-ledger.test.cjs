const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const { initPushRoutes, enqueuePushPass, flushPushDeliveryState } = require('../lib/push-routes');

// Teslim defteri yalnızca bildirim penceresinde anlamı olan kimlikleri taşır.
test('processed quake ids older than the delivery window are not persisted', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-delivery-ledger' });
  t.mock.method(admin.messaging(), 'sendEach', async batch => ({
    successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true }))
  }));
  let clock = Date.parse('2026-09-13T08:00:00Z');
  t.mock.method(Date, 'now', () => clock);
  try {
    const writes = [];
    const device = {
      id: 'legacy', data: () => ({ transport: 'fcm', token: 't', is_premium: true, registered_at: 0, updated_at: 1, source: 'afad', min_magnitude: 3 })
    };
    const db = {
      runTransaction: async work => work({ get: ref => ref.get(), set: () => {} }),
      collection: name => {
        if (name === '_system') {
          return { doc: id => ({
            get: async () => ({ exists: id === 'device_registry_v1', data: () => (id === 'device_registry_v1' ? { revision: 'r', deletions: 0 } : undefined) }),
            set: async value => { if (id === 'push_delivery_v1') writes.push(value); }
          }) };
        }
        return { where: () => ({ get: async () => ({ docs: [device], size: 1, forEach: fn => [device].forEach(fn) }) }) };
      }
    };
    initPushRoutes(db);
    const quake = (id, magnitude, at) => ({
      id, provider: 'AFAD', title: 'X', magnitude, depth: 7, lat: 38.2, lon: 38.9, date: new Date(at).toISOString()
    });

    // Eşleşmeyen deprem: bellekte işlenir.
    await enqueuePushPass(db, [quake('afad-old', 1.5, clock - 60000)], false, 'test');
    clock += 4 * 60 * 60 * 1000;
    // Dört saat sonra gönderilen deprem teslim durumunu kirletir.
    await enqueuePushPass(db, [quake('afad-new', 4.0, clock - 60000)], false, 'test');
    await flushPushDeliveryState();

    assert.equal(writes.length, 1);
    assert.deepEqual(writes[0].processed_quake_ids, ['afad-new']);
  } finally {
    await app.delete();
  }
});
