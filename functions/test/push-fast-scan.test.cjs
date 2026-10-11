const test = require('node:test');
const assert = require('node:assert/strict');
const earthquakeRoutes = require('../lib/earthquake-routes');
const { runScheduledPushCheck } = require('../lib/push-routes');

// Dakikalık tur, :30 taramasını görev kuyruğuna devredebildiğinde o saniyeyi
// açık istekte beklemez (bekleme faturalanıyordu); devredemezse taramayı
// eskisi gibi turun içinde yapar — tarama hiçbir koşulda kaybolmaz.

const MINUTE = Date.UTC(2026, 8, 14, 10, 0, 0);

function stubSources(t) {
  const recentCalls = [];
  const originals = {
    collectRecentQuakesForPush: earthquakeRoutes.collectRecentQuakesForPush,
    collectQuakes: earthquakeRoutes.collectQuakes
  };
  earthquakeRoutes.collectRecentQuakesForPush = async () => {
    recentCalls.push(Date.now());
    return { quakes: [], timings: {} };
  };
  // Tam toplama boş döner; tur "kaynakların tamamı boş" hatasıyla biter —
  // burada ölçülen yalnızca tarama sayısı ve zamanlaması.
  earthquakeRoutes.collectQuakes = async () => [];
  t.after(() => Object.assign(earthquakeRoutes, originals));
  return recentCalls;
}

test('delegated :15/:30/:45 scans: the minute run does not wait for them', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: MINUTE + 2_000 });
  const recentCalls = stubSources(t);
  const scheduled = [];

  await assert.rejects(
    runScheduledPushCheck({}, async () => {}, async at => { scheduled.push(at); return true; }),
    /boş döndü/
  );

  assert.deepEqual(scheduled, [MINUTE + 15_000, MINUTE + 30_000, MINUTE + 45_000],
    'görevler dakikanın :15, :30 ve :45 saniyelerine kurulur');
  assert.equal(recentCalls.length, 1, 'tur yalnızca anlık taramayı yapar');
});

// Mock zamanlayıcıda turu :15, :30 ve :45 taramalarından geçirir.
async function advanceThroughScans(t) {
  const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve)); };
  await settle();
  for (const step of [13_000, 15_000, 15_000]) {
    t.mock.timers.tick(step);
    await settle();
  }
}

test('failed delegation: the scans still run inside the minute run', async t => {
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now: MINUTE + 2_000 });
  const recentCalls = stubSources(t);

  // Tur, zaman ilerlerken beklenen hatayla biter; sonuç baştan yakalanır.
  const outcome = runScheduledPushCheck({}, async () => {}, async () => false).then(() => null, error => error);
  await advanceThroughScans(t);

  assert.match(String((await outcome)?.message), /boş döndü/);
  assert.equal(recentCalls.length, 4, 'devredilemeyen taramalar turun içinde yapılır');
  assert.deepEqual(recentCalls.slice(1), [MINUTE + 15_000, MINUTE + 30_000, MINUTE + 45_000]);
});

test('no scheduler given (tests, local runs): old in-run behavior', async t => {
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now: MINUTE + 2_000 });
  const recentCalls = stubSources(t);

  const outcome = runScheduledPushCheck({}, async () => {}).then(() => null, error => error);
  await advanceThroughScans(t);

  assert.match(String((await outcome)?.message), /boş döndü/);
  assert.equal(recentCalls.length, 4);
});
