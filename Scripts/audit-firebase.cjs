// Read-only production audit. Never prints tokens or device documents.
const { createRequire } = require('node:module');
const { gunzipSync } = require('node:zlib');
const requireBackend = createRequire(require('node:path').resolve(__dirname, '../functions/package.json'));
const auth = requireBackend('firebase-tools/lib/auth');
const project = 'sismik-app-ea600';
(async () => {
  const account = auth.getGlobalDefaultAccount();
  if (!account) throw new Error('Firebase CLI login required');
  const credentials = await auth.getAccessToken(account.tokens.refresh_token, ['https://www.googleapis.com/auth/cloud-platform']);
  async function get(url, body) {
    const response = await fetch(url, {
      method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${credentials.access_token}`, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(20000)
    });
    if (!response.ok) throw new Error(`Audit HTTP ${response.status}: ${new URL(url).pathname}`);
    return response.json();
  }
  const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)`;
  const result = {};
  const database = await get(base);
  result.database = Object.fromEntries(['locationId','type','concurrencyMode','pointInTimeRecoveryEnablement','deleteProtectionState'].map(k=>[k,database[k]]));
  for (const name of ['live_quakes_v1','afad_map_90d_v1','noa_map_90d_v1']) {
    try {
      const doc = await get(`${base}/documents/_public/${name}`);
      const fields = doc.fields || {};
      const number = key => Number(fields[key]?.integerValue ?? fields[key]?.doubleValue ?? 0);
      const summary = { updatedAt: new Date(number('updated_at') || number('checked_at') || Date.parse(doc.updateTime)).toISOString() };
      if (fields.payload?.bytesValue) {
        const compressed = Buffer.from(fields.payload.bytesValue, 'base64');
        const quakes = JSON.parse(gunzipSync(compressed));
        const rows = Array.isArray(quakes) ? quakes : [];
        summary.compressedBytes = compressed.length;
        summary.records = rows.length;
        summary.providers = rows.reduce((a,q)=>(a[q.provider]=(a[q.provider]||0)+1,a),{});
        summary.invalidRecords = rows.filter(q=>!Number.isFinite(q.magnitude)||!Number.isFinite(q.lat)||!Number.isFinite(q.lon)||!Number.isFinite(Date.parse(q.date))).length;
        summary.duplicateIds = rows.length-new Set(rows.map(q=>q.id)).size;
        summary.latestEvent = rows.map(q=>q.date).sort().at(-1);
      }
      result[name] = summary;
    } catch(error) { result[name] = { error: error.message }; }
  }
  const count = await get(`${base}/documents:runAggregationQuery`, {
    structuredAggregationQuery: { structuredQuery: { from:[{collectionId:'devices'}] }, aggregations:[{alias:'count',count:{}}] }
  });
  result.deviceCount = count[0]?.result?.aggregateFields?.count;
  const query = await get(`${base}/documents:runQuery`, { structuredQuery: {
    from: [{collectionId:'devices'}], select: { fields: ['transport','is_premium','premium_expires_at','earthquake_notifications_enabled','product_updates_enabled','notification_schema_version','entitlement_source','latitude','longitude','nearby_only','minimum_estimated_mmi'].map(fieldPath=>({fieldPath})) }, limit: 1000
  }});
  const rows = query.filter(r=>r.document).map(r=>r.document.fields);
  const value = (r,k)=>r[k]?.booleanValue ?? r[k]?.integerValue ?? r[k]?.doubleValue ?? r[k]?.stringValue;
  result.deviceSample = { count: rows.length, premium: rows.filter(r=>value(r,'is_premium')===true).length,
    expiredPremium: rows.filter(r=>value(r,'is_premium')===true && Number(value(r,'premium_expires_at'))>0 && Number(value(r,'premium_expires_at'))<Date.now()).length,
    legacyTransport: rows.filter(r=>value(r,'transport')!=='fcm').length,
    locationFilterWithoutCoordinates: rows.filter(r=>(value(r,'nearby_only') || Number(value(r,'minimum_estimated_mmi'))>0) && (value(r,'latitude')==null || value(r,'longitude')==null)).length
  };
  const functions = await get(`https://cloudfunctions.googleapis.com/v2/projects/${project}/locations/us-central1/functions`);
  result.functions = functions.functions?.map(f=>({name:f.name.split('/').at(-1),state:f.state,timeout:f.serviceConfig?.timeoutSeconds,memory:f.serviceConfig?.availableMemory,maxInstances:f.serviceConfig?.maxInstanceCount,concurrency:f.serviceConfig?.maxInstanceRequestConcurrency}));
  const indexes = await get(`${base}/collectionGroups/-/indexes`);
  result.indexes = indexes.indexes?.map(i=>({collection:i.name.split('/collectionGroups/')[1]?.split('/')[0],state:i.state,fields:i.fields}));
  const jobs = await get(`https://cloudscheduler.googleapis.com/v1/projects/${project}/locations/us-central1/jobs`);
  result.scheduler = jobs.jobs?.map(j=>({name:j.name.split('/').at(-1),schedule:j.schedule,state:j.state,lastAttemptTime:j.lastAttemptTime,status:j.status,attemptDeadline:j.attemptDeadline}));
  console.log(JSON.stringify(result,null,2));
})().catch(error => { console.error(error.message); process.exitCode=1; });
