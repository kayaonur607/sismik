// `devices/*.push_candidate` alanını bir kez doldurur.
//
// Bildirim turunun tam okuması yalnızca `push_candidate == true` ya da
// `is_premium == true` olan cihazları okur (push-routes.ts). Alan, ücretsiz
// katmanla (21 Eyl 2026) eklendi ve yalnızca `/register` sırasında yazılıyor;
// istemci kaydı haftada bir yenilediği için o tarihten beri kaydolmamış
// ücretsiz cihazlarda alan yok ve bu cihazlar (ör. dünya M6+ bildirimi açık)
// bildirim alamazdı. Değer sunucunun kendi kuralıyla (`isPushCandidate`)
// hesaplanır; yalnızca bu alan yazılır (`updated_at` değişmez, cihaz
// önbelleğinin delta senkronu tetiklenmez). Yazım, belgenin okunduğu andaki
// `updateTime` ön koşuluyla yapılır: arada kaydolan cihaz ezilmez, atlanır.
//
// Varsayılan KURU ÇALIŞMA'dır. Uygulamak için:
//   cd functions && npm run build && cd .. && node Scripts/backfill-push-candidate.cjs --apply
const { createRequire } = require('node:module');
const path = require('node:path');
const requireBackend = createRequire(path.resolve(__dirname, '../functions/package.json'));
const auth = requireBackend('firebase-tools/lib/auth');
const { isPushCandidate } = requireBackend(path.resolve(__dirname, '../functions/lib/worker-utils.js'));

const project = 'sismik-app-ea600';
const APPLY = process.argv.includes('--apply');

// Firestore REST değerini düz JS değerine çevirir (isPushCandidate'in baktığı alanlar için yeterli).
function decode(value) {
  if (!value || typeof value !== 'object') return undefined;
  if ('booleanValue' in value) return value.booleanValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('stringValue' in value) return value.stringValue;
  if ('nullValue' in value) return null;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(decode);
  if ('mapValue' in value) return Object.fromEntries(Object.entries(value.mapValue.fields || {}).map(([k, v]) => [k, decode(v)]));
  return undefined;
}

(async () => {
  const account = auth.getGlobalDefaultAccount();
  if (!account) throw new Error('Firebase CLI oturumu gerekli (firebase login)');
  const token = (await auth.getAccessToken(account.tokens.refresh_token, ['https://www.googleapis.com/auth/cloud-platform'])).access_token;
  const base = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents`;
  const call = async (url, method = 'GET', body) => {
    const r = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(30000)
    });
    if (!r.ok) throw Object.assign(new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`), { status: r.status });
    return r.json();
  };

  console.log(APPLY ? '=== UYGULAMA MODU (yazar) ===' : '=== KURU ÇALIŞMA (hiçbir şey yazmaz) ===');
  let docs = [], pageToken = '';
  do {
    const page = await call(`${base}/devices?pageSize=300${pageToken ? `&pageToken=${pageToken}` : ''}`);
    docs = docs.concat(page.documents || []);
    pageToken = page.nextPageToken || '';
  } while (pageToken);

  let unchanged = 0, written = 0, skipped = 0;
  const changes = { toTrue: 0, toFalse: 0 };
  for (const doc of docs) {
    const data = Object.fromEntries(Object.entries(doc.fields || {}).map(([k, v]) => [k, decode(v)]));
    const want = isPushCandidate(data);
    if (data.push_candidate === want) { unchanged++; continue; }
    want ? changes.toTrue++ : changes.toFalse++;
    if (!APPLY) continue;
    try {
      await call(
        `https://firestore.googleapis.com/v1/${doc.name}?updateMask.fieldPaths=push_candidate&currentDocument.updateTime=${encodeURIComponent(doc.updateTime)}`,
        'PATCH',
        { fields: { push_candidate: { booleanValue: want } } }
      );
      written++;
    } catch (error) {
      // Ön koşul tutmadı: cihaz az önce kaydoldu; `/register` alanı zaten yazdı.
      if (error.status === 400 || error.status === 409 || error.status === 412) skipped++;
      else throw error;
    }
  }
  console.log(`Cihaz: ${docs.length} · zaten doğru: ${unchanged} · true olacak: ${changes.toTrue} · false olacak: ${changes.toFalse}`);
  if (APPLY) console.log(`Yazıldı: ${written} · atlandı (arada kaydoldu): ${skipped}`);
  else console.log('KURU ÇALIŞMA — yazmak için --apply ekle.');
})().catch(error => { console.error('✗', error.message); process.exit(1); });
