const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseNOAEventText,
  providerArchiveFallback,
  topTurkeyProvincesFromAFAD,
  isQuakeWithinTimeWindow
} = require('../lib/worker-utils');

test('NOA FDSN text feed maps to the common earthquake model', () => {
  const feed = [
    '#EventID|Time|Latitude|Longitude|Depth/km|Author|Catalog|Contributor|ContributorID|MagType|Magnitude|MagAuthor|EventLocationName|EventType',
    'noa2026nvnrn|2026-07-16T17:43:06.926049|35.072937|23.703918|17.31726074|NOA||NOAIG|noa2026nvnrn|MLh|2.640446349|NOA|Crete, Greece|earthquake'
  ].join('\n');

  const result = parseNOAEventText(feed);

  assert.equal(result.length, 1);
  assert.deepEqual(result[0], {
    id: 'noa-noa2026nvnrn',
    provider: 'NOA',
    title: 'Crete, Greece',
    magnitude: 2.640446349,
    depth: 17.31726074,
    lat: 35.072937,
    lon: 23.703918,
    date: '2026-07-16T17:43:06.926Z',
    closestCity: null,
    epiCenter: 'Crete, Greece',
    magType: 'MLh',
    author: 'NOA',
    catalog: null,
    eventType: 'earthquake',
    revised: false
  });
});

test('NOA live timeout falls back to recent Firestore archive records', () => {
  const start = Date.parse('2026-07-16T00:00:00.000Z');
  const quake = (id, magnitude, date) => ({
    id,
    provider: 'NOA',
    title: id,
    magnitude,
    depth: 5,
    lat: 38,
    lon: 24,
    date
  });
  const archive = [
    quake('recent', 2.4, '2026-07-16T01:00:00.000Z'),
    quake('too-low', 2.0, '2026-07-16T02:00:00.000Z'),
    quake('old', 3.1, '2026-07-15T23:59:59.000Z')
  ];

  assert.deepEqual(
    providerArchiveFallback([], archive, start, 2.0).map(item => item.id),
    ['recent']
  );
  assert.deepEqual(
    providerArchiveFallback([quake('live', 2.2, '2026-07-16T03:00:00.000Z')], archive, start, 2.0)
      .map(item => item.id),
    ['live']
  );
});

test('active Turkey provinces use only AFAD records inside the selected range', () => {
  const quake = (id, provider, province, date, magnitude = 3) => ({
    id,
    provider,
    title: province || 'Central Turkey',
    magnitude,
    depth: 8,
    lat: 39,
    lon: 35,
    date,
    closestCity: province
  });
  const start = Date.parse('2026-07-15T00:00:00.000Z');
  const result = topTurkeyProvincesFromAFAD([
    quake('a1', 'AFAD', 'KAHRAMANMARAŞ', '2026-07-15T01:00:00.000Z'),
    quake('a2', 'AFAD', 'Kahramanmaraş', '2026-07-15T02:00:00.000Z'),
    quake('a3', 'AFAD', 'ÇANAKKALE', '2026-07-15T03:00:00.000Z'),
    quake('a3', 'AFAD', 'ÇANAKKALE', '2026-07-15T03:00:00.000Z'),
    quake('old', 'AFAD', 'İzmir', '2026-07-14T23:59:59.000Z'),
    quake('low', 'AFAD', 'Muğla', '2026-07-15T04:00:00.000Z', 2.0),
    quake('e1', 'EMSC', null, '2026-07-15T05:00:00.000Z')
  ], start);

  assert.deepEqual(result, [
    { name: 'Kahramanmaraş', count: 2 },
    { name: 'Çanakkale', count: 1 }
  ]);
});

test('archived provider records respect the selected statistics window', () => {
  const start = Date.parse('2026-07-16T12:00:00.000Z');
  const end = Date.parse('2026-07-16T13:00:00.000Z');

  assert.equal(isQuakeWithinTimeWindow({ date: '2026-07-16T12:30:00.000Z' }, start, end), true);
  assert.equal(isQuakeWithinTimeWindow({ date: '2026-07-16T11:59:59.999Z' }, start, end), false);
  assert.equal(isQuakeWithinTimeWindow({ date: '2026-07-16T13:00:00.001Z' }, start, end), false);
  assert.equal(isQuakeWithinTimeWindow({ date: 'invalid' }, start, end), false);
});
