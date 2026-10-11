const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const { sendFcmBatches, initPushRoutes } = require('../lib/push-routes');
const { expirePremiumEntitlements } = require('../lib/subscription-routes');
const { registerEarthquakeRoutes, publishLiveSnapshot } = require('../lib/earthquake-routes');

test('10,000 recipient fanout bounds concurrency and preserves failure/device order', async t => {
  let active = 0, maximum = 0;
  const app = admin.initializeApp({ projectId: 'unit-test' });
  t.mock.method(admin.messaging(), 'sendEach', async (batch, dryRun) => {
    active++; maximum = Math.max(maximum, active);
    await new Promise(resolve => setImmediate(resolve));
    active--;
    assert.equal(dryRun, true);
    if (batch[0].token === '800') throw new Error('transient');
    return { successCount: batch.length, failureCount: 0, responses: batch.map(() => ({ success: true })) };
  });
  try {
    const batches = Array.from({ length: 25 }, (_, i) => Array.from({length:400}, (_,j)=>({token:String(i*400+j)})));
    const results = await sendFcmBatches(batches, true);
    assert.equal(maximum, 4);
    assert.equal(results.length, 25);
    assert.equal(results[2].status, 'rejected');
    assert.equal(results.filter(r=>r.status==='fulfilled').length, 24);
    assert.deepEqual(await sendFcmBatches([]), []);
  } finally { await app.delete(); }
});

test('expiry sweep preserves a concurrent renewal and never recreates a deleted device', async () => {
  const writes = [];
  const docs = ['renewed','expired','deleted','removed-expiry'].map(id=>({ref:{id}}));
  const states = {
    renewed: {is_premium:true,premium_expires_at:2000},
    expired: {is_premium:true,premium_expires_at:500,entitlement_source:'revenuecat'},
    'removed-expiry': {is_premium:false}
  };
  const db = {
    collection: () => ({ doc: id=>({id}), where:()=>({limit:()=>({get:async()=>({empty:false,docs})})}) }),
    runTransaction: async fn=>fn({
      getAll: async(...refs)=>refs.map(ref=>({ref,data:()=>states[ref.id]})),
      update: (ref,value)=>writes.push({id:ref.id,value}),
      set: ()=>{}
    })
  };
  initPushRoutes(db);
  assert.equal(await expirePremiumEntitlements(db,1000),1);
  assert.deepEqual(writes.map(w=>w.id),['expired']);
  assert.equal(writes[0].value.is_premium,false);
  assert.equal(writes[0].value.entitlement_source,undefined);
});

test('unchanged live snapshot gets a bounded freshness heartbeat', async t => {
  let now = 1000000;
  t.mock.method(Date,'now',()=>now);
  const writes=[];
  const db={collection:()=>({doc:id=>({set:async value=>writes.push({id,value})})})};
  registerEarthquakeRoutes({get:()=>{}},db);
  const quake={id:'a',provider:'AFAD',magnitude:3,lat:38,lon:27,date:'2026-09-08T00:00:00Z'};
  await publishLiveSnapshot([quake]);
  now+=60000;
  await publishLiveSnapshot([quake]);
  assert.equal(writes.length,1);
  now+=60001;
  await publishLiveSnapshot([quake]);
  assert.equal(writes.length,2);
  assert.equal(writes[1].value.updated_at,now);
});

const { withExecutionLease } = require('../lib/execution-lease');
// Firestore belge semantiği: create var olan belgede ALREADY_EXISTS, ön
// koşullu update/delete değişmiş belgede FAILED_PRECONDITION fırlatır.
function leaseDoc() {
  const doc = { state: undefined, version: 0, reads: 0, transactions: 0 };
  const fail = code => Object.assign(new Error(String(code)), { code });
  const write = value => { doc.state = value; doc.version++; return { writeTime: doc.version }; };
  doc.ref = {
    create: async value => { if (doc.state) throw fail(6); return write(value); },
    get: async () => { doc.reads++; return { exists: Boolean(doc.state), data: () => doc.state, updateTime: doc.version }; },
    update: async (value, pre) => { if (!doc.state || pre.lastUpdateTime !== doc.version) throw fail(9); return write(value); },
    delete: async pre => { if (!doc.state) throw fail(5); if (pre.lastUpdateTime !== doc.version) throw fail(9); doc.state = undefined; doc.version++; }
  };
  doc.db = {
    collection: () => ({ doc: () => doc.ref }),
    runTransaction: async () => { doc.transactions++; throw new Error('lease must not use transactions'); }
  };
  return doc;
}

test('scheduler lease skips an overlapping run and releases after a failure', async () => {
  const lease = leaseDoc();
  const db = lease.db;
  let release;
  const held = new Promise(resolve=>{release=resolve;});
  let started;
  const ready = new Promise(resolve=>{started=resolve;});
  const first = withExecutionLease(db,'lease',240000,async()=>{started();await held;});
  await ready;
  assert.equal(await withExecutionLease(db,'lease',240000,async()=>assert.fail('overlap')),false);
  release();
  assert.equal(await first,true);
  await assert.rejects(withExecutionLease(db,'lease',240000,async()=>{throw new Error('work failed');}),/work failed/);
  assert.equal(lease.state,undefined);
  assert.equal(lease.transactions,0);
});

test('an uncontended scheduler lease costs two writes and no reads', async () => {
  const lease = leaseDoc();
  assert.equal(await withExecutionLease(lease.db,'lease',240000,async()=>{}),true);
  assert.equal(lease.reads,0);
  assert.equal(lease.version,2);
  assert.equal(lease.state,undefined);
});

test('an expired lease is taken over and the stale holder cannot release it', async t => {
  let now = 1_000_000;
  t.mock.method(Date,'now',()=>now);
  const lease = leaseDoc();
  let releaseStale;
  const staleHeld = new Promise(resolve=>{releaseStale=resolve;});
  let staleStarted;
  const staleReady = new Promise(resolve=>{staleStarted=resolve;});
  const stale = withExecutionLease(lease.db,'lease',240000,async()=>{staleStarted();await staleHeld;});
  await staleReady;
  now += 240001;
  let resumeFresh;
  const freshHeld = new Promise(resolve=>{resumeFresh=resolve;});
  let freshStarted;
  const freshReady = new Promise(resolve=>{freshStarted=resolve;});
  const fresh = withExecutionLease(lease.db,'lease',240000,async()=>{freshStarted();await freshHeld;});
  await freshReady;
  releaseStale();
  assert.equal(await stale,true);
  assert.ok(lease.state, 'stale holder must not delete the new lease');
  resumeFresh();
  assert.equal(await fresh,true);
  assert.equal(lease.state,undefined);
});
