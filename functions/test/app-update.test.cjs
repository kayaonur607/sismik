const test = require('node:test');
const assert = require('node:assert/strict');
const { createHmac } = require('node:crypto');
const admin = require('firebase-admin');
const { isVersionOlder } = require('../lib/worker-utils');
const {
  needsAppUpdateNotice,
  appUpdateMessage,
  isValidAscSignature,
  registerAppUpdateRoutes,
  runAppReleaseRule,
  APP_RELEASE_RULE_ID
} = require('../lib/app-update');
const { initPushRoutes } = require('../lib/push-routes');
const { registerEarthquakeRoutes, latestAppVersion, BASELINE_APP_VERSION } = require('../lib/earthquake-routes');
const { registerConfigRoute } = require('../lib/admin-routes');

// Belge deposu: `koleksiyon/kimlik` → veri. Sayılan şey okuma ve yazımlar.
function memoryDb(devices = []) {
  const docs = new Map();
  const stats = { reads: 0, writes: [], deleted: [] };
  const merge = (key, value, options) => {
    const previous = docs.get(key) || {};
    const next = options?.merge || options?.mergeFields ? { ...previous, ...value } : { ...value };
    for (const [field, fieldValue] of Object.entries(next)) {
      if (fieldValue && fieldValue.constructor?.name === 'DeleteTransform') delete next[field];
    }
    docs.set(key, next);
  };
  const docRef = (collection, id) => ({
    id,
    get: async () => { stats.reads++; const data = docs.get(`${collection}/${id}`); return { exists: Boolean(data), data: () => data }; },
    set: async (value, options) => { stats.writes.push({ key: `${collection}/${id}`, value, options }); merge(`${collection}/${id}`, value, options); }
  });
  const deviceQuery = cursor => ({
    where: () => deviceQuery(cursor),
    orderBy: () => deviceQuery(cursor),
    limit: () => deviceQuery(cursor),
    startAfter: next => deviceQuery(next),
    get: async () => {
      const start = cursor ? devices.findIndex(device => device.id === cursor) + 1 : 0;
      const page = devices.slice(start, start + 500).map(device => ({ id: device.id, data: () => device.data }));
      stats.reads += Math.max(1, page.length);
      return { empty: page.length === 0, size: page.length, docs: page };
    }
  });
  const db = {
    collection: name => name === 'devices'
      ? { ...deviceQuery(''), doc: id => ({ id }) }
      : { doc: id => docRef(name, id) },
    runTransaction: async fn => fn({
      get: async ref => ref.get(),
      set: (ref, value, options) => { merge(`_system/${ref.id}`, value, options); }
    }),
    batch: () => ({ delete: ref => stats.deleted.push(ref.id), set: () => {}, commit: async () => {} })
  };
  return { db, docs, stats };
}

