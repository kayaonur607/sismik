const test = require('node:test');
const assert = require('node:assert/strict');
const {
  filterMapQuakes,
  uniqueQuakesByProviderId,
  optionalFiniteNumber,
  toMapProjection,
  MAP_OMITTED_FIELDS,
  MAP_DETAIL_CRITICAL_FIELDS
} = require('../lib/worker-utils');

const now = Date.parse('2026-07-13T08:00:00.000Z');

function quake(id, provider, magnitude, date = '2026-07-13T07:00:00.000Z') {
  return { id, provider, magnitude, date, title: id, depth: 5, lat: 39, lon: 35 };
}

test('map all-magnitudes mode keeps every source-provided magnitude', () => {
  const result = filterMapQuakes([
    quake('a-low', 'AFAD', 0.5),
    quake('e-low', 'EMSC', 1.9),
    quake('u-negative', 'USGS', -0.2)
  ], now - 86400000, 0);

  assert.deepEqual(result.map(item => item.id), ['a-low', 'e-low', 'u-negative']);
});

test('map magnitude filter applies consistently to every provider', () => {
  const result = filterMapQuakes([
    quake('a-low', 'AFAD', 0.5),
    quake('e-low', 'EMSC', 1.9),
    quake('e-ok', 'EMSC', 2.0)
  ], now - 86400000, 2.0);

  assert.deepEqual(result.map(item => item.id), ['e-ok']);
});

test('provider-aware identity keeps AFAD when EMSC reports the same event', () => {
  const result = uniqueQuakesByProviderId([
    quake('shared', 'AFAD', 3.1),
    quake('shared', 'EMSC', 3.2)
  ]);

  assert.equal(result.length, 2);
  assert.deepEqual(new Set(result.map(item => item.provider)), new Set(['AFAD', 'EMSC']));
});

test('map removes records outside the selected 34-day window', () => {
  const result = filterMapQuakes([
    quake('inside', 'AFAD', 0.7, '2026-06-09T08:00:00.000Z'),
    quake('outside', 'AFAD', 2.4, '2026-06-09T07:59:59.000Z')
  ], Date.parse('2026-06-09T08:00:00.000Z'), 0);

  assert.deepEqual(result.map(item => item.id), ['inside']);
});

test('optional provider intensity keeps real MMI but never converts null to zero', () => {
  assert.equal(optionalFiniteNumber(6.4), 6.4);
  assert.equal(optionalFiniteNumber('3.2'), 3.2);
  assert.equal(optionalFiniteNumber(null), null);
  assert.equal(optionalFiniteNumber(undefined), null);
  assert.equal(optionalFiniteNumber(''), null);
  assert.equal(optionalFiniteNumber('not-a-number'), null);
});

// Harita havuzundaki nesne, kullanıcı bir işarete dokunup "Detay"a gittiğinde
// doğrudan `EarthquakeDetailView`e geçer ve teknik kartı doldurur. Detay ekranı
// kaydı sunucudan yeniden çekmez, bu yüzden buradan düşen alan o ekranda
// kalıcı olarak kaybolur ve yayımlanmış istemcileri de anında etkiler.
test('map projection preserves every field the detail technical card renders', () => {
  const full = {
    id: 'usgs-1', provider: 'USGS', title: '26 km E of Alamo', magnitude: 1.5,
    depth: 13.7, lat: 37.3, lon: -114.8, date: '2026-08-24T21:11:59.101Z',
    sourceURL: 'https://earthquake.usgs.gov/earthquakes/eventpage/nn00923826',
    updatedAt: '2026-08-24T21:15:41.580Z', status: 'automatic', network: 'nn',
    code: '00923826', eventType: 'earthquake', catalog: 'USGS ComCat',
    author: 'nn', significance: 36, stationCount: 12, minimumDistance: 0.165,
    rms: 0.3067, gap: 130
  };

  const projected = toMapProjection(full);
  for (const field of MAP_DETAIL_CRITICAL_FIELDS) {
    assert.deepEqual(
      projected[field], full[field],
      `${field} is shown in the detail technical card and must survive /map`
    );
  }
});

test('the omitted map fields are genuinely unread by every screen', () => {
  // Bu liste bilinçli olarak küçüktür. Büyütmeden önce alanın hiçbir görünümde
  // okunmadığı doğrulanmalıdır, aksi halde eski istemciler sessizce bozulur.
  assert.deepEqual([...MAP_OMITTED_FIELDS].sort(), ['detailURL', 'tsunami']);
  for (const field of MAP_OMITTED_FIELDS) {
    assert.ok(
      !MAP_DETAIL_CRITICAL_FIELDS.includes(field),
      `${field} cannot be both omitted and required by the detail card`
    );
  }
});

test('map projection drops only the omitted fields and keeps everything else', () => {
  const projected = toMapProjection({
    id: 'afad-1', provider: 'AFAD', title: 't', magnitude: 2, depth: 7,
    lat: 39, lon: 35, date: '2026-08-24T21:11:59.101Z',
    detailURL: 'https://example.invalid/detail', tsunami: true,
    network: 'nn', rms: 0.3
  });

  assert.equal(projected.detailURL, undefined);
  assert.equal(projected.tsunami, undefined);
  assert.deepEqual(Object.keys(projected).sort(), [
    'date', 'depth', 'id', 'lat', 'lon', 'magnitude', 'network', 'provider', 'rms', 'title'
  ]);
});
