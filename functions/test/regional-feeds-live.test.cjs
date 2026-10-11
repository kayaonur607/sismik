const test = require('node:test');
const assert = require('node:assert/strict');
const { parseNOAGeoJSON } = require('../lib/worker-utils');
const { parseBMKGLiveXML, parseCENCList } = require('../lib/earthquake-providers');

test('NOA live GeoJSON: UTC time, stable id, normalized title', () => {
  const quakes = parseNOAGeoJSON({
    type: 'FeatureCollection',
    features: [
      { properties: { Gmt: '24/09/2026 17:20:28.54', Magnitude: '1.4', Depth: '12.2', Lon: '21.9630', Lat: '38.4187', EventId: 'noa2026stkwg', Type: 'Manual', MagnitudeType: 'ML', Location: '3 Km E from Efpalion' } },
      { properties: { Gmt: 'bad', Magnitude: '2', Lon: '21', Lat: '38', EventId: 'x' } }
    ]
  });
  assert.equal(quakes.length, 1);
  assert.equal(quakes[0].id, 'noa-noa2026stkwg', 'same id scheme as the FDSN archive');
  assert.equal(quakes[0].date, '2026-09-24T17:20:28.540Z');
  assert.equal(quakes[0].title, '3 km E of Efpalion');
  assert.equal(quakes[0].status, 'reviewed');
});

test('BMKG live30event: Indonesia region only, id matches TEWS seconds', () => {
  const xml = `<Infogempa>
    <gempa><eventid>a</eventid><status>confirmed</status><waktu>2026/09/24  03:30:27.665</waktu><lintang>-8.28</lintang><bujur>119.26</bujur><dalam>12</dalam><mag>4.6</mag><area>Flores Region, Indonesia</area></gempa>
    <gempa><eventid>b</eventid><status>confirmed</status><waktu>2026/09/24  07:40:59.418</waktu><lintang>37.46</lintang><bujur>39.24</bujur><dalam>10</dalam><mag>5.3</mag><area>Türkiye</area></gempa>
  </Infogempa>`;
  const quakes = parseBMKGLiveXML(xml);
  assert.equal(quakes.length, 1, 'out-of-region events are left to their own agencies');
  assert.equal(quakes[0].id, `bmkg-${Math.round(Date.UTC(2026, 8, 24, 3, 30, 27, 665) / 1000)}`);
  assert.equal(quakes[0].date, '2026-09-24T03:30:27.665Z');
  assert.equal(quakes[0].depth, 12);
});

test('CENC Wolfx list accepts dash dates (UTC+8)', () => {
  const quakes = parseCENCList({ No1: { type: 'reviewed', time: '2026-09-23 17:21:13', magnitude: '5.3', depth: '120', latitude: '-28.85', longitude: '-67.10', placeName: '阿根廷' } });
  assert.equal(quakes.length, 1);
  assert.equal(quakes[0].date, '2026-09-23T09:21:13.000Z');
});
