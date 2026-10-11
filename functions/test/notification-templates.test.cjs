const test = require('node:test');
const assert = require('node:assert/strict');
const { buildNotificationContent, feltLevel } = require('../lib/notification-templates');
const {
  normalizePlaceIcon,
  sanitizeDevicePlaces,
  notificationMatch,
  selectFreshQuakes,
  findMagnitudeRevisions,
  magnitudeRevisionDecision
} = require('../lib/worker-utils');
const { buildQuakeMessage, pushMaxEventAgeMs, isCriticalDelivery } = require('../lib/push-routes');

const base = { magnitude: 1.6, depth: 7, place: 'Dulkadiroğlu (Kahramanmaraş)', hhmm: '15:04', provider: 'AFAD' };

// MARK: - Onaylanan şablonlar (Türkçe)

test('yer bildirimi: büyüklük başlıkta, yer adı ve uzaklık alt başlıkta', () => {
  const c = buildNotificationContent('tr', { ...base, kind: 'place', placeName: 'Ev', distanceKm: 93 });
  assert.equal(c.title, '🟢 M1.6 · Ev yakınında deprem');
  assert.equal(c.subtitle, 'Dulkadiroğlu (Kahramanmaraş) · 93 km uzakta');
  assert.equal(c.body, '15:04 · 7 km derinlik · AFAD\nBu uzaklıkta muhtemelen hissedilmedi.');
});

test('güçlü deprem: başlık "güçlü", renk yerdeki şiddetten, toplanma alanı çağrısı', () => {
  const c = buildNotificationContent('tr', {
    ...base, kind: 'place', magnitude: 5.4, depth: 9, place: 'Pütürge (Malatya)',
    placeName: 'Annemler', distanceKm: 15, assemblyCta: true
  });
  assert.equal(c.title, '🟠 M5.4 · Annemler yakınında güçlü deprem');
  assert.equal(c.subtitle, 'Pütürge (Malatya) · 15 km uzakta');
  assert.match(c.body, /güçlü hissedilmiş olabilir\. Toplanma alanları için dokun\.$/);
});

test('geç yayımlanan kayıt: alt başlıkta "dk önce", gövdede kaynağın geç yayımladığı', () => {
  const c = buildNotificationContent('tr', { ...base, kind: 'place', placeName: 'Ev', distanceKm: 93, lateMinutes: 28 });
  assert.equal(c.subtitle, 'Dulkadiroğlu (Kahramanmaraş) · 93 km uzakta · 28 dk önce');
  assert.match(c.body, /\nAFAD bu kaydı geç yayımladı\.$/);
});

test('10 dakikadan kısa gecikme "geç" sayılmaz', () => {
  const c = buildNotificationContent('tr', { ...base, kind: 'place', placeName: 'Ev', distanceKm: 93, lateMinutes: 4 });
  assert.equal(c.subtitle, 'Dulkadiroğlu (Kahramanmaraş) · 93 km uzakta');
});

test('düzeltme: eski → yeni büyüklük, kaynağın düzelttiği', () => {
  const c = buildNotificationContent('tr', {
    kind: 'correction', magnitude: 1.17, previousMagnitude: 2.0, depth: 15, place: 'Greece',
    hhmm: '16:09', provider: 'NOA', placeName: 'Seyahat', distanceKm: 64
  });
  assert.equal(c.title, '🟢 Seyahat yakınındaki deprem güncellendi');
  assert.equal(c.subtitle, 'M2.0 → M1.2 · 64 km uzakta');
  assert.match(c.body, /^Greece · 16:09 · NOA\nNOA büyüklüğü düzeltti\./);
});

test('dünya geneli ve artçı: renk büyüklükten gelir', () => {
  const world = buildNotificationContent('tr', {
    kind: 'world_major', magnitude: 6.8, depth: 30, place: 'Near East Coast of Honshu, Japan',
    hhmm: '15:04', provider: 'USGS', hasSavedPlaces: true
  });
  assert.equal(world.title, '🔴 M6.8 · Dünyada büyük deprem');
  assert.equal(world.subtitle, 'Near East Coast of Honshu, Japan');
  assert.match(world.body, /^15:04 · 30 km derinlik · USGS\nKayıtlı yerlerinden uzakta/);
  const after = buildNotificationContent('tr', {
    kind: 'aftershock', magnitude: 3.1, depth: 8, place: 'Sındırgı (Balıkesir)', hhmm: '15:04',
    provider: 'AFAD', distanceKm: 12, watchMagnitude: 4.8
  });
  assert.equal(after.title, '🟢 M3.1 · Olası artçı deprem');
  assert.equal(after.subtitle, 'Sındırgı (Balıkesir) · ana depreme 12 km');
  assert.match(after.body, /Takip ettiğin M4\.8 depremin bölgesinde\./);
});

