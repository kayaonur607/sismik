const test = require('node:test');
const assert = require('node:assert/strict');
const { gunzipSync } = require('node:zlib');
const {
  notificationMatch,
  notificationPlaceLabel,
  freeTierPrefs,
  effectivePushPrefs,
  isPushCandidate,
  FREE_PLACE_LIMIT,
  FREE_MAX_RADIUS_KM,
  FREE_WORLD_MAJOR_MIN_MAGNITUDE
} = require('../lib/worker-utils');
const { toCachedPushDevice, buildQuakeMessage, buildSnapshotParts } = require('../lib/push-routes');

const NOW = Date.parse('2026-09-21T12:00:00.000Z');

function quake(overrides = {}) {
  return {
    id: 'afad-1', provider: 'AFAD', title: 'Kadıköy (İstanbul)', magnitude: 4.2, depth: 7,
    lat: 40.99, lon: 29.03, date: new Date(NOW - 60_000).toISOString(), ...overrides
  };
}

const home = { id: 'p1', name: 'Ev', icon: 'house', lat: 40.99, lon: 29.03, radiusKm: 200, minMagnitude: 3.0, criticalMagnitude: 5.0 };
const office = { id: 'p2', name: 'Ofis', icon: 'briefcase', lat: 38.42, lon: 27.14, radiusKm: 100, minMagnitude: 3.0 };

function prefs(extra = {}) {
  return { places: [home, office], tzOffset: 180, lang: 'tr', notified: [], ...extra };
}

// Firestore belgesi taklidi
function doc(id, data) {
  return { id, data: () => data };
}

test('free tier limits: one place, 50 km, world M6.0+', () => {
  assert.equal(FREE_PLACE_LIMIT, 1);
  assert.equal(FREE_MAX_RADIUS_KM, 50);
  assert.equal(FREE_WORLD_MAJOR_MIN_MAGNITUDE, 6.0);
});

test('free prefs keep only the first place, clamp its radius and drop premium extras', () => {
  const limited = freeTierPrefs(prefs({
    worldMajorEnabled: true, worldMajorThreshold: 5.0, criticalAlertsEnabled: true,
    notificationSound: 'sismik_pulse.caf',
    aftershockWatch: { mainshockId: 'x', title: 'x', magnitude: 6, latitude: 40, longitude: 29, startedAt: 0, expiresAt: NOW + 1e6, radiusKm: 150, minimumMagnitude: 2.5 }
  }));
  assert.equal(limited.places.length, 1);
  assert.equal(limited.places[0].id, 'p1');
  assert.equal(limited.places[0].radiusKm, 50);
  assert.equal(limited.places[0].criticalMagnitude, undefined);
  assert.equal(limited.worldMajorThreshold, 6.0);
  assert.equal(limited.aftershockWatch, undefined);
  assert.equal(limited.criticalAlertsEnabled, false);
  assert.equal(limited.notificationSound, '');
  // Eski kural ücretsizde işletilmez.
  assert.equal(freeTierPrefs(prefs({ legacy: { source: 'afad' } })), null);
});

test('free place only matches inside 50 km, whatever radius the client sent', () => {
  const limited = freeTierPrefs(prefs());
  assert.equal(notificationMatch(quake({ lat: 41.3 }), limited, NOW)?.reason, 'place'); // ~35 km
  assert.equal(notificationMatch(quake({ lat: 41.7 }), limited, NOW), null);            // ~80 km
  assert.equal(notificationMatch(quake({ lat: 41.7 }), prefs(), NOW)?.reason, 'place'); // premium: 200 km
  // İkinci yer (İzmir) ücretsizde yok sayılır.
  assert.equal(notificationMatch(quake({ lat: 38.42, lon: 27.14 }), limited, NOW), null);
});

test('free world alerts start at M6.0', () => {
  const limited = freeTierPrefs(prefs({ places: [], worldMajorEnabled: true, worldMajorThreshold: 5.0 }));
  const far = quake({ lat: 52.5, lon: 160.1 });
  assert.equal(notificationMatch({ ...far, magnitude: 5.9 }, limited, NOW), null);
  assert.equal(notificationMatch({ ...far, magnitude: 6.0 }, limited, NOW)?.reason, 'world_major');
});

