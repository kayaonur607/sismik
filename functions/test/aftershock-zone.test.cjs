const test = require('node:test');
const assert = require('node:assert/strict');
const { aftershockZoneRadiusKm, selectAftershockSequence, dedupeAgencyCopies, authorityRank } = require('../lib/worker-utils');

test('aftershock zone grows with magnitude', () => {
  assert.equal(aftershockZoneRadiusKm(4.0), 30);
  assert.equal(aftershockZoneRadiusKm(5.8), 50);
  assert.equal(aftershockZoneRadiusKm(7.0), 71);
  assert.equal(aftershockZoneRadiusKm(7.8), 145);
});

// 24 Eylül 2026 Şanlıurfa M5.8: uygulama 150 km istiyordu; Adıyaman'daki
// 2023 dizisinin depremleri de artçı sayılıyordu.
test('Şanlıurfa M5.8: only the rupture area counts, agency copies of the mainshock do not', () => {
  const start = Date.parse('2026-09-24T07:40:58Z');
  const at = (seconds) => new Date(start + seconds * 1000).toISOString();
  const mainshock = { id: 'afad-main', provider: 'AFAD', magnitude: 5.8, depth: 7, lat: 37.47, lon: 38.86, date: at(0) };
  const quakes = [
    mainshock,
    { id: 'emsc-main', provider: 'EMSC', magnitude: 5.1, depth: 10, lat: 37.50, lon: 38.90, date: at(1) },
    { id: 'afad-a1', provider: 'AFAD', magnitude: 3.2, depth: 6, lat: 37.55, lon: 38.95, date: at(600) },
    { id: 'afad-a2', provider: 'AFAD', magnitude: 2.4, depth: 8, lat: 37.30, lon: 38.70, date: at(3600) },
    // Adıyaman merkez (~100 km): 2023 dizisi, bu depremin artçısı değil.
    { id: 'afad-adiyaman', provider: 'AFAD', magnitude: 2.8, depth: 9, lat: 37.76, lon: 38.28, date: at(1800) }
  ];
  const result = selectAftershockSequence(quakes, { lat: 37.47, lon: 38.86, start, requestedRadiusKm: 150 });
  assert.equal(result.magnitude, 5.8);
  assert.equal(result.radiusKm, 50);
  assert.deepEqual(result.quakes.map(q => q.id), ['afad-main', 'afad-a1', 'afad-a2']);
});

test('without the mainshock in the catalog the legacy radius sets the magnitude; never wider than requested', () => {
  const start = Date.parse('2026-09-24T07:40:58Z');
  const result = selectAftershockSequence([], { lat: 37.47, lon: 38.86, start, requestedRadiusKm: 250 });
  assert.equal(result.magnitude, 6.5);
  assert.equal(result.radiusKm, aftershockZoneRadiusKm(6.5));
  assert.equal(selectAftershockSequence([], { lat: 0, lon: 0, start, requestedRadiusKm: 20 }).radiusKm, 20);
});

test('ajans kopyaları tek sayılır, yakın ama ayrı artçılar korunur', () => {
  const t0 = Date.parse('2026-09-24T08:00:00Z');
  const at = (s) => new Date(t0 + s * 1000).toISOString();
  const q = (id, provider, s, lat, lon, magnitude) => ({ id, provider, title: '', magnitude, depth: 7, lat, lon, date: at(s) });
  const kept = dedupeAgencyCopies([
    q('kandilli-1', 'KANDILLI', 0, 37.60, 38.80, 3.4),
    q('afad-1', 'AFAD', 3, 37.40, 38.95, 3.2),          // aynı artçı: 3 sn, ~26 km
    q('emsc-1', 'EMSC', 2, 37.45, 38.90, 3.3),          // aynı artçı
    q('afad-2', 'AFAD', 40, 37.52, 38.70, 2.6),         // 40 sn sonra ~25 km ötede: AYRI artçı
    q('afad-3', 'AFAD', 50, 37.50, 38.80, 2.1)          // 50 sn sonra ~3 km ötede ama AFAD'ın kendi ayrı kaydı
  ]);
  const ids = kept.map(x => x.id).sort();
  assert.ok(ids.includes('afad-1'), 'resmî ajans kaydı kalır');
  assert.ok(!ids.includes('kandilli-1') && !ids.includes('emsc-1'));
  assert.ok(ids.includes('afad-2'));
  assert.ok(ids.includes('afad-3'), 'aynı ajansın ayrı kaydı kopya sayılmaz');
  assert.equal(authorityRank({ provider: 'KANDILLI', lat: 37.5, lon: 38.8 }), 1);
  assert.equal(authorityRank({ provider: 'AFAD', lat: 37.5, lon: 38.8 }), 0);
});
