const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseKandilliList, parseBMKGList, parseGeoNetList, parseJMAList, parseCENCList
} = require('../lib/earthquake-providers');

// 24 Eylül 2026 Şanlıurfa: Kandilli satırı (TSİ) ve revizyonu.
const KANDILLI = `
Date       Time      Latit(N)  Long(E)   Depth(km)     MD   ML   Mw    Region                                                   Solution Type
---------- --------  --------  -------   ----------    ------------    --------------                                          --------------
2026.09.24 13:08:58  39.2508   28.9185        7.2      -.-  1.6  -.-   KAYALIDERE-SIMAV (KUTAHYA)                        İlksel
2026.09.24 10:40:55  37.3630   38.8185        5.1      -.-  5.5  5.3   PINARBASI-(SANLIURFA)                             REVIZE01   (2026.09.24 10:40:55)
2026.09.24 09:00:00  37.9000   26.5000       12.0      2.1  -.-  -.-   EGE DENIZI                                        İlksel
`;

test('Kandilli: Türkiye saati UTC olur, Mw > ML > MD, revizyon kimliği sabit', () => {
  const quakes = parseKandilliList(KANDILLI);
  assert.equal(quakes.length, 3);
  const [simav, urfa, ege] = quakes;
  assert.equal(simav.date, '2026-09-24T10:08:58.000Z');
  assert.equal(simav.magnitude, 1.6);
  assert.equal(simav.magType, 'ML');
  assert.equal(simav.title, 'Kayalidere-Simav (Kutahya)');
  assert.equal(simav.closestCity, 'Kutahya');
  assert.equal(simav.country, 'Türkiye');
  assert.equal(urfa.id, 'kandilli-20260924104055');
  assert.equal(urfa.magnitude, 5.3);
  assert.equal(urfa.magType, 'Mw');
  assert.equal(urfa.revised, true);
  assert.equal(urfa.title, 'Pinarbasi (Sanliurfa)');
  assert.equal(ege.magnitude, 2.1);
  assert.equal(ege.magType, 'MD');
  assert.equal(urfa.provider, 'KANDILLI');
});

test('BMKG: tsunami potansiyeli ve İngilizce başlık', () => {
  const quakes = parseBMKGList({ Infogempa: { gempa: [
    { DateTime: '2026-09-24T03:30:28+00:00', Coordinates: '-8.32,119.25', Magnitude: '4.6', Kedalaman: '12 km', Wilayah: 'Pusat gempa berada di laut 57 km timur Kota Bima', Potensi: 'Tidak berpotensi tsunami' },
    { DateTime: '2026-09-24T05:00:00+00:00', Coordinates: '-3.1,100.2', Magnitude: '7.1', Kedalaman: '20 km', Wilayah: 'Barat Daya Mentawai', Potensi: 'Berpotensi tsunami' }
  ] } });
  assert.equal(quakes.length, 2);
  assert.equal(quakes[0].tsunami, false);
  assert.equal(quakes[1].tsunami, true);
  assert.equal(quakes[0].depth, 12);
  assert.equal(quakes[0].date, '2026-09-24T03:30:28.000Z');
  assert.match(quakes[0].title, /Indonesia$/);
  assert.equal(quakes[0].epiCenter, 'Pusat gempa berada di laut 57 km timur Kota Bima');
  // Tek kayıt (autogempa.json) nesne olarak gelir.
  assert.equal(parseBMKGList({ Infogempa: { gempa: { DateTime: '2026-09-24T03:30:28+00:00', Coordinates: '-8.32,119.25', Magnitude: '4.6', Kedalaman: '12 km' } } }).length, 1);
});

test('GeoNet: silinen olay atlanır', () => {
  const quakes = parseGeoNetList({ features: [
    { geometry: { coordinates: [176.8, -39.7] }, properties: { publicID: '2026p720071', time: '2026-09-24T10:14:02.351Z', depth: 39.69, magnitude: 3.1058, mmi: 3, locality: '10 km south of Hastings', quality: 'best' } },
    { geometry: { coordinates: [176.8, -39.7] }, properties: { publicID: 'x', time: '2026-09-24T10:14:02.351Z', depth: 1, magnitude: 2, quality: 'deleted' } }
  ] });
  assert.equal(quakes.length, 1);
  assert.equal(quakes[0].magnitude, 3.1);
  assert.equal(quakes[0].title, '10 km south of Hastings, New Zealand');
  assert.equal(quakes[0].status, 'reviewed');
});

test('JMA ve CENC: yerel saat UTC olur, tsunami notu okunur, başlık İngilizce', () => {
  const jma = parseJMAList({
    No1: { EventID: '20260924172735', time_full: '2026/09/24 17:27:00', location: '千葉県北東部', magnitude: '3.6', depth: '50km', latitude: '35.7', longitude: '140.6', info: 'この地震による津波の心配はありません。' },
    No2: { EventID: '20260924180000', time_full: '2026/09/24 18:00:00', location: '三陸沖', magnitude: '7.4', depth: '10km', latitude: '38.5', longitude: '143.0', info: '津波警報を発表しています。' },
    No3: { EventID: 'bad', time_full: '2026/09/24 18:00:00', magnitude: '-1' }
  });
  assert.equal(jma.length, 2);
  assert.equal(jma[0].date, '2026-09-24T08:27:00.000Z');
  assert.equal(jma[0].tsunami, false);
  assert.equal(jma[1].tsunami, true);
  assert.equal(jma[0].epiCenter, '千葉県北東部');
  assert.match(jma[0].title, /Japan$/);
  const cenc = parseCENCList({ No1: { type: 'reviewed', EventID: 'CC.20260923175037.4', time: '2026-09-23 17:21:13', location: '阿根廷', placeName: '阿根廷', magnitude: '5.3', depth: '120', latitude: '-28.85', longitude: '-67.10' } });
  assert.equal(cenc[0].date, '2026-09-23T09:21:13.000Z');
  assert.equal(cenc[0].id, 'cenc-20260923092113');
  assert.equal(cenc[0].status, 'reviewed');
});
