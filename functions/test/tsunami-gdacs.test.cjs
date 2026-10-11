const test = require('node:test');
const assert = require('node:assert/strict');
const { parseNOAAAtom, noaaLevel, alertsFromQuakes, buildTsunamiNotification, tsunamiAlertRadiusKm } = require('../lib/tsunami-alerts');
const { parseGdacsEvents, applyGdacsAlertLevels } = require('../lib/gdacs');
const { majorEventRegion } = require('../lib/major-event');

const atom = (category) => `<?xml version="1.0"?><feed><title>x</title>
<entry><title>45 miles NE of Amukta Pass, Alaska</title><updated>2026-09-17T14:23:45Z</updated>
<geo:lat>52.810</geo:lat><geo:long>-171.341</geo:long>
<summary type="xhtml"><div><strong>Category:</strong> ${category}<br/><strong>Preliminary Magnitude: </strong>7.8(Mwp)<br/>
<strong>Affected Region: </strong>45 miles NE of Amukta Pass, Alaska<br/></div></summary>
<link rel="alternate" title="Bulletin" href="https://www.tsunami.gov/events/PAAQ/2026/09/17/tliih5/1/WEAK53/WEAK53.txt"/></entry></feed>`;

test('NOAA: bilgi bülteni uyarı sayılmaz; uyarı seviyesi ve olay kimliği okunur', () => {
  assert.deepEqual(parseNOAAAtom(atom('Information'), 'NTWC'), []);
  const [alert] = parseNOAAAtom(atom('Warning'), 'NTWC');
  assert.equal(alert.level, 'warning');
  assert.equal(alert.magnitude, 7.8);
  assert.equal(alert.region, '45 miles NE of Amukta Pass, Alaska');
  assert.equal(alert.id, 'tsunami-PAAQ-2026-09-17-tliih5-warning');
  assert.equal(noaaLevel('Cancellation'), null);
  assert.equal(noaaLevel('Advisory'), 'advisory');
  assert.equal(tsunamiAlertRadiusKm('warning'), 1000);
  assert.equal(tsunamiAlertRadiusKm('advisory'), 500);
});

test('JMA/BMKG tsunami işareti uyarıya dönüşür; metin kullanıcının dilinde', () => {
  const alerts = alertsFromQuakes([
    { id: 'jma-1', provider: 'JMA', title: '80 km E of Sendai, Japan', magnitude: 7.4, depth: 10, lat: 38.5, lon: 143, date: '2026-09-24T09:00:00Z', tsunami: true },
    { id: 'usgs-1', provider: 'USGS', title: 'x', magnitude: 7.4, depth: 10, lat: 38.5, lon: 143, date: '2026-09-24T09:00:00Z', tsunami: true }
  ]);
  assert.equal(alerts.length, 1, 'USGS tsunami bayrağı uyarı değil');
  const tr = buildTsunamiNotification(alerts[0], 'tr');
  assert.equal(tr.title, '🌊 Tsunami uyarısı');
  assert.match(tr.body, /^JMA: 80 km E of Sendai, Japan · M7\.4\nKıyıdan hemen uzaklaşın/);
  assert.equal(buildTsunamiNotification(alerts[0], 'pt-BR').title, '🌊 Alerta de tsunami');
  assert.equal(buildTsunamiNotification(alerts[0], 'zh-Hans').title, '🌊 海啸警报');
});

test('GDACS: turuncu alarm kayda işlenir ve büyük olay açar', () => {
  const events = parseGdacsEvents({ features: [
    { geometry: { coordinates: [146.09, -5.90] }, properties: { eventtype: 'EQ', eventid: 1, alertlevel: 'Orange', fromdate: '2026-09-20T09:17:35', severitydata: { severity: 6.4 }, country: 'Papua New Guinea' } },
    { geometry: { coordinates: [0, 0] }, properties: { eventtype: 'TC', alertlevel: 'Red' } }
  ] });
  assert.equal(events.length, 1);
  assert.equal(events[0].alertLevel, 'orange');
  const quake = { id: 'emsc-1', provider: 'EMSC', title: 'PNG', magnitude: 6.4, depth: 100, lat: -5.95, lon: 146.1, date: '2026-09-20T09:17:40Z' };
  const [enriched] = applyGdacsAlertLevels([quake], events);
  assert.equal(enriched.alertLevel, 'orange');
  assert.equal(majorEventRegion(quake), null, 'M6.4 tek başına dünya eşiğinin altında');
  assert.equal(majorEventRegion(enriched), 'world');
  // USGS PAGER seviyesi korunur.
  const pager = { ...quake, alertLevel: 'yellow' };
  assert.equal(applyGdacsAlertLevels([pager], events)[0].alertLevel, 'yellow');
});
