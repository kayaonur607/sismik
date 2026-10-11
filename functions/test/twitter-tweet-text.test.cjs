const test = require('node:test');
const assert = require('node:assert/strict');
const {
  buildQuakeTweetText,
  buildQuakeCardSVG,
  magnitudeTweetEmoji,
  isQuakeEligibleForTwitter,
  isQuakePreviouslyTweeted,
  toQuakeFingerprint,
  isMeaningfulQuakeRevision,
  buildQuakeRevisionReplyText,
  describeTweetLocation,
  tweetLength
} = require('../lib/worker-utils');

const STUB_ASSETS = {
  appIconBase64: 'AA==',
  storeBadgeBase64: 'AA==',
  worldMap: { path: 'M0 0L1 1', width: 460, height: 300, scale: 73.21127382227186, translate: [230, 145.9399441666667] }
};

function quake(overrides = {}) {
  return {
    id: 'afad-1',
    provider: 'AFAD',
    title: 'Seferihisar (İzmir)',
    magnitude: 4.2,
    depth: 8,
    lat: 38.2,
    lon: 26.8,
    date: '2026-07-15T12:00:00.000Z',
    closestCity: 'İzmir',
    district: 'Seferihisar',
    country: 'Türkiye',
    magType: 'ml',
    ...overrides
  };
}

test('magnitude emoji tiers follow the app color families (green / orange / red)', () => {
  assert.equal(magnitudeTweetEmoji(3.9), '🟢');
  assert.equal(magnitudeTweetEmoji(4.0), '🟠');
  assert.equal(magnitudeTweetEmoji(4.9), '🟠');
  assert.equal(magnitudeTweetEmoji(5.0), '🟠');
  assert.equal(magnitudeTweetEmoji(5.9), '🟠');
  assert.equal(magnitudeTweetEmoji(6.0), '🔴');
});

