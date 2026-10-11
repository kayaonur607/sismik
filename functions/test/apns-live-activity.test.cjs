const test = require('node:test');
const assert = require('node:assert/strict');
const { toApnsPayload, tsunamiRecipients, buildTsunamiMessage } = require('../lib/push-routes');
const { attachApnsTarget, apnsTargetOf, withApnsTarget } = require('../lib/apns');
const { liveActivityState, aftershockForecast } = require('../lib/live-activity');
const { quakesForVariant } = require('../lib/earthquake-routes');

test('APNs yükü FCM ile aynı: notification → aps.alert, data → kök anahtarlar', () => {
  const payload = toApnsPayload({
    token: 'fcm',
    notification: { title: 'Başlık', body: 'Gövde' },
    apns: { payload: { aps: { sound: 'default' }, notificationKind: 'premium_offer' } },
    data: { type: 'automation', ruleId: 'r1' }
  });
  assert.deepEqual(payload.aps, { sound: 'default', alert: { title: 'Başlık', body: 'Gövde' } });
  assert.equal(payload.type, 'automation');
  assert.equal(payload.notificationKind, 'premium_offer');
  // Mesajın kendi alert'i korunur.
  const own = toApnsPayload({ token: 'x', notification: { title: 'a' }, apns: { payload: { aps: { alert: { title: 'b' } } } } });
  assert.deepEqual(own.aps.alert, { title: 'b' });
});

test('APNs hedefi yalnızca geçerli token için eklenir; ortam korunur', () => {
  const token = 'a'.repeat(64);
  const message = attachApnsTarget({ token: 'fcm' }, token.toUpperCase(), 'sandbox');
  assert.deepEqual(apnsTargetOf(message), { token, environment: 'sandbox' });
  assert.equal(apnsTargetOf(attachApnsTarget({ token: 'fcm' }, 'kısa', 'prod')), undefined);
  assert.deepEqual(apnsTargetOf(withApnsTarget({ token: 'fcm' }, { apns_token: token })), { token, environment: 'prod' });
  assert.equal(apnsTargetOf(withApnsTarget({ token: 'fcm' }, { token: 'fcm' })), undefined);
});

const device = (key, places, extra = {}) => ({
  key, token: `fcm-${key}`, premium: false, premiumExpiresAt: 0,
  prefs: { places, tzOffset: 180, lang: 'tr', notified: [], ...extra }
});

test('Tsunami: yarıçaptaki yeri olan cihaza gider; kritik izin varsa kritik ses', () => {
  const alert = { id: 'tsunami-x-warning', agency: 'PTWC', level: 'warning', region: 'Tonga', lat: -20, lon: -175, magnitude: 8, issuedAt: Date.now() };
  const near = device('near', [{ id: 'p', name: 'Ev', icon: 'house', lat: -21, lon: -175.2, radiusKm: 50, minMagnitude: 4 }], { criticalAlertsEnabled: true });
  const far = device('far', [{ id: 'p', name: 'Ev', icon: 'house', lat: 41, lon: 29, radiusKm: 50, minMagnitude: 4 }]);
  const legacy = device('legacy', [], { legacy: { minMagnitude: 4, majorThreshold: 5, source: 'afad', sourceFallbackEnabled: true, nearbyOnly: true, latitude: -19.5, longitude: -174.8, minimumEstimatedMMI: 0 } });
  const recipients = tsunamiRecipients([near, far, legacy], alert).map(item => item.device.key);
  assert.deepEqual(recipients, ['near', 'legacy']);
  const message = buildTsunamiMessage(near, alert, Date.now());
  assert.equal(message.apns.payload.aps['interruption-level'], 'critical');
  assert.equal(message.apns.payload.notificationKind, 'admin_manual');
  assert.equal(message.apns.payload.tsunami.level, 'warning');
  assert.equal(buildTsunamiMessage(legacy, alert, Date.now()).apns.payload.aps['interruption-level'], 'time-sensitive');
});

