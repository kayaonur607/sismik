const test = require('node:test');
const assert = require('node:assert/strict');
const { parseEMSCFeature, EMSCWebSocketIngestor, USGSRealtimePoller } = require('../lib/realtime-ingestion');

test('parseEMSCFeature: geçerli GeoJSON Feature nesnesini Earthquake modeline dönüştürür', () => {
  const feature = {
    type: 'Feature',
    id: '20260911_0000001',
    geometry: {
      type: 'Point',
      coordinates: [27.14, 38.42, 10.5] // lon, lat, depth
    },
    properties: {
      source_id: '123456',
      source_catalog: 'EMSC',
      lastupdate: '2026-09-11T07:15:00.000Z',
      time: '2026-09-11T07:14:22.000Z',
      flynn_region: 'WESTERN TURKEY',
      mag: 3.4,
      magtype: 'ml',
      auth: 'AFAD',
      unid: '20260911_0000001'
    }
  };

  const q = parseEMSCFeature(feature);
  assert.ok(q);
  assert.equal(q.id, 'emsc-20260911_0000001');
  assert.equal(q.provider, 'EMSC');
  assert.equal(q.title, 'WESTERN TURKEY');
  assert.equal(q.magnitude, 3.4);
  assert.equal(q.lat, 38.42);
  assert.equal(q.lon, 27.14);
  assert.equal(q.depth, 10.5);
  assert.equal(q.magType, 'ml');
  assert.equal(q.date, '2026-09-11T07:14:22.000Z');
  assert.equal(q.updatedAt, '2026-09-11T07:15:00.000Z');
  assert.ok(q.sourceURL.includes('20260911_0000001'));
});

test('parseEMSCFeature: eksik veya bozuk veriyi güvenle null döner', () => {
  assert.equal(parseEMSCFeature(null), null);
  assert.equal(parseEMSCFeature({}), null);
  assert.equal(parseEMSCFeature({ properties: {}, geometry: {} }), null);
  // Geçersiz koordinat
  assert.equal(parseEMSCFeature({
    properties: { mag: 3.0, time: '2026-09-11T07:14:22.000Z' },
    geometry: { coordinates: ['invalid', 38.42] }
  }), null);
});

test('EMSCWebSocketIngestor: yaşam döngüsü başlatma ve durdurma temiz çalışır', () => {
  const ingestor = new EMSCWebSocketIngestor({ autoReconnect: false });
  assert.equal(ingestor.connected, false);

  let quakeReceived = null;
  const unsubscribe = ingestor.onEarthquake((q) => {
    quakeReceived = q;
  });

  // Sahte mesaj işletimi (handleMessage private metodunu test amacıyla tetikle)
  const mockPayload = JSON.stringify({
    action: 'create',
    data: {
      type: 'Feature',
      id: 'test-123',
      geometry: { coordinates: [29.0, 41.0, 5.0] },
      properties: { mag: 4.1, time: '2026-09-11T10:00:00.000Z', flynn_region: 'MARMARA SEA' }
    }
  });

  ingestor['handleMessage'](mockPayload);
  assert.ok(quakeReceived);
  assert.equal(quakeReceived.id, 'emsc-test-123');
  assert.equal(quakeReceived.magnitude, 4.1);

  unsubscribe();
  ingestor.stop();
});

test('USGSRealtimePoller: yaşam döngüsü başlatma ve durdurma temiz çalışır', () => {
  const poller = new USGSRealtimePoller(60_000);
  assert.equal(poller.running, false);

  poller.start();
  assert.equal(poller.running, true);

  poller.stop();
  assert.equal(poller.running, false);
});

