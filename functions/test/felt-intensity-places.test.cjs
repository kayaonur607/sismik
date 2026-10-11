const test = require('node:test');
const assert = require('node:assert/strict');
const { matchPlace, notificationMatch, sanitizeDevicePlaces, feltReachKm } = require('../lib/worker-utils');
const { SpatialGridIndex } = require('../lib/spatial-index');
const { buildNotificationContent } = require('../lib/notification-templates');

// Diyarbakır'da 50 km'lik, M4+ yer; 24 Eyl 2026 Şanlıurfa M5.4 ~150 km uzakta.
const home = { id: 'h', name: 'Ev', icon: 'house', lat: 37.91, lon: 40.23, radiusKm: 50, minMagnitude: 4 };
const urfa = { id: 'afad-1', provider: 'AFAD', title: 'Karaköprü', magnitude: 5.4, depth: 7, lat: 37.42, lon: 38.87, date: new Date().toISOString() };

test('sabit yarıçap uzaktaki hissedilir depremi kaçırıyordu; hissedilir kural yakalar', () => {
  assert.equal(matchPlace(urfa, [home]), null, 'yalnızca yarıçap: bildirim yok');
  assert.equal(matchPlace(urfa, [{ ...home, feltIntensity: 4 }]), null, 'MMI 4 eşiğinin altında');
  const hit = matchPlace({ ...urfa, magnitude: 6.2 }, [{ ...home, feltIntensity: 4 }]);
  assert.equal(hit.feltAtPlace, true);
  assert.ok(hit.distanceKm > 100);
  // Küçük deprem (M2.8) hissedilir kuralı tetiklemez.
  assert.equal(matchPlace({ ...urfa, magnitude: 2.8, lat: 37.95, lon: 40.25 }, [{ ...home, minMagnitude: 4, feltIntensity: 3 }]), null);
  // Yarıçap içindeki olağan eşleşme hissedilir olarak işaretlenmez.
  const near = matchPlace({ ...urfa, magnitude: 4.5, lat: 37.95, lon: 40.25 }, [{ ...home, feltIntensity: 3 }]);
  assert.equal(near.feltAtPlace, undefined);
});

test('uzaktan hissedilir eşleşme kritik uyarı vermez (şiddet V altı); bildirim metni doğru', () => {
  const place = { ...home, feltIntensity: 3, criticalMagnitude: 5 };
  const prefs = { places: [place], tzOffset: 180, lang: 'tr', notified: [] };
  const match = notificationMatch({ ...urfa, magnitude: 6.0 }, prefs);
  assert.equal(match.reason, 'place');
  assert.equal(match.feltAtPlace, true);
  assert.equal(match.placeCriticalMagnitude, undefined);
  const text = buildNotificationContent('tr', { kind: 'place', magnitude: 6.0, depth: 7, place: 'Karaköprü', hhmm: '10:40', provider: 'AFAD', distanceKm: match.distanceKm, placeName: 'Ev', feltAtPlace: true });
  assert.match(text.title, /Ev konumunda hissedilebilir deprem/);
});

test('istemci yükü: yalnızca 3/4/5 kabul edilir; dizin uzak depremde yeri aday yapar', () => {
  const [a, b] = sanitizeDevicePlaces([{ ...home, feltIntensity: 4 }, { ...home, id: 'x', feltIntensity: 9 }]);
  assert.equal(a.feltIntensity, 4);
  assert.equal(b.feltIntensity, undefined);
  assert.ok(feltReachKm(4) > 250 && feltReachKm(4) <= 600);
  const index = new SpatialGridIndex();
  const device = { key: 'd1', token: 't', premium: false, premiumExpiresAt: 0, prefs: { places: [a], tzOffset: 180, lang: 'tr', notified: [] } };
  index.addOrUpdateDevice(device);
  const candidates = index.queryCandidates(urfa.lat, urfa.lon, 6.2).map(d => d.key);
  assert.ok(candidates.includes('d1'));
});
