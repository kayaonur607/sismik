// Tek seferlik Firestore kalıntı temizliği.
//
// Neyi siler:
//   1) Okuyanı kalmamış sistem belgeleri: `_public/app_config_v1` (sürüm
//      kapısı kaldırıldı; `/config` Firestore'a hiç gitmeyen statik yanıt) ve
//      `_public/source_health_v1` (yazılıyordu ama hiçbir kod okumuyordu),
//      `_system/twitter_posting_v1` (Twitter defteri artık bellekte).
//   2) `devices/*` üzerindeki ölü alanlar: sessiz saatler üründen kaldırıldı
//      (istemcide arayüzü yok), bildirim şema sürümü artık dallanmıyor,
//      `device_key` belge kimliğinin okunmayan bir kopyasıydı,
//      `subscription_is_trial` ücretsiz denemeyle birlikte kalktı.
//   3) Eski kuraldaki (`source` taşıyan) belgelerde `places`. Bir belge ya
//      yer modelinde ya eski kuraldadır (`deviceUsesPlaces`); ikisini birden
//      taşıyan belge, eski istemciyi sessizce yer modeline geçirir. Bu
//      alanlar geçiş denemesindeki bir backfill betiğinden kalma.
//
// Yazımlar belgenin okunduğu andaki `updateTime` ön koşuluyla yapılır:
// arada kayıt yenilenen cihaz ezilmez, atlanır (yeni `/register` zaten
// aynı temizliği kendisi yapıyor).
//
//   4) TTL alanı (`expire_at`) taşımayan eski ai_cache / felt_reports /
//      _system_push_claims belgeleri: alan eklenir ya da (süresi geçmiş
//      kilitler) silinir.
//
// Varsayılan KURU ÇALIŞMA'dır; hiçbir şey yazmaz. Uygulamak için:
//   node Scripts/purge-legacy-firestore.cjs --apply
const { createRequire } = require('node:module');
const requireBackend = createRequire(require('node:path').resolve(__dirname, '../functions/package.json'));
const auth = requireBackend('firebase-tools/lib/auth');

const project = 'sismik-app-ea600';
const APPLY = process.argv.includes('--apply');
const ORPHAN_DOCUMENTS = [
  '_public/app_config_v1',
  // Kaynak sağlığı yalnızca push sürecinin belleğinde kullanılıyor; belgeyi
  // okuyan kod yoktu, yazımı kaldırıldı (12 Eylül 2026).
  '_public/source_health_v1',
  // Twitter paylaşım defteri artık yalnızca süreç belleğinde (13 Eylül 2026).
  '_system/twitter_posting_v1',
  // Yönetim paneli ve API'si kaldırıldı (22 Eylül 2026).
  '_system/admin_access'
];
const DEAD_DEVICE_FIELDS = [
  'quiet_hours',
  'quiet_start',
  'quiet_end',
  'update_topics',
  'notification_schema_version',
  'device_key',
  // Ücretsiz deneme kaldırıldı (13 Eylül 2026); alanı okuyan kod kalmadı.
  'subscription_is_trial',
  // Yazılıyordu ama hiçbir kod okumuyordu (22 Eylül 2026'da yazımı kaldırıldı).
  'entitlement_status'
];

