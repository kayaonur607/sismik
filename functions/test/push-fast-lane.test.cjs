const test = require('node:test');
const assert = require('node:assert/strict');
const {
  isTurkeyFastLaneQuake,
  matches,
  notificationMatch,
  selectFreshQuakes,
  selectFastestQuakes,
  toQuakeFingerprint
} = require('../lib/worker-utils');

function quake(overrides = {}) {
  return {
    id: 'afad-1',
    provider: 'AFAD',
    title: 'Test',
    magnitude: 4.2,
    depth: 8,
    lat: 39,
    lon: 35,
    date: '2026-07-15T12:00:00.000Z',
    ...overrides
  };
}

const prefs = {
  places: [{ id: 'p1', name: 'Merkez', lat: 39, lon: 35, radiusKm: 200, minMagnitude: 3 }],
  tzOffset: 180,
  lang: 'tr',
  notified: []
};

test('push freshness excludes delayed events so they cannot arrive as a batch', () => {
  const now = Date.parse('2026-07-15T12:10:00.000Z');
  const fresh = quake({ id: 'fresh', date: '2026-07-15T12:08:30.000Z' });
  const delayed = quake({ id: 'delayed', date: '2026-07-15T12:04:59.000Z' });

  assert.deepEqual(selectFreshQuakes([delayed, fresh], now).map(item => item.id), ['fresh']);
});

test('same physical Turkey quake from a second provider is suppressed', () => {
  const afad = quake();
  const emsc = quake({
    id: 'emsc-1',
    provider: 'EMSC',
    magnitude: 4.4,
    lat: 39.1,
    lon: 35.1,
    date: '2026-07-15T12:00:20.000Z'
  });

  const result = selectFastestQuakes([emsc], [toQuakeFingerprint(afad)]);
  assert.deepEqual(result.selected, []);
  assert.deepEqual(result.suppressed.map(item => item.id), ['emsc-1']);
});

test('push delivery keeps the original narrow dedup radius even though Twitter dedup was widened to 100km/120s', () => {
  // ~80km uzakta, aynı sağlayıcı değil ama X'in gevşetilmiş 100km/120s
  // eşiğinin İÇİNDE, push'un 50km/60s eşiğinin ise DIŞINDA — bu, farklı,
  // gerçek bir fiziksel deprem olarak değerlendirilip bildirime GİTMELİ.
  const afad = quake();
  const distinctEmsc = quake({
    id: 'emsc-distinct',
    provider: 'EMSC',
    magnitude: 4.3,
    lat: 39.72,
    lon: 35,
    date: '2026-07-15T12:00:20.000Z'
  });

  const result = selectFastestQuakes([distinctEmsc], [toQuakeFingerprint(afad)]);
  assert.deepEqual(result.selected.map(item => item.id), ['emsc-distinct']);
  assert.deepEqual(result.suppressed, []);
});

test('nearby aftershocks from the same provider are never cross-source suppressed', () => {
  const first = quake();
  const aftershock = quake({ id: 'afad-2', date: '2026-07-15T12:00:30.000Z' });

  const result = selectFastestQuakes([aftershock], [toQuakeFingerprint(first)]);
  assert.deepEqual(result.selected.map(item => item.id), ['afad-2']);
  assert.deepEqual(result.suppressed, []);
});

test('active aftershock watch matches independently of the normal source filter', () => {
  const aftershock = quake({ id: 'emsc-aftershock', provider: 'EMSC', magnitude: 3.1, lat: 39.2, lon: 35.1 });
  const now = Date.parse('2026-07-15T12:01:00.000Z');
  const match = notificationMatch(aftershock, {
    ...prefs,
    aftershockWatch: {
      mainshockId: 'afad-main',
      title: 'Test Ana Depremi',
      magnitude: 5.8,
      latitude: 39,
      longitude: 35,
      startedAt: Date.parse('2026-07-15T11:00:00.000Z'),
      expiresAt: Date.parse('2026-07-16T11:00:00.000Z'),
      radiusKm: 150,
      minimumMagnitude: 2.5
    }
  }, now);

  assert.equal(match?.reason, 'aftershock');
  assert.equal(match?.watchTitle, 'Test Ana Depremi');
});


/// Çapraz sağlayıcı tekilleştirmesi artık Türkiye kutusuyla sınırlı değil.
/// Kaynak filtresi kalkınca kutu dışındaki kopyalar da elenmeli: Tokyo'da
/// kayıtlı yeri olan kullanıcı aynı depremi USGS ve EMSC'den iki kez almasın.
test('hızlı şerit DIŞINDAKİ çapraz sağlayıcı kopyası da bastırılır', () => {
  const usgs = quake({ id: 'usgs-jp', provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 5.1 });
  const emsc = quake({
    id: 'emsc-jp', provider: 'EMSC', lat: 35.65, lon: 139.75, magnitude: 5.2,
    date: '2026-07-15T12:00:20.000Z'
  });

  assert.equal(isTurkeyFastLaneQuake(usgs), false);
  const result = selectFastestQuakes([emsc], [toQuakeFingerprint(usgs)]);
  assert.deepEqual(result.selected, []);
  assert.deepEqual(result.suppressed.map(item => item.id), ['emsc-jp']);
});

test('kutu dışında da aynı sağlayıcının art arda artçıları bastırılmaz', () => {
  const first = quake({ id: 'usgs-jp-1', provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 5.1 });
  const aftershock = quake({
    id: 'usgs-jp-2', provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 4.4,
    date: '2026-07-15T12:00:30.000Z'
  });

  const result = selectFastestQuakes([aftershock], [toQuakeFingerprint(first)]);
  assert.deepEqual(result.selected.map(item => item.id), ['usgs-jp-2']);
});
