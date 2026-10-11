const test = require('node:test');
const assert = require('node:assert/strict');
const {
  normalizeVerifiedTransaction,
  verifyTransactionJWS
} = require('../lib/subscription-verification');

const now = Date.parse('2026-07-12T10:00:00.000Z');

function transaction(overrides = {}) {
  return {
    originalTransactionId: '1000000000001',
    transactionId: '1000000000002',
    productId: 'com.kayasoftware.sismik.premium.yearly',
    environment: 'Sandbox',
    purchaseDate: now,
    originalPurchaseDate: now,
    expiresDate: now + 365 * 86400000,
    signedDate: now,
    ...overrides
  };
}

test('a current subscription transaction is active', () => {
  const result = normalizeVerifiedTransaction(transaction(), now);
  assert.equal(result.status, 'active');
  assert.equal(result.isActive, true);
  assert.equal('isTrial' in result, false);
});

// Ücretsiz deneme kaldırıldı; kaldırılmadan önce başlamış bir deneme işlemi
// süresi boyunca normal aktif abonelik sayılır.
test('a legacy free-trial transaction is treated as a plain active subscription', () => {
  const result = normalizeVerifiedTransaction(transaction({
    expiresDate: now + 7 * 86400000,
    offerType: 1,
    offerDiscountType: 'FREE_TRIAL'
  }), now);
  assert.equal(result.status, 'active');
  assert.equal(result.isActive, true);
});

test('expired and revoked transactions cannot grant premium access', () => {
  const expired = normalizeVerifiedTransaction(transaction({ expiresDate: now - 1 }), now);
  const revoked = normalizeVerifiedTransaction(transaction({ revocationDate: now - 1000 }), now);
  assert.equal(expired.status, 'expired');
  assert.equal(expired.isActive, false);
  assert.equal(revoked.status, 'revoked');
  assert.equal(revoked.isActive, false);
});

test('unknown product and malformed JWS are rejected', async () => {
  assert.throws(() => normalizeVerifiedTransaction(transaction({ productId: 'fake.product' }), now));
  await assert.rejects(() => verifyTransactionJWS('not-a-jws'));
});

// MARK: - Ömür boyu (tüketilmeyen ürün)

test('a lifetime purchase has no expiry and stays active', () => {
  const result = normalizeVerifiedTransaction(transaction({
    productId: 'com.kayasoftware.sismik.lifetime',
    type: 'Non-Consumable',
    expiresDate: undefined
  }), now);
  assert.equal(result.isActive, true);
  assert.equal(result.status, 'active');
  assert.equal(result.expiresDate, 0);
});

test('a refunded lifetime purchase is revoked', () => {
  const result = normalizeVerifiedTransaction(transaction({
    productId: 'com.kayasoftware.sismik.lifetime',
    expiresDate: undefined,
    revocationDate: now - 1000
  }), now);
  assert.equal(result.isActive, false);
  assert.equal(result.status, 'revoked');
});

test('subscriptions still require an expiry date', () => {
  assert.throws(() => normalizeVerifiedTransaction(transaction({ expiresDate: undefined }), now));
});
