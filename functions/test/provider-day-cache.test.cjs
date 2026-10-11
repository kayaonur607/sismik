const test = require('node:test');
const assert = require('node:assert/strict');
const { mergeProviderDay } = require('../lib/earthquake-routes');

const now = Date.parse('2026-09-22T15:00:00Z');
const q = (id, hoursAgo, magnitude = 2) => ({
  id, provider: 'NOA', magnitude, lat: 38, lon: 23, date: new Date(now - hoursAgo * 3600e3).toISOString()
});
const ids = cache => [...cache.byId.keys()].sort();

test('tam çekim listeyi aynen alır, 24 saat dışını atar', () => {
  const cache = mergeProviderDay(undefined, [q('a', 1), q('b', 20), q('eski', 30)], true, now);
  assert.deepEqual(ids(cache), ['a', 'b']);
  assert.equal(cache.fullAt, now);
});

test('artımlı çekim pencereyi yeniler, pencere dışını korur, silineni düşürür', () => {
  const full = mergeProviderDay(undefined, [q('yakin', 1), q('silinen', 2), q('uzak', 10)], true, now - 5 * 60e3);
  const next = mergeProviderDay(full, [q('yakin', 1, 2.4), q('yeni', 0.1)], false, now);
  assert.deepEqual(ids(next), ['uzak', 'yakin', 'yeni'], 'pencere içindeki silinen kayıt düşer');
  assert.equal(next.byId.get('yakin').magnitude, 2.4, 'düzeltme alınır');
  assert.equal(next.fullAt, full.fullAt, 'artımlı çekim tam çekim zamanını değiştirmez');
});

test('boş yanıt (hata olabilir) hiçbir kaydı silmez', () => {
  const full = mergeProviderDay(undefined, [q('a', 1), q('b', 10)], true, now - 60e3);
  const next = mergeProviderDay(full, [], false, now);
  assert.deepEqual(ids(next), ['a', 'b']);
  assert.equal(next.lastNonEmptyAt, full.lastNonEmptyAt);
});

test('başarısız tam çekim eldekini korur ve bir sonraki turda yeniden tam çekim ister', () => {
  const full = mergeProviderDay(undefined, [q('a', 1)], true, now - 20 * 60e3);
  const failed = mergeProviderDay(full, [], true, now);
  assert.deepEqual(ids(failed), ['a']);
  assert.equal(failed.fullAt, full.fullAt);
});

test('gün sınırını geçen kayıt düşer', () => {
  const full = mergeProviderDay(undefined, [q('sinirda', 23.99)], true, now - 60e3);
  const next = mergeProviderDay(full, [q('yeni', 0.1)], false, now + 60e3);
  assert.deepEqual(ids(next), ['yeni']);
});
