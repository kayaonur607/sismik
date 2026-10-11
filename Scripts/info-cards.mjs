// Bilgi kartlarını yönetir: uygulama açıldığında bir kez görünen duyuru /
// yenilik kartları ve onları açan zamanlanmış bildirimler.
//
// Kartlar `_public/live_quakes_v1` belgesinin `info_cards` alanında durur
// (sunucu bu belgeyi zaten okuyor; ek okuma maliyeti yok). Her yayında
// `info_cards_revision` artar, açık uygulamalar bir sonraki liste isteğinde
// yeni kartı görür. Ayrıntı: functions/src/info-cards.ts
//
// Varsayılan KURU ÇALIŞMA'dır; hiçbir şey yazmaz. Yazmak için `--apply`.
//
//   node Scripts/info-cards.mjs list
//   node Scripts/info-cards.mjs publish InfoCards/ornek-kart.json [--apply]
//   node Scripts/info-cards.mjs remove <kart-id> [--apply]
//   node Scripts/info-cards.mjs push <kart-id> [--at 2026-10-01T10:00:00+03:00]
//        [--audience all|free|premium|marketing_opt_in] [--apply]
//   node Scripts/info-cards.mjs push-cancel <kart-id> [--apply]
//
// `push`: kartın `push` metniyle zamanlanmış bir otomasyon kuralı açar
// (`automations/info-card-<id>`). Saatlik bakım turu `--at` anından sonraki
// ilk turda gönderir (en geç ~1 saat); dokunulunca uygulama kartı açar.
// Maliyet: gönderim kitle başına bir kez okunur ve her cihaza bir
// "gönderildi" işareti yazılır (mevcut otomasyon motoru).
//
// Önkoşul: `firebase login` ve `cd functions && npm run build` (doğrulama
// derlenmiş lib/info-cards.js'ten gelir).
import { createRequire } from 'node:module';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const requireBackend = createRequire(resolve(here, '../functions/package.json'));
const libPath = resolve(here, '../functions/lib/info-cards.js');
if (!existsSync(libPath)) {
  console.error('functions/lib/info-cards.js yok. Önce: cd functions && npm run build');
  process.exit(1);
}
const { validateInfoCard, parseInfoCards, upsertInfoCard, infoCardPushMessages, INFO_CARDS_MAX_BYTES, INFO_CARDS_MAX_COUNT } = requireBackend(libPath);
const { validateAutomationRule } = requireBackend(resolve(here, '../functions/lib/worker-utils.js'));
const auth = requireBackend('firebase-tools/lib/auth');

const PROJECT = 'sismik-app-ea600';
const SNAPSHOT_PATH = '_public/live_quakes_v1';
const AUDIENCES = ['all', 'free', 'premium', 'marketing_opt_in'];

const args = process.argv.slice(2);
const APPLY = args.includes('--apply');
const option = name => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : undefined;
};
const positional = args.filter((arg, index) => !arg.startsWith('--') && !(index > 0 && args[index - 1].startsWith('--') && args[index - 1] !== '--apply'));
const [command, target] = positional;

const fail = message => { console.error(`✗ ${message}`); process.exit(1); };

// MARK: Firestore REST (firebase-tools oturumu)