test('henüz yer kaydetmemiş kullanıcı: başlık "Deprem"; renk yalnız yeşil/turuncu/kırmızı', () => {
  const c = buildNotificationContent('tr', {
    kind: 'regular', magnitude: 4.2, depth: 8, place: 'Sındırgı (Balıkesir)', hhmm: '15:04', provider: 'AFAD'
  });
  assert.equal(c.title, '🟠 M4.2 · Deprem');
  assert.equal(c.subtitle, 'Sındırgı (Balıkesir)');
  assert.equal(c.body, '15:04 · 8 km derinlik · AFAD');
  for (const magnitude of [1, 3.9, 4, 5.9, 6, 8]) {
    const title = buildNotificationContent('tr', { ...base, kind: 'regular', magnitude }).title;
    assert.ok(!title.includes('🟡'), `M${magnitude}: sarı kullanılmaz`);
  }
});

test('sade biçim: başlıkta büyüklük ve yer, tek satır gövde, alt başlık yok', () => {
  const place = buildNotificationContent('tr', {
    ...base, kind: 'place', magnitude: 2.8, place: 'Saimbeyli (Adana)', placeName: 'Ev', distanceKm: 21.6, style: 'compact'
  });
  assert.equal(place.title, '🟢 M2.8 · Saimbeyli (Adana)');
  assert.equal(place.subtitle, '');
  assert.equal(place.body, 'Ev: 22 km uzakta · 15:04');
  const strong = buildNotificationContent('tr', {
    ...base, kind: 'place', magnitude: 5.6, place: 'Pütürge (Malatya)', placeName: 'Ev', distanceKm: 20,
    assemblyCta: true, lateMinutes: 12, style: 'compact'
  });
  assert.equal(strong.body, 'Ev: 20 km uzakta · 15:04 · 12 dk önce\nToplanma alanları için dokun.');
  const world = buildNotificationContent('en', { ...base, kind: 'world_major', magnitude: 7.1, place: 'Tonga', style: 'compact' });
  assert.equal(world.title, '🔴 M7.1 · Tonga');
  assert.equal(world.body, 'Major earthquake worldwide · 15:04');
});

test('14 dilin hepsi, iki biçimde de eksiksiz metin üretir; tanınmayan dil İngilizceye düşer', () => {
  const kinds = [
    { kind: 'place', placeName: 'Home', distanceKm: 20, lateMinutes: 30 },
    { kind: 'place', placeName: 'Home', distanceKm: 20, magnitude: 5.5, assemblyCta: true },
    { kind: 'correction', placeName: 'Home', distanceKm: 20, previousMagnitude: 2.4 },
    { kind: 'correction', previousMagnitude: 2.4 },
    { kind: 'world_major', magnitude: 7 },
    { kind: 'aftershock', distanceKm: 5, watchMagnitude: 5 },
    { kind: 'felt', distanceKm: 10, isNearbyMatch: true },
    { kind: 'regular' }
  ];
  const langs = ['tr', 'en', 'de', 'es', 'fr', 'it', 'ja', 'ru', 'ar', 'el', 'pt-br', 'id', 'ko', 'zh-hans'];
  for (const lang of langs) {
    for (const style of ['detailed', 'compact']) {
      for (const extra of kinds) {
        const c = buildNotificationContent(lang, { ...base, magnitude: 3.2, style, ...extra });
        for (const [field, value] of Object.entries(c)) {
          if (field === 'subtitle' && style === 'compact' && extra.kind !== 'correction') continue;
          assert.ok(value && !/undefined|NaN|null/.test(value), `${lang}/${style}/${extra.kind}/${field}: ${value}`);
        }
      }
    }
  }
  assert.match(buildNotificationContent('ko', { ...base, kind: 'regular' }).title, /지진$/);
  assert.match(buildNotificationContent('zh-Hans', { ...base, kind: 'regular' }).title, /地震$/);
  assert.match(buildNotificationContent('pt-BR', { ...base, kind: 'regular' }).title, /Terremoto$/);
  assert.equal(buildNotificationContent('xx', { ...base, kind: 'regular' }).title, '🟢 M1.6 · Earthquake');
});

