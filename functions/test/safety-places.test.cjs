const test = require('node:test');
const assert = require('node:assert/strict');
const { gzipSync } = require('node:zlib');
const {
  safetyCellKey, safetyCellsAround, parseOverpassElements, nearestSafetyPlaces, loadSafetyCells
} = require('../lib/safety-places');

test('hücre anahtarı ve çevre hücreleri', () => {
  assert.equal(safetyCellKey(41.0082, 28.9784), '410_289');
  assert.equal(safetyCellKey(-33.45, -70.66), '-335_-707');
  const cells = safetyCellsAround(41.0082, 28.9784, 12_000);
  assert.ok(cells.includes('410_289'));
  assert.ok(cells.length >= 4 && cells.length <= 12, `${cells.length} hücre`);
  assert.deepEqual(safetyCellsAround(41.05, 28.95, 1_000), ['410_289']);
});

test('Overpass kayıtları: kategori, ad dilleri, deprem için uygun olmayan alan elenir', () => {
  const places = parseOverpassElements([
    { type: 'node', id: 1, lat: 41.01, lon: 28.97, tags: { emergency: 'assembly_point', name: 'Sultanahmet Parkı', 'name:en': 'Sultanahmet Park', ref: '12' } },
    { type: 'way', id: 2, center: { lat: 41.02, lon: 28.98 }, tags: { amenity: 'hospital', name: 'Cerrahpaşa', 'addr:street': 'Kocamustafapaşa Cd.' } },
    { type: 'node', id: 3, lat: 41.03, lon: 28.99, tags: { emergency: 'assembly_point', 'assembly_point:earthquake': 'no' } },
    { type: 'node', id: 4, lat: 41.03, lon: 28.99, tags: { amenity: 'bench' } },
    { type: 'node', id: 1, lat: 41.01, lon: 28.97, tags: { emergency: 'assembly_point' } }
  ]);
  assert.equal(places.length, 2);
  assert.deepEqual(places[0], {
    id: 'osm-node-1', c: 'assemblyArea', lat: 41.01, lon: 28.97, n: 'Sultanahmet Parkı', nl: { en: 'Sultanahmet Park' }, r: '12'
  });
  assert.equal(places[1].c, 'hospital');
  assert.equal(places[1].a, 'Kocamustafapaşa Cd.');
});

test('en yakınlar: yarıçap dışı elenir, kategori başına sınır, uzaklığa göre sıralı', () => {
  const pharmacies = Array.from({ length: 10 }, (_, i) => ({ id: `p${i}`, c: 'pharmacy', lat: 41 + i * 0.001, lon: 29, n: '' }));
  const places = nearestSafetyPlaces([
    pharmacies,
    [{ id: 'a', c: 'assemblyArea', lat: 41.0005, lon: 29, n: 'Park' }, { id: 'far', c: 'hospital', lat: 42, lon: 29, n: '' }],
    null
  ], 41, 29, 5_000, 3);
  assert.deepEqual(places.map(place => place.id), ['p0', 'a', 'p1', 'p2']);
  assert.ok(places.every((place, i) => i === 0 || places[i - 1].d <= place.d));
});

test('hücre Firestore önbelleğinden okunur; ağa çıkılmaz', async () => {
  const stored = [{ id: 'osm-node-9', c: 'pharmacy', lat: 39.93, lon: 32.85, n: 'Eczane' }];
  const reads = [];
  const db = {
    collection: () => ({ doc: id => ({ id }) }),
    getAll: async (...refs) => {
      reads.push(...refs.map(ref => ref.id));
      return refs.map(() => ({ data: () => ({ payload: gzipSync(Buffer.from(JSON.stringify(stored))), expire_at: { toMillis: () => Date.now() + 1e9 } }) }));
    }
  };
  const first = await loadSafetyCells(db, ['399_328']);
  assert.deepEqual(first.get('399_328'), stored);
  // İkinci istek bellekten: Firestore okunmaz.
  await loadSafetyCells(db, ['399_328']);
  assert.deepEqual(reads, ['399_328']);
});
