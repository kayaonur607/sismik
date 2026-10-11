const test = require('node:test');
const assert = require('node:assert/strict');
const {
  notificationMatch,
  matchPlace,
  sanitizeDevicePlaces,
  placesFromDeviceData,
  legacyRulesFromDeviceData,
  deviceUsesPlaces,
  selectFastestQuakes,
  shouldDeliverDuplicate
} = require('../lib/worker-utils');

function quake(overrides = {}) {
  return {
    id: 'afad-1',
    provider: 'AFAD',
    title: 'Test',
    magnitude: 3.2,
    depth: 8,
    lat: 40.99,   // Kadıköy
    lon: 29.03,
    date: '2026-07-15T12:00:00.000Z',
    ...overrides
  };
}

const ev = { name: 'Ev', id: 'p-ev', icon: 'house', lat: 40.99, lon: 29.03, radiusKm: 50, minMagnitude: 2.0 };
const izmir = { name: 'Annemler', id: 'p-izmir', lat: 38.42, lon: 27.14, radiusKm: 100, minMagnitude: 3.0 };

function prefs(places, extra = {}) {
  return { places, tzOffset: 180, lang: 'tr', notified: [], ...extra };
}

// MARK: - Yer eşleşmesi

test('yarıçap içindeki ve eşiği geçen deprem eşleşir, yer adı taşınır', () => {
  const match = notificationMatch(quake(), prefs([ev]));
  assert.equal(match?.reason, 'place');
  assert.equal(match?.placeName, 'Ev');
  assert.ok(match.distanceKm < 1);
});

test('yer başına eşik: aynı deprem bir yeri tetikler, diğerini tetiklemez', () => {
  const kucuk = quake({ magnitude: 2.4 });
  assert.equal(notificationMatch(kucuk, prefs([ev]))?.reason, 'place');
  // İzmir'deki yerin eşiği M3.0 ve deprem zaten uzakta.
  assert.equal(notificationMatch(kucuk, prefs([izmir])), null);
});

test('yarıçap dışındaki deprem eşleşmez', () => {
  // Kadıköy'den ~330 km: Ev'in 50 km yarıçapının dışında.
  const uzak = quake({ lat: 38.42, lon: 27.14, magnitude: 4.5 });
  assert.equal(notificationMatch(uzak, prefs([ev])), null);
});

test('iki yer de tutuyorsa en yakın olan kazanır', () => {
  // Kadıköy'e 20 km, İzmir'e ~300 km. İkisinin de eşiğini geçiyor.
  const yakin = quake({ lat: 41.10, lon: 29.20, magnitude: 4.0 });
  const genisEv = { ...ev, radiusKm: 400 };
  const genisIzmir = { ...izmir, radiusKm: 400 };
  const match = notificationMatch(yakin, prefs([genisIzmir, genisEv]));
  assert.equal(match?.placeName, 'Ev', 'sıralama değil mesafe belirlemeli');
});

test('yer listesi boşken yalnızca dünya geneli büyük deprem eşleşir', () => {
  const p = prefs([], { worldMajorEnabled: true, worldMajorThreshold: 6.5 });
  assert.equal(notificationMatch(quake({ magnitude: 4.9 }), p), null);
  assert.equal(notificationMatch(quake({ magnitude: 6.8 }), p)?.reason, 'world_major');
});

test('kaynak artık filtre değil: her sağlayıcı eşit davranır', () => {
  for (const provider of ['AFAD', 'EMSC', 'USGS', 'NOA']) {
    assert.equal(
      notificationMatch(quake({ provider, id: `${provider}-1` }), prefs([ev]))?.reason,
      'place',
      `${provider} eşleşmeli`
    );
  }
});

test('matchPlace saf: eşleşmeyen yer null döner, eşleşen mesafe verir', () => {
  assert.equal(matchPlace(quake({ magnitude: 1.5 }), [ev]), null, 'eşiğin altı');
  const hit = matchPlace(quake(), [ev]);
  assert.equal(hit?.place.id, 'p-ev');
  assert.ok(hit.distanceKm >= 0);
});