test('hissedilme ölçeği eşikleri', () => {
  assert.deepEqual([1.9, 2, 3.4, 3.5, 4.9, 5, 6.4, 6.5].map(feltLevel), [0, 1, 1, 2, 2, 3, 3, 4]);
});

// MARK: - AFAD geç yayımı

test('AFAD kaydı 60 dakika, diğerleri 15 dakika aday kalır', () => {
  assert.equal(pushMaxEventAgeMs({ provider: 'AFAD' }), 60 * 60 * 1000);
  assert.equal(pushMaxEventAgeMs({ provider: 'EMSC' }), 15 * 60 * 1000);
  const now = Date.parse('2026-09-10T12:40:00Z');
  const quakes = [
    { id: 'afad-728279', provider: 'AFAD', magnitude: 1.6, date: '2026-09-10T12:04:21Z', lat: 37.6, lon: 36.9, depth: 7, title: 'x' },
    { id: 'emsc-1', provider: 'EMSC', magnitude: 1.6, date: '2026-09-10T12:04:21Z', lat: 37.6, lon: 36.9, depth: 7, title: 'x' }
  ];
  // Dulkadiroğlu depremi 36 dakika sonra ilk kez görülürse artık aday.
  assert.deepEqual(selectFreshQuakes(quakes, now, pushMaxEventAgeMs, 12).map(q => q.id), ['afad-728279']);
});

// MARK: - Simgeler

test('eski emojili yerler en yakın simgeye taşınır, bilinmeyen "other" olur', () => {
  assert.equal(normalizePlaceIcon('house'), 'house');
  assert.equal(normalizePlaceIcon('🏡'), 'house');
  assert.equal(normalizePlaceIcon('🏙️'), 'city');
  assert.equal(normalizePlaceIcon('❤️'), 'family');
  assert.equal(normalizePlaceIcon('🌎'), 'other');
  assert.equal(normalizePlaceIcon(undefined), 'other');
  assert.equal(normalizePlaceIcon('<script>'), 'other');
});

// MARK: - Büyüklük düzeltmesi

const sentAt = Date.parse('2026-09-10T13:12:20Z');
const noaFirst = { id: 'noa-rtnkl', provider: 'NOA', magnitude: 2.002353463, depth: 15, lat: 38.2, lon: 21.7, date: '2026-09-10T13:09:45Z', sentAt, corrections: 0 };
const noaNow = { ...noaFirst, magnitude: 1.17442083, title: 'Greece' };
delete noaNow.sentAt; delete noaNow.corrections;
const seyahat = { id: 'p', name: 'Seyahat', icon: 'travel', lat: 38.5, lon: 22.2, radiusKm: 145, minMagnitude: 2 };
const placePrefs = (places, extra = {}) => ({ places, tzOffset: 180, lang: 'tr', notified: [], registeredAt: 1, ...extra });

test('NOA M2.0 → M1.17: ilk hâli alan cihaz düzeltme alır', () => {
  const later = sentAt + 30 * 60000;
  const [revision] = findMagnitudeRevisions([noaFirst], [noaNow], later);
  assert.ok(revision, '0.3 üstü değişim düzeltme adayı');
  const decision = magnitudeRevisionDecision(revision.snapshot, revision.current, placePrefs([seyahat]), later);
  assert.equal(decision?.kind, 'correction');
  assert.equal(decision.match.placeName, 'Seyahat');
});

test('küçük oynama, eski bildirim ve düzeltme sınırı düzeltme üretmez', () => {
  const later = sentAt + 30 * 60000;
  assert.equal(findMagnitudeRevisions([noaFirst], [{ ...noaNow, magnitude: 2.2 }], later).length, 0);
  assert.equal(findMagnitudeRevisions([noaFirst], [noaNow], sentAt + 4 * 3600000).length, 0);
  assert.equal(findMagnitudeRevisions([{ ...noaFirst, corrections: 2 }], [noaNow], later).length, 0);
});

