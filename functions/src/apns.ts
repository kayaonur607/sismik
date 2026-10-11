import * as http2 from 'node:http2';
import { createSign, randomUUID } from 'node:crypto';

// MARK: - Doğrudan APNs (HTTP/2, token tabanlı)
//
// Bildirimler FCM'e uğramadan Apple'a gider: bir ara sunucu ve bir ağ sıçraması
// eksilir. Tek HTTP/2 bağlantısı yüzlerce eşzamanlı akışı taşır; 10 bin cihazlık
// bir depremde gönderim tek bağlantı üzerinden paralel akar. APNs ücretsizdir.
//
// Kimlik: Apple Developer'daki APNs anahtarı (.p8) — `APNS_AUTH_KEY`,
// `APNS_KEY_ID`, `APNS_TEAM_ID` sırları. Sırlar yoksa `apnsConfigured()` false
// döner ve her şey eskisi gibi FCM'den gider.
//
// Canlı Etkinlik yayın kanalları (live-activity.ts) aynı JWT'yi ve bağlantı
// havuzunu kullanır.

export const APNS_BUNDLE_ID = 'com.kayasoftware.sismik';
export type ApnsEnvironment = 'prod' | 'sandbox';

const SECRET_PLACEHOLDER = 'not-configured-yet';

interface ApnsCredentials { key: string; keyId: string; teamId: string; }

let credentials: ApnsCredentials | null | undefined;

function readCredentials(): ApnsCredentials | null {
  if (credentials !== undefined) return credentials;
  const key = String(process.env.APNS_AUTH_KEY || '').replace(/\\n/g, '\n').trim();
  const keyId = String(process.env.APNS_KEY_ID || '').trim();
  const teamId = String(process.env.APNS_TEAM_ID || '').trim();
  credentials = key.includes('PRIVATE KEY') && keyId && teamId && keyId !== SECRET_PLACEHOLDER
    ? { key, keyId, teamId }
    : null;
  return credentials;
}

export function apnsConfigured(): boolean {
  return readCredentials() !== null;
}

/// Yalnızca testler için: sırları yeniden okut.
export function resetApnsForTesting(): void {
  credentials = undefined;
  cachedJwt = null;
  for (const session of sessions.values()) session.close();
  sessions.clear();
}

// MARK: JWT (ES256). Apple 20–60 dk arası yenilemeyi ister; 50 dk'da bir üretilir.

let cachedJwt: { token: string; issuedAt: number } | null = null;
const JWT_TTL_MS = 50 * 60 * 1000;

function base64url(input: Buffer | string): string {
  return Buffer.from(input).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

export function apnsJwt(now: number = Date.now()): string {
  const creds = readCredentials();
  if (!creds) throw new Error('APNs sırları yapılandırılmamış');
  if (cachedJwt && now - cachedJwt.issuedAt < JWT_TTL_MS) return cachedJwt.token;
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: creds.keyId }));
  const claims = base64url(JSON.stringify({ iss: creds.teamId, iat: Math.floor(now / 1000) }));
  const signer = createSign('SHA256');
  signer.update(`${header}.${claims}`);
  const signature = signer.sign({ key: creds.key, dsaEncoding: 'ieee-p1363' });
  cachedJwt = { token: `${header}.${claims}.${base64url(signature)}`, issuedAt: now };
  return cachedJwt.token;
}

// MARK: HTTP/2 bağlantı havuzu (sunucu başına bir oturum)

const sessions = new Map<string, http2.ClientHttp2Session>();

function sessionFor(origin: string): http2.ClientHttp2Session {
  const existing = sessions.get(origin);
  if (existing && !existing.closed && !existing.destroyed) return existing;
  const session = http2.connect(origin);
  // Boşta bağlantı süreci canlı tutmasın; Apple da boşta bağlantıları kapatır.
  session.unref();
  const drop = () => { if (sessions.get(origin) === session) sessions.delete(origin); };
  session.on('close', drop);
  session.on('goaway', drop);
  session.on('error', drop);
  sessions.set(origin, session);
  return session;
}

export interface ApnsResponse { status: number; reason?: string; headers: http2.IncomingHttpHeaders; }

