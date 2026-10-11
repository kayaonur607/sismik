const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const {
  campaignCopyFor,
  isCampaignRecipient,
  hasRecentMajorRegionalQuake,
  runPremiumEngagementCampaign
} = require('../lib/premium-campaign');
const { initPushRoutes } = require('../lib/push-routes');

const DAY = 86400000;
const NOW = Date.parse('2026-09-20T15:00:00Z');

test('copy rotates, follows the device language and skips features the app version lacks', () => {
  assert.equal(campaignCopyFor(0, 'tr', '2.1.0').title, 'Sevdiklerinin şehrini de takip et');
  // 2.0.9'da kayıtlı yerler yok: sıradaki metin gider.
  assert.equal(campaignCopyFor(0, 'tr', '2.0.9').title, 'Artçıları kilit ekranından izle');
  assert.equal(campaignCopyFor(2, 'es', '2.1.0').title, 'La historia detrás de cada sismo');
  assert.equal(campaignCopyFor(3, 'xx', '2.1.0').title, 'Explore fault lines and the past');
});

test('only free, established devices receive the campaign', () => {
  const device = { token: 't', is_premium: false, registered_at: NOW - 10 * DAY };
  assert.equal(isCampaignRecipient(device, NOW), true);
  assert.equal(isCampaignRecipient({ ...device, registered_at: NOW - 2 * DAY }, NOW), false);
  assert.equal(isCampaignRecipient({ ...device, is_premium: true }, NOW), false);
  assert.equal(isCampaignRecipient({ ...device, token: '' }, NOW), false);
  assert.equal(isCampaignRecipient({ ...device, registered_at: undefined }, NOW), true);
});

test('a regional M6.0+ in the last 24 hours silences the campaign; smaller or distant ones do not', () => {
  const quake = (magnitude, lat, lon, ageHours) => ({ magnitude, lat, lon, date: new Date(NOW - ageHours * 3600000).toISOString() });
  assert.equal(hasRecentMajorRegionalQuake([quake(6.0, 38.2, 38.9, 5)], NOW), true);
  assert.equal(hasRecentMajorRegionalQuake([quake(5.9, 38.2, 38.9, 5)], NOW), false);
  assert.equal(hasRecentMajorRegionalQuake([quake(7.1, 35.7, 139.7, 5)], NOW), false);
  assert.equal(hasRecentMajorRegionalQuake([quake(6.4, 38.2, 38.9, 25)], NOW), false);
});

function campaignDb(state, devices) {
  const store = { state: { ...state }, reads: 0, queries: 0 };
  const stateRef = {
    get: async () => { store.reads++; return { data: () => store.state }; },
    set: async value => { Object.assign(store.state, value); }
  };
  const query = cursor => ({
    where: () => query(cursor), orderBy: () => query(cursor), limit: () => query(cursor),
    startAfter: next => query(next),
    get: async () => {
      store.queries++;
      const start = cursor ? devices.findIndex(d => d.id === cursor) + 1 : 0;
      const docs = devices.slice(start, start + 500).map(d => ({ id: d.id, data: () => d.data }));
      return { empty: docs.length === 0, size: docs.length, docs };
    }
  });
  store.db = {
    collection: name => name === '_system' ? { doc: () => stateRef } : { ...query(''), doc: id => ({ id }) },
    runTransaction: async fn => fn({
      get: async () => { store.reads++; return { data: () => store.state }; },
      set: (_ref, value) => { Object.assign(store.state, value); }
    }),
    batch: () => ({ delete: () => {}, set: () => {}, commit: async () => {} })
  };
  return store;
}

test('a week inside the frequency limit costs one read and loads no quakes', async () => {
  const store = campaignDb({ last_started_at: NOW - 7 * DAY }, []);
  let quakeLoads = 0;
  await runPremiumEngagementCampaign(store.db, NOW, async () => { quakeLoads++; return []; });
  assert.equal(store.reads, 1);
  assert.equal(quakeLoads, 0);
  assert.equal(store.queries, 0);
});

test('a major regional quake postpones the campaign without spending the slot', async () => {
  const store = campaignDb({ last_started_at: NOW - 14 * DAY }, []);
  await runPremiumEngagementCampaign(store.db, NOW, async () => [
    { magnitude: 6.2, lat: 38.2, lon: 38.9, date: new Date(NOW - 3600000).toISOString() }
  ]);
  assert.equal(store.state.last_started_at, NOW - 14 * DAY);
  assert.equal(store.queries, 0);
});

test('the campaign reaches free devices in their language and skips new installs', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-campaign' });
  const sent = [];
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    batch.forEach(m => sent.push(m));
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  try {
    const store = campaignDb({ last_started_at: NOW - 14 * DAY }, [
      { id: 'es', data: { token: 'es', lang: 'es', app_version: '2.1.0', is_premium: false, registered_at: NOW - 30 * DAY } },
      { id: 'new', data: { token: 'new', lang: 'tr', app_version: '2.1.0', is_premium: false, registered_at: NOW - DAY } },
      { id: 'old', data: { token: 'old', lang: 'tr', app_version: '2.0.9', is_premium: false, registered_at: NOW - 30 * DAY } }
    ]);
    initPushRoutes(store.db);
    await runPremiumEngagementCampaign(store.db, NOW, async () => []);
    assert.deepEqual(sent.map(m => m.token), ['es', 'old']);
    assert.equal(sent[0].apns.payload.notificationKind, 'premium_offer');
    assert.ok(!/[ığüşöçİ]/.test(sent[0].notification.body), 'İspanyolca cihaza Türkçe metin gitmemeli');
    assert.equal(store.state.status, 'completed');
    assert.equal(store.state.sent, 2);
    assert.equal(store.state.last_started_at, NOW);
  } finally {
    await app.delete();
  }
});