test('yukarı revizyon: ilk hâlde eşiğin altında kalan cihaz olayı ilk kez duyar', () => {
  const later = sentAt + 5 * 60000;
  const snapshot = { ...noaFirst, magnitude: 2.8 };
  const current = { ...noaNow, magnitude: 3.2 };
  const threshold3 = placePrefs([{ ...seyahat, minMagnitude: 3 }]);
  const decision = magnitudeRevisionDecision(snapshot, current, threshold3, later);
  assert.equal(decision?.kind, 'new');
  assert.equal(magnitudeRevisionDecision(snapshot, current, placePrefs([{ ...seyahat, lat: 0, lon: 0 }]), later), null);
});

// MARK: - Bildirim yükü

const device = {
  key: 'k', token: 't', premiumExpiresAt: 0,
  prefs: placePrefs([seyahat], { notificationSound: 'bildirim.caf', criticalAlertsEnabled: true })
};

test('yük: alt başlık, simge için mutable-content, kritik ses yerin eşiğinde', () => {
  const q = { id: 'afad-1', provider: 'AFAD', title: 'Pütürge (Malatya)', magnitude: 5.4, depth: 9, lat: 38.2, lon: 38.9, date: new Date().toISOString() };
  const match = { reason: 'place', placeName: 'Annemler', placeIcon: 'family', distanceKm: 38, placeCriticalMagnitude: 5 };
  const message = buildQuakeMessage(device, q, match, Date.now());
  const payload = message.apns.payload;
  assert.equal(payload.aps.alert.title, '🟠 M5.4 · Annemler yakınında güçlü deprem');
  assert.equal(payload.aps.alert.subtitle, 'Pütürge (Malatya) · 38 km uzakta');
  assert.equal(payload.aps['mutable-content'], 1);
  assert.equal(payload.placeIcon, 'family');
  assert.equal(payload.openTarget, 'assembly', 'Türkiye içindeki güçlü deprem toplanma alanlarını açar');
  assert.equal(payload.aps.sound.critical, true);
  assert.equal(payload.aps.sound.name, 'bildirim.caf', 'kritik ses seçmemiş (eski) istemci olağan sesle çalar');
});

test('kritik uyarı kullanıcının seçtiği kritik sesi çalar; olağan bildirim etkilenmez', () => {
  const withCritical = {
    ...device,
    prefs: { ...device.prefs, criticalNotificationSound: 'sismik_critical_siren.caf' }
  };
  const q = { id: 'afad-2', provider: 'AFAD', title: 'Pütürge (Malatya)', magnitude: 5.4, depth: 9, lat: 38.2, lon: 38.9, date: new Date().toISOString() };
  const critical = buildQuakeMessage(withCritical, q, { reason: 'place', placeName: 'Annemler', distanceKm: 38, placeCriticalMagnitude: 5 }, Date.now());
  assert.equal(critical.apns.payload.aps.sound.name, 'sismik_critical_siren.caf');
  const regular = buildQuakeMessage(withCritical, { ...q, magnitude: 4.1 }, { reason: 'place', placeName: 'Annemler', distanceKm: 38, placeCriticalMagnitude: 5 }, Date.now());
  assert.equal(regular.apns.payload.aps.sound, 'bildirim.caf');
  // Tanınmayan kritik ad olağan sese düşer.
  const bogus = { ...device, prefs: { ...device.prefs, criticalNotificationSound: 'x.caf' } };
  assert.equal(buildQuakeMessage(bogus, q, { reason: 'place', placeName: 'A', distanceKm: 3, placeCriticalMagnitude: 5 }, Date.now()).apns.payload.aps.sound.name, 'bildirim.caf');
});

test('sade biçimi seçen cihaza alt başlıksız bildirim gider', () => {
  const compact = { ...device, prefs: { ...device.prefs, notificationStyle: 'compact' } };
  const q = { id: 'afad-3', provider: 'AFAD', title: 'Saimbeyli (Adana)', magnitude: 2.8, depth: 7, lat: 37.9, lon: 36.1, date: new Date().toISOString() };
  const alert = buildQuakeMessage(compact, q, { reason: 'place', placeName: 'Ev', distanceKm: 21 }, Date.now()).apns.payload.aps.alert;
  assert.equal(alert.title, '🟢 M2.8 · Saimbeyli (Adana)');
  assert.equal('subtitle' in alert, false);
  assert.equal(alert.body, `Ev: 21 km uzakta · ${alert.body.slice(-5)}`);
});