// MARK: - Yük temizliği

test('sanitizeDevicePlaces sekizden fazlasını kırpar', () => {
  const many = Array.from({ length: 12 }, (_, i) => ({ ...ev, id: `p-${i}` }));
  assert.equal(sanitizeDevicePlaces(many).length, 8);
});

test('sanitizeDevicePlaces geçersiz koordinatlı yeri atar, geçerlileri korur', () => {
  const input = [
    ev,
    { ...ev, id: 'bozuk-lat', lat: 200 },
    { ...ev, id: 'bozuk-lon', lon: NaN },
    { ...ev, id: 'eksik', lat: undefined }
  ];
  const clean = sanitizeDevicePlaces(input);
  assert.deepEqual(clean.map(p => p.id), ['p-ev']);
});

test('sanitizeDevicePlaces yarıçap ve eşiği sınırlara çeker, adı kısaltır', () => {
  const [clean] = sanitizeDevicePlaces([{
    ...ev,
    radiusKm: 9000,
    minMagnitude: 42,
    name: 'x'.repeat(120)
  }]);
  assert.equal(clean.radiusKm, 1000);
  assert.equal(clean.minMagnitude, 9);
  assert.equal(clean.name.length, 40);
});

test('sanitizeDevicePlaces dizi olmayan girdide boş döner', () => {
  assert.deepEqual(sanitizeDevicePlaces(undefined), []);
  assert.deepEqual(sanitizeDevicePlaces('yer'), []);
  assert.deepEqual(sanitizeDevicePlaces([null, 3]), []);
});

// MARK: - Kural biçimi: yer modeli / eski kural
//
// Üretimde (10 Eylül 2026) push alan 21 cihazın 18'i "tüm bölgeler,
// koordinat yok" eski kuralında. Bu kural yer listesine çevrilemez; eski
// kural kendi eşleştiricisiyle, 2.0.9 sunucusundakiyle aynen işletilir.

const legacyDoc = (extra = {}) => ({
  source: 'afad', min_magnitude: 4, major_threshold: 5, nearby_only: false,
  radius: 250, minimum_estimated_mmi: 0, source_fallback_enabled: true, ...extra
});
const legacyPrefs = (doc, extra = {}) => ({
  places: placesFromDeviceData(doc),
  legacy: legacyRulesFromDeviceData(doc),
  tzOffset: 180, lang: 'tr', notified: [], ...extra
});

test('places dizisi varsa yer modeli; eski alanlar yok sayılır', () => {
  const doc = { places: [ev], ...legacyDoc() };
  assert.equal(deviceUsesPlaces(doc), true);
  assert.equal(legacyRulesFromDeviceData(doc), undefined);
  assert.deepEqual(placesFromDeviceData(doc).map(p => p.id), ['p-ev']);
});

test('boş places dizisi "yer yok" demektir, eski kurala düşmez', () => {
  const doc = { places: [], ...legacyDoc() };
  assert.equal(deviceUsesPlaces(doc), true);
  assert.equal(notificationMatch(quake({ magnitude: 4.5 }), legacyPrefs(doc)), null);
});

test('places alanı yoksa eski kural: koordinatsız tüm bölgeler AFAD kaydını alır', () => {
  const doc = legacyDoc();
  assert.equal(deviceUsesPlaces(doc), false);
  // Ege'de, kutu dışında, AFAD kaydı: 2.0.9 sunucusunda bildirim gidiyordu.
  const match = notificationMatch(
    quake({ id: 'afad-ege', provider: 'AFAD', lat: 38.5, lon: 20.8, magnitude: 4.2 }),
    legacyPrefs(doc)
  );
  assert.equal(match?.reason, 'regular');
});