test('Canlı Etkinlik: artçılar alanda, ajans kopyaları bir kez sayılır', () => {
  const start = Date.parse('2026-09-24T07:40:58Z');
  const at = s => new Date(start + s * 1000).toISOString();
  const event = { id: 'afad-main', magnitude: 5.8, lat: 37.47, lon: 38.86, date: at(0), expires_at: start + 86400_000 };
  const quakes = [
    { id: 'emsc-main', provider: 'EMSC', magnitude: 5.6, depth: 10, lat: 37.5, lon: 38.9, date: at(2), title: '' },
    { id: 'afad-a1', provider: 'AFAD', magnitude: 3.2, depth: 6, lat: 37.55, lon: 38.95, date: at(600), title: '' },
    { id: 'kandilli-a1', provider: 'KANDILLI', magnitude: 3.4, depth: 6, lat: 37.56, lon: 38.94, date: at(601), title: '' },
    { id: 'afad-a2', provider: 'AFAD', magnitude: 2.4, depth: 8, lat: 37.3, lon: 38.7, date: at(3600), title: '' },
    { id: 'afad-far', provider: 'AFAD', magnitude: 2.8, depth: 9, lat: 37.76, lon: 38.28, date: at(1800), title: '' }
  ];
  quakes[3].title = 'SOGUTLU-HILVAN (SANLIURFA)';
  const state = liveActivityState(event, quakes, start + 4000_000);
  assert.equal(state.aftershockCount, 2);
  // Aynı artçının Kandilli (3.4) ve AFAD (3.2) kaydı: Türkiye'de AFAD kalır.
  assert.equal(state.maxAftershockMagnitude, 3.2);
  assert.equal(state.lastMagnitude, 2.4);
  assert.equal(state.lastTitle, 'Sogutlu-Hilvan (Sanliurfa)');
  // Swift Date: 2001-01-01'den saniye.
  assert.equal(state.lastDate, Math.round((start + 3600_000) / 1000 - 978307200));
  assert.equal(state.forecastMagnitude, 4);
  assert.ok(state.forecastProbability > 0 && state.forecastProbability < 1);
});

test('Liste görünümü: eski istemciye yalnızca dört kaynak', () => {
  const list = [
    { id: 'afad-1', provider: 'AFAD' }, { id: 'kandilli-1', provider: 'KANDILLI' }, { id: 'jma-1', provider: 'JMA' }, { id: 'usgs-1', provider: 'USGS' }
  ];
  assert.deepEqual(quakesForVariant(list, 'legacy').map(q => q.id), ['afad-1', 'usgs-1']);
  assert.equal(quakesForVariant(list, 'all'), list);
  assert.equal(quakesForVariant(list, 'legacy'), quakesForVariant(list, 'legacy'), 'aynı liste için bir kez hesaplanır');
});

test('APNs JWT: ES256 imzası doğrulanır, 50 dk önbellekte kalır', () => {
  const { generateKeyPairSync, createVerify } = require('node:crypto');
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  process.env.APNS_AUTH_KEY = privateKey.export({ type: 'pkcs8', format: 'pem' });
  process.env.APNS_KEY_ID = 'ABC123DEFG';
  process.env.APNS_TEAM_ID = 'Z6ANLC75YG';
  const apns = require('../lib/apns');
  apns.resetApnsForTesting();
  assert.equal(apns.apnsConfigured(), true);
  const now = Date.now();
  const token = apns.apnsJwt(now);
  const [header, claims, signature] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iss, 'Z6ANLC75YG');
  const verifier = createVerify('SHA256');
  verifier.update(`${header}.${claims}`);
  assert.equal(verifier.verify({ key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
  assert.equal(apns.apnsJwt(now + 49 * 60_000), token);
  assert.notEqual(apns.apnsJwt(now + 51 * 60_000), token);
  delete process.env.APNS_AUTH_KEY; delete process.env.APNS_KEY_ID; delete process.env.APNS_TEAM_ID;
  apns.resetApnsForTesting();
  assert.equal(apns.apnsConfigured(), false);
});

test('Artçı olasılığı uygulamadaki modelle aynı', () => {
  // Swift AftershockForecast ile aynı kapalı form: M6.3, 1 saat sonra, M5+.
  const { probability, magnitude } = aftershockForecast(6.3, 3600_000);
  assert.equal(magnitude, 5);
  const start = 1 / 24, end = start + 1;
  const expected = Math.pow(10, -1.67 + 0.91 * 1.3) * (Math.pow(start + 0.05, -0.08) - Math.pow(end + 0.05, -0.08)) / 0.08;
  assert.equal(probability, Math.round((1 - Math.exp(-expected)) * 1000) / 1000);
});