test('push candidates are devices with any enabled rule, premium or not', () => {
  assert.equal(isPushCandidate({ earthquake_notifications_enabled: true, places: [home] }), true);
  assert.equal(isPushCandidate({ earthquake_notifications_enabled: true, places: [], world_major_enabled: true }), true);
  assert.equal(isPushCandidate({ earthquake_notifications_enabled: true, source: 'afad' }), true);
  assert.equal(isPushCandidate({ earthquake_notifications_enabled: true, places: [] }), false);
  assert.equal(isPushCandidate({ earthquake_notifications_enabled: false, places: [home] }), false);
});

test('push loader accepts free devices with rules and marks the tier', () => {
  const base = { transport: 'fcm', token: 'tok', earthquake_notifications_enabled: true, places: [home] };
  const free = toCachedPushDevice(doc('free', { ...base, is_premium: false }), NOW);
  assert.equal(free.premium, false);
  const premium = toCachedPushDevice(doc('prem', { ...base, is_premium: true, premium_expires_at: NOW + 86_400_000 }), NOW);
  assert.equal(premium.premium, true);
  assert.equal(toCachedPushDevice(doc('none', { ...base, places: [], is_premium: false }), NOW), null);
  assert.equal(toCachedPushDevice(doc('off', { ...base, is_premium: false, earthquake_notifications_enabled: false }), NOW), null);
});

test('an expired premium device falls back to free limits instead of going silent', () => {
  const device = { key: 'd', token: 't', premium: true, premiumExpiresAt: NOW - 1000, prefs: prefs() };
  const effective = effectivePushPrefs(device, NOW);
  assert.equal(effective.places.length, 1);
  assert.equal(effective.places[0].radiusKm, 50);
  const active = { ...device, premiumExpiresAt: NOW + 1000 };
  assert.equal(effectivePushPrefs(active, NOW), active.prefs);
  // Eski snapshot'larda `premium` alanı yok: o önbellek yalnızca premium cihaz tutuyordu.
  const legacySnapshot = { key: 'd', token: 't', premiumExpiresAt: 0, prefs: prefs() };
  assert.equal(effectivePushPrefs(legacySnapshot, NOW), legacySnapshot.prefs);
});

test('free pushes never use critical alerts or custom sounds', () => {
  const device = {
    key: 'd', token: 't', premium: false, premiumExpiresAt: 0,
    prefs: { ...freeTierPrefs(prefs({ criticalAlertsEnabled: true, notificationSound: 'sismik_pulse.caf' })) }
  };
  const message = buildQuakeMessage(device, quake({ magnitude: 5.5 }), { reason: 'place', distanceKm: 3, placeName: 'Ev' }, NOW);
  const { aps } = message.apns.payload;
  assert.equal(typeof aps.sound, 'string');
  assert.equal(aps.category, 'QUAKE_FEEDBACK');
});

test('device snapshot is split into parts that each fit a Firestore document', () => {
  const devices = Array.from({ length: 3000 }, (_, i) => ({
    key: `device-${i}-${Math.random().toString(36).slice(2)}`,
    token: `token-${i}-${Math.random().toString(36).repeat(4)}`,
    premium: i % 3 === 0, premiumExpiresAt: 0,
    prefs: prefs({ notified: [`q-${i}`] })
  }));
  const parts = buildSnapshotParts(devices, 60_000);
  assert.ok(parts.length > 1);
  assert.ok(parts.every(part => part.length <= 60_000));
  const restored = parts.flatMap(part => JSON.parse(gunzipSync(part).toString('utf8')));
  assert.equal(restored.length, devices.length);
  assert.equal(restored[2999].key, devices[2999].key);
});

// MARK: - Bildirimde AFAD yer adı

test('AFAD sea titles are cleaned up in notifications', () => {
  assert.equal(
    notificationPlaceLabel({ provider: 'AFAD', title: 'Marmara Denizi - [16.46 km] Silivri (İstanbul)' }),
    'Marmara Denizi · Silivri (İstanbul) 16 km'
  );
  assert.equal(
    notificationPlaceLabel({ provider: 'AFAD', title: 'Ege Denizi, Santurin Adası (Thira) - [179.05 km] Bodrum (Muğla)' }),
    'Santurin Adası (Thira), Ege Denizi · Bodrum (Muğla) 179 km'
  );
  assert.equal(notificationPlaceLabel({ provider: 'AFAD', title: 'Sındırgı (Balıkesir)' }), 'Sındırgı (Balıkesir)');
  assert.equal(notificationPlaceLabel({ provider: 'USGS', title: '120 km E of Hualien City, Taiwan' }), '120 km E of Hualien City, Taiwan');
});
