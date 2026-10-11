import { APNS_BUNDLE_ID, ApnsEnvironment, apnsConfigured, apnsJwt, apnsRequest, newApnsRequestId } from './apns';
import { Earthquake, aftershockZoneRadiusKm, dedupeAgencyCopies, getDistanceKm } from './worker-utils';

// MARK: - Büyük olay Canlı Etkinliği (iOS 18 yayın kanalı)
//
// Büyük olay açıldığında (major-event.ts) APNs'te bir yayın kanalı açılır ve
// kimliği olayla birlikte canlı anlık görüntü belgesine yazılır (ek yazım yok:
// `major_event` alanı zaten yazılıyor). Kullanıcı kartta "Canlı takip"e
// dokununca uygulama Canlı Etkinliği bu kanala abone başlatır; kilit ekranı ve
// Dynamic Island artçı sayısı, en büyük artçı ve büyüklük revizyonuyla
// güncellenir.
//
// Ölçek: güncelleme cihaz sayısından bağımsız TEK istektir — 10 bin ya da 1
// milyon abone aynı maliyet. Güncelleme yalnızca içerik değiştiğinde ve en sık
// dakikada bir gönderilir. Olay kapanınca "end" gönderilir ve kanal silinir.

export interface LiveChannels { prod?: string; sandbox?: string; }

const MANAGE_ORIGINS: Record<ApnsEnvironment, string> = {
  prod: 'https://api-manage-broadcast.push.apple.com:2196',
  sandbox: 'https://api-manage-broadcast.sandbox.push.apple.com:2195'
};
const BROADCAST_ORIGINS: Record<ApnsEnvironment, string> = {
  prod: 'https://api.push.apple.com:443',
  sandbox: 'https://api.sandbox.push.apple.com:443'
};
const ENVIRONMENTS: ApnsEnvironment[] = ['prod', 'sandbox'];

/// İçerik: uygulamadaki `AftershockActivityAttributes.ContentState` ile birebir
/// aynı anahtarlar. Canlı Etkinlik bu yapıyı Swift'in varsayılan `Date`
/// çözümüyle okur: tarih, 2001-01-01'den bu yana geçen SANİYE olmalıdır.
export interface LiveActivityState {
  aftershockCount: number;
  maxAftershockMagnitude: number;
  lastMagnitude: number;
  lastTitle: string;
  lastDate: number;
  updatedAt: number;
  forecastProbability: number;
  forecastMagnitude: number;
}

const APPLE_REFERENCE_EPOCH_S = 978_307_200;
export function appleReferenceSeconds(ms: number): number {
  return Math.round(ms / 1000 - APPLE_REFERENCE_EPOCH_S);
}

/// Reasenberg & Jones (1989) genel modeli — uygulamadaki `AftershockForecast`
/// ile aynı parametreler: sonraki 24 saatte en az bir M(ana − 1, en az 4)+
/// artçı olasılığı.
export function aftershockForecast(mainshockMagnitude: number, elapsedMs: number): { probability: number; magnitude: number } {
  const a = -1.67, b = 0.91, p = 1.08, c = 0.05;
  const magnitude = Math.max(4, Math.floor(mainshockMagnitude) - 1);
  const start = Math.max(0, elapsedMs) / 86_400_000;
  const end = start + 1;
  const productivity = Math.pow(10, a + b * (mainshockMagnitude - magnitude));
  const integral = (Math.pow(start + c, 1 - p) - Math.pow(end + c, 1 - p)) / (p - 1);
  const probability = 1 - Math.exp(-Math.max(0, productivity * integral));
  return { probability: Math.round(probability * 1000) / 1000, magnitude };
}