test('eski kural: seçilen ajansın kapsamında ilk yayımlayan tetikler, kapsam dışında seçilen ajans', () => {
  const prefs = legacyPrefs(legacyDoc());
  assert.equal(notificationMatch(quake({ provider: 'EMSC', magnitude: 4.1 }), prefs)?.reason, 'regular',
    'kutu içinde ilk yayımlayan ajans tetikler');
  assert.equal(notificationMatch(quake({ provider: 'EMSC', lat: 35.6, lon: 139.7, magnitude: 4.5 }), prefs), null,
    'AFAD kapsamı dışında (Japonya) AFAD kullanıcısına EMSC kaydı gitmez');
  assert.equal(notificationMatch(quake({ provider: 'EMSC', lat: 35.6, lon: 139.7, magnitude: 4.5 }), prefs, Date.now(), true)?.reason,
    'regular', 'seçili kaynak kesintideyse ve yedek açıksa filtre kalkar');
});

test('eski kural: eşik ve yakınlık 2.0.9 ile aynı', () => {
  assert.equal(notificationMatch(quake({ magnitude: 3.9 }), legacyPrefs(legacyDoc())), null, 'eşiğin altı');
  const nearby = legacyDoc({ nearby_only: true, radius: 50, latitude: 38.42, longitude: 27.14 });
  assert.equal(notificationMatch(quake({ magnitude: 4.2 }), legacyPrefs(nearby)), null, 'yarıçap dışı');
  const regionalMajor = notificationMatch(quake({ magnitude: 5.4 }), legacyPrefs(nearby));
  assert.equal(regionalMajor?.reason, 'regular', 'bölgesel büyük deprem yarıçapı aşar');
  assert.equal(regionalMajor?.isNearbyMatch, false, '"bölgende" denmemeli');
  const noCoords = legacyDoc({ nearby_only: true, radius: 50 });
  assert.equal(notificationMatch(quake({ magnitude: 4.2 }), legacyPrefs(noCoords)), null,
    'koordinatsız yakınlık kuralı global akışa dönüşmez');
});

test('eski kural: dünya büyük depremi Türkiye kutusunu dışarıda tutar', () => {
  const prefs = legacyPrefs(legacyDoc(), { worldMajorEnabled: true, worldMajorThreshold: 6.5 });
  assert.equal(notificationMatch(quake({ provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 6.8 }), prefs)?.reason, 'world_major');
  assert.equal(notificationMatch(quake({ magnitude: 6.8 }), prefs)?.reason, 'regular',
    'kutudaki M6.8 bölgesel kural üzerinden gelir');
});

// MARK: - Sağlayıcı kopyası

test('kopya: AFAD kapsamında (Ege) EMSC önce yayımlarsa bildirim hemen gider, AFAD kopyası tekrar gitmez', () => {
  const emsc = quake({ id: 'emsc-ege', provider: 'EMSC', lat: 38.5, lon: 20.8, magnitude: 4.3 });
  const afad = quake({ id: 'afad-ege', provider: 'AFAD', lat: 38.52, lon: 20.82, magnitude: 4.2,
    date: new Date(new Date(emsc.date).getTime() + 20_000).toISOString() });
  const { suppressed, duplicateOf } = selectFastestQuakes([emsc, afad], []);
  assert.deepEqual(suppressed.map(q => q.id), ['afad-ege']);
  const prefs = legacyPrefs(legacyDoc());
  assert.equal(notificationMatch(emsc, prefs)?.reason, 'regular', 'en hızlı ajans (EMSC) tetikler');
  assert.equal(shouldDeliverDuplicate(afad, duplicateOf.get('afad-ege'), prefs), null, 'çift bildirim yok');
});

