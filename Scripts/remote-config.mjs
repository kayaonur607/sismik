// Uzak yapılandırmayı yönetir: güncelleme beklemeden sunucu ve uygulama
// davranışını değiştiren tek belge (`_system/remote_config_v1`).
// Ayrıntı ve alanların tam listesi: functions/src/remote-config.ts
//
// Aynı belge Firebase konsolundan da düzenlenebilir (Firestore → _system →
// remote_config_v1). Revizyon elle artırılmaz; sunucu en geç ~1 dk içinde
// görür, uygulama ~2 dk içinde (bir sonraki liste yenilemesinde).
//
// Varsayılan KURU ÇALIŞMA'dır; hiçbir şey yazmaz. Yazmak için `--apply`.
//
//   node Scripts/remote-config.mjs show
//   node Scripts/remote-config.mjs pause push|tsunami|twitter|live [--apply]
//   node Scripts/remote-config.mjs resume push|tsunami|twitter|live [--apply]
//   node Scripts/remote-config.mjs hide-quake <deprem-id> [--apply]
//   node Scripts/remote-config.mjs unhide-quake <deprem-id> [--apply]
//   node Scripts/remote-config.mjs hide-source <AFAD|KANDILLI|…> [--apply]
//   node Scripts/remote-config.mjs unhide-source <kaynak> [--apply]
//   node Scripts/remote-config.mjs close-major <olay-id> [--apply]
//   node Scripts/remote-config.mjs reopen-major <olay-id> [--apply]
//   node Scripts/remote-config.mjs feature <felt_card|live_activity|…> on|off [--apply]
//   node Scripts/remote-config.mjs set <yol> <json-değer> [--apply]
//        örn. set client.felt_card.nearby_radius_km 40
//             set client.min_version '"2.1.4"'
//             set client.notice "$(cat notice.json)"
//   node Scripts/remote-config.mjs unset <yol> [--apply]
//   node Scripts/remote-config.mjs reset [--apply]        (belgeyi siler → tüm varsayılanlar)
//
// Önkoşul: `firebase login` ve `cd functions && npm run build`.
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const requireBackend = createRequire(resolve(here, '../functions/package.json'));
const libPath = resolve(here, '../functions/lib/remote-config.js');
if (!existsSync(libPath)) {
  console.error('functions/lib/remote-config.js yok. Önce: cd functions && npm run build');
  process.exit(1);
}
const { sanitizeRemoteConfig, configHash, CLIENT_FEATURES, KNOWN_SOURCES } = requireBackend(libPath);
const auth = requireBackend('firebase-tools/lib/auth');

const PROJECT = 'sismik-app-ea600';
const DOC_PATH = '_system/remote_config_v1';
const PAUSES = { push: 'push_paused', tsunami: 'tsunami_paused', twitter: 'twitter_paused', live: 'live_activity_paused' };

const args = process.argv.slice(2);
const APPLY = args.includes('--apply');
const [command, ...rest] = args.filter(arg => arg !== '--apply');

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
  if (Array.isArray(value)) return { arrayValue: { values: value.map(encode) } };
  if (value && typeof value === 'object') {
    return { mapValue: { fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)])) } };
  }
  return { nullValue: null };
};

const decode = value => {
  if (!value || typeof value !== 'object') return undefined;
  if ('stringValue' in value) return value.stringValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('integerValue' in value) return Number(value.integerValue);
  if ('doubleValue' in value) return value.doubleValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('arrayValue' in value) return (value.arrayValue.values || []).map(decode);
  if ('mapValue' in value) return decodeFields(value.mapValue.fields || {});
  return null;
};
const decodeFields = fields => Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, decode(v)]));

async function readRaw() {
  const doc = await call(DOC_PATH);
  return doc ? decodeFields(doc.fields || {}) : {};
}

// MARK: Yol işlemleri

function getPath(object, path) {
  return path.split('.').reduce((node, key) => (node && typeof node === 'object' ? node[key] : undefined), object);
}

function setPath(object, path, value) {
  const keys = path.split('.');
  let node = object;
  for (const key of keys.slice(0, -1)) {
    if (!node[key] || typeof node[key] !== 'object' || Array.isArray(node[key])) node[key] = {};
    node = node[key];
  }
  if (value === undefined) delete node[keys[keys.length - 1]];
  else node[keys[keys.length - 1]] = value;
}

function listEdit(raw, path, value, add) {
  const list = Array.isArray(getPath(raw, path)) ? [...getPath(raw, path)] : [];
  const next = add ? [...new Set([...list, value])] : list.filter(item => item !== value);
  setPath(raw, path, next.length ? next : undefined);
}

function pruneEmpty(object) {
  for (const [key, value] of Object.entries(object)) {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      pruneEmpty(value);
      if (!Object.keys(value).length) delete object[key];
    }
  }
  return object;
}

// MARK: Gösterim

