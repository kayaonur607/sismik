const test = require('node:test');
const assert = require('node:assert/strict');
const {
  selectFreshQuakes,
  orderQuakesForDelivery
} = require('../lib/worker-utils');

function quake(overrides = {}) {
  return {
    id: 'afad-1',
    provider: 'AFAD',
    title: 'Test',
    magnitude: 4.2,
    depth: 8,
    lat: 39,
    lon: 35,
    date: '2026-07-15T12:00:00.000Z',
    ...overrides
  };
}

/// Aday listesi `limit` ile kırpılıyor. Kırpma işlenmiş kimlikler ELENDİKTEN
/// sonra yapılmazsa, zaten bildirilmiş depremler kotayı doldurur ve henüz
/// bildirilmemiş olan hiç incelenmeden düşer; 15 dakikalık tazelik penceresi
/// dolunca da kalıcı olarak kaybolur.
test('daha önce işlenmiş depremler aday kotasını tüketmez', () => {
  const now = Date.parse('2026-07-15T12:05:00.000Z');
  const processed = [];
  for (let i = 0; i < 12; i++) {
    processed.push(quake({
      id: `islenmis-${i}`,
      magnitude: 2,
      date: new Date(now - (i + 1) * 1000).toISOString()
    }));
  }
  // En eski kayıt: henüz bildirilmemiş ve büyük.
  const yeni = quake({ id: 'yeni', magnitude: 5.4, date: new Date(now - 60_000).toISOString() });

  const excluded = new Set(processed.map(q => q.id));
  const selected = selectFreshQuakes([...processed, yeni], now, 15 * 60_000, 12, excluded);

  assert.deepEqual(selected.map(q => q.id), ['yeni']);
});

/// Kota gerçekten dolduğunda hangi kayıtların düşeceği önemlidir: en küçük
/// sarsıntılar bir M6'yı listeden atmamalı.
test('kota dolduğunda en büyük depremler korunur, en küçükler düşer', () => {
  const now = Date.parse('2026-07-15T12:05:00.000Z');
  const kucukler = [];
  for (let i = 0; i < 12; i++) {
    kucukler.push(quake({
      id: `kucuk-${i}`,
      magnitude: 1.2,
      // Hepsi büyük depremden DAHA YENİ: saf zaman sıralaması onu dışarıda bırakırdı.
      date: new Date(now - (i + 1) * 1000).toISOString()
    }));
  }
  const buyuk = quake({ id: 'buyuk', magnitude: 6.1, date: new Date(now - 120_000).toISOString() });

  const selected = selectFreshQuakes([...kucukler, buyuk], now, 15 * 60_000, 12);

  assert.equal(selected.length, 12);
  assert.ok(selected.some(q => q.id === 'buyuk'), 'M6.1 kayıt kotaya girmeli');
  // Dönen sıralama sözleşmesi değişmez: en yeniden eskiye.
  const times = selected.map(q => new Date(q.date).getTime());
  assert.deepEqual(times, [...times].sort((a, b) => b - a));
});

/// Bir cihaz tek turda yalnızca bir bildirim alır. O tek bildirim, turdaki en
/// yeni deprem değil EN ÖNEMLİ deprem olmalı: art arda gelen küçük bir artçı,
/// ana şoku bastırmamalı.
test('teslim sırası büyüklüğe göre, eşitlikte yeniye göre kurulur', () => {
  const anaSok = quake({ id: 'ana', magnitude: 6.4, date: '2026-07-15T12:00:00.000Z' });
  const artci = quake({ id: 'artci', magnitude: 3.1, date: '2026-07-15T12:01:30.000Z' });
  const digerArtci = quake({ id: 'artci-2', magnitude: 3.1, date: '2026-07-15T12:00:45.000Z' });

  const sirali = orderQuakesForDelivery([artci, digerArtci, anaSok]);

  assert.deepEqual(sirali.map(q => q.id), ['ana', 'artci', 'artci-2']);
});

test('teslim sıralaması girdiyi değiştirmez', () => {
  const girdi = [quake({ id: 'a', magnitude: 3 }), quake({ id: 'b', magnitude: 5 })];
  orderQuakesForDelivery(girdi);
  assert.deepEqual(girdi.map(q => q.id), ['a', 'b']);
});