function readableTitle(title: string): string {
  const value = String(title || '').trim();
  if (!value || /[a-zçğıöşü]/.test(value)) return value;
  return value.toLowerCase().replace(/(^|[\s(\-,])(\p{L})/gu, (_, prefix, letter) => prefix + letter.toUpperCase());
}

export interface LiveEventRef {
  id: string;
  magnitude: number;
  lat: number;
  lon: number;
  date: string;
  expires_at: number;
  live_channels?: LiveChannels;
}

async function createChannel(environment: ApnsEnvironment): Promise<string | undefined> {
  const response = await apnsRequest(MANAGE_ORIGINS[environment], {
    ':method': 'POST',
    ':path': `/1/apps/${APNS_BUNDLE_ID}/channels`,
    authorization: `bearer ${apnsJwt()}`,
    'apns-request-id': newApnsRequestId(),
    'content-type': 'application/json'
  }, JSON.stringify({
    // "En son mesaj saklanır": çevrimdışı cihaz bağlanınca son durumu alır.
    'message-storage-policy': 1,
    'push-type': 'LiveActivity'
  }));
  const channel = response.headers['apns-channel-id'];
  if (response.status !== 201 || !channel) {
    console.warn(`Canlı Etkinlik kanalı açılamadı (${environment}): ${response.status} ${response.reason ?? ''}`);
    return undefined;
  }
  return String(channel);
}

/// Yeni büyük olay için iki ortamda da kanal açar (geliştirme derlemeleri
/// sandbox'a bağlanır). APNs yapılandırılmamışsa `null`.
export async function createLiveChannels(): Promise<LiveChannels | null> {
  if (!apnsConfigured()) return null;
  const [prod, sandbox] = await Promise.all(ENVIRONMENTS.map(environment =>
    createChannel(environment).catch(error => {
      console.warn(`Canlı Etkinlik kanalı açılamadı (${environment}):`, error?.message || error);
      return undefined;
    })
  ));
  return prod || sandbox ? { ...(prod ? { prod } : {}), ...(sandbox ? { sandbox } : {}) } : null;
}

async function broadcast(environment: ApnsEnvironment, channel: string, payload: unknown, priority: 5 | 10, expiration: number): Promise<boolean> {
  const response = await apnsRequest(BROADCAST_ORIGINS[environment], {
    ':method': 'POST',
    ':path': `/4/broadcasts/apps/${APNS_BUNDLE_ID}`,
    authorization: `bearer ${apnsJwt()}`,
    'apns-channel-id': channel,
    'apns-push-type': 'liveactivity',
    'apns-priority': String(priority),
    'apns-expiration': String(expiration),
    'content-type': 'application/json'
  }, JSON.stringify(payload));
  if (response.status !== 200) {
    console.warn(`Canlı Etkinlik yayını başarısız (${environment}): ${response.status} ${response.reason ?? ''}`);
    return false;
  }
  return true;
}

async function deleteChannel(environment: ApnsEnvironment, channel: string): Promise<void> {
  await apnsRequest(MANAGE_ORIGINS[environment], {
    ':method': 'DELETE',
    ':path': `/1/apps/${APNS_BUNDLE_ID}/channels`,
    authorization: `bearer ${apnsJwt()}`,
    'apns-channel-id': channel
  }).catch(() => undefined);
}

/// Olayın artçı özetini canlı listeden hesaplar (Firestore yok).
export function liveActivityState(event: LiveEventRef, quakes: Earthquake[], now: number): LiveActivityState {
  const start = Date.parse(event.date);
  const radiusKm = aftershockZoneRadiusKm(event.magnitude);
  // Ana şokun ajans kopyaları ilk 3 dk ve 30 km içinde; artçı sayılmaz.
  const sequence = quakes.filter(q => {
    const time = Date.parse(q.date);
    if (!(time > start) || time > now + 60_000) return false;
    const distance = getDistanceKm(event.lat, event.lon, q.lat, q.lon);
    if (time - start <= 180_000 && distance <= 30 && Math.abs(q.magnitude - event.magnitude) < 1) return false;
    return distance <= radiusKm;
  });
  // Aynı artçının farklı ajans kayıtları bir kez sayılır (resmî ajans kalır);
  // uygulamadaki "Artçılar" ve `/aftershocks` ile aynı kural.
  const unique = dedupeAgencyCopies(sequence).sort((a, b) => b.magnitude - a.magnitude);
  const latest = unique.reduce<Earthquake | null>((best, q) => !best || Date.parse(q.date) > Date.parse(best.date) ? q : best, null);
  const forecast = aftershockForecast(event.magnitude, now - start);
  return {
    aftershockCount: unique.length,
    maxAftershockMagnitude: unique.length ? Math.round(unique[0].magnitude * 10) / 10 : 0,
    lastMagnitude: latest ? Math.round(latest.magnitude * 10) / 10 : 0,
    lastTitle: latest ? readableTitle(latest.title) : '',
    lastDate: appleReferenceSeconds(latest ? Date.parse(latest.date) : start),
    updatedAt: appleReferenceSeconds(now),
    forecastProbability: forecast.probability,
    forecastMagnitude: forecast.magnitude
  };
}

const lastSent = new Map<string, { state: LiveActivityState; at: number }>();
const UPDATE_MIN_GAP_MS = 60_000;

/// Olasılık zamanla yavaşça azalır; tek başına güncelleme sebebi değildir.
function sameContent(a: LiveActivityState, b: LiveActivityState): boolean {
  return a.aftershockCount === b.aftershockCount && a.maxAftershockMagnitude === b.maxAftershockMagnitude
    && a.lastMagnitude === b.lastMagnitude && a.lastDate === b.lastDate;
}

/// İçerik değiştiyse (ve son güncellemeden 1 dk geçtiyse) kanala yayınlar.
/// Büyüklük revizyonu hemen, yüksek öncelikle gider; artçı sayısı düşük
/// öncelikle (Apple'ın bütçesini korur).
export async function publishLiveActivityUpdate(event: LiveEventRef | null, quakes: Earthquake[], now: number = Date.now()): Promise<void> {
  if (!event?.live_channels || !apnsConfigured()) return;
  const state = liveActivityState(event, quakes, now);
  const previous = lastSent.get(event.id);
  if (previous && sameContent(previous.state, state)) return;
  // Yeni bir büyük artçı (M4+) hemen ve yüksek öncelikle; diğerleri en sık
  // dakikada bir, düşük öncelikle (Apple'ın öncelik bütçesini korur).
  const strongAftershock = state.maxAftershockMagnitude >= 4 && (!previous || state.maxAftershockMagnitude > previous.state.maxAftershockMagnitude);
  if (previous && !strongAftershock && now - previous.at < UPDATE_MIN_GAP_MS) return;
  const payload = {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: 'update',
      'content-state': state,
      // Olay kapanınca kart bayat görünür; kapanış yayını ayrıca gönderilir.
      'stale-date': Math.floor(event.expires_at / 1000)
    }
  };
  const expiration = Math.floor(event.expires_at / 1000);
  const results = await Promise.all(ENVIRONMENTS.map(environment => {
    const channel = event.live_channels?.[environment];
    return channel ? broadcast(environment, channel, payload, strongAftershock ? 10 : 5, expiration).catch(() => false) : Promise.resolve(false);
  }));
  if (results.some(Boolean)) {
    lastSent.set(event.id, { state, at: now });
    console.log(`Canlı Etkinlik güncellendi: ${event.id} · ${state.aftershockCount} artçı, en büyük M${state.maxAftershockMagnitude}.`);
  }
}

/// Olay kapandı ya da daha büyüğü geldi: Canlı Etkinlik biter, kanal silinir.
export async function endLiveActivity(event: LiveEventRef, quakes: Earthquake[], now: number = Date.now()): Promise<void> {
  if (!event.live_channels || !apnsConfigured()) return;
  const state = liveActivityState(event, quakes, now);
  const payload = {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: 'end',
      'content-state': state,
      // Son durum kilit ekranında bir saat daha görünür.
      'dismissal-date': Math.floor(now / 1000) + 3600
    }
  };
  await Promise.all(ENVIRONMENTS.map(async environment => {
    const channel = event.live_channels?.[environment];
    if (!channel) return;
    await broadcast(environment, channel, payload, 10, Math.floor(now / 1000) + 3600).catch(() => false);
    await deleteChannel(environment, channel);
  }));
  lastSent.delete(event.id);
  console.log(`Canlı Etkinlik kapandı: ${event.id}.`);
}