test('EMSCWebSocketIngestor: aynı büyüklükte gelen ardışık paketleri tekilleştirir (mükerrerliği engeller)', () => {
  const ingestor = new EMSCWebSocketIngestor({ autoReconnect: false });
  let callCount = 0;
  let lastQuake = null;
  let lastRevision = null;

  ingestor.onEarthquake((q, isRev) => {
    callCount++;
    lastQuake = q;
    lastRevision = isRev;
  });

  const createMsg = JSON.stringify({
    action: 'create',
    data: {
      type: 'Feature',
      id: 'emsc-dup-1',
      geometry: { coordinates: [29.0, 41.0, 10.0] },
      properties: { mag: 6.1, time: '2026-09-11T12:00:00.000Z', flynn_region: 'WESTERN TURKEY' }
    }
  });

  const updateMsgSameMag = JSON.stringify({
    action: 'update',
    data: {
      type: 'Feature',
      id: 'emsc-dup-1',
      geometry: { coordinates: [29.0, 41.0, 12.0] },
      properties: { mag: 6.1, time: '2026-09-11T12:00:00.000Z', flynn_region: 'WESTERN TURKEY' }
    }
  });

  // İlk mesaj: dinleyici çağrılmalı
  ingestor['handleMessage'](createMsg);
  assert.equal(callCount, 1);
  assert.equal(lastQuake.id, 'emsc-emsc-dup-1');
  assert.equal(lastQuake.magnitude, 6.1);
  assert.equal(lastRevision, false);

  // İkinci mesaj (aynı büyüklük, 6.1): TEKİLLEŞTİRİLMELİ, çağrılmamalı!
  ingestor['handleMessage'](updateMsgSameMag);
  assert.equal(callCount, 1);

  // Üçüncü mesaj: küçük oynama (0.1 fark, ör. 6.2): yine tekilleştirilmeli (< 0.3)
  const minorChangeMsg = JSON.stringify({
    action: 'update',
    data: {
      type: 'Feature',
      id: 'emsc-dup-1',
      geometry: { coordinates: [29.0, 41.0, 10.0] },
      properties: { mag: 6.2, time: '2026-09-11T12:00:00.000Z', flynn_region: 'WESTERN TURKEY' }
    }
  });
  ingestor['handleMessage'](minorChangeMsg);
  assert.equal(callCount, 1);

  // Dördüncü mesaj: belirgin revizyon (>= 0.3, ör. 6.5): çağrılmalı ve isRevision true olmalı!
  const majorRevisionMsg = JSON.stringify({
    action: 'update',
    data: {
      type: 'Feature',
      id: 'emsc-dup-1',
      geometry: { coordinates: [29.0, 41.0, 10.0] },
      properties: { mag: 6.5, time: '2026-09-11T12:00:00.000Z', flynn_region: 'WESTERN TURKEY' }
    }
  });
  ingestor['handleMessage'](majorRevisionMsg);
  assert.equal(callCount, 2);
  assert.equal(lastQuake.magnitude, 6.5);
  assert.equal(lastRevision, true);

  ingestor.stop();
});

test('claimQuakeEvent: kimlik ve ajanslar arası kopya tek defterde, kendi kaydı yeniden alınabilir', async () => {
  const { claimQuakeEvent } = require('../lib/push-routes');
  let stored;
  const ref = { get: async () => ({ data: () => stored }), set: async value => { stored = value; } };
  const db = {
    collection: () => ({ doc: () => ref }),
    runTransaction: async work => work({ get: r => r.get(), set: (r, value) => r.set(value) })
  };
  const now = Date.parse('2026-09-23T07:56:00Z');
  const quake = (id, provider, magnitude, lat, lon, offsetMs = 0) => ({
    id, provider, title: 'Saimbeyli (Adana)', magnitude, depth: 7, lat, lon,
    date: new Date(Date.parse('2026-09-23T07:44:53Z') + offsetMs).toISOString()
  });

  assert.deepEqual(await claimQuakeEvent(db, quake('claim-emsc-1', 'EMSC', 2.8, 37.798, 36.183), now), { status: 'claimed' });
  // Aynı süreç kendi kaydını okuma yapmadan yeniden alır (geçici FCM hatası yedeği).
  assert.deepEqual(await claimQuakeEvent(db, quake('claim-emsc-1', 'EMSC', 2.8, 37.798, 36.183), now), { status: 'claimed' });

  // Başka süreç: aynı kimlik defterde → taken.
  stored.events.push({ id: 'claim-foreign', provider: 'AFAD', time: now - 60_000, magnitude: 3.1, lat: 40, lon: 30, claimedAt: now });
  const taken = await claimQuakeEvent(db, quake('claim-foreign', 'AFAD', 3.1, 40, 30), now);
  assert.equal(taken.status, 'taken');

  // Aynı fiziksel deprem, başka ajans: kopya.
  const copy = await claimQuakeEvent(db, quake('claim-afad-1', 'AFAD', 2.9, 37.81, 36.17, 2_000), now);
  assert.equal(copy.status, 'duplicate');
  assert.equal(copy.original.id, 'claim-emsc-1');

  // Aynı ajansın yakın ama ayrı kaydı kopya DEĞİLDİR (art arda iki deprem).
  assert.deepEqual(await claimQuakeEvent(db, quake('claim-emsc-2', 'EMSC', 2.5, 37.80, 36.18, 30_000), now), { status: 'claimed' });
  // Uzak/geç bir deprem de kopya sayılmaz.
  assert.deepEqual(await claimQuakeEvent(db, quake('claim-afad-2', 'AFAD', 2.9, 39.5, 36.2, 10 * 60_000), now), { status: 'claimed' });

  // Firestore'a ulaşılamazsa bildirim engellenmez.
  const broken = { collection: () => ({ doc: () => ref }), runTransaction: async () => { throw new Error('unavailable'); } };
  assert.deepEqual(await claimQuakeEvent(broken, quake('claim-offline', 'AFAD', 4, 38, 27), now), { status: 'claimed' });
});
