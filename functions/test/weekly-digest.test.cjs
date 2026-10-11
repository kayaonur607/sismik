const test = require('node:test');
const assert = require('node:assert/strict');
const { summarizeWeek, buildDigestText, isoWeekKey } = require('../lib/weekly-digest');

const home = { id: 'h', name: 'Ev', icon: 'home', lat: 41.0, lon: 29.0, radiusKm: 30, minMagnitude: 2 };
const family = { id: 'f', name: 'Annemler', icon: 'family', lat: 38.4, lon: 27.1, radiusKm: 100, minMagnitude: 3 };
const quake = (id, magnitude, lat, lon) => ({ id, provider: 'AFAD', title: 'Test (İzmir)', magnitude, depth: 7, lat, lon, date: new Date().toISOString() });

test('haftalık özet: yarıçaptaki depremleri sayar, en büyüğü en yakın yerle eşler', () => {
  const quakes = [
    quake('a', 2.4, 41.1, 29.1),   // Ev'e ~14 km
    quake('b', 3.8, 38.5, 27.2),   // Annemler'e ~14 km
    quake('c', 1.8, 41.0, 29.0),   // eşik altı
    quake('d', 4.5, 36.0, 36.0)    // hiçbir yerin yakınında değil
  ];
  const summary = summarizeWeek(quakes, [home, family]);
  assert.equal(summary.count, 2);
  assert.equal(summary.largest.quake.id, 'b');
  assert.equal(summary.largest.placeName, 'Annemler');
  // Küçük yarıçap en az 50 km sayılır: Ev'e 40 km'deki deprem de girer.
  assert.equal(summarizeWeek([quake('e', 2.5, 41.36, 29.0)], [home]).count, 1);
});

test('haftalık özet metni: boş hafta ve dolu hafta, bilinmeyen dil İngilizceye düşer', () => {
  assert.match(buildDigestText('tr', { count: 0 }).body, /olmadı/);
  const text = buildDigestText('tr', summarizeWeek([quake('b', 3.8, 38.5, 27.2)], [family]));
  assert.match(text.body, /1 deprem/);
  assert.match(text.body, /M3\.8/);
  assert.match(text.body, /Annemler/);
  assert.equal(buildDigestText('xx', { count: 0 }).title, 'Weekly earthquake summary');
});

test('ISO hafta anahtarı', () => {
  assert.equal(isoWeekKey(Date.parse('2026-09-21T06:05:00Z')), '2026-W39');
  assert.equal(isoWeekKey(Date.parse('2027-01-01T12:00:00Z')), '2026-W53');
});

test('haftalık özet: hafta gönderimden önce sahiplenilir, ikinci koşu göndermez', async () => {
  const { runWeeklyDigest } = require('../lib/weekly-digest');
  const now = Date.parse('2026-09-21T06:05:00Z');
  const state = new Map();
  const device = {
    id: 'dev1',
    data: () => ({
      is_premium: true, transport: 'fcm', token: 'tok', lang: 'tr',
      weekly_digest_enabled: true, places: [home]
    })
  };
  const stateRef = {
    get: async () => ({ data: () => state.get('digest') }),
    set: async value => { state.set('digest', { ...(state.get('digest') || {}), ...value }); }
  };
  const db = {
    collection: name => name === '_system'
      ? { doc: () => stateRef }
      : { where: () => ({ get: async () => ({ docs: [device] }) }) },
    runTransaction: async fn => fn({
      get: ref => ref.get(),
      set: (ref, value) => { state.set('digest', { ...(state.get('digest') || {}), ...value }); }
    })
  };
  let sends = 0;
  let statusDuringSend;
  const send = async messages => {
    sends += 1;
    statusDuringSend = state.get('digest')?.status;
    return { successCount: messages.length, failureCount: 0 };
  };

  await runWeeklyDigest(db, async () => [], send, now);
  await runWeeklyDigest(db, async () => [], send, now);
  assert.equal(sends, 1);
  assert.equal(statusDuringSend, 'sending', 'kilit gönderimden önce yazılmalı');
  assert.equal(state.get('digest').status, 'completed');
  assert.equal(state.get('digest').last_week, isoWeekKey(now));
});