(async () => {
  const account = auth.getGlobalDefaultAccount();
  if (!account) throw new Error('Firebase CLI oturumu gerekli (firebase login)');
  const credentials = await auth.getAccessToken(account.tokens.refresh_token, ['https://www.googleapis.com/auth/cloud-platform']);
  const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)`;
  const call = async (url, method = 'GET', body) => {
    const r = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${credentials.access_token}`, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(30000)
    });
    if (!r.ok) throw new Error(`HTTP ${r.status} ${method} ${new URL(url).pathname}: ${(await r.text()).slice(0, 200)}`);
    return r.status === 204 ? {} : r.json();
  };

  console.log(APPLY ? '=== UYGULAMA MODU (yazar) ===' : '=== KURU ÇALIŞMA (hiçbir şey yazmaz) ===');

  // 1) Okuyanı kalmamış sistem belgeleri
  for (const path of ORPHAN_DOCUMENTS) {
    let orphan = null;
    try {
      orphan = await call(`${base}/documents/${path}`);
    } catch (e) {
      if (!/HTTP 404/.test(e.message)) throw e;
    }
    if (orphan) {
      console.log(`\n[1] ${path} SİLİNECEK — alanlar: ${Object.keys(orphan.fields || {}).join(', ')}`);
      if (APPLY) {
        await call(`${base}/documents/${path}`, 'DELETE');
        console.log('    → silindi');
      }
    } else {
      console.log(`\n[1] ${path} zaten yok.`);
    }
  }

  // 2) Cihaz belgelerindeki ölü alanlar
  console.log('\n[2] devices/* ölü alan temizliği');
  let cursor = null;
  let scanned = 0;
  const affected = [];
  do {
    const page = await call(`${base}/documents:runQuery`, 'POST', {
      structuredQuery: {
        from: [{ collectionId: 'devices' }],
        orderBy: [{ field: { fieldPath: '__name__' }, direction: 'ASCENDING' }],
        ...(cursor ? { startAt: { values: [{ referenceValue: cursor }], before: false } } : {}),
        limit: 300
      }
    });
    const docs = page.filter(row => row.document).map(row => row.document);
    if (!docs.length) break;
    scanned += docs.length;
    cursor = docs[docs.length - 1].name;
    for (const doc of docs) {
      const present = DEAD_DEVICE_FIELDS.filter(field => doc.fields?.[field] !== undefined);
      if (doc.fields?.source !== undefined && doc.fields?.places !== undefined) present.push('places');
      if (present.length) affected.push({ name: doc.name, present, updateTime: doc.updateTime });
    }
    if (docs.length < 300) break;
  } while (cursor);

  const counts = {};
  affected.forEach(({ present }) => present.forEach(f => { counts[f] = (counts[f] || 0) + 1; }));
  console.log(`    taranan cihaz: ${scanned}, etkilenen: ${affected.length}`);
  console.log(`    alan bazında: ${JSON.stringify(counts)}`);

  if (APPLY) {
    let cleaned = 0;
    let skipped = 0;
    for (const { name, present, updateTime } of affected) {
      // updateMask alanları listeler, gövde onları İÇERMEZ → alanlar silinir.
      const mask = present.map(f => `updateMask.fieldPaths=${encodeURIComponent(f)}`).join('&');
      const precondition = `currentDocument.updateTime=${encodeURIComponent(updateTime)}`;
      try {
        await call(`https://firestore.googleapis.com/v1/${name}?${mask}&${precondition}`, 'PATCH', { fields: {} });
        cleaned++;
      } catch (error) {
        if (!/HTTP (400|409|412)/.test(error.message)) throw error;
        skipped++;
      }
    }
    console.log(`    → ${cleaned} cihaz belgesi temizlendi, ${skipped} tanesi arada güncellendiği için atlandı`);
  }

  // 3) TTL alanı taşımayan eski belgeler. Firestore TTL yalnızca `expire_at`
  //    alanı olan belgeleri siler; bu alan eklenmeden önce yazılmış belgeler
  //    sonsuza kadar kalırdı. AI önbelleği ve Hissettim sayaçlarına kendi
  //    ömürleri kadar `expire_at` eklenir; 24 saati geçmiş push kilitlerinin
  //    işlevi kalmadığı için doğrudan silinir.
  const DAY = 86400000;
  const ttlBackfill = [
    { collection: 'ai_cache', field: 'created_at', lifetimeMs: 30 * DAY },
    { collection: 'felt_reports', field: 'updated_at', lifetimeMs: 34 * DAY },
    { collection: '_system_push_claims', field: 'claimedAt', lifetimeMs: DAY, deleteWhenExpired: true }
  ];
  for (const rule of ttlBackfill) {
    const rows = await call(`${base}/documents:runQuery`, 'POST', {
      structuredQuery: { from: [{ collectionId: rule.collection }], select: { fields: [{ fieldPath: 'expire_at' }, { fieldPath: rule.field }] }, limit: 5000 }
    });
    const missing = rows.filter(row => row.document && !row.document.fields?.expire_at).map(row => row.document);
    let deleted = 0;
    let patched = 0;
    for (const doc of missing) {
      const raw = doc.fields?.[rule.field];
      const anchor = Number(raw?.integerValue ?? raw?.doubleValue ?? Date.parse(doc.updateTime));
      const expireAt = anchor + rule.lifetimeMs;
      const precondition = `currentDocument.updateTime=${encodeURIComponent(doc.updateTime)}`;
      if (!APPLY) continue;
      try {
        if (rule.deleteWhenExpired && expireAt <= Date.now()) {
          await call(`https://firestore.googleapis.com/v1/${doc.name}?${precondition}`, 'DELETE');
          deleted++;
        } else {
          await call(`https://firestore.googleapis.com/v1/${doc.name}?updateMask.fieldPaths=expire_at&${precondition}`, 'PATCH', {
            fields: { expire_at: { timestampValue: new Date(expireAt).toISOString() } }
          });
          patched++;
        }
      } catch (error) {
        if (!/HTTP (400|404|409|412)/.test(error.message)) throw error;
      }
    }
    console.log(`\n[3] ${rule.collection}: expire_at olmayan ${missing.length} belge${APPLY ? ` → ${patched} güncellendi, ${deleted} silindi` : ''}`);
  }

  console.log(APPLY ? '\nTemizlik tamamlandı.' : '\nKuru çalışma bitti. Uygulamak için: --apply');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
