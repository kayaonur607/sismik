const test = require('node:test');
const assert = require('node:assert/strict');
const {
  validateAutomationRule,
  shouldRunAutomation,
  isWithinExpiryWindow,
  automationSentKey
} = require('../lib/worker-utils');

const baseRule = {
  name: 'Yenileme hatırlatması',
  trigger: 'subscription_expiring',
  audience: 'premium',
  daysBefore: 7,
  messages: { tr: { title: 'Başlık', body: 'Metin' } }
};

test('geçerli kural kabul edilir', () => {
  assert.equal(validateAutomationRule(baseRule).valid, true);
});

test('eksik ad, tetikleyici veya kitle reddedilir', () => {
  assert.equal(validateAutomationRule({ ...baseRule, name: '' }).valid, false);
  assert.equal(validateAutomationRule({ ...baseRule, trigger: 'nope' }).valid, false);
  assert.equal(validateAutomationRule({ ...baseRule, audience: 'nope' }).valid, false);
});

test('yedek dil olmadan kural reddedilir', () => {
  const r = validateAutomationRule({ ...baseRule, messages: { de: { title: 'a', body: 'b' } } });
  assert.equal(r.valid, false);
  assert.ok(r.errors.some(e => e.includes('Yedek dil')));
});

test('boş başlık veya metin reddedilir', () => {
  assert.equal(validateAutomationRule({ ...baseRule, messages: { tr: { title: '', body: 'x' } } }).valid, false);
  assert.equal(validateAutomationRule({ ...baseRule, messages: { tr: { title: 'x', body: '  ' } } }).valid, false);
});

test('daysBefore sınır dışıysa reddedilir', () => {
  assert.equal(validateAutomationRule({ ...baseRule, daysBefore: -1 }).valid, false);
  assert.equal(validateAutomationRule({ ...baseRule, daysBefore: 61 }).valid, false);
  assert.equal(validateAutomationRule({ ...baseRule, daysBefore: 0 }).valid, true);
});

test('zamanlanmış kural geçerli bir an ister', () => {
  const r = { ...baseRule, trigger: 'scheduled', runAt: 0 };
  assert.equal(validateAutomationRule(r).valid, false);
  assert.equal(validateAutomationRule({ ...r, runAt: Date.now() }).valid, true);
});

test('kapalı kural hiç çalışmaz', () => {
  assert.equal(shouldRunAutomation({ ...baseRule, id: 'x', enabled: false }, Date.now()), false);
});

test('zamanlanmış kural vakti gelmeden çalışmaz, bir kez çalışır', () => {
  const now = Date.now();
  const rule = { ...baseRule, id: 'x', enabled: true, trigger: 'scheduled', runAt: now + 60000 };
  assert.equal(shouldRunAutomation(rule, now), false);
  assert.equal(shouldRunAutomation({ ...rule, runAt: now - 1000 }, now), true);
  assert.equal(shouldRunAutomation({ ...rule, runAt: now - 1000, lastRunAt: now - 500 }, now), false);
});

test('tanınmayan tetikleyici bakım turunda çalışmaz', () => {
  // Kaldırılmış bir tetikleyiciyle Firestore'da kalan eski kural, kod
  // silindiği anda her turda ateşlenmemeli.
  for (const trigger of ['app_version_released', 'bilinmeyen', '']) {
    const rule = { ...baseRule, id: 'x', enabled: true, trigger };
    assert.equal(shouldRunAutomation(rule, Date.now()), false, trigger);
  }
});

test('bitiş penceresi yalnızca hedef günde açılır', () => {
  const DAY = 86400000;
  const now = Date.parse('2026-09-10T12:00:00Z');
  const expires = now + 7 * DAY;
  assert.equal(isWithinExpiryWindow(expires, 7, now), true);
  assert.equal(isWithinExpiryWindow(expires, 7, now - DAY), false);
  assert.equal(isWithinExpiryWindow(expires, 7, now + DAY + 1), false);
});

test('süresi geçmiş abonelik pencereye girmez', () => {
  const now = Date.now();
  assert.equal(isWithinExpiryWindow(now - 1000, 7, now), false);
  assert.equal(isWithinExpiryWindow(NaN, 7, now), false);
});

