const test = require('node:test');
const assert = require('node:assert/strict');
const {
  validateInfoCard,
  parseInfoCards,
  publicInfoCards,
  upsertInfoCard,
  infoCardPushMessages
} = require('../lib/info-cards');
const { validateAutomationRule } = require('../lib/worker-utils');

const card = {
  id: '2026-10-hazirlik',
  audience: 'all',
  minVersion: '2.1.2',
  startAt: '2026-10-01T09:00:00+03:00',
  endAt: '2026-10-15T09:00:00+03:00',
  icon: 'sparkles',
  tint: 'orange',
  title: { tr: 'Yeni', en: 'New' },
  subtitle: { tr: 'Açıklama', en: 'Description' },
  items: [{ icon: 'bell.fill', title: { tr: 'A', en: 'A' }, body: { tr: 'B', en: 'B' } }],
  action: { label: { tr: 'Aç', en: 'Open' }, url: 'sismik://risk' },
  push: { title: { tr: 'Başlık', en: 'Title' }, body: { tr: 'Metin', en: 'Body' } }
};

test('geçerli kart kabul edilir', () => {
  assert.deepEqual(validateInfoCard(card), { valid: true, errors: [] });
});

test('hatalı alanlar reddedilir', () => {
  const bad = { ...card, id: 'Büyük Harf', audience: 'vip', minVersion: 'v2', tint: 'pink',
    action: { label: { tr: 'x' }, url: 'javascript:alert(1)' }, endAt: '2026-09-01T00:00:00Z' };
  const { valid, errors } = validateInfoCard(bad);
  assert.equal(valid, false);
  for (const field of ['id', 'audience', 'minVersion', 'tint', 'action.url', 'endAt']) {
    assert.ok(errors.some(e => e.startsWith(field)), `${field} hatası bekleniyordu: ${errors.join(' / ')}`);
  }
});

test('boş kart reddedilir: subtitle ya da items gerekli', () => {
  const { subtitle, items, ...empty } = card;
  assert.equal(validateInfoCard(empty).valid, false);
});

test('tr ya da en olmadan dil nesnesi reddedilir', () => {
  assert.equal(validateInfoCard({ ...card, title: { de: 'Neu' } }).valid, false);
  assert.equal(validateInfoCard({ ...card, title: { tr: 'x', xx: 'y' } }).valid, false);
});

test('bozuk belge metni liste ucunu bozmaz, geçersiz kart atlanır', () => {
  assert.deepEqual(parseInfoCards('{bozuk'), []);
  assert.deepEqual(parseInfoCards(undefined), []);
  const parsed = parseInfoCards(JSON.stringify([card, { id: 'x' }]));
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].id, card.id);
});

test('istemciye push metni gitmez', () => {
  const [pub] = publicInfoCards([card]);
  assert.equal(pub.push, undefined);
  assert.equal(pub.id, card.id);
});

test('upsert aynı kimliği değiştirir', () => {
  const next = upsertInfoCard([card, { ...card, id: 'diger' }], { ...card, tint: 'blue' });
  assert.equal(next.length, 2);
  assert.equal(next.find(c => c.id === card.id).tint, 'blue');
});

test('push metinleri otomasyon mesajlarına çevrilir', () => {
  assert.deepEqual(infoCardPushMessages(card), {
    tr: { title: 'Başlık', body: 'Metin' },
    en: { title: 'Title', body: 'Body' }
  });
});

test('otomasyon kuralı infoCardId doğrular', () => {
  const rule = { name: 'x', trigger: 'scheduled', audience: 'all', runAt: Date.now(),
    messages: { tr: { title: 'a', body: 'b' } } };
  assert.equal(validateAutomationRule({ ...rule, infoCardId: card.id }).valid, true);
  assert.equal(validateAutomationRule({ ...rule, infoCardId: '../x' }).valid, false);
});
