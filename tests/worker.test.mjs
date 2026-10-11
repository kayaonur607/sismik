import test from 'node:test'
import assert from 'node:assert/strict'
import workerUtils from '../functions/lib/worker-utils.js'

const {
  isValidPushToken,
  normalizePushToken,
  selectFreshQuakes
} = workerUtils

const now = Date.parse('2026-07-09T12:00:00.000Z')

function quake({ id = 'q-1', provider = 'AFAD', magnitude = 4.2, date = '2026-07-09T10:00:00.000Z' } = {}) {
  return { id, provider, magnitude, date }
}

test('fresh quake selection rejects future events and de-duplicates IDs', () => {
  const selected = selectFreshQuakes([
    quake({ id: 'old', date: '2026-07-09T11:56:00.000Z' }),
    // Üç dakikalık sağlayıcı saat sapması toleransının dışında.
    quake({ id: 'future', date: '2026-07-09T12:04:00.000Z' }),
    quake({ id: 'new', date: '2026-07-09T11:59:00.000Z' }),
    quake({ id: 'new', date: '2026-07-09T11:58:00.000Z' })
  ], now)

  assert.deepEqual(selected.map(({ id }) => id), ['new', 'old'])
})

test('fresh quake selection caps the batch at the production limit', () => {
  const many = Array.from({ length: 30 }, (_, index) => quake({
    id: `q-${index}`,
    date: new Date(now - index * 1000).toISOString()
  }))
  assert.equal(selectFreshQuakes(many, now).length, 12)
})

test('FCM tokens stay case-sensitive while APNs tokens are normalized', () => {
  const fcm = 'AbCdEf0123456789:Case_Sensitive-Token'
  assert.equal(normalizePushToken(fcm, 'fcm'), fcm)
  assert.equal(isValidPushToken(fcm, 'fcm'), true)
  assert.equal(normalizePushToken('AABBCCDD', 'apns'), 'aabbccdd')
  assert.equal(isValidPushToken('a'.repeat(64), 'apns'), true)
  assert.equal(isValidPushToken('not an fcm token with spaces', 'fcm'), false)
})
