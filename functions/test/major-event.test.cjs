const test = require('node:test');
const assert = require('node:assert/strict');
const { nextMajorEvent, majorEventRegion, parseMajorEvent } = require('../lib/major-event');

const now = Date.parse('2026-09-23T10:00:00Z');
const quake = (id, magnitude, extra = {}) => ({
  id, provider: 'AFAD', title: 'Pazarcık (Kahramanmaraş)', magnitude, depth: 10,
  lat: 37.5, lon: 37.1, country: 'Türkiye', date: new Date(now - 5 * 60_000).toISOString(), ...extra
});

test('eşikler: Türkiye M5.5+, dünya M7.0+', () => {
  assert.equal(majorEventRegion(quake('a', 5.4)), null);
  assert.equal(majorEventRegion(quake('a', 5.5)), 'turkiye');
  const chile = quake('c', 6.9, { provider: 'USGS', country: 'Chile', lat: -33, lon: -71 });
  assert.equal(majorEventRegion(chile), null);
  assert.equal(majorEventRegion({ ...chile, magnitude: 7.1 }), 'world');
});

test('olay açılır; aynı olay tekrar gelince referans değişmez (yazım yok)', () => {
  const event = nextMajorEvent(null, [quake('afad-1', 6.2)], now);
  assert.equal(event.id, 'afad-1');
  assert.equal(event.region, 'turkiye');
  assert.equal(event.expires_at - Date.parse(event.date), 72 * 3600_000, 'Türkiye M6+ 72 saat');
  assert.equal(nextMajorEvent(event, [quake('afad-1', 6.2)], now), event);
});

test('ajans kopyası aynı olaydır; resmî ajansın değeri geçerli, revizyon aşağı da günceller', () => {
  const event = nextMajorEvent(null, [quake('afad-1', 5.8)], now);
  // EMSC kopyası AFAD'ın (Türkiye'de resmî) değerini ezmez.
  const copy = nextMajorEvent(event, [quake('emsc-9', 6.1, { provider: 'EMSC', lat: 37.52 })], now);
  assert.equal(copy, event, 'değişiklik yok, yazım yok');
  // AFAD'ın kendi revizyonu yukarı da aşağı da günceller; kimlik korunur.
  const up = nextMajorEvent(event, [quake('afad-1', 6.1)], now);
  assert.equal(up.id, 'afad-1');
  assert.equal(up.magnitude, 6.1);
  assert.equal(up.expires_at - Date.parse(up.date), 72 * 3600_000);
  const down = nextMajorEvent(up, [quake('afad-1', 5.9)], now);
  assert.equal(down.magnitude, 5.9);
});

test('24 Eyl 2026 Şanlıurfa: EMSC M5.6 ile açılan olay AFAD M5.4 gelince 5.4 olur, kapanmaz', () => {
  const emsc = quake('emsc-20260924_0000086', 5.6, { provider: 'EMSC', title: 'EASTERN TURKEY', country: null, lat: 37.47, lon: 38.79 });
  const event = nextMajorEvent(null, [emsc], now);
  assert.equal(event.magnitude, 5.6);
  const afad = quake('afad-729508', 5.4, { title: 'Karaköprü (Şanlıurfa)', lat: 37.42, lon: 38.87, depth: 7 });
  const updated = nextMajorEvent(event, [emsc, afad], now);
  assert.equal(updated.id, 'emsc-20260924_0000086', 'kimlik ve kanal korunur');
  assert.equal(updated.magnitude, 5.4);
  assert.equal(updated.provider, 'AFAD');
  assert.equal(updated.title, 'Karaköprü (Şanlıurfa)');
  // Sonraki turda EMSC'nin farklı değeri AFAD'ı ezmez.
  assert.equal(nextMajorEvent(updated, [{ ...emsc, magnitude: 5.1 }, afad], now), updated);
});

test('daha büyük ayrı olay öncekinin yerini alır, küçüğü almaz; süresi dolan kapanır', () => {
  const first = nextMajorEvent(null, [quake('afad-1', 6.0)], now);
  const far = { lat: 39.9, lon: 32.8, date: new Date(now - 60_000).toISOString() };
  assert.equal(nextMajorEvent(first, [quake('afad-2', 5.6, far)], now), first);
  assert.equal(nextMajorEvent(first, [quake('afad-3', 6.4, far)], now).id, 'afad-3');
  assert.equal(nextMajorEvent(first, [], first.expires_at + 1), null);
});

test('eski katalog kaydı olay açmaz; bozuk alan okunmaz', () => {
  const old = quake('afad-old', 6.5, { date: new Date(now - 7 * 3600_000).toISOString() });
  assert.equal(nextMajorEvent(null, [old], now), null);
  assert.equal(parseMajorEvent('{bozuk', now), null);
  assert.equal(parseMajorEvent(JSON.stringify({ id: 'x', expires_at: now - 1 }), now), null);
});