/// Tek bir HTTP/2 isteği. Ağ hatası reddedilir; APNs hatası `status`/`reason`
/// ile döner.
export function apnsRequest(
  origin: string,
  headers: Record<string, string>,
  body?: string,
  timeoutMs = 10_000
): Promise<ApnsResponse> {
  return new Promise((resolve, reject) => {
    let session: http2.ClientHttp2Session;
    try { session = sessionFor(origin); } catch (error) { reject(error); return; }
    const request = session.request(headers);
    request.setTimeout(timeoutMs, () => request.close(http2.constants.NGHTTP2_CANCEL));
    let responseHeaders: http2.IncomingHttpHeaders = {};
    let data = '';
    request.setEncoding('utf8');
    request.on('response', value => { responseHeaders = value; });
    request.on('data', chunk => { data += chunk; });
    request.on('error', reject);
    request.on('close', () => {
      const status = Number(responseHeaders[':status'] || 0);
      if (!status) { reject(new Error('APNs yanıtı alınamadı')); return; }
      let reason: string | undefined;
      if (data) { try { reason = JSON.parse(data).reason; } catch { reason = data.slice(0, 200); } }
      resolve({ status, reason, headers: responseHeaders });
    });
    request.end(body);
  });
}

// MARK: Cihaz bildirimi

export interface ApnsTarget { token: string; environment: ApnsEnvironment; }

/// Mesaj nesnesine eklenmiş doğrudan APNs hedefi. Mesajlar FCM biçiminde
/// kurulur; gönderim katmanı (push-routes `sendFcmBatches`) hedefi olanları
/// Apple'a doğrudan gönderir.
const apnsTargets = new WeakMap<object, ApnsTarget>();

export function attachApnsTarget<T extends object>(message: T, token: unknown, environment: unknown): T {
  const value = String(token || '').toLowerCase();
  if (/^[0-9a-f]{64,200}$/.test(value)) {
    apnsTargets.set(message, { token: value, environment: environment === 'sandbox' ? 'sandbox' : 'prod' });
  }
  return message;
}

/// Cihaz belgesinden APNs hedefini ekler (kampanya, sürüm duyurusu vb.).
export function withApnsTarget<T extends object>(message: T, data: { apns_token?: unknown; apns_env?: unknown } | undefined): T {
  return data ? attachApnsTarget(message, data.apns_token, data.apns_env) : message;
}

export function apnsTargetOf(message: object): ApnsTarget | undefined {
  return apnsTargets.get(message);
}

const DEVICE_ORIGINS: Record<ApnsEnvironment, string> = {
  prod: 'https://api.push.apple.com:443',
  sandbox: 'https://api.sandbox.push.apple.com:443'
};

export type ApnsSendOutcome =
  | { ok: true }
  /// Token artık geçersiz: cihaz belgesi silinebilir.
  | { ok: false; unregistered: true; reason: string }
  /// Geçici ya da yapılandırma hatası: FCM yedeğine düşülür.
  | { ok: false; unregistered: false; reason: string };

const UNREGISTERED_REASONS = new Set(['Unregistered', 'BadDeviceToken', 'DeviceTokenNotForTopic']);

export async function sendApnsNotification(
  target: ApnsTarget,
  apnsHeaders: Record<string, string | undefined>,
  payload: unknown
): Promise<ApnsSendOutcome> {
  const headers: Record<string, string> = {
    ':method': 'POST',
    ':path': `/3/device/${target.token}`,
    authorization: `bearer ${apnsJwt()}`,
    'apns-topic': APNS_BUNDLE_ID
  };
  for (const [name, value] of Object.entries(apnsHeaders)) {
    if (value !== undefined && value !== '') headers[name.toLowerCase()] = String(value);
  }
  try {
    const response = await apnsRequest(DEVICE_ORIGINS[target.environment], headers, JSON.stringify(payload));
    if (response.status === 200) return { ok: true };
    const reason = response.reason || `HTTP ${response.status}`;
    // 410: token artık geçersiz. 400 BadDeviceToken: yanlış ortam ya da bozuk
    // token — ikisinde de bu token'a bir daha gönderilmez.
    const unregistered = response.status === 410 || UNREGISTERED_REASONS.has(reason);
    // Süresi dolmuş JWT: bir sonraki istekte yenisi üretilsin.
    if (reason === 'ExpiredProviderToken' || reason === 'InvalidProviderToken') cachedJwt = null;
    return { ok: false, unregistered, reason };
  } catch (error: any) {
    return { ok: false, unregistered: false, reason: String(error?.message || error) };
  }
}

/// Aynı anda en fazla bu kadar akış. APNs bağlantı başına ~1000 akışa izin
/// verir; 200 hem hızlı hem de bellek açısından güvenli.
const APNS_CONCURRENCY = 200;

export async function sendApnsNotifications<T>(
  items: T[],
  send: (item: T) => Promise<ApnsSendOutcome>
): Promise<ApnsSendOutcome[]> {
  const results: ApnsSendOutcome[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(APNS_CONCURRENCY, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await send(items[index]);
    }
  }));
  return results;
}

export function newApnsRequestId(): string {
  return randomUUID();
}