test('gönderim anahtarı yenilemede değişir, aynı dönemde sabit kalır', () => {
  const a = automationSentKey('r1', 1788000000000);
  assert.equal(a, automationSentKey('r1', 1788000000000));
  assert.notEqual(a, automationSentKey('r1', 1790000000000));
  assert.notEqual(a, automationSentKey('r2', 1788000000000));
});

test('süre sonu kuralı yalnızca bitişi pencereye düşen cihazları okur', async () => {
  const { runAutomationRule } = require('../lib/admin-routes');
  const DAY = 86400000;
  const now = Date.parse('2026-09-12T12:00:00Z');
  const clauses = [];
  const docs = [
    { id: 'premium', ref: { id: 'premium' }, data: () => ({ token: 't1', is_premium: true, premium_expires_at: now + 3 * DAY - 1000 }) },
    { id: 'free', ref: { id: 'free' }, data: () => ({ token: 't2', is_premium: false, premium_expires_at: now + 3 * DAY - 1000 }) }
  ];
  const query = {
    where: (field, op, value) => { clauses.push([field, op, value]); return query; },
    get: async () => ({ empty: false, docs, forEach: fn => docs.forEach(fn) })
  };
  const db = { collection: () => query, batch: () => ({ set: () => {}, update: () => {}, commit: async () => {} }) };
  let sentTo = [];
  const sent = await runAutomationRule(db, async messages => {
    sentTo = messages.map(m => m.token);
    return { successCount: messages.length, failureCount: 0, errorCodes: {} };
  }, { ...baseRule, id: 'r1', enabled: true, daysBefore: 3 }, now);

  assert.deepEqual(clauses, [
    ['premium_expires_at', '>', now + 2 * DAY],
    ['premium_expires_at', '<=', now + 3 * DAY]
  ]);
  assert.deepEqual(sentTo, ['t1'], 'kitle (premium) bellekte süzülmeli');
  assert.equal(sent, 1);
});

test('belgedeki last_run_at, zamanlanmış kuralı tekrar çalıştırmaz', () => {
  const now = Date.now();
  const rule = { ...baseRule, id: 'x', enabled: true, trigger: 'scheduled', runAt: now - 60000 };
  assert.equal(shouldRunAutomation({ ...rule, lastRunAt: now - 30000 }, now), false);
  // Panelde ileri bir ana yeniden zamanlanan kural yeniden çalışabilir.
  assert.equal(shouldRunAutomation({ ...rule, runAt: now - 1000, lastRunAt: now - 30000 }, now), true);
});

test('500+ cihazlı kitlede gönderim kaydı 450’lik partilere bölünür', async () => {
  const { runAutomationRule } = require('../lib/admin-routes');
  const now = Date.parse('2026-09-12T12:00:00Z');
  const docs = Array.from({ length: 1000 }, (_, i) => ({
    id: `d${i}`, ref: { id: `d${i}` }, data: () => ({ token: `t${i}`, product_updates_enabled: true })
  }));
  const query = {
    where: () => query,
    get: async () => ({ empty: false, docs, forEach: fn => docs.forEach(fn) })
  };
  const batches = [];
  const db = {
    collection: () => query,
    batch: () => {
      const ops = [];
      batches.push(ops);
      return { set: () => ops.push('set'), update: () => ops.push('update'), commit: async () => {
        // Gerçek Firestore 500'ü aşan partiyi reddeder.
        if (ops.length > 500) throw new Error('maximum 500 writes allowed per request');
      } };
    }
  };
  const sent = await runAutomationRule(db, async messages => (
    { successCount: messages.length, failureCount: 0, errorCodes: {} }
  ), { ...baseRule, id: 'r-mass', trigger: 'scheduled', audience: 'marketing_opt_in', runAt: now - 1000 }, now);

  assert.equal(sent, 1000);
  assert.deepEqual(batches.map(ops => ops.length), [450, 450, 100]);
  assert.ok(batches.flat().every(op => op === 'update'), 'silinmiş cihaz yarım belgeyle geri yaratılmamalı');
});