let token;
async function call(path, method = 'GET', body) {
  if (!token) {
    const account = auth.getGlobalDefaultAccount();
    if (!account) fail('Firebase CLI oturumu gerekli (firebase login)');
    token = (await auth.getAccessToken(account.tokens.refresh_token, ['https://www.googleapis.com/auth/cloud-platform'])).access_token;
  }
  const base = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
  const response = await fetch(`${base}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(30000)
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`HTTP ${response.status} ${method} ${path}: ${(await response.text()).slice(0, 300)}`);
  return response.json();
}

const encode = value => {
  if (typeof value === 'string') return { stringValue: value };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (Number.isInteger(value)) return { integerValue: String(value) };
  if (typeof value === 'number') return { doubleValue: value };
  if (value && typeof value === 'object') {
    return { mapValue: { fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)])) } };
  }
  return { nullValue: null };
};

async function readCards() {
  const doc = await call(`${SNAPSHOT_PATH}?mask.fieldPaths=info_cards&mask.fieldPaths=info_cards_revision`);
  const fields = doc?.fields || {};
  return {
    revision: Number(fields.info_cards_revision?.integerValue || 0),
    cards: parseInfoCards(fields.info_cards?.stringValue || '')
  };
}

async function writeCards(cards, revision) {
  const text = JSON.stringify(cards);
  if (Buffer.byteLength(text) > INFO_CARDS_MAX_BYTES) fail(`Kartlar ${INFO_CARDS_MAX_BYTES} baytı aşıyor; eskileri kaldır.`);
  if (cards.length > INFO_CARDS_MAX_COUNT) fail(`En fazla ${INFO_CARDS_MAX_COUNT} kart; eskileri kaldır.`);
  // Yalnızca bu iki alan yazılır; deprem verisi ve sürüm alanı korunur.
  await call(`${SNAPSHOT_PATH}?updateMask.fieldPaths=info_cards&updateMask.fieldPaths=info_cards_revision`, 'PATCH', {
    fields: { info_cards: encode(text), info_cards_revision: encode(revision) }
  });
}

const titleOf = card => card.title?.tr || card.title?.en || '';
const describe = card => {
  const parts = [card.audience || 'all'];
  if (card.minVersion || card.maxVersion) parts.push(`sürüm ${card.minVersion || '*'}…${card.maxVersion || '*'}`);
  if (card.startAt || card.endAt) parts.push(`${card.startAt || '…'} → ${card.endAt || '…'}`);
  if (card.push) parts.push('push metni var');
  return parts.join(' · ');
};

// MARK: Komutlar

async function list() {
  const { revision, cards } = await readCards();
  console.log(`Revizyon ${revision} · ${cards.length} kart`);
  for (const card of cards) console.log(`  • ${card.id} — ${titleOf(card)}\n    ${describe(card)}`);
  const rules = await call('automations?pageSize=100');
  const pushes = (rules?.documents || []).filter(doc => doc.fields?.infoCardId);
  if (pushes.length) {
    console.log('\nKart bildirimleri:');
    for (const doc of pushes) {
      const f = doc.fields;
      const runAt = Number(f.runAt?.integerValue || 0);
      const lastRun = Number(f.last_run_at?.integerValue || 0);
      const state = f.enabled?.booleanValue === false ? 'iptal' : lastRun >= runAt ? `gönderildi (${f.last_sent_count?.integerValue || 0})` : 'bekliyor';
      console.log(`  • ${f.infoCardId.stringValue} → ${f.audience?.stringValue} · ${new Date(runAt).toISOString()} · ${state}`);
    }
  }
}

async function publish(file) {
  if (!file) fail('Kart dosyası gerekli: publish InfoCards/<dosya>.json');
  let card;
  try { card = JSON.parse(readFileSync(resolve(process.cwd(), file), 'utf8')); }
  catch (error) { fail(`${file} okunamadı: ${error.message}`); }
  const { valid, errors } = validateInfoCard(card);
  if (!valid) fail(`Kart geçersiz:\n  - ${errors.join('\n  - ')}`);

  const { revision, cards } = await readCards();
  const replacing = cards.some(existing => existing.id === card.id);
  const next = upsertInfoCard(cards, card);
  console.log(`${replacing ? 'Güncellenecek' : 'Eklenecek'}: ${card.id} — ${titleOf(card)}\n  ${describe(card)}`);
  if (replacing) console.log('  Not: kartı zaten görmüş cihazlar aynı kimliği tekrar görmez; yeniden göstermek için yeni bir id kullan.');
  if (!APPLY) return console.log('\nKURU ÇALIŞMA — yazmak için --apply ekle.');
  await writeCards(next, revision + 1);
  console.log(`✓ Yayında (revizyon ${revision + 1}). Açık uygulamalar ~1 dk içinde, diğerleri açılışta görür.`);
}

async function remove(id) {
  if (!id) fail('Kart kimliği gerekli: remove <id>');
  const { revision, cards } = await readCards();
  if (!cards.some(card => card.id === id)) fail(`${id} yayında değil.`);
  console.log(`Kaldırılacak: ${id}`);
  if (!APPLY) return console.log('\nKURU ÇALIŞMA — yazmak için --apply ekle.');
  await writeCards(cards.filter(card => card.id !== id), revision + 1);
  console.log(`✓ Kaldırıldı (revizyon ${revision + 1}).`);
}

async function schedulePush(id) {
  if (!id) fail('Kart kimliği gerekli: push <id>');
  const { cards } = await readCards();
  const card = cards.find(existing => existing.id === id);
  if (!card) fail(`${id} yayında değil; önce publish --apply.`);
  const messages = infoCardPushMessages(card);
  if (!Object.keys(messages).length) fail('Kartta push metni yok: karta "push": { "title": {...}, "body": {...} } ekleyip yeniden yayınla.');

  const audience = option('audience') || card.audience || 'all';
  if (!AUDIENCES.includes(audience)) fail(`--audience: ${AUDIENCES.join(' | ')}`);
  const atText = option('at');
  const runAt = atText ? Date.parse(atText) : Date.now();
  if (!Number.isFinite(runAt)) fail('--at: ISO 8601 tarih (ör. 2026-10-01T10:00:00+03:00)');

  const rule = {
    name: `Bilgi kartı: ${titleOf(card)}`.slice(0, 120),
    enabled: true,
    trigger: 'scheduled',
    audience,
    runAt,
    infoCardId: card.id,
    messages,
    created_at: Date.now()
  };
  // Otomasyon motorunun kabul ettiği kural mı? Bozuk kural her bakım
  // turunda hata verir; yazılmadan reddedilir.
  const check = validateAutomationRule(rule);
  if (!check.valid) fail(`Otomasyon kuralı geçersiz:\n  - ${check.errors.join('\n  - ')}`);
  console.log(`Bildirim: ${card.id} → ${audience} · ${new Date(runAt).toLocaleString('tr-TR')}`);
  console.log(`  Diller: ${Object.keys(messages).join(', ')} (eksik dildeki cihaz en → tr metnini alır)`);
  console.log('  Gönderim, bu andan sonraki ilk saatlik bakım turunda (maintenanceSweep) yapılır.');
  if (!APPLY) return console.log('\nKURU ÇALIŞMA — zamanlamak için --apply ekle.');
  // Belge tamamen yazılır: aynı kart için önceki kural (ve last_run_at) sıfırlanır.
  await call(`automations/info-card-${card.id}`, 'PATCH', {
    fields: Object.fromEntries(Object.entries(rule).map(([k, v]) => [k, encode(v)]))
  });
  console.log(`✓ Zamanlandı: automations/info-card-${card.id}`);
}

async function cancelPush(id) {
  if (!id) fail('Kart kimliği gerekli: push-cancel <id>');
  const doc = await call(`automations/info-card-${id}`);
  if (!doc) fail(`${id} için zamanlanmış bildirim yok.`);
  console.log(`İptal edilecek: automations/info-card-${id}`);
  if (!APPLY) return console.log('\nKURU ÇALIŞMA — iptal için --apply ekle.');
  await call(`automations/info-card-${id}?updateMask.fieldPaths=enabled`, 'PATCH', { fields: { enabled: encode(false) } });
  console.log('✓ İptal edildi.');
}

const commands = { list, publish, remove, push: schedulePush, 'push-cancel': cancelPush };
if (!commands[command]) {
  console.log('Kullanım: node Scripts/info-cards.mjs <list | publish <dosya> | remove <id> | push <id> [--at ISO] [--audience x] | push-cancel <id>> [--apply]');
  process.exit(command ? 1 : 0);
}
console.log(APPLY ? '=== UYGULAMA MODU (yazar) ===' : '=== KURU ÇALIŞMA ===');
commands[command](target).catch(error => fail(error.message));
