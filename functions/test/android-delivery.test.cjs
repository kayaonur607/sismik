const test = require('node:test');
const assert = require('node:assert/strict');
const { toCachedPushDevice, buildQuakeMessage } = require('../lib/push-routes');

const NOW = Date.parse('2026-09-25T08:00:00Z');
const home = { id: 'p1', name: 'Ev', icon: 'house', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 3.0 };
const quake = { id: 'afad-1', provider: 'AFAD', title: 'Kadıköy (İstanbul)', magnitude: 4.2, depth: 7, lat: 40.99, lon: 29.03, date: new Date(NOW - 60_000).toISOString() };
const doc = (id, data) => ({ id, data: () => data });
const base = { transport: 'fcm', token: 'tok', earthquake_notifications_enabled: true, places: [home], is_premium: false };
const match = { reason: 'place', distanceKm: 3, placeName: 'Ev', placeIcon: 'house' };

test('iOS device: message has no android block or data (unchanged)', () => {
  const device = toCachedPushDevice(doc('ios', base), NOW);
  assert.equal(device.platform, undefined);
  const message = buildQuakeMessage(device, quake, match, NOW);
  assert.equal(message.android, undefined);
  assert.equal(message.data, undefined);
  assert.ok(message.apns);
});

test('Android device: high priority, channel, string data with quake payload', () => {
  const device = toCachedPushDevice(doc('and', { ...base, platform: 'android' }), NOW);
  assert.equal(device.platform, 'android');
  const message = buildQuakeMessage(device, quake, match, NOW);
  assert.equal(message.android.priority, 'high');
  assert.equal(message.android.notification.channelId, 'earthquakes');
  assert.equal(message.android.collapseKey, 'afad-1');
  assert.equal(message.data.quakeId, 'afad-1');
  assert.equal(JSON.parse(message.data.quake).magnitude, 4.2);
  assert.equal(message.data.placeIcon, 'house');
  for (const value of Object.values(message.data)) assert.equal(typeof value, 'string');
  assert.ok(message.notification.title);
});