function mockMessaging(t) {
  const sent = [];
  t.mock.method(admin.messaging(), 'sendEach', async batch => {
    batch.forEach(message => sent.push(message));
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  return sent;
}

test('version comparison matches the client update gate', () => {
  assert.equal(isVersionOlder('2.0.9', '2.1.0'), true);
  assert.equal(isVersionOlder('1.0.8', '2.1.0'), true);
  assert.equal(isVersionOlder('2.1', '2.1.0'), false);
  assert.equal(isVersionOlder('2.1.0', '2.1.0'), false);
  assert.equal(isVersionOlder('2.1.1', '2.1.0'), false);
  assert.equal(isVersionOlder('2.0.10', '2.0.9'), false);
});

test('only reachable devices on an older version need the notice', () => {
  const device = { transport: 'fcm', token: 't', app_version: '2.0.9' };
  assert.equal(needsAppUpdateNotice(device, '2.1.0'), true);
  assert.equal(needsAppUpdateNotice({ ...device, app_version: '2.1.0' }, '2.1.0'), false);
  assert.equal(needsAppUpdateNotice({ ...device, app_version: '' }, '2.1.0'), false);
  assert.equal(needsAppUpdateNotice({ ...device, transport: 'apns' }, '2.1.0'), false);
  assert.equal(needsAppUpdateNotice({ ...device, token: '' }, '2.1.0'), false);
});

test('release copy is version specific when written, generic otherwise, in the device language', () => {
  const tr210 = appUpdateMessage('t', 'tr', 0, '2.1.0');
  assert.match(tr210.notification.body, /konum bazlı/);
  const tr211 = appUpdateMessage('t', 'tr', 0, '2.1.1');
  assert.equal(tr211.notification.title, '🚀 Sismik 2.1.1 yayında');
  assert.match(tr211.notification.body, /^✨ .+ 📲 App Store'dan hemen güncelle\.$/);
  assert.match(appUpdateMessage('t', 'es', 0, '2.1.1').notification.title, /2\.1\.1/);
  // Genel şablon her dilde emojili: başlık 🚀, gövde ✨ … 📲.
  for (const lang of ['tr', 'en', 'de', 'es', 'fr', 'it', 'ja', 'ru', 'ar']) {
    const { title, body } = appUpdateMessage('t', lang, 0, '2.1.2').notification;
    assert.match(title, /^🚀 /, lang);
    assert.match(title, /2\.1\.2/, lang);
    assert.match(body, /^✨ /, lang);
    assert.match(body, /📲/, lang);
  }
  assert.match(appUpdateMessage('t', 'xx', 0, '2.1.1').notification.title, /is out/);
  // Eski istemci bilinmeyen türü deprem detayı sanıyor; admin_manual güvenli.
  assert.equal(tr211.apns.payload.notificationKind, 'admin_manual');
  assert.equal(tr211.apns.headers['apns-collapse-id'], 'app-update-2.1.1');
});

test('App Store Connect signature follows the documented HMAC-SHA256 example', () => {
  const body = Buffer.from('Hello, World!');
  const header = 'hmacsha256=7f062172b01cb00b53ca068614674a3d982a34062a0f5d37687d5e3377e54657';
  assert.equal(isValidAscSignature(body, header, 'This is my secret'), true);
  assert.equal(isValidAscSignature(body, header, 'wrong secret'), false);
  assert.equal(isValidAscSignature(Buffer.from('Hello, World?'), header, 'This is my secret'), false);
  assert.equal(isValidAscSignature(undefined, header, 'This is my secret'), false);
  assert.equal(isValidAscSignature(body, '7f06', 'This is my secret'), false);
});

function webhookHandler(db) {
  const routes = new Map();
  registerAppUpdateRoutes({ post: (path, fn) => routes.set(path, fn) }, db);
  return routes.get('/app-store-connect/webhook');
}

function signedRequest(payload, secret) {
  const rawBody = Buffer.from(JSON.stringify(payload));
  const signature = createHmac('sha256', secret).update(rawBody).digest('hex');
  return { rawBody, body: payload, headers: { 'x-apple-signature': `hmacsha256=${signature}` } };
}

function response() {
  return { code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; } };
}

test('webhook opens the release rule only for a verified READY_FOR_DISTRIBUTION event', async () => {
  process.env.ASC_WEBHOOK_SECRET = 'asc-secret';
  const { db, docs } = memoryDb();
  registerEarthquakeRoutes({ get: () => {} }, db);
  const handle = webhookHandler(db);
  const event = state => ({
    data: {
      type: 'appStoreVersionAppVersionStateUpdated',
      attributes: { newValue: state, oldValue: 'PENDING_DEVELOPER_RELEASE' },
      relationships: { instance: { data: { type: 'appStoreVersions', id: 'asv-1' } } }
    }
  });

  const forged = response();
  await handle({ ...signedRequest(event('READY_FOR_DISTRIBUTION'), 'other'), }, forged);
  assert.equal(forged.code, 401);
  assert.equal(docs.has(`automations/${APP_RELEASE_RULE_ID}`), false);

  const review = response();
  await handle(signedRequest(event('IN_REVIEW'), 'asc-secret'), review);
  assert.equal(review.body.ignored, true);
  assert.equal(docs.has(`automations/${APP_RELEASE_RULE_ID}`), false);

  const ready = response();
  await handle(signedRequest(event('READY_FOR_DISTRIBUTION'), 'asc-secret'), ready);
  assert.equal(ready.code, 200);
  const rule = docs.get(`automations/${APP_RELEASE_RULE_ID}`);
  assert.equal(rule.trigger, 'app_release');
  assert.equal(rule.enabled, true);
  assert.equal(rule.newer_than, BASELINE_APP_VERSION);
  assert.equal(rule.app_store_version_id, 'asv-1');
  delete process.env.ASC_WEBHOOK_SECRET;
});

test('release rule waits for the store, then publishes the banner version and announces once', async t => {
  const app = admin.initializeApp({ projectId: 'unit-test-app-release' });
  const sent = mockMessaging(t);
  try {
    const { db, docs } = memoryDb([
      { id: 'a', data: { transport: 'fcm', token: 'on-210', app_version: '2.1.0', lang: 'tr' } },
      { id: 'b', data: { transport: 'fcm', token: 'on-209', app_version: '2.0.9', lang: 'es' } },
      { id: 'c', data: { transport: 'fcm', token: 'on-211', app_version: '2.1.1', lang: 'tr' } }
    ]);
    registerEarthquakeRoutes({ get: () => {} }, db);
    initPushRoutes(db);
    const now = Date.now();
    const ruleRef = db.collection('automations').doc(APP_RELEASE_RULE_ID);
    const rule = { trigger: 'app_release', enabled: true, newer_than: '2.1.0', requested_at: now };
    docs.set(`automations/${APP_RELEASE_RULE_ID}`, rule);

    // Mağaza henüz eski sürümü gösteriyor: hiçbir şey yapılmaz.
    await runAppReleaseRule(db, ruleRef, rule, now, async () => '2.1.0');
    assert.equal(sent.length, 0);
    assert.equal(docs.get(`automations/${APP_RELEASE_RULE_ID}`).enabled, true);
    assert.equal(latestAppVersion(), BASELINE_APP_VERSION);

    await runAppReleaseRule(db, ruleRef, rule, now + 900000, async () => '2.1.1');
    assert.deepEqual(sent.map(m => m.token), ['on-210', 'on-209']);
    assert.equal(sent[0].notification.title, '🚀 Sismik 2.1.1 yayında');
    assert.equal(docs.get('_public/live_quakes_v1').latest_app_version, '2.1.1');
    assert.equal(latestAppVersion(), '2.1.1');
    const closed = docs.get(`automations/${APP_RELEASE_RULE_ID}`);
    assert.equal(closed.enabled, false);
    assert.equal(closed.status, 'completed');
    assert.equal(docs.get('_system/app_update_v1').announced_version, '2.1.1');
  } finally {
    await app.delete();
  }
});

test('release rule gives up when the store never shows the version', async () => {
  const { db, docs } = memoryDb();
  const now = Date.now();
  const ruleRef = db.collection('automations').doc(APP_RELEASE_RULE_ID);
  const rule = { trigger: 'app_release', enabled: true, newer_than: '2.1.0', requested_at: now - 73 * 3600000 };
  await runAppReleaseRule(db, ruleRef, rule, now, async () => null);
  assert.equal(docs.get(`automations/${APP_RELEASE_RULE_ID}`).status, 'timeout');
  assert.equal(docs.get(`automations/${APP_RELEASE_RULE_ID}`).enabled, false);
});

test('/config and the live list serve the published version without extra reads', async () => {
  const { db, docs, stats } = memoryDb();
  const routes = new Map();
  const app = { get: (path, fn) => routes.set(path, fn), use: () => {}, post: () => {}, delete: () => {} };
  registerEarthquakeRoutes(app, db);
  registerConfigRoute(app);
  const { gzipSync } = require('node:zlib');
  const quake = { id: 'a', provider: 'AFAD', title: 'X', magnitude: 3, depth: 7, lat: 38, lon: 27, date: new Date().toISOString() };
  docs.set('_public/live_quakes_v1', {
    latest_app_version: '2.2.0',
    updated_at: Date.now(),
    payload: gzipSync(Buffer.from(JSON.stringify([quake])))
  });

  const config = { headers: {}, setHeader(k, v) { this.headers[k] = v; }, json(b) { this.body = b; } };
  await routes.get('/config')({}, config);
  assert.equal(config.body.minVersion, '1.0.0');
  assert.equal(config.body.latestVersion, '2.2.0');
  assert.match(config.body.storeURL, /id6787776158/);
  const readsAfterConfig = stats.reads;
  await routes.get('/config')({}, config);
  assert.equal(stats.reads, readsAfterConfig, 'anlık görüntü 15 sn bellekten gelmeli');
});

test('the minute snapshot publish keeps the published app version field', async () => {
  const { db, docs } = memoryDb();
  const { publishLiveSnapshot } = require('../lib/earthquake-routes');
  registerEarthquakeRoutes({ get: () => {} }, db);
  docs.set('_public/live_quakes_v1', { latest_app_version: '2.3.0' });
  await publishLiveSnapshot([{ id: 'keep', provider: 'AFAD', magnitude: 3, lat: 38, lon: 27, date: new Date().toISOString() }]);
  const doc = docs.get('_public/live_quakes_v1');
  assert.equal(doc.latest_app_version, '2.3.0');
  assert.ok(doc.payload);
});
