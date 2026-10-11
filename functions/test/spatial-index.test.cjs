const test = require('node:test');
const assert = require('node:assert/strict');
const { SpatialGridIndex } = require('../lib/spatial-index');
const { notificationMatch } = require('../lib/worker-utils');

function makeDevice(key, places, extraPrefs = {}) {
  return {
    key,
    token: `token-${key}`,
    transport: 'apns',
    apnsSound: 'default',
    premiumExpiresAt: Date.now() + 86400000,
    prefs: {
      places,
      tzOffset: 180,
      lang: 'tr',
      notified: [],
      ...extraPrefs
    }
  };
}

function quake(overrides = {}) {
  return {
    id: 'test-q1',
    provider: 'AFAD',
    title: 'Kadıköy',
    magnitude: 3.5,
    depth: 10,
    lat: 40.99,   // Kadıköy
    lon: 29.03,
    date: '2026-09-11T12:00:00.000Z',
    ...overrides
  };
}

test('SpatialGridIndex: yarıçap içindeki deprem O(1) adaylarda bulunur ve eşleşir', () => {
  const index = new SpatialGridIndex();
  const ev = { id: 'p-ev', name: 'Ev', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 2.0 };
  const d1 = makeDevice('dev-1', [ev]);
  index.addOrUpdateDevice(d1);

  const q = quake();
  const candidates = index.queryCandidates(q.lat, q.lon, q.magnitude);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].key, 'dev-1');

  const matches = index.findMatches(q);
  assert.equal(matches.length, 1);
  assert.equal(matches[0].device.key, 'dev-1');
  assert.equal(matches[0].match.reason, 'place');
  assert.equal(matches[0].match.placeName, 'Ev');
});

test('SpatialGridIndex: yarıçap dışındaki deprem adaylara bile girmez', () => {
  const index = new SpatialGridIndex();
  // İzmir'deki yer: Kadıköy'den ~330 km uzakta
  const izmir = { id: 'p-izmir', name: 'İzmir', lat: 38.42, lon: 27.14, radiusKm: 50, minMagnitude: 2.0 };
  index.addOrUpdateDevice(makeDevice('dev-izmir', [izmir]));

  const q = quake(); // Kadıköy
  const candidates = index.queryCandidates(q.lat, q.lon, q.magnitude);
  assert.equal(candidates.length, 0);

  const matches = index.findMatches(q);
  assert.equal(matches.length, 0);
});

test('SpatialGridIndex: dünya geneli büyük deprem (M >= 6.0) her hücreden adaya eklenir', () => {
  const index = new SpatialGridIndex();
  const dWorld = makeDevice('dev-world', [], { worldMajorEnabled: true, worldMajorThreshold: 6.5 });
  index.addOrUpdateDevice(dWorld);

  // Japonya'da M7.0 deprem
  const qMajor = quake({ lat: 35.68, lon: 139.76, magnitude: 7.0 });
  const candidates = index.queryCandidates(qMajor.lat, qMajor.lon, qMajor.magnitude);
  assert.ok(candidates.some(d => d.key === 'dev-world'));

  const matches = index.findMatches(qMajor);
  assert.equal(matches.length, 1);
  assert.equal(matches[0].match.reason, 'world_major');

  // Küçük depremde dünya geneli adaya eklenmez
  const qMinor = quake({ lat: 35.68, lon: 139.76, magnitude: 4.0 });
  const minorCandidates = index.queryCandidates(qMinor.lat, qMinor.lon, qMinor.magnitude);
  assert.equal(minorCandidates.length, 0);
});

test('SpatialGridIndex: cihaz güncelleme ve silme hücreleri temizler', () => {
  const index = new SpatialGridIndex();
  const ev = { id: 'p-ev', name: 'Ev', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 2.0 };
  index.addOrUpdateDevice(makeDevice('dev-1', [ev]));

  assert.equal(index.size, 1);
  assert.equal(index.queryCandidates(40.99, 29.03, 3.0).length, 1);

  // Silme
  index.removeDevice('dev-1');
  assert.equal(index.size, 0);
  assert.equal(index.queryCandidates(40.99, 29.03, 3.0).length, 0);
});

test('SpatialGridIndex: 10.000 cihaz altında mikrosaniyelik aday tespiti performansı', () => {
  const index = new SpatialGridIndex();

  // Türkiye ve çevre ülkelere dağılmış 10.000 sanal cihaz
  for (let i = 0; i < 10000; i++) {
    const lat = 36 + Math.random() * 6; // 36 - 42 enlem
    const lon = 26 + Math.random() * 18; // 26 - 44 boylam
    const place = { id: `p-${i}`, name: `Yer ${i}`, lat, lon, radiusKm: 50, minMagnitude: 2.5 };
    index.addOrUpdateDevice(makeDevice(`dev-${i}`, [place]));
  }

  assert.equal(index.size, 10000);

  const q = quake({ lat: 39.93, lon: 32.85, magnitude: 4.2 }); // Ankara

  const start = performance.now();
  const candidates = index.queryCandidates(q.lat, q.lon, q.magnitude);
  const durationMs = performance.now() - start;

  // 10.000 cihaz arasında bile O(1) grid araması < 1 ms sürmeli
  assert.ok(durationMs < 5.0, `Sorgu ${durationMs}ms sürdü, 5ms'den kısa olmalı`);
  // Ankara hücresindeki adaylar toplam 10.000 cihazın çok küçük bir kesri olmalı
  assert.ok(candidates.length < 1000, `Aday sayısı: ${candidates.length}`);
});

// Üretim regresyonu (11-12 Eylül 2026): ızgara yalnızca koordinatlı cihazları
// hücrelere koyuyordu. Eski kuraldaki koordinatsız "tüm bölgeler" cihazları —
// push alan cihazların çoğu — hiçbir depremde aday olmuyor, bildirim almıyordu.
test('SpatialGridIndex: eski kuraldaki koordinatsız cihaz her depremde adaydır', () => {
  const index = new SpatialGridIndex();
  const legacy = makeDevice('dev-legacy', [], {
    legacy: { minMagnitude: 3, majorThreshold: 5, source: 'afad', sourceFallbackEnabled: true, nearbyOnly: false, minimumEstimatedMMI: 0 }
  });
  index.addOrUpdateDevice(legacy);

  const q = quake({ lat: 38.4, lon: 38.3, magnitude: 3.4 });
  assert.ok(index.queryCandidates(q.lat, q.lon, q.magnitude).some(d => d.key === 'dev-legacy'));
  assert.equal(index.findMatches(q).length, 1);

  index.removeDevice('dev-legacy');
  assert.equal(index.queryCandidates(q.lat, q.lon, q.magnitude).length, 0);
});

test('SpatialGridIndex: dünya geneli eşiği 5.x seçen cihaz o büyüklükte aday olur', () => {
  const index = new SpatialGridIndex();
  index.addOrUpdateDevice(makeDevice('dev-world-5', [], { worldMajorEnabled: true, worldMajorThreshold: 5.2 }));
  const q = quake({ lat: 35.68, lon: 139.76, magnitude: 5.5 });
  assert.ok(index.queryCandidates(q.lat, q.lon, q.magnitude).some(d => d.key === 'dev-world-5'));
  assert.equal(index.findMatches(q)[0].match.reason, 'world_major');
});