test('düzeltme yükü sessizdir ve eski bildirimin yerine geçer', () => {
  const q = { id: 'noa-rtnkl', provider: 'NOA', title: 'Greece', magnitude: 1.17, depth: 15, lat: 38.2, lon: 21.7, date: new Date().toISOString() };
  const match = { reason: 'place', placeName: 'Seyahat', placeIcon: 'travel', distanceKm: 64 };
  const message = buildQuakeMessage(device, q, match, Date.now(), { previousMagnitude: 2.0 });
  assert.equal(message.apns.headers['apns-collapse-id'], 'noa-rtnkl');
  assert.equal(message.apns.payload.aps.sound, undefined);
  assert.equal(message.apns.payload.aps['interruption-level'], 'passive');
  assert.equal(message.apns.payload.notificationKind, 'correction');
  assert.equal(message.apns.payload.openTarget, undefined);
});

// MARK: - Kritik uyarı: yer başına kullanıcı eşiği

test('kritik uyarı artık M5+ için otomatik değil: yalnızca yerin eşiğinde', () => {
  const on = { criticalAlertsEnabled: true };
  assert.equal(isCriticalDelivery(on, { magnitude: 6.2 }, { reason: 'place' }), false, 'eşik seçilmemiş yer');
  assert.equal(isCriticalDelivery(on, { magnitude: 5.4 }, { reason: 'place', placeCriticalMagnitude: 6 }), false, 'eşiğin altı');
  assert.equal(isCriticalDelivery(on, { magnitude: 6.0 }, { reason: 'place', placeCriticalMagnitude: 6 }), true, 'eşik dahil');
  assert.equal(isCriticalDelivery({ criticalAlertsEnabled: false }, { magnitude: 7 }, { reason: 'place', placeCriticalMagnitude: 5 }), false, 'iOS izni yok');
  assert.equal(isCriticalDelivery(on, { magnitude: 7.5 }, { reason: 'world_major' }), false, 'dünya geneli kritik değil');
});

test('kritik eşik temizlenir: alt sınır 3, yer eşiğinin altına inemez, yoksa alan yazılmaz', () => {
  const base = { id: 'p', name: 'Ev', icon: 'house', lat: 41, lon: 29, radiusKm: 50, minMagnitude: 4 };
  const [none, low, below, high] = sanitizeDevicePlaces([
    base,
    { ...base, id: 'a', minMagnitude: 1, criticalMagnitude: 2 },
    { ...base, id: 'b', criticalMagnitude: 3.5 },
    { ...base, id: 'c', criticalMagnitude: 12 }
  ]);
  assert.equal('criticalMagnitude' in none, false, 'Firestore undefined kabul etmez');
  assert.equal(low.criticalMagnitude, 3);
  assert.equal(below.criticalMagnitude, 4, 'bildirim eşiğinin altında kritik eşik anlamsız');
  assert.equal(high.criticalMagnitude, 9);
});

test('eşleşme yerin kritik eşiğini taşır; en yakın yerin eşiği geçerli', () => {
  const home = { id: 'h', name: 'Ev', icon: 'house', lat: 41.0, lon: 29.0, radiusKm: 300, minMagnitude: 3, criticalMagnitude: 5.5 };
  const far = { id: 'f', name: 'Yazlık', icon: 'beach', lat: 39.0, lon: 27.0, radiusKm: 400, minMagnitude: 3, criticalMagnitude: 4 };
  const match = notificationMatch(
    { id: 'q', provider: 'AFAD', title: 'x', magnitude: 5.0, depth: 10, lat: 40.9, lon: 29.1, date: new Date().toISOString() },
    { places: [far, home], tzOffset: 180, lang: 'tr', notified: [] }
  );
  assert.equal(match.placeName, 'Ev');
  assert.equal(match.placeCriticalMagnitude, 5.5);
  assert.equal(isCriticalDelivery({ criticalAlertsEnabled: true }, { magnitude: 5.0 }, match), false);
});