test('an AFAD Türkiye record: one English template, provider district/province names', () => {
  const text = buildQuakeTweetText(quake());
  assert.match(text, /^📢 #Earthquake$/m);
  assert.match(text, /^🟠 M4\.2 \(ML\) — Seferihisar, İzmir, Türkiye$/m);
  assert.match(text, /Source: #AFAD/);
  assert.match(text, /15 July 2026 · 🕒 12:00 UTC/);
  assert.match(text, /#Seferihisar #İzmir #Türkiye #Earthquake #Deprem/);
  assert.doesNotMatch(text, /Kaynak|Derinlik|TSİ/);
  assert.doesNotMatch(text, /https?:\/\//);
  assert.ok(Array.from(text).length <= 280);
});

test('a USGS world record keeps the provider English title', () => {
  const text = buildQuakeTweetText(quake({
    id: 'usgs-1', provider: 'USGS', title: '145 km N of Caluula, Somalia', magnitude: 6.4,
    lat: 13.2654, lon: 50.5425, country: null, closestCity: null, district: null
  }));
  assert.match(text, /^🚨 #Earthquake$/m);
  assert.match(text, /^🔴 M6\.4 \(ML\) — 145 km N of Caluula, Somalia$/m);
  assert.match(text, /#Caluula #Somalia #Earthquake$/m);
  assert.doesNotMatch(text, /#Deprem/, 'Türkiye dışında #Deprem yok');
  assert.doesNotMatch(text, /[\u{1F1E6}-\u{1F1FF}]/u, 'bayrak emojisi yok');
});

test('a coarse EMSC region is named from coordinates', () => {
  const location = describeTweetLocation(quake({
    id: 'emsc-1', provider: 'EMSC', title: 'CENTRAL TURKEY', lat: 37.83, lon: 36.21,
    country: null, closestCity: null, district: null
  }));
  assert.equal(location.label, '69 km WNW of Kahramanmaraş, Türkiye');
  assert.equal(location.inTurkiye, true);
});

test('a remote EMSC region with no nearby place falls back to a readable region name', () => {
  const location = describeTweetLocation(quake({
    id: 'emsc-2', provider: 'EMSC', title: 'NORTHERN MID-ATLANTIC RIDGE', lat: 30, lon: -42,
    country: null, closestCity: null, district: null
  }));
  assert.equal(location.label, 'Northern Mid-Atlantic Ridge');
});

test('a long worldwide post with an extreme provider/title combo still fits the X limit', () => {
  const text = buildQuakeTweetText(quake({
    id: 'emsc-long-world',
    provider: 'EUROPEAN-MEDITERRANEAN-SEISMOLOGICAL-CENTRE',
    title: 'A very long earthquake location description near a remote island region, Federated States of Micronesia',
    magnitude: 7.1,
    depth: 640,
    lat: -10.123,
    lon: -179.987,
    country: 'Federated States of Micronesia',
    closestCity: null,
    district: null
  }));
  assert.match(text, /#Earthquake/);
  assert.ok(Array.from(text).length <= 280);
});

test('an AFAD Türkiye record without district/province is named from coordinates', () => {
  const location = describeTweetLocation(quake({ closestCity: null, district: null }));
  assert.match(location.label, /of İzmir, Türkiye$/);
});

test('a world record keeps the provider UTC time', () => {
  const text = buildQuakeTweetText(quake({
    id: 'usgs-vanuatu', provider: 'USGS', title: 'Vanuatu', magnitude: 6.0,
    lat: -19.2675, lon: 168.2841, country: 'Vanuatu', closestCity: null, district: null,
    date: '2026-08-28T08:32:35.971Z'
  }));
  assert.match(text, /28 August 2026 · 🕒 08:32 UTC/);
});

test('major and long regional posts stay within the X character limit', () => {
  const text = buildQuakeTweetText(quake({
    magnitude: 5.8,
    depth: 123,
    closestCity: 'Kahramanmaraş Büyükşehir Belediyesi',
    district: 'Marmara Ereğlisi Çok Uzun İlçe Adı',
    magType: 'mw'
  }));
  assert.match(text, /^🚨 #Earthquake$/m);
  assert.match(text, /Stay away from damaged buildings/);
  // X bağlantıyı 23 karakter sayar.
  assert.ok(tweetLength(text) <= 280);
  assert.match(text, /📲 Live alerts on Sismik: https:\/\/apps\.apple\.com\/app\/id6787776158/);
});

test('only Türkiye M4.8+ posts carry the App Store link: linked posts cost 13x on the X API', () => {
  for (const magnitude of [3.0, 4.7]) {
    assert.doesNotMatch(buildQuakeTweetText(quake({ magnitude })), /https?:\/\//);
  }
  for (const magnitude of [4.8, 5.0, 7.2]) {
    assert.match(buildQuakeTweetText(quake({ magnitude })), /https:\/\/apps\.apple\.com\/app\/id6787776158$/m);
  }
  for (const magnitude of [5.0, 7.2]) {
    assert.doesNotMatch(buildQuakeTweetText(quake({
      id: 'usgs-world', provider: 'USGS', title: 'Indonesia', country: 'Indonesia',
      lat: -2.5, lon: 138.1, closestCity: null, district: null, magnitude
    })), /https?:\/\//);
  }
});

test('Turkey Twitter eligibility starts at M3.0 independently from push preferences', () => {
  assert.equal(isQuakeEligibleForTwitter(quake({ magnitude: 2.9 })), false);
  assert.equal(isQuakeEligibleForTwitter(quake({ magnitude: 3.0 })), true);
});

test('worldwide Twitter eligibility starts at M5.5', () => {
  const world = { ...quake(), provider: 'USGS', country: null, lat: -2.5, lon: 138.1 };
  assert.equal(isQuakeEligibleForTwitter({ ...world, magnitude: 5.4 }), false);
  assert.equal(isQuakeEligibleForTwitter({ ...world, magnitude: 5.5 }), true);
});

test('eligibility: Türkiye M3.0+, everywhere else M5.5+, whatever the agency', () => {
  // Türkiye'de hangi ajans olursa olsun M3.0+ (EMSC'nin "CENTRAL TURKEY" kaydı da).
  assert.equal(isQuakeEligibleForTwitter({ provider: 'EMSC', lat: 37.8, lon: 36.2, magnitude: 3.0 }), true);
  assert.equal(isQuakeEligibleForTwitter({ provider: 'AFAD', lat: 38.2, lon: 26.8, magnitude: 2.9 }), false);
  // Marmara Denizi: kara poligonunun dışında ama Türkiye kıyısına yakın.
  assert.equal(isQuakeEligibleForTwitter({ provider: 'EMSC', lat: 40.8, lon: 28.6, magnitude: 3.2 }), true);
  // Türkiye dışı komşu bölge (Santorini, Kafkasya): dünya eşiği.
  assert.equal(isQuakeEligibleForTwitter({ provider: 'NOA', lat: 36.3, lon: 25.4, magnitude: 5.4 }), false);
  assert.equal(isQuakeEligibleForTwitter({ provider: 'EMSC', lat: 41.4, lon: 43.5, magnitude: 4.0 }), false);
  // AFAD'ın ülke=Türkiye dediği kayıt Türkiye sayılır.
  assert.equal(isQuakeEligibleForTwitter({ provider: 'AFAD', country: 'Türkiye', lat: 36.0, lon: 29.0, magnitude: 3.0 }), true);
  // Dünya: M5.5+.
  assert.equal(isQuakeEligibleForTwitter({ provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 5.4 }), false);
  assert.equal(isQuakeEligibleForTwitter({ provider: 'USGS', lat: 35.6, lon: 139.7, magnitude: 5.5 }), true);
});

function santorini(overrides = {}) {
  return quake({
    id: 'afad-728784',
    title: 'Ege Denizi, Santurin Adası (Thira) - [179.05 km] Bodrum (Muğla)',
    magnitude: 3.4,
    depth: 12,
    lat: 36.34433,
    lon: 25.43267,
    closestCity: 'Muğla',
    district: null,
    country: null,
    ...overrides
  });
}

test('an AFAD sea record (no country) is named from coordinates, never as Türkiye or Muğla', () => {
  const text = buildQuakeTweetText(santorini());
  assert.doesNotMatch(text, /Türkiye|Muğla|Bodrum|Ege Denizi/);
  assert.match(text, /^🟢 M3\.4 \(ML\) — \d+ km [NSEW]{1,3} of [^,]+, Greece$/m);
  assert.doesNotMatch(text, /#Deprem/);
});

test('an AFAD record in a named foreign country keeps AFAD place names with an English country', () => {
  const text = buildQuakeTweetText(santorini({
    id: 'afad-727249',
    title: 'Akhalkalaki, Samtskhe-Javakheti (Gürcistan) - [46.11 km] Çıldır (Ardahan)',
    country: 'Gürcistan',
    closestCity: 'Ardahan',
    lat: 41.4,
    lon: 43.5,
    magnitude: 4.1
  }));
  assert.match(text, /— Akhalkalaki, Samtskhe-Javakheti, Georgia$/m);
  assert.doesNotMatch(text, /Türkiye|Ardahan|Gürcistan/);
});

test('the card for an AFAD record outside Türkiye is English and never shows the nearest Turkish province', () => {
  const svg = buildQuakeCardSVG(santorini(), STUB_ASSETS);
  assert.doesNotMatch(svg, />Muğla</);
  assert.match(svg, />Greece</);
  assert.match(svg, />Depth 12 km · [^<]+ UTC · Source: AFAD</);
});

test('a Türkiye AFAD record keeps the provider district as the headline', () => {
  const text = buildQuakeTweetText(quake({
    title: 'Beytüşşebap (Şırnak)', closestCity: 'Şırnak', district: 'Beytüşşebap', magnitude: 3.2
  }));
  assert.match(text, /^🟢 M3\.2 \(ML\) — Beytüşşebap, Şırnak, Türkiye$/m);
});

test('a successful physical quake fingerprint suppresses another provider copy', () => {
  const original = quake({ id: 'afad-original', provider: 'AFAD', magnitude: 3.2 });
  const fingerprint = toQuakeFingerprint(original);
  assert.ok(fingerprint);
  const copy = quake({
    id: 'emsc-copy',
    provider: 'EMSC',
    magnitude: 3.3,
    date: '2026-07-15T12:00:20.000Z',
    lat: 38.21,
    lon: 26.81
  });
  assert.equal(isQuakePreviouslyTweeted(copy, new Set(), [fingerprint]), true);
});

test('a delayed cross-tick NOA report of the same physical quake is still caught as a duplicate', () => {
  // Gerçek örnek: EMSC bir depremi hemen tivitliyor, NOA aynı depremi birkaç
  // dakika sonra farklı bir scheduledPushCheck turunda bildiriyor — bu ikisi
  // aynı turda değilse deduplicateQuakes'in 90sn/90km kümelemesi devreye
  // girmez, sadece parmak izi kontrolü (isLikelyCrossProviderDuplicate)
  // çalışır. O yüzden eşikleri deduplicateQuakes'ten daha dar tutmamak lazım.
  const original = quake({ id: 'emsc-original', provider: 'EMSC', magnitude: 4.5, lat: 38.2, lon: 26.8 });
  const fingerprint = toQuakeFingerprint(original);
  assert.ok(fingerprint);
  const delayedCopy = quake({
    id: 'noa-copy',
    provider: 'NOA',
    magnitude: 4.6,
    date: '2026-07-15T12:01:40.000Z', // 100s sonra — eski 60s eşiğini aşardı
    lat: 39.0, // ~89km uzakta — eski 50km eşiğini de aşardı
    lon: 26.9
  });
  assert.equal(isQuakePreviouslyTweeted(delayedCopy, new Set(), [fingerprint]), true);
});

test('a failed/unpersisted quake remains eligible for retry', () => {
  assert.equal(isQuakePreviouslyTweeted(quake(), new Set(), []), false);
});

test('magnitude revision below threshold is not meaningful, at/above threshold is', () => {
  const previous = { magnitude: 4.2, depth: 8 };
  assert.equal(isMeaningfulQuakeRevision(previous, { magnitude: 4.35, depth: 8 }), false);
  assert.equal(isMeaningfulQuakeRevision(previous, { magnitude: 4.4, depth: 8 }), true);
});

test('depth revision uses a relative (percentage) threshold, not absolute km', () => {
  const previous = { magnitude: 4.2, depth: 10 };
  assert.equal(isMeaningfulQuakeRevision(previous, { magnitude: 4.2, depth: 11.5 }), false);
  assert.equal(isMeaningfulQuakeRevision(previous, { magnitude: 4.2, depth: 12.5 }), true);
});

test('revision reply is English and mentions only the fields that actually changed', () => {
  const text = buildQuakeRevisionReplyText(quake({ magnitude: 4.6 }), { magnitude: 4.2, depth: 8 });
  assert.equal(text, '🔄 Update: Magnitude revised from M4.2 to M4.6. (Source: AFAD)');
});

test('world revision reply is in English and mentions depth when it changed', () => {
  const q = quake({
    id: 'usgs-3',
    provider: 'USGS',
    title: 'Indonesia',
    magnitude: 6.0,
    depth: 50,
    lat: -2.5,
    lon: 138.1
  });
  const text = buildQuakeRevisionReplyText(q, { magnitude: 5.6, depth: 30 });
  assert.match(text, /^🔄 Update: Magnitude revised from M5\.6 to M6\.0\. Depth updated from 30 km to 50 km\. \(Source: USGS\)$/);
});

test('the card SVG is English and embeds magnitude, place, brand assets and data source', () => {
  const svg = buildQuakeCardSVG(quake(), STUB_ASSETS);
  assert.match(svg, /<svg /);
  assert.match(svg, />M4\.2</);
  assert.match(svg, />Seferihisar</);
  assert.match(svg, />İzmir, Türkiye</);
  assert.match(svg, />Sismik</);
  assert.match(svg, />Earthquake &amp; Emergency</);
  assert.match(svg, /base64,AA==/);
  assert.match(svg, /Source: AFAD/);
});

test('a long district/province name never overlaps the CTA cluster (App Store badge + logo)', () => {
  // Gerçek örnek: uzun il/ilçe adları başlık/alt satırın CTA kümesine
  // (App Store rozeti + Sismik logosu) taşmasına yol açabilir. Karakter
  // bütçesi dinamik olarak hesaplanıp "…" ile kesiliyor mu, doğrula.
  const svg = buildQuakeCardSVG(quake({
    district: 'Marmara Ereğlisi Çok Uzun İlçe Adı Buraya Kadar',
    closestCity: 'Kahramanmaraş Büyükşehir Belediyesi Alanı'
  }), STUB_ASSETS);
  const headlineMatch = svg.match(/<text x="80" y="526"[^>]*>([^<]*)<\/text>/);
  assert.ok(headlineMatch, 'headline metni bulunamalı');
  assert.ok(headlineMatch[1].length <= 20, `başlık çok uzun: "${headlineMatch[1]}"`);
  assert.match(headlineMatch[1], /…$/);
});

test('the world card SVG uses the country as headline and full title as subtitle', () => {
  const svg = buildQuakeCardSVG(quake({
    id: 'usgs-4',
    provider: 'USGS',
    title: '61 km S of Whites City, New Mexico',
    magnitude: 5.1,
    lat: 32.0,
    lon: -104.5,
    country: null,
    closestCity: null,
    district: null
  }), STUB_ASSETS);
  assert.match(svg, />New Mexico</);
  assert.match(svg, />61 km S of Whites City, New Mexico</);
  assert.match(svg, />Earthquake &amp; Emergency</);
});

test('a remote EMSC region shows the readable region name on the card', () => {
  const svg = buildQuakeCardSVG(quake({
    id: 'emsc-2',
    provider: 'EMSC',
    title: 'WESTERN XIZANG',
    magnitude: 5.0,
    lat: 33.2,
    lon: 86.9,
    country: null,
    closestCity: null,
    district: null
  }), STUB_ASSETS);
  assert.match(svg, />Western Xizang</);
});
