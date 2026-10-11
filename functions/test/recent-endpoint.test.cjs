const test = require('node:test');
const assert = require('node:assert/strict');
const { recentResponseFor, RECENT_WINDOW_MS } = require('../lib/earthquake-routes');

// `/recent`: uygulamanın 90 sn'lik yenilemesi tam liste (~45 KB) yerine son
// 65 dakikayı (~2-3 KB) çeker. Pencere, önbellek ve ETag davranışı.

const NOW = Date.UTC(2026, 8, 14, 12, 0, 30);
const quake = (id, minutesAgo) => ({
  id, provider: 'AFAD', title: id, magnitude: 2.5, depth: 7, lat: 38, lon: 38,
  date: new Date(NOW - minutesAgo * 60_000).toISOString()
});

test('only quakes inside the 65-minute window are returned', () => {
  const list = [quake('a', 1), quake('b', 64), quake('c', 66), quake('d', 600)];
  const ids = JSON.parse(recentResponseFor(list, NOW).body).map(q => q.id);
  assert.deepEqual(ids, ['a', 'b']);
  assert.equal(RECENT_WINDOW_MS, 65 * 60_000);
});

test('same list in the same minute: identical body and ETag (304 works)', () => {
  const list = [quake('a', 1), quake('b', 30)];
  const first = recentResponseFor(list, NOW);
  const second = recentResponseFor(list, NOW + 20_000);
  assert.equal(second.body, first.body);
  assert.equal(second.etag, first.etag);
  assert.match(first.etag, /^W\/"r[0-9a-f]{24}"$/);
});

test('a new quake changes the ETag', () => {
  const before = recentResponseFor([quake('a', 1)], NOW).etag;
  const after = recentResponseFor([quake('z', 0), quake('a', 1)], NOW).etag;
  assert.notEqual(after, before);
});
