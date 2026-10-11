const test = require('node:test');
const assert = require('node:assert/strict');
const { mergeFreshIntoList, withRecentFreshQuakes } = require('../lib/earthquake-routes');

const now = Date.parse('2026-09-22T13:00:00Z');
const q = (id, minutesAgo, extra = {}) => ({
  id, provider: 'AFAD', magnitude: 2, lat: 38, lon: 27,
  date: new Date(now - minutesAgo * 60_000).toISOString(), ...extra
});

test('yeni kimlik doğru yere (zamana göre) girer', () => {
  const base = [q('a', 1), q('b', 10), q('c', 30)];
  const merged = mergeFreshIntoList(base, [q('n', 5)], now);
  assert.deepEqual(merged.map(x => x.id), ['a', 'n', 'b', 'c']);
});

test('bilinen kimlik ve pencere dışı kayıt yazım üretmez', () => {
  const base = [q('a', 1)];
  assert.equal(mergeFreshIntoList(base, [q('a', 1, { magnitude: 5 })], now), null);
  assert.equal(mergeFreshIntoList(base, [q('eski', 25 * 60)], now), null);
  assert.equal(mergeFreshIntoList(base, [q('gelecek', -5)], now), null);
  assert.equal(mergeFreshIntoList(base, [q('bozuk', 1, { magnitude: NaN })], now), null);
});

test('mevcut kayda dokunulmaz (düzeltmeler tam turdan gelir)', () => {
  const base = [q('a', 1, { magnitude: 3.1, extra: 'tam' })];
  const merged = mergeFreshIntoList(base, [q('a', 1, { magnitude: 9 }), q('n', 2)], now);
  assert.equal(merged.find(x => x.id === 'a').magnitude, 3.1);
  assert.equal(merged.find(x => x.id === 'a').extra, 'tam');
});

test('taze kayıt yoksa tam liste aynen döner', () => {
  const list = [q('a', 1)];
  assert.equal(withRecentFreshQuakes(list, now), list);
});