function summarize(raw) {
  const { server, client } = sanitizeRemoteConfig(raw);
  const lines = [];
  const paused = Object.entries(PAUSES).filter(([, key]) => server[key]).map(([name]) => name);
  lines.push(`Duraklatılan: ${paused.length ? paused.join(', ') : '—'}`);
  lines.push(`Büyük olay: ${server.major_event_disabled ? 'KAPALI' : 'açık'}${server.major_event_suppress.length ? ` · kapatılan: ${server.major_event_suppress.join(', ')}` : ''}`);
  lines.push(`Gizli kaynak: ${server.disabled_sources.join(', ') || '—'}`);
  lines.push(`Gizli deprem: ${server.hidden_quakes.join(', ') || '—'}`);
  lines.push(`Uygulama (revizyon ${configHash(client)}):`);
  lines.push(JSON.stringify(client, null, 2).split('\n').map(line => `  ${line}`).join('\n'));
  return lines.join('\n');
}

/// Belgede olup doğrulamada düşen alanları bildirir (yazım hatası vb.).
function droppedFields(raw) {
  const clean = sanitizeRemoteConfig(raw);
  const dropped = [];
  const walk = (node, cleanNode, prefix) => {
    if (!node || typeof node !== 'object' || Array.isArray(node)) return;
    for (const [key, value] of Object.entries(node)) {
      const path = prefix ? `${prefix}.${key}` : key;
      const cleanValue = cleanNode && typeof cleanNode === 'object' ? cleanNode[key] : undefined;
      if (cleanValue === undefined) dropped.push(path);
      else if (value && typeof value === 'object' && !Array.isArray(value)) walk(value, cleanValue, path);
      else if (JSON.stringify(value) !== JSON.stringify(cleanValue)) dropped.push(`${path} (düzeltildi → ${JSON.stringify(cleanValue)})`);
    }
  };
  walk(raw, clean, '');
  return dropped;
}

async function commit(before, after) {
  pruneEmpty(after);
  const dropped = droppedFields(after);
  console.log('Önce:\n' + summarize(before) + '\n');
  console.log('Sonra:\n' + summarize(after));
  if (dropped.length) console.log(`\n⚠︎ Geçersiz ya da aralık dışı, yok sayılacak: ${dropped.join(', ')}`);
  if (!APPLY) {
    console.log('\nKuru çalışma. Yazmak için --apply ekle.');
    return;
  }
  await call(DOC_PATH, 'PATCH', { fields: Object.fromEntries(Object.entries(after).map(([k, v]) => [k, encode(v)])) });
  console.log('\n✓ Yazıldı. Sunucu ~1 dk, uygulama ~2 dk içinde uygular.');
}

// MARK: Komutlar

const raw = await readRaw();
const next = structuredClone(raw);

switch (command) {
  case 'show':
  case undefined: {
    console.log(summarize(raw));
    const dropped = droppedFields(raw);
    if (dropped.length) console.log(`\n⚠︎ Yok sayılan alanlar: ${dropped.join(', ')}`);
    break;
  }
  case 'pause':
  case 'resume': {
    const key = PAUSES[rest[0]];
    if (!key) fail(`Şunlardan biri: ${Object.keys(PAUSES).join(', ')}`);
    setPath(next, `server.${key}`, command === 'pause' ? true : undefined);
    await commit(raw, next);
    break;
  }
  case 'hide-quake':
  case 'unhide-quake':
    if (!rest[0]) fail('Deprem kimliği gerekli (uygulamada detay → paylaş bağlantısındaki ya da günlükteki kimlik).');
    listEdit(next, 'server.hidden_quakes', rest[0], command === 'hide-quake');
    await commit(raw, next);
    break;
  case 'hide-source':
  case 'unhide-source': {
    const source = String(rest[0] || '').toUpperCase();
    if (!KNOWN_SOURCES.includes(source)) fail(`Kaynak şunlardan biri: ${KNOWN_SOURCES.join(', ')}`);
    listEdit(next, 'server.disabled_sources', source, command === 'hide-source');
    await commit(raw, next);
    break;
  }
  case 'close-major':
  case 'reopen-major':
    if (!rest[0]) fail('Olay kimliği gerekli (GET /major-event yanıtındaki event.id).');
    listEdit(next, 'server.major_event_suppress', rest[0], command === 'close-major');
    await commit(raw, next);
    break;
  case 'feature': {
    const [name, state] = rest;
    if (!CLIENT_FEATURES.includes(name)) fail(`Özellik şunlardan biri: ${CLIENT_FEATURES.join(', ')}`);
    if (!['on', 'off'].includes(state)) fail('on ya da off');
    // Varsayılan açık: "on" alanı kaldırır.
    setPath(next, `client.features.${name}`, state === 'off' ? false : undefined);
    await commit(raw, next);
    break;
  }
  case 'set': {
    const [path, json] = rest;
    if (!path || json === undefined) fail('Kullanım: set <yol> <json-değer>');
    let value;
    try { value = JSON.parse(json); } catch { value = json; }
    setPath(next, path, value);
    await commit(raw, next);
    break;
  }
  case 'unset':
    if (!rest[0]) fail('Kullanım: unset <yol>');
    setPath(next, rest[0], undefined);
    await commit(raw, next);
    break;
  case 'reset':
    console.log('Önce:\n' + summarize(raw));
    if (!APPLY) { console.log('\nKuru çalışma. Belgeyi silmek için --apply.'); break; }
    await call(DOC_PATH, 'DELETE');
    console.log('\n✓ Belge silindi; tüm varsayılanlar geçerli.');
    break;
  default:
    fail(`Bilinmeyen komut: ${command}. Dosya başındaki kullanım notlarına bak.`);
}