test('kopya: kapsam dışında ilk kaydı istemeyen eski AFAD cihazına AFAD kopyası gider', () => {
  const emsc = quake({ id: 'emsc-jp', provider: 'EMSC', lat: 35.6, lon: 139.7, magnitude: 4.5 });
  const afad = quake({ id: 'afad-jp', provider: 'AFAD', lat: 35.61, lon: 139.71, magnitude: 4.4,
    date: new Date(new Date(emsc.date).getTime() + 20_000).toISOString() });
  const { duplicateOf } = selectFastestQuakes([emsc, afad], []);
  assert.equal(shouldDeliverDuplicate(afad, duplicateOf.get('afad-jp'), legacyPrefs(legacyDoc()))?.reason, 'regular');
});

test('kopya: ilk kaydı zaten alan cihaza gitmez (çift bildirim yok)', () => {
  const emsc = quake({ id: 'emsc-1', provider: 'EMSC', magnitude: 3.2 });
  const afad = quake({ id: 'afad-1', provider: 'AFAD', magnitude: 3.3 });
  const { duplicateOf } = selectFastestQuakes([emsc, afad], []);
  assert.equal(shouldDeliverDuplicate(afad, duplicateOf.get('afad-1'), prefs([ev])), null, 'yer modeli');
  const turkeyLegacy = legacyPrefs(legacyDoc({ min_magnitude: 3 }));
  assert.equal(shouldDeliverDuplicate(afad, duplicateOf.get('afad-1'), turkeyLegacy), null,
    'kutuda eski kural ilk ajansı kabul ediyor');
});

test('kopya: ilk ajans eşiğin altında kaldıysa ikinci ajansın kaydı gider', () => {
  const emsc = quake({ id: 'emsc-2', provider: 'EMSC', magnitude: 2.9 });
  const afad = quake({ id: 'afad-2', provider: 'AFAD', magnitude: 3.1 });
  const { duplicateOf } = selectFastestQuakes([emsc, afad], []);
  const threshold3 = prefs([{ ...ev, minMagnitude: 3.0 }]);
  assert.equal(shouldDeliverDuplicate(afad, duplicateOf.get('afad-2'), threshold3)?.reason, 'place');
});

// MARK: - Yarıçap doğruluğu (regresyon)
//
// Ön eleme ASLA yarıçap içindeki bir depremi elememeli: elerse kullanıcı
// kendi seçtiği alanın içindeki depremde bildirim almaz ve bunu fark etmesi
// imkânsıza yakındır. Aşağıdaki üç vaka, ölçülerek bulunmuş üç ayrı hatayı
// kilitler.

test('180. meridyen sarması: 21 km uzaktaki deprem elenmez', () => {
  // Yer 179,9°D, deprem 179,9°B. Ham boylam farkı 359,8° çıkıyordu.
  const fiji = { id: 'p', name: 'Fiji', lat: -17.0, lon: 179.9, radiusKm: 100, minMagnitude: 1 };
  const hit = matchPlace({ lat: -17.0, lon: -179.9, magnitude: 4 }, [fiji]);
  assert.ok(hit, 'meridyenin diğer yanındaki deprem eşleşmeli');
  assert.ok(hit.distanceKm < 25, `mesafe makul olmalı, bulunan: ${hit?.distanceKm}`);
});

test('sınırın hemen dışındaki deprem eşleşmez', () => {
  const yer = { id: 'p', name: 'Ekvator', lat: 0, lon: 0, radiusKm: 100, minMagnitude: 1 };
  assert.ok(matchPlace({ lat: 0.85, lon: 0, magnitude: 4 }, [yer]), '≈94 km içeride');
  assert.equal(matchPlace({ lat: 1.2, lon: 0, magnitude: 4 }, [yer]), null, '≈133 km dışarıda');
});

test('kutup yakınında büyük yarıçap: gerçek yol kutuptan kısalır, elenmez', () => {
  // Enlem -84'te 1000 km yarıçapta, 93 km içeride kalan olay eleniyordu.
  const kutup = { id: 'p', name: 'Kutup', lat: -84.4, lon: -78.8, radiusKm: 1000, minMagnitude: 1 };
  assert.ok(matchPlace({ lat: -84.5, lon: 16.1, magnitude: 4 }, [kutup]));
});
