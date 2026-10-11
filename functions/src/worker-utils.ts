import { remoteClientConfig } from './remote-config';
import { isDeepStrictEqual } from 'node:util';
import { describeNearest, isInTurkiye, nearestPlace, titleCaseRegion } from './place-names';
export interface Earthquake {
  id: string;
  provider: string;
  title: string;
  magnitude: number;
  depth: number;
  lat: number;
  lon: number;
  date: string;
  closestCity?: string | null;
  epiCenter?: string | null;
  magType?: string | null;
  status?: string | null;
  tsunami?: boolean;
  felt?: number | null;
  district?: string | null;
  country?: string | null;
  revised?: boolean;
  updatedAt?: string | null;
  sourceURL?: string | null;
  detailURL?: string | null;
  network?: string | null;
  code?: string | null;
  eventType?: string | null;
  significance?: number | null;
  stationCount?: number | null;
  minimumDistance?: number | null;
  rms?: number | null;
  gap?: number | null;
  communityIntensity?: number | null;
  maximumIntensity?: number | null;
  alertLevel?: string | null;
  author?: string | null;
  catalog?: string | null;
}

/// API alanlarında `null`/boş değerleri JavaScript'in `Number(null) === 0`
/// dönüşümünden korur. Böylece yayımlanmamış MMI, CDI ve kalite değerleri
/// gerçek bir sıfır ölçümüymüş gibi istemciye gönderilmez.
export function optionalFiniteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

// MARK: - Dil normalizasyonu
//
// push-routes.ts (bildirim metni) ve ai-routes.ts (AI yanıt dili) aynı
// desteklenen dil kümesini paylaşır. Eskiden ikisinde de ayrı ayrı tanımlıydı;
// tek bir kopya tutulmayınca biri güncellenip diğeri unutulduğunda bildirim
// dili ile AI yanıt dili sessizce birbirinden ayrışırdı.
export type SupportedLang = 'tr' | 'en' | 'de' | 'es' | 'fr' | 'it' | 'ja' | 'ru' | 'ar';

/// Basit semver karşılaştırması: "2.0.9" < "2.1.0", "1.0.9" < "1.0.10".
/// İstemcideki sürüm kontrolüyle aynı kural.
export function isVersionOlder(lhs: string, rhs: string): boolean {
  const a = String(lhs).split('.').map(part => parseInt(part, 10) || 0);
  const b = String(rhs).split('.').map(part => parseInt(part, 10) || 0);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const x = a[index] ?? 0;
    const y = b[index] ?? 0;
    if (x !== y) return x < y;
  }
  return false;
}

export function normalizeLang(lang?: string): SupportedLang {
  const l = (lang || '').toLowerCase().slice(0, 2);
  if (['tr', 'en', 'de', 'es', 'fr', 'it', 'ja', 'ru', 'ar'].includes(l)) {
    return l as SupportedLang;
  }
  return 'en';
}

export interface QuakeFingerprint {
  id: string;
  provider: string;
  time: number;
  magnitude: number;
  lat: number;
  lon: number;
}

/// Kullanıcının takip ettiği tek bir yer. Her kayıt kendi yarıçapını ve
/// büyüklük eşiğini taşır — bildirim kuralının tamamı burada.
export interface DevicePlace {
  id: string;
  /// Bildirim metninde "🏠 Ev yakınında M 3.2" diyebilmek için taşınır.
  name: string;
  /// Kullanıcının seçtiği simge (`PLACE_ICONS`); bildirimin sağında görünür.
  icon: PlaceIcon;
  lat: number;
  lon: number;
  radiusKm: number;
  minMagnitude: number;
  /// Bu büyüklük ve üstündeki depremde bildirim KRİTİK uyarı olarak gelir
  /// (sessiz modu ve Odak'ı aşar). Kullanıcı tercihidir; yoksa hiçbir deprem
  /// kritik uyarı üretmez. Her zaman `minMagnitude`'dan büyük ya da eşittir.
  criticalMagnitude?: number;
  /// "Hissedilecek depremlerde de haber ver" (2.1.4+): yerde tahmini şiddet
  /// bu MMI değerine (3, 4 ya da 5) ulaşırsa deprem, yarıçapın dışında ya da
  /// büyüklük eşiğinin altında olsa bile bildirilir. Sabit yarıçap uzaktaki
  /// güçlü ve hissedilen depremi kaçırıyordu.
  feltIntensity?: number;
}

export const MAX_DEVICE_PLACES = 8;
/// Hissedilir şiddet kuralı için en küçük büyüklük: daha küçüğü (M3 altı)
/// yalnızca merkez üssünün hemen üstünde hissedilir; o durumu yarıçap kuralı
/// zaten kapsar.
export const FELT_RULE_MIN_MAGNITUDE = 3.0;
const FELT_INTENSITIES = new Set([3, 4, 5]);

/// Bu MMI'ya M7.5'lik sığ bir depremin ulaştığı en uzak mesafe (km, en fazla
/// 600). Konumsal dizin hissedilir kurallı yeri bu yarıçapla kaydeder;
/// eşleşmeyi `matchPlace` asıl azalım modeliyle yapar.
const feltReachCache = new Map<number, number>();
export function feltReachKm(intensity: number): number {
  const cached = feltReachCache.get(intensity);
  if (cached !== undefined) return cached;
  const value = computeFeltReachKm(intensity);
  feltReachCache.set(intensity, value);
  return value;
}

function computeFeltReachKm(intensity: number): number {
  let low = 0, high = 600;
  if (estimatedMMIAtDistance(7.5, 10, high) >= intensity) return high;
  for (let i = 0; i < 30; i++) {
    const mid = (low + high) / 2;
    if (estimatedMMIAtDistance(7.5, 10, mid) >= intensity) low = mid; else high = mid;
  }
  return Math.ceil(high);
}
/// Kritik uyarı eşiğinin alt sınırı: daha küçük depremde telefonu sessiz
/// moddan çalmak savunulamaz.
export const PLACE_MIN_CRITICAL_MAGNITUDE = 3;

/// Yer simgeleri: emoji klavyesinin yerine gelen sabit set (10 Eylül 2026
/// onayı). Kimlik sunucu ile istemci arasındaki sözleşmedir; çizim istemcide
/// (SF Symbols) ve bildirim uzantısında yapılır.
export const PLACE_ICONS = [
  'house', 'work', 'family', 'friends', 'school', 'kids', 'hospital', 'beach',
  'village', 'mountain', 'travel', 'city', 'landmark', 'favorite', 'other'
] as const;
export type PlaceIcon = typeof PLACE_ICONS[number];
const PLACE_ICON_SET = new Set<string>(PLACE_ICONS);

/// Simge setinden önceki (emojili) kayıtları en yakın simgeye taşır.
const EMOJI_TO_ICON: Array<[RegExp, PlaceIcon]> = [
  [/[🏠🏡🏘]/u, 'house'],
  [/[🏢💼]/u, 'work'],
  [/[❤🧡💛💚💙💜🤍👪]|👨‍👩/u, 'family'],
  [/[👥🧑]/u, 'friends'],
  [/[🏫🎓📚]/u, 'school'],
  [/[👶🧒🧸]/u, 'kids'],
  [/[🏥⚕]/u, 'hospital'],
  [/[🏖⛱🌊🏝]/u, 'beach'],
  [/[🌳🌲🌾🚜]/u, 'village'],
  [/[⛰🏔🏕]/u, 'mountain'],
  [/[✈🧳🛫]/u, 'travel'],
  [/[🏙🌆🌃🏬]/u, 'city'],
  [/[🏛🕌⛪🏰]/u, 'landmark'],
  [/[⭐🌟]/u, 'favorite']
];

export function normalizePlaceIcon(value: unknown): PlaceIcon {
  const raw = String(value ?? '');
  if (PLACE_ICON_SET.has(raw)) return raw as PlaceIcon;
  for (const [pattern, icon] of EMOJI_TO_ICON) if (pattern.test(raw)) return icon;
  return 'other';
}
export const PLACE_MIN_RADIUS_KM = 5;
/// Üst sınır, ülke ölçeğinde bir alanı tek yerle kapsayabilmek için geniş
/// tutulur; eski `radius` ayarının üst sınırıyla aynı.
export const PLACE_MAX_RADIUS_KM = 1000;

/// Hızlı sınır kontrolünün kullandığı sabitler.
///
/// İkisi de bilinçli olarak MESAFEYİ OLDUĞUNDAN KÜÇÜK gösterecek yönde
/// seçilir: ön eleme asla yarıçap içindeki bir depremi elememeli. Elerse
/// kullanıcı kendi seçtiği alanın içindeki depremde bildirim almaz ve bunu
/// fark etmesi imkânsıza yakındır.
///
/// Enlem: `getDistanceKm` küresel bir dünya (R=6371) varsaydığı için bir
/// enlem derecesi orada tam 111,195 km'dir. Sınırda bunun ALTINDA bir değer
/// kullanmak şart — üstünde bir değer mesafeyi fazla gösterip yarıçap
/// içindeki depremi elerdi. 110,574 (WGS84'ün en kısa enlem derecesi)
/// güvenli tarafta kalır.
const KM_PER_DEG_LAT = 110.574;
/// Boylam: ekvatorda bir derece 111,320 km, enlem arttıkça kosinüsle daralır.
const KM_PER_DEG_LON_EQUATOR = 111.320;
/// Boylam ön elemesinin güvenli olduğu üst enlem sınırı (bkz. `matchPlace`).
const LON_PREFILTER_MAX_ABS_LAT = 60;
/// Boylam sınırına eklenen güvenlik payı.
///
/// Paralel boyunca ölçülen mesafe, aynı iki nokta arasındaki gerçek büyük
/// çember mesafesinden HER ZAMAN biraz uzundur (yol kutba doğru kısalır).
/// Yani sınır doğası gereği mesafeyi fazla gösterir ve pay konmazsa sınıra
/// yakın depremleri eler. 60 derecenin altında ölçülen en büyük sapma
/// binde 1,6; %1'lik pay altı kat güvenlik marjı bırakıyor.
const LON_PREFILTER_SAFETY = 1.01;

/// İki boylam arasındaki en kısa açısal fark (derece).
///
/// 180. meridyen sarması: yer 179,9°D, deprem 179,9°B ise ham fark 359,8°
/// çıkıyor ve 21 km uzaktaki deprem eleniyordu. Fiji, Yeni Zelanda ve
/// Çukotka hattındaki her kullanıcı bundan etkileniyordu.
export function longitudeDeltaDegrees(a: number, b: number): number {
  const raw = Math.abs(a - b) % 360;
  return raw > 180 ? 360 - raw : raw;
}

/// 2.0.9 ve önceki sürümlerin bildirim kuralı: tek kaynak, tek eşik,
/// isteğe bağlı yakınlık yarıçapı ve hissedilme (MMI) eşiği.
///
/// Bu kural yer listesine ÇEVRİLEMEZ. Push alan eski cihazların çoğu
/// "tüm bölgeler, koordinat yok" ayarında: AFAD'ın her kaydını ve Türkiye
/// kutusundaki her olayı alıyorlar. Yer modeli koordinatsız bir kuralı
/// ifade edemiyor; dönüştürmek bu kullanıcıları sessizce bildirimsiz
/// bırakıyordu. Bu yüzden eski kural, kullanıcı yeni sürümde ilk yerini
/// kaydedene kadar kendi eşleştiricisiyle aynen işletilir.
export interface LegacyRules {
  minMagnitude: number;
  majorThreshold: number;
  source: string;
  sourceFallbackEnabled: boolean;
  nearbyOnly: boolean;
  latitude?: number;
  longitude?: number;
  radius?: number;
  minimumEstimatedMMI: number;
}

export interface DevicePrefs {
  places: DevicePlace[];
  /// Doluysa cihaz eski kuralla eşleştirilir ve `places` yok sayılır.
  legacy?: LegacyRules;
  tzOffset: number;
  lang: string;
  registeredAt?: number;
  updatedAt?: number;
  notified: string[];
  /// Sistem kritik uyarı izni verdi mi? Kullanıcı tercihi DEĞİL, iOS'un
  /// bildirdiği durum. Push yükünde `critical` sesi yalnızca bu açıkken
  /// kullanılır.
  criticalAlertsEnabled?: boolean;
  worldMajorEnabled?: boolean;
  worldMajorThreshold?: number;
  notificationSound?: string;
  /// Kritik uyarıda çalan ses (2.2+ istemci). Boşsa olağan ses kullanılır:
  /// eski sürümün paketinde kritik ses dosyaları yok.
  criticalNotificationSound?: string;
  /// Bildirim biçimi: 'detailed' (varsayılan) ya da 'compact'.
  notificationStyle?: 'detailed' | 'compact';
  aftershockWatch?: AftershockWatch;
}

export interface AftershockWatch {
  mainshockId: string;
  title: string;
  magnitude: number;
  latitude: number;
  longitude: number;
  startedAt: number;
  expiresAt: number;
  radiusKm: number;
  minimumMagnitude: number;
}

export interface CachedPushDevice {
  key: string;
  token: string;
  /// Doğrudan APNs hedefi (2.1.4+ istemci gönderir). Yoksa FCM kullanılır.
  apnsToken?: string;
  apnsEnv?: 'prod' | 'sandbox';
  /// Android istemcisi (`platform: "android"` ile kaydolur). Yoksa iOS.
  platform?: 'android';
  /// Yükleme anındaki yetki. Eski snapshot'larda alan yok: o önbellek
  /// yalnızca premium cihaz tutuyordu, yokluğu premium sayılır.
  premium?: boolean;
  premiumExpiresAt: number;
  /// Kullanıcının kayıtlı tüm kuralları; ücretsizde teslim anında
  /// `effectivePushPrefs` ile sınırlanır.
  prefs: DevicePrefs;
}

/// Ücretsiz katmanın uygulanabilir kuralları: ilk yer (yarıçap 50 km'ye
/// kırpılır, kritik eşik düşer) ve sabit M6.0 dünya eşiği. Eski kuraldaki
/// (2.0.9 ve öncesi) cihazın kuralları bu sınırlara çevrilemediği için
/// ücretsizde işletilmez (`null`).
export function freeTierPrefs(prefs: DevicePrefs): DevicePrefs | null {
  if (prefs.legacy) return null;
  const places = prefs.places.slice(0, FREE_PLACE_LIMIT).map(place => {
    const { criticalMagnitude: _critical, ...rest } = place;
    return { ...rest, radiusKm: Math.min(FREE_MAX_RADIUS_KM, place.radiusKm) };
  });
  return {
    ...prefs,
    places,
    worldMajorThreshold: FREE_WORLD_MAJOR_MIN_MAGNITUDE,
    criticalAlertsEnabled: false,
    notificationSound: '',
    criticalNotificationSound: '',
    aftershockWatch: undefined
  };
}

/// Teslim anında geçerli kurallar. Premium'un süresi önbellek yaşarken
/// dolabilir; o cihaz susmaz, ücretsiz sınırlara düşer.
export function effectivePushPrefs(device: CachedPushDevice, now: number): DevicePrefs | null {
  const premiumActive = device.premium !== false
    && (device.premiumExpiresAt <= 0 || device.premiumExpiresAt > now);
  return premiumActive ? device.prefs : freeTierPrefs(device.prefs);
}

/// Cihaz belgesi sunucu eşleştirmesine girmeli mi? Yetkiden bağımsız:
/// bildirimi açık ve en az bir kuralı (yer, eski kural, dünya geneli, artçı)
/// olan her cihaz. `/register` bunu `push_candidate` alanına yazar; push
/// görevinin tam okuması yalnızca bu cihazları okur.
export function isPushCandidate(data: Record<string, any> | undefined): boolean {
  if (!data || data.earthquake_notifications_enabled === false) return false;
  const hasPlaces = Array.isArray(data.places) && data.places.length > 0;
  const hasLegacyRules = !Array.isArray(data.places)
    && (data.source !== undefined || data.min_magnitude !== undefined || data.nearby_only !== undefined);
  return hasPlaces || hasLegacyRules || data.world_major_enabled === true || Boolean(data.aftershock_watch);
}

/// `place` yeni modelin tek sıradan eşleşmesi. `regular` ve `felt` yalnızca
/// eski kuralla (`LegacyRules`) çalışan cihazlarda üretilir.
export type NotificationMatchReason = 'place' | 'world_major' | 'aftershock' | 'regular' | 'felt';

export interface NotificationMatch {
  reason: NotificationMatchReason;
  /// Yer eşleşmesinde depremin o yere uzaklığı. `world_major` sonucunda
  /// bulunmaz — o eşleşme yer listesinden bağımsızdır.
  distanceKm?: number;
  /// Eşleşmeyi tetikleyen yerin adı ("Ev", "Annemler · İzmir").
  placeName?: string;
  /// O yerin simgesi; bildirim uzantısı bunu bildirimin sağına çizer.
  placeIcon?: PlaceIcon;
  /// O yerin kritik uyarı eşiği (kullanıcı tercihi); yoksa kritik uyarı yok.
  placeCriticalMagnitude?: number;
  /// Yer yarıçapın dışında ama tahmini şiddet eşiği aşıldı ("X'te
  /// hissedilebilir deprem").
  feltAtPlace?: boolean;
  watchTitle?: string;
  /// Eski kural: mesafe gerçekten yakınlık yarıçapından geçerek mi bulundu,
  /// yoksa yalnızca gösterim için mi hesaplandı? Metnin "bölgende"
  /// diyebilmesi buna bağlı.
  isNearbyMatch?: boolean;
  /// Eski kural: `felt` eşleşmesinde tahmini şiddet.
  estimatedMMI?: number;
}

/// NOA'nın (Atina Ulusal Gözlemevi) SeisComP FDSN servisi `format=text`
/// yanıtını uygulamanın ortak deprem modeline dönüştürür. Başlık isimlerini
/// kullanmak, servis sütun sırasına yeni alanlar eklense bile ayrıştırmayı
/// kararlı tutar.
export function parseNOAEventText(value: unknown): Earthquake[] {
  const lines = String(value ?? '')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean);
  const headerLine = lines.find(line => line.startsWith('#'));
  if (!headerLine) return [];

  const headers = headerLine.slice(1).split('|').map(item => item.trim());
  const column = (name: string) => headers.indexOf(name);
  const indexes = {
    id: column('EventID'),
    time: column('Time'),
    latitude: column('Latitude'),
    longitude: column('Longitude'),
    depth: column('Depth/km'),
    magnitudeType: column('MagType'),
    magnitude: column('Magnitude'),
    author: column('Author'),
    catalog: column('Catalog'),
    eventType: column('EventType'),
    location: column('EventLocationName')
  };
  if (indexes.id < 0 || indexes.time < 0 || indexes.latitude < 0
      || indexes.longitude < 0 || indexes.magnitude < 0) return [];

  const quakes: Earthquake[] = [];
  for (const line of lines) {
    if (line.startsWith('#')) continue;
    const fields = line.split('|').map(item => item.trim());
    const eventID = fields[indexes.id];
    const magnitude = Number(fields[indexes.magnitude]);
    const lat = Number(fields[indexes.latitude]);
    const lon = Number(fields[indexes.longitude]);
    if (!eventID || !Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;

    const rawTime = fields[indexes.time] || '';
    const normalizedTime = /[zZ]|[+-]\d\d:\d\d$/.test(rawTime) ? rawTime : `${rawTime}Z`;
    const time = new Date(normalizedTime);
    if (!Number.isFinite(time.getTime())) continue;

    const rawDepth = indexes.depth >= 0 ? Number(fields[indexes.depth]) : 0;
    const title = indexes.location >= 0 ? fields[indexes.location] : '';
    quakes.push({
      id: `noa-${eventID}`,
      provider: 'NOA',
      title: title || 'Greece and Eastern Mediterranean',
      magnitude,
      depth: Number.isFinite(rawDepth) ? rawDepth : 0,
      lat,
      lon,
      date: time.toISOString(),
      closestCity: null,
      epiCenter: title || null,
      magType: indexes.magnitudeType >= 0 ? (fields[indexes.magnitudeType] || null) : null,
      author: indexes.author >= 0 ? (fields[indexes.author] || null) : null,
      catalog: indexes.catalog >= 0 ? (fields[indexes.catalog] || null) : null,
      eventType: indexes.eventType >= 0 ? (fields[indexes.eventType] || null) : null,
      revised: false
    });
  }

  return quakes.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
}

/// NOA'nın canlı GeoJSON akışı (bbnet2.gein.noa.gr/data/{1,2,7}: son 24 sa,
/// 48 sa, 7 gün). FDSN kataloğu Eylül 2026'dan beri boş dönüyor; resmî site
/// ve NOA'nın kendi uygulaması bu akışı kullanıyor. Kimlik FDSN'dekiyle aynı
/// (`noa-<EventId>`), arşivdeki eski kayıtlarla çakışmaz. `Gmt` UTC'dir.
export function parseNOAGeoJSON(value: unknown): Earthquake[] {
  const features = Array.isArray((value as any)?.features) ? (value as any).features : [];
  const quakes: Earthquake[] = [];
  for (const feature of features) {
    const p = feature?.properties ?? {};
    const eventID = String(p.EventId || '').trim();
    const magnitude = Number(p.Magnitude);
    const lat = Number(p.Lat);
    const lon = Number(p.Lon);
    const match = /^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)$/.exec(String(p.Gmt || '').trim());
    if (!eventID || !match || !Number.isFinite(magnitude) || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    const [, day, month, year, hour, minute, second] = match;
    const time = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), 0)
      + Math.round(Number(second) * 1000);
    if (!Number.isFinite(time)) continue;
    const depth = Number(p.Depth);
    // "3 Km E from Efpalion" → "3 km E of Efpalion" (diğer ajanslarla aynı dil).
    const title = String(p.Location || '').trim()
      .replace(/^(\d+(?:\.\d+)?)\s*Km\s+([NSEW]{1,3})\s+from\s+/i, (_m, km, dir) => `${km} km ${String(dir).toUpperCase()} of `);
    quakes.push({
      id: `noa-${eventID}`,
      provider: 'NOA',
      title: title || 'Greece and Eastern Mediterranean',
      magnitude,
      depth: Number.isFinite(depth) ? depth : 0,
      lat,
      lon,
      date: new Date(time).toISOString(),
      closestCity: null,
      epiCenter: title || null,
      magType: p.MagnitudeType ? String(p.MagnitudeType) : null,
      status: String(p.Type || '').toLowerCase() === 'manual' ? 'reviewed' : 'automatic',
      eventType: 'earthquake',
      revised: false
    });
  }
  return quakes.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));
}

/// Anlık sağlayıcı isteği geçici olarak boş kaldığında, taze Firestore
/// arşivinden yalnızca istenen zaman aralığındaki kayıtları seçer. Anlık veri
/// varsa arşive başvurulmaz; böylece yeni kayıtların gecikmesi önlenir.
export function providerArchiveFallback(
  live: Earthquake[],
  archive: Earthquake[],
  startTime: number,
  minMagnitude: number
): Earthquake[] {
  if (live.length) return live;

  return archive.filter(quake => {
    const time = new Date(quake.date).getTime();
    return Number.isFinite(time)
      && time >= startTime
      && quake.magnitude > minMagnitude;
  });
}

export interface RegionCount {
  name: string;
  count: number;
}

/// Türkiye istatistiğindeki "En Aktif İller" yalnızca seçilen tarih
/// penceresindeki resmî AFAD kayıtlarının il alanından hesaplanır. EMSC/USGS/
/// NOA'nın "Central Turkey" gibi sismik bölge adlarını il sanmasını ve uzun
/// aralığın kısa aralık sonucunu göstermesini önler.
export function topTurkeyProvincesFromAFAD(
  quakes: Earthquake[],
  startMs: number,
  minMagnitude = 2.0,
  limit = 8
): RegionCount[] {
  const counts = new Map<string, RegionCount>();
  const seen = new Set<string>();

  for (const quake of quakes) {
    if (quake.provider.toUpperCase() !== 'AFAD' || quake.magnitude <= minMagnitude) continue;
    const time = new Date(quake.date).getTime();
    if (!Number.isFinite(time) || time < startMs || seen.has(quake.id)) continue;
    seen.add(quake.id);

    const rawProvince = String(quake.closestCity || '').trim();
    if (!rawProvince) continue;
    const normalized = rawProvince
      .toLocaleLowerCase('tr-TR')
      .split(/\s+/)
      .map(word => word ? word[0].toLocaleUpperCase('tr-TR') + word.slice(1) : word)
      .join(' ');
    const key = normalized.toLocaleLowerCase('tr-TR');
    const current = counts.get(key);
    if (current) current.count += 1;
    else counts.set(key, { name: normalized, count: 1 });
  }

  return Array.from(counts.values())
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name, 'tr'))
    .slice(0, Math.max(0, limit));
}

/// Kaynak filtresi istemcide uygulandığı için farklı sağlayıcıların aynı olaya
/// ait kayıtlarını korur; yalnızca aynı sağlayıcı + kimlik tekrarını kaldırır.
export function uniqueQuakesByProviderId(quakes: Earthquake[]): Earthquake[] {
  const unique = new Map<string, Earthquake>();
  for (const quake of quakes) {
    unique.set(`${quake.provider}:${quake.id}`, quake);
  }
  return Array.from(unique.values())
    .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
}

/// `minMagnitude == 0`, istemcideki “Tümü” seçeneğidir ve sağlayıcının
/// yayımladığı negatif/mikro büyüklükleri de korur.
export function filterMapQuakes(quakes: Earthquake[], startMs: number, minMagnitude: number): Earthquake[] {
  return quakes.filter(quake => {
    const time = new Date(quake.date).getTime();
    if (!Number.isFinite(time) || time < startMs) return false;
    return Number.isFinite(quake.magnitude)
      && (minMagnitude <= 0 || quake.magnitude >= minMagnitude);
  });
}

/// Harita yanıtı kayıt başına ~450 bayt taşır ve 30 günlük havuz 30.000 kaydı
/// aşar. Ancak bu havuz yalnızca haritayı çizmez: kullanıcı bir işarete
/// dokunup "Detay"a gittiğinde `EarthquakeDetailView` **aynı nesneyi** alır ve
/// teknik kartı ondan doldurur. Detay ekranı kaydı sunucudan yeniden
/// çekmediği için, burada düşürülen her alan o ekranda kalıcı olarak kaybolur.
///
/// Bu nedenle yalnızca hiçbir ekranın okumadığı alanlar düşürülür:
/// - `detailURL`: sadece `SeismicDataService` kendi USGS eşleşmesinden aldığı
///   kayıtta kullanılır, `/map` kaydından hiç okunmaz.
/// - `tsunami`: `stripNullish` zaten `false` değerleri atıyor; `true` olduğunda
///   da hiçbir görünüm `/map` havuzundan okumuyor.
///
/// `sourceURL`, `updatedAt`, `status`, `network`, `code`, `eventType`,
/// `catalog`, `author`, `significance`, `stationCount`, `minimumDistance`,
/// `rms` ve `gap` KASITLI olarak korunur — hepsi teknik kartta gösterilir.
/// Yayımlanmış istemciler bu alanları bekliyor, dolayısıyla bunları düşürmek
/// sunucu tarafında geriye dönük kırıcı bir değişikliktir.
export const MAP_OMITTED_FIELDS: readonly string[] = ['detailURL', 'tsunami'];

/// Harita havuzundan gelen bir kaydın detay ekranında göstereceği alanlar.
/// Bunlar projeksiyondan düşerse teknik kart sessizce boşalır.
export const MAP_DETAIL_CRITICAL_FIELDS: readonly string[] = [
  'sourceURL', 'updatedAt', 'status', 'network', 'code', 'eventType',
  'catalog', 'author', 'significance', 'stationCount', 'minimumDistance',
  'rms', 'gap'
];

export function toMapProjection(quake: Earthquake): Partial<Earthquake> {
  const projected: Record<string, unknown> = { ...(quake as unknown as Record<string, unknown>) };
  for (const field of MAP_OMITTED_FIELDS) delete projected[field];
  return projected as Partial<Earthquake>;
}

/// Uzun süreli sağlayıcı arşivleri istatistiklere katılırken seçilen tarih
/// penceresinin dışındaki kayıtların toplamları bozmasını önler. Küçük saat
/// sapmalarına izin verilir; belirgin gelecekteki hatalı kayıtlar elenir.
export function isQuakeWithinTimeWindow(
  quake: Pick<Earthquake, 'date'>,
  startMs: number,
  endMs: number = Date.now() + 180_000
): boolean {
  const time = new Date(quake.date).getTime();
  return Number.isFinite(time) && time >= startMs && time <= endMs;
}

/// Tazelik penceresindeki bildirim adaylarını seçer.
///
/// `excludeIds` (ör. daha önce işlenmiş deprem kimlikleri) kotadan ÖNCE
/// elenir. Çağıran taraf kırpılmış listeyi sonradan filtrelediğinde, zaten
/// bildirilmiş kayıtlar `limit` kotasını doldurup henüz bildirilmemiş bir
/// depremi hiç incelenmeden dışarıda bırakıyordu; olay tazelik penceresini
/// aşınca da kalıcı olarak kayboluyordu.
///
/// Kota gerçekten dolduğunda hangi kayıtların düşeceğini büyüklük belirler:
/// bir sarsıntı yağmuru, aynı pencerede yayımlanan bir ana şoku listeden
/// atmamalı. Dönen sıralama sözleşmesi değişmez — en yeniden eskiye.
export function selectFreshQuakes(
  quakes: Earthquake[],
  now: number = Date.now(),
  maxAgeMs: number | ((quake: Earthquake) => number) = 5 * 60 * 1000,
  limit: number = 12,
  excludeIds: ReadonlySet<string> = new Set()
): Earthquake[] {
  const seen = new Set<string>();
  const candidates: { quake: Earthquake; time: number }[] = [];
  const maxAgeFor = typeof maxAgeMs === 'function' ? maxAgeMs : () => maxAgeMs;

  for (const quake of quakes) {
    const time = new Date(quake.date).getTime();
    if (!Number.isFinite(time) || time > now + 180000 || now - time >= maxAgeFor(quake)
        || seen.has(quake.id) || excludeIds.has(quake.id)) continue;
    seen.add(quake.id);
    candidates.push({ quake, time });
  }

  if (candidates.length > limit) {
    candidates.sort((a, b) =>
      (b.quake.magnitude - a.quake.magnitude) || (b.time - a.time));
    candidates.length = limit;
  }

  return candidates
    .sort((a, b) => b.time - a.time)
    .map(({ quake }) => quake);
}

/// Bildirim gönderim sırası. Bir cihaz tek scheduler turunda yalnızca bir
/// bildirim alır (bkz. `deliveredDeviceKeysThisRun`); o tek bildirim turun en
/// YENİ değil, en ÖNEMLİ olayı olmalı. Saf zaman sıralamasında saniyeler
/// sonra gelen küçük bir artçı, ana şokun bildirimini bastırıyordu.
export function orderQuakesForDelivery(quakes: readonly Earthquake[]): Earthquake[] {
  return [...quakes].sort((a, b) =>
    (b.magnitude - a.magnitude)
    || (new Date(b.date).getTime() - new Date(a.date).getTime()));
}

export function getDistanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371; // Earth's radius in km
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = 
    Math.sin(dLat/2) * Math.sin(dLat/2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * 
    Math.sin(dLon/2) * Math.sin(dLon/2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return R * c;
}

/// iOS'taki SeismicImpactModel ile aynı azalım ve Wald MMI dönüşümü. Böylece
/// bildirim filtresi ile "Beni Nasıl Etkiler" ekranı aynı sonucu üretir.
export function estimatedMMIAtDistance(magnitude: number, depthKm: number, distanceKm: number): number {
  const depth = Math.max(1, depthKm);
  const epicentral = Math.max(0, distanceKm);
  const hypocentral = Math.hypot(epicentral, depth);
  const logPGA = 0.58 * magnitude - 1.25 * Math.log10(hypocentral + 6) - 0.0021 * hypocentral - 2.20;
  const pgaG = Math.max(0.00001, Math.pow(10, logPGA));
  const pgaCmPerSecSquared = pgaG * 980.665;
  const mmi = pgaCmPerSecSquared >= 80
    ? 3.66 * Math.log10(pgaCmPerSecSquared) - 1.66
    : 2.20 * Math.log10(pgaCmPerSecSquared) + 1.00;
  return Math.min(10, Math.max(0, mmi));
}

// Türkiye, Ege, Kıbrıs ve yakın Doğu Akdeniz'i kapsayan hızlı bildirim alanı.
// AFAD'ın yerel kapsamasına yakın tutulur; böylece AFAD seçen kullanıcıya
// bölge dışındaki tüm EMSC/USGS/NOA kataloğu yanlışlıkla gönderilmez.
export function isTurkeyFastLaneQuake(q: Pick<Earthquake, 'lat' | 'lon'>): boolean {
  return q.lat >= 34 && q.lat <= 43 && q.lon >= 23 && q.lon <= 47;
}

/// Eski kuralda seçilen kaynağın izlediği bölge. Son 30 günün kayıtları
/// (22 Eyl 2026: AFAD enlem 34,1–43,2 boylam 23,4–45,5 · NOA enlem
/// 34,0–41,1 boylam 19,7–27,4) ve ajansların bilinen yayın alanı (AFAD Batı
/// Yunanistan, Kafkasya ve Batı İran'ı da yayımlar) payla kapsanır. Seçilen
/// ajansın KENDİ kaydı bu kutudan bağımsız olarak her zaman eşleşir.
export function isWithinSourceCoverage(q: Pick<Earthquake, 'lat' | 'lon'>, source: string): boolean {
  switch (source) {
    case 'afad': return q.lat >= 33 && q.lat <= 45 && q.lon >= 19 && q.lon <= 50;
    case 'noa': return q.lat >= 33 && q.lat <= 42.5 && q.lon >= 18.5 && q.lon <= 30;
    default: return true; // usgs, emsc, all: dünya geneli
  }
}

// MARK: - Ücretsiz bildirim katmanı
//
// Ücretsiz kullanıcı, dünyanın neresinde olursa olsun kendi seçtiği TEK bir
// yerin dar çevresini (en fazla 50 km) ve dünya genelindeki M6.0+ depremleri
// alır. Daha fazla yer, daha geniş yarıçap, dünya eşiğini ayarlamak, kritik
// uyarı, özel ses ve artçı takibi premium'dur. Sınırlar sunucuda uygulanır
// (`freeTierPrefs`): istemci ne gönderirse göndersin ücretsiz cihazda
// yalnızca ilk yer ve kırpılmış yarıçap kullanılır.
export const FREE_PLACE_LIMIT = 1;
export const FREE_MAX_RADIUS_KM = 50;
export const FREE_WORLD_MAJOR_MIN_MAGNITUDE = 6.0;

/// X paylaşımında "Türkiye depremi": sınırın içinde, kıyısına yakın denizde
/// (bkz. `isInTurkiye`) ya da AFAD'ın ülke alanı Türkiye olan kaydı. Kaynak
/// fark etmez: EMSC'nin "CENTRAL TURKEY" kaydı da sayılır.
export function isTurkiyeQuake(q: Pick<Earthquake, 'provider' | 'country' | 'lat' | 'lon'>): boolean {
  const country = String(q.country || '').trim().toLocaleLowerCase('tr');
  if (String(q.provider || '').toUpperCase() === 'AFAD' && (country === 'türkiye' || country === 'turkey')) return true;
  return isInTurkiye(q.lat, q.lon);
}

/// X paylaşım uygunluğu KONUMA bağlıdır, kaynağa değil (22 Eyl 2026):
/// Türkiye'de M3.0+, diğer her yerde M5.5+. Hangi ajans olayı önce
/// yayımlarsa onun kaydı paylaşılır; aynı olayın diğer ajans kopyaları parmak
/// iziyle atlanır (twitter-posting.ts). Eskiden Türkiye'deki M3–M6 olaylarda
/// yalnızca AFAD kaydı uygundu ve AFAD'ın geç yayını (ölçülen: 53 dk)
/// paylaşımı da geciktiriyordu.
export function isQuakeEligibleForTwitter(
  q: Pick<Earthquake, 'magnitude' | 'provider' | 'country' | 'lat' | 'lon'>,
  turkiyeMinMagnitude = 3.0,
  worldMinMagnitude = 5.5
): boolean {
  return q.magnitude >= (isTurkiyeQuake(q) ? turkiyeMinMagnitude : worldMinMagnitude);
}

/// Başarılı bir X paylaşımının kimliği sağlayıcı tarafından değiştirilse bile
/// aynı fiziksel depremi yeniden paylaşma. Başarısız denemeler bu listeye
/// eklenmediğinden kredi/ağ hataları güvenle yeniden denenebilir.
export function isQuakePreviouslyTweeted(
  q: Earthquake,
  tweetedIds: ReadonlySet<string>,
  tweetedFingerprints: readonly QuakeFingerprint[]
): boolean {
  if (tweetedIds.has(q.id)) return true;
  return tweetedFingerprints.some(item =>
    item.id === q.id || isLikelyCrossProviderDuplicate(q, item)
  );
}

export function toQuakeFingerprint(q: Earthquake): QuakeFingerprint | null {
  const time = new Date(q.date).getTime();
  if (!Number.isFinite(time) || !Number.isFinite(q.magnitude)
      || !Number.isFinite(q.lat) || !Number.isFinite(q.lon)) return null;
  return {
    id: q.id,
    provider: q.provider,
    time,
    magnitude: q.magnitude,
    lat: q.lat,
    lon: q.lon
  };
}

// Sağlayıcı kimlikleri farklı olduğu için aynı fiziksel depremi zaman, konum
// ve büyüklük yakınlığıyla eşleştirir. Dar eşikler art arda gerçekleşen gerçek
// iki depremden birini yanlışlıkla bastırma riskini azaltır.
export function isLikelyCrossProviderDuplicate(
  q: Earthquake,
  fingerprint: QuakeFingerprint,
  maxTimeDeltaMs = 120_000,
  maxDistanceKm = 100,
  maxMagnitudeDelta = 1.0
): boolean {
  if (q.provider.toLowerCase() === fingerprint.provider.toLowerCase()) return false;
  const time = new Date(q.date).getTime();
  if (!Number.isFinite(time) || Math.abs(time - fingerprint.time) > maxTimeDeltaMs) return false;
  if (Math.abs(q.magnitude - fingerprint.magnitude) > maxMagnitudeDelta) return false;
  return getDistanceKm(q.lat, q.lon, fingerprint.lat, fingerprint.lon) <= maxDistanceKm;
}

// Push bildirimi teslimi X paylaşımından farklı bir hassasiyet ister: art arda
// gerçekleşen gerçek artçı depremleri yanlışlıkla bastırmamak için burada
// isLikelyCrossProviderDuplicate'in varsayılanlarından (X'in gevşetilmiş
// çapraz-tur eşiklerinden) BİLEREK daha dar, orijinal değerler kullanılır —
// bu iki çağrı yeri paylaşılan varsayılanlara bağlı kalırsa, X tarafında
// yapılan bir gevşetme sessizce push teslimini de etkiler.
const PUSH_DUPLICATE_MAX_TIME_DELTA_MS = 60_000;
const PUSH_DUPLICATE_MAX_DISTANCE_KM = 50;

/// Push teslimindeki ajanslar arası kopya kuralı (servisler arası ortak
/// teslim defteri de aynı eşikleri kullanır).
export function isPushDuplicateOf(quake: Earthquake, fingerprint: QuakeFingerprint): boolean {
  return isLikelyCrossProviderDuplicate(
    quake, fingerprint, PUSH_DUPLICATE_MAX_TIME_DELTA_MS, PUSH_DUPLICATE_MAX_DISTANCE_KM
  );
}

/// Aynı fiziksel depremin ikinci sağlayıcı kopyasını eler; ilk raporlayan
/// kazanır.
///
/// Eskiden yalnızca Türkiye kutusuna uygulanıyordu (`selectFastestTurkeyQuakes`):
/// kutu dışında kaynak filtresi sağlayıcıları birbirinden ayırdığı için gerek
/// yoktu. Kaynak filtresi kalkınca bu gerekçe de kalktı — Tokyo'da kayıtlı
/// yeri olan kullanıcı aynı depremi USGS ve EMSC'den iki kez alırdı.
///
/// Eşikler (60 sn / 50 km / 1.0 büyüklük) değişmedi: bunlar fizikten geliyor,
/// coğrafyadan değil ve art arda gelen gerçek artçıları yanlışlıkla
/// bastırmamak için bilinçle dar tutuluyor.
///
/// `duplicateOf`, her bastırılan kopyanın hangi ilk kayda denk geldiğini
/// söyler. Bastırma "kimse almasın" demek DEĞİLDİR: kaynağı katı olan eski
/// kuraldaki bir cihaz ilk kopyayla hiç eşleşmemiş olabilir (ör. Batı
/// Yunanistan'daki olayı EMSC önce yayımladı, cihazın kaynağı AFAD). Teslim
/// döngüsü kopyayı yalnızca ilk kaydı İSTEMEYEN cihazlara gönderir — bkz.
/// `shouldDeliverDuplicate`.
export function selectFastestQuakes(
  quakes: Earthquake[],
  handled: QuakeFingerprint[]
): { selected: Earthquake[]; suppressed: Earthquake[]; duplicateOf: Map<string, QuakeFingerprint> } {
  const selected: Earthquake[] = [];
  const selectedFingerprints: QuakeFingerprint[] = [];
  const suppressed: Earthquake[] = [];
  const duplicateOf = new Map<string, QuakeFingerprint>();

  for (const quake of quakes) {
    const isDuplicateOf = (item: QuakeFingerprint) => isPushDuplicateOf(quake, item);
    const original = handled.find(isDuplicateOf) ?? selectedFingerprints.find(isDuplicateOf);
    if (original) {
      suppressed.push(quake);
      duplicateOf.set(quake.id, original);
      continue;
    }

    selected.push(quake);
    const fingerprint = toQuakeFingerprint(quake);
    if (fingerprint) selectedFingerprints.push(fingerprint);
  }

  return { selected, suppressed, duplicateOf };
}

/// Parmak izinden eşleştiriciye verilebilecek bir deprem kurar. Derinlik ve
/// başlık parmak izinde tutulmaz; kopyanınkiler kullanılır (aynı fiziksel
/// olay, farklı ajans).
export function quakeFromFingerprint(fingerprint: QuakeFingerprint, copy: Earthquake): Earthquake {
  return {
    ...copy,
    id: fingerprint.id,
    provider: fingerprint.provider,
    magnitude: fingerprint.magnitude,
    lat: fingerprint.lat,
    lon: fingerprint.lon,
    date: new Date(fingerprint.time).toISOString()
  };
}

/// Depremi kullanıcının takip ettiği yerlerle karşılaştırır.
///
/// Sıralama maliyete göre kurulur: önce büyüklük (tek karşılaştırma), sonra
/// derece bazlı hızlı sınır (iki çıkarma), en sonda haversine. On binlerce
/// cihaz × 5 yer × 12 deprem ölçeğinde kontrollerin ~%95'i ilk iki adımda
/// elenir; uzamsal indeks bu yüzden gerekmiyor (bkz. spec §7).
///
/// Birden fazla yer tutarsa EN YAKIN olan kazanır — bildirimde görünecek ad
/// ve mesafe ondan gelir.
export function matchPlace(
  q: Pick<Earthquake, 'lat' | 'lon' | 'magnitude'> & { depth?: number },
  places: readonly DevicePlace[] | undefined
): { place: DevicePlace; distanceKm: number; feltAtPlace?: boolean; feltMMI?: number } | null {
  if (!places?.length) return null;
  let best: { place: DevicePlace; distanceKm: number; feltAtPlace?: boolean; feltMMI?: number } | null = null;
  for (const place of places) {
    // Hissedilir şiddet kuralı: yarıçaptan ve büyüklük eşiğinden bağımsız.
    if (place.feltIntensity && q.magnitude >= FELT_RULE_MIN_MAGNITUDE
        && Math.abs(place.lat - q.lat) * KM_PER_DEG_LAT <= 600) {
      const distanceKm = getDistanceKm(place.lat, place.lon, q.lat, q.lon);
      const inRadius = distanceKm <= place.radiusKm && q.magnitude >= place.minMagnitude;
      const mmi = estimatedMMIAtDistance(q.magnitude, q.depth ?? 10, distanceKm);
      if (!inRadius && mmi >= place.feltIntensity) {
        if (!best || distanceKm < best.distanceKm) best = { place, distanceKm, feltAtPlace: true, feltMMI: mmi };
        continue;
      }
    }
    if (q.magnitude < place.minMagnitude) continue;
    if (Math.abs(place.lat - q.lat) * KM_PER_DEG_LAT > place.radiusKm) continue;
    // Boylam ön elemesi YALNIZCA orta enlemlerde uygulanır.
    //
    // Yüksek enlemde iki nokta arasındaki gerçek yol kutbun üzerinden geçerek
    // KISALIR; paralel boyunca ölçen bir sınır bunu göremez ve yarıçapın
    // yüzlerce km içindeki depremi eler (ölçüldü: enlem -84'te 1000 km
    // yarıçapta 93 km içeride kalan olay eleniyordu). Bu bölgede ön eleme
    // atlanıp doğrudan haversine'a geçilir — maliyeti ihmal edilebilir,
    // çünkü adayların ezici çoğunluğu zaten enlem sınırında elenmiş oluyor.
    const maxAbsLat = Math.max(Math.abs(place.lat), Math.abs(q.lat));
    if (maxAbsLat <= LON_PREFILTER_MAX_ABS_LAT) {
      // Kosinüs YÜKSEK olan mutlak enlemle alınır: orada bir boylam derecesi
      // en kısadır, dolayısıyla sınır en gevşek hâlini alır. Mevcut yarıçap
      // üst sınırında (1000 km) yerin kendi enlemini kullanmak da ölçülebilir
      // bir hata üretmiyordu — enlem farkı zaten yarıçapla sınırlı olduğu
      // için iki kosinüs birbirine yakın kalıyor. Yine de doğru olan bu:
      // yarıçap sınırı ileride büyütülürse fark açılır.
      const lonScale = KM_PER_DEG_LON_EQUATOR * Math.cos(maxAbsLat * Math.PI / 180);
      if (longitudeDeltaDegrees(place.lon, q.lon) * lonScale
          > place.radiusKm * LON_PREFILTER_SAFETY) continue;
    }
    const distanceKm = getDistanceKm(place.lat, place.lon, q.lat, q.lon);
    if (distanceKm > place.radiusKm) continue;
    if (!best || distanceKm < best.distanceKm) best = { place, distanceKm };
  }
  return best;
}

/// İstemciden gelen yer listesini güvenli hâle getirir.
///
/// Yük tamamen istemci kontrolünde olduğu için kırpma ZORUNLUDUR: sayı,
/// isim uzunluğu, yarıçap ve eşik sınırlanır, geçersiz koordinatlı kayıt
/// atılır.
export function sanitizeDevicePlaces(input: unknown): DevicePlace[] {
  if (!Array.isArray(input)) return [];
  const out: DevicePlace[] = [];
  for (const raw of input) {
    if (!raw || typeof raw !== 'object') continue;
    const item = raw as Record<string, unknown>;
    const lat = Number(item.lat);
    const lon = Number(item.lon);
    if (!Number.isFinite(lat) || Math.abs(lat) > 90) continue;
    if (!Number.isFinite(lon) || Math.abs(lon) > 180) continue;
    const minMagnitude = Math.min(9, Math.max(1, Number(item.minMagnitude) || 3));
    const criticalRaw = Number(item.criticalMagnitude);
    // Firestore `undefined` alan kabul etmez; eşik yoksa alan hiç yazılmaz.
    const critical = item.criticalMagnitude !== undefined && item.criticalMagnitude !== null
      && Number.isFinite(criticalRaw)
      ? { criticalMagnitude: Math.min(9, Math.max(PLACE_MIN_CRITICAL_MAGNITUDE, minMagnitude, criticalRaw)) }
      : {};
    out.push({
      id: String(item.id ?? '').slice(0, 64) || `p${out.length}`,
      name: String(item.name ?? '').slice(0, 40),
      // Eski (emojili) istemci `emoji` gönderir; en yakın simgeye taşınır.
      icon: normalizePlaceIcon(item.icon ?? item.emoji),
      lat,
      lon,
      radiusKm: Math.min(PLACE_MAX_RADIUS_KM,
        Math.max(PLACE_MIN_RADIUS_KM, Number(item.radiusKm) || 100)),
      minMagnitude,
      ...critical,
      ...(FELT_INTENSITIES.has(Number(item.feltIntensity)) ? { feltIntensity: Number(item.feltIntensity) } : {})
    });
    if (out.length >= MAX_DEVICE_PLACES) break;
  }
  return out;
}

/// Cihaz belgesi hangi bildirim kuralına tabi?
///
/// Tek değişmez kural: `places` alanı DİZİ olarak varsa belge yer
/// modelindedir, yoksa eski kuraldadır. `/register` bunu korur — yer
/// listesi yazan kayıt eski alanları siler, eski biçimde gelen kayıt da
/// `places`'i siler. Boş dizi "yer yok" demektir, eski kurala düşmez:
/// yerlerini silen kullanıcıya eski kural sessizce geri dönmemeli.
export function deviceUsesPlaces(data: Record<string, any> | undefined): boolean {
  return Array.isArray(data?.places);
}

/// Belgeden push eşleşmesinde kullanılacak yer listesi. Eski kuraldaki
/// belgede boştur.
export function placesFromDeviceData(data: Record<string, any> | undefined): DevicePlace[] {
  return deviceUsesPlaces(data) ? sanitizeDevicePlaces(data!.places) : [];
}

const LEGACY_SOURCES = new Set(['afad', 'emsc', 'usgs', 'noa']);

/// Eski kuraldaki belgenin alanlarını okur. Varsayılanlar, 2.0.9'u işleten
/// sunucuyla (9 Eylül 2026 dağıtımı) birebir aynıdır.
export function legacyRulesFromDeviceData(data: Record<string, any> | undefined): LegacyRules | undefined {
  if (!data || deviceUsesPlaces(data)) return undefined;
  const rawSource = String(data.source || '').toLowerCase();
  const latitude = data.latitude !== undefined && data.latitude !== null ? Number(data.latitude) : undefined;
  const longitude = data.longitude !== undefined && data.longitude !== null ? Number(data.longitude) : undefined;
  const hasCoordinate = Number.isFinite(latitude) && Number.isFinite(longitude);
  return {
    minMagnitude: Number(data.min_magnitude) || 4.0,
    majorThreshold: Number(data.major_threshold) || 5.0,
    source: LEGACY_SOURCES.has(rawSource) ? rawSource : 'afad',
    sourceFallbackEnabled: Boolean(data.source_fallback_enabled),
    nearbyOnly: Boolean(data.nearby_only),
    latitude: hasCoordinate ? latitude : undefined,
    longitude: hasCoordinate ? longitude : undefined,
    radius: data.radius !== undefined ? Number(data.radius) : undefined,
    minimumEstimatedMMI: Number(data.minimum_estimated_mmi) || 0
  };
}

/// Eski kuralın eşleştiricisi — 2.0.9'u işleten sunucudaki
/// `notificationMatch`'in artçı takibinden sonraki bölümünün aynısı.
/// Bilerek DEĞİŞTİRİLMEDİ: güncellememiş kullanıcı, sunucu yenilendi diye
/// farklı bildirim almamalı.
function legacyNotificationMatch(
  q: Earthquake,
  prefs: DevicePrefs,
  rules: LegacyRules,
  ignoreSource: boolean
): NotificationMatch | null {
  const isWorldwideMajor = Boolean(prefs.worldMajorEnabled)
    && !isTurkeyFastLaneQuake(q)
    && q.magnitude >= (prefs.worldMajorThreshold || 6.5);
  if (isWorldwideMajor) return { reason: 'world_major' };

  if (q.magnitude < rules.minMagnitude) return null;

  // majorThreshold "Türkiye ve yakın çevresi için öncelikli deprem eşiği":
  // yakınlık filtresini yalnızca Türkiye kutusundaki olaylar için aşar.
  const isMajor = q.magnitude >= rules.majorThreshold;
  const isRegionalMajor = isMajor && isTurkeyFastLaneQuake(q);
  // Seçilen kaynak FİLTRE değil KAPSAMDIR (22 Eyl 2026): o ajansın izlediği
  // bölgedeki olayı hangi ajans ÖNCE yayımlarsa bildirim o anda gider —
  // Türkiye/dünya ayrımı yok. Eskiden yalnızca Türkiye kutusunda böyleydi,
  // dışında seçilen ajansın kendi kaydı beklenirdi. Kapsam korunur: AFAD'ı
  // seçip "tüm bölgeler" diyen kullanıcı dünyanın her yerindeki M3'leri
  // almamalı. USGS/EMSC dünyayı izlediği için onlarda sınır yok.
  if (!ignoreSource && rules.source !== 'all' && q.provider.toLowerCase() !== rules.source
      && !isWithinSourceCoverage(q, rules.source)) return null;

  let distance: number | undefined;
  let isNearbyMatch = false;
  if (rules.nearbyOnly && !isRegionalMajor) {
    // "Yalnızca yakınımdakiler" ama koordinat yok: onay verilmemiş bir
    // global akış göndermek yerine eşleşme yok.
    if (rules.latitude === undefined || rules.longitude === undefined) return null;
    const limitRadius = rules.radius || 250;
    if (Math.abs(rules.latitude - q.lat) * 111 > limitRadius) return null;
    distance = getDistanceKm(rules.latitude, rules.longitude, q.lat, q.lon);
    if (distance > limitRadius) return null;
    isNearbyMatch = true;
  } else if (rules.latitude !== undefined && rules.longitude !== undefined) {
    // Yalnızca gösterim için; `isNearbyMatch` false kalır.
    distance = getDistanceKm(rules.latitude, rules.longitude, q.lat, q.lon);
  }

  const minimumMMI = rules.minimumEstimatedMMI || 0;
  let estimatedMMI: number | undefined;
  if (minimumMMI > 0) {
    if (rules.latitude === undefined || rules.longitude === undefined) return null;
    distance ??= getDistanceKm(rules.latitude, rules.longitude, q.lat, q.lon);
    estimatedMMI = estimatedMMIAtDistance(q.magnitude, q.depth, distance);
    if (estimatedMMI < minimumMMI) return null;
  }

  return {
    reason: minimumMMI > 0 ? 'felt' : 'regular',
    distanceKm: distance,
    isNearbyMatch,
    estimatedMMI
  };
}

/// Bir depremin bu cihaza bildirim üretip üretmeyeceğine karar verir.
///
/// Sıra en özelden en genele: artçı takibi → takip edilen yerler → dünya
/// geneli büyük deprem. Yerler dünya eşiğinden ÖNCE denenir; evinin 10 km
/// yanındaki M7 için kullanıcı "Dünyada büyük deprem" değil "Ev yakınında"
/// bildirimini görmeli.
///
/// Yer modelinde kaynak filtresi YOKTUR: bildirim kaydedilen yerlere göre
/// geldiğine göre, olayı hangi ajansın raporladığı kullanıcıyı
/// ilgilendirmez. Eski kuraldaki cihaz (`prefs.legacy`) ise artçı
/// takibinden sonra tamamen kendi eşleştiricisine gider; `ignoreSource`
/// yalnızca orada, seçili sağlayıcı kesintideyken anlam taşır.
export function notificationMatch(
  q: Earthquake,
  prefs: DevicePrefs,
  now: number = Date.now(),
  ignoreSource = false
): NotificationMatch | null {
  const watch = prefs.aftershockWatch;
  const quakeTime = new Date(q.date).getTime();
  if (watch && now < watch.expiresAt && Number.isFinite(quakeTime)
      && quakeTime > watch.startedAt && q.id !== watch.mainshockId
      && q.magnitude >= watch.minimumMagnitude) {
    const watchDistance = getDistanceKm(watch.latitude, watch.longitude, q.lat, q.lon);
    if (watchDistance <= watch.radiusKm) {
      return { reason: 'aftershock', distanceKm: watchDistance, watchTitle: watch.title };
    }
  }

  if (prefs.legacy) return legacyNotificationMatch(q, prefs, prefs.legacy, ignoreSource);

  const hit = matchPlace(q, prefs.places);
  if (hit) {
    return {
      reason: 'place',
      distanceKm: hit.distanceKm,
      placeName: hit.place.name,
      placeIcon: hit.place.icon,
      // Uzaktan hissedilir eşleşme kritik uyarı (sessiz modu aşan alarm)
      // yalnızca yerde güçlü sarsıntı (tahmini MMI ≥ 5) bekleniyorsa verir.
      placeCriticalMagnitude: hit.feltAtPlace && (hit.feltMMI ?? 0) < 5 ? undefined : hit.place.criticalMagnitude,
      ...(hit.feltAtPlace ? { feltAtPlace: true } : {})
    };
  }

  if (Boolean(prefs.worldMajorEnabled) && q.magnitude >= (prefs.worldMajorThreshold || 6.5)) {
    return { reason: 'world_major' };
  }

  return null;
}

export function matches(
  q: Earthquake,
  prefs: DevicePrefs,
  now: number = Date.now()
): boolean {
  return notificationMatch(q, prefs, now) !== null;
}

/// Bastırılmış bir sağlayıcı kopyası bu cihaza gitmeli mi?
///
/// Yalnızca cihaz kopyayla eşleşiyor VE aynı olayın ilk kaydıyla
/// eşleşmiyorsa. İlk kayıtla eşleşen cihaz o bildirimi zaten aldı (ya da
/// alacak); kopyayı da göndermek çift bildirim olurdu. Karar deterministik
/// olduğu için cihaz başına "neyi aldı" kaydı tutmak gerekmiyor.
///
/// Bu kural iki durumu birden kapatır:
///  - Eski kuralda kaynağı katı olan cihaz (ör. AFAD), kutu dışındaki bir
///    olayı EMSC önce yayımladığında AFAD kopyasını kaybetmez.
///  - Yer modelinde, ilk ajansın büyüklüğü eşiğin altında kalıp ikincisininki
///    üstünde çıkarsa kullanıcı olayı yine duyar.
export function shouldDeliverDuplicate(
  copy: Earthquake,
  original: QuakeFingerprint,
  prefs: DevicePrefs,
  now: number = Date.now(),
  ignoreSource = false
): NotificationMatch | null {
  const match = notificationMatch(copy, prefs, now, ignoreSource);
  if (!match) return null;
  const originalQuake = quakeFromFingerprint(original, copy);
  // Cihaz ilk kayıttan SONRA kaydolduysa ilk kaydı hiç almamıştır.
  const registeredAt = prefs.registeredAt || 0;
  const originalWasEligible = original.time > registeredAt;
  if (originalWasEligible && notificationMatch(originalQuake, prefs, now, ignoreSource)) return null;
  return match;
}

// MARK: - Büyüklük düzeltmesi
//
// Ajansların ilk çözümü otomatik bir ön değerdir. 10 Eylül'de NOA bir
// depremi M2.0 olarak yayımladı (kullanıcının M2.0 eşiğini kıl payı geçti),
// sonra M1.17'ye çekti: bildirim hiç gitmemeliydi. Gönderilmiş bildirim bu
// yüzden ajans büyüklüğü belirgin biçimde değiştirdiğinde güncellenir.

/// Gönderilmiş bir depremin, gönderildiği andaki hâli.
export interface DeliveredQuakeSnapshot {
  id: string;
  provider: string;
  magnitude: number;
  depth: number;
  lat: number;
  lon: number;
  date: string;
  sentAt: number;
  corrections: number;
  /// Kopya olarak teslim edildiyse asıl kaydın parmak izi; alıcılar aynı
  /// kuralla (`shouldDeliverDuplicate`) yeniden bulunur.
  duplicateOf?: QuakeFingerprint;
}

/// Düzeltmeyi tetikleyen en küçük büyüklük farkı. Ajanslar arası olağan
/// oynama (±0.1–0.2) kullanıcıya ikinci bildirim olarak yansımasın.
export const MAGNITUDE_CORRECTION_THRESHOLD = 0.3;
/// Bu süreden eski bildirim düzeltilmez: Bildirim Merkezi'nde çoktan
/// görülmüş, değeri kalmamış bir kaydı güncellemek gürültüdür.
export const MAGNITUDE_CORRECTION_WINDOW_MS = 3 * 60 * 60 * 1000;
export const MAX_MAGNITUDE_CORRECTIONS = 2;

export function findMagnitudeRevisions(
  snapshots: readonly DeliveredQuakeSnapshot[],
  quakes: readonly Earthquake[],
  now: number
): Array<{ snapshot: DeliveredQuakeSnapshot; current: Earthquake }> {
  if (!snapshots.length) return [];
  const byId = new Map(quakes.map(q => [q.id, q]));
  const out: Array<{ snapshot: DeliveredQuakeSnapshot; current: Earthquake }> = [];
  for (const snapshot of snapshots) {
    if (now - snapshot.sentAt > MAGNITUDE_CORRECTION_WINDOW_MS) continue;
    if (snapshot.corrections >= MAX_MAGNITUDE_CORRECTIONS) continue;
    const current = byId.get(snapshot.id);
    if (!current || !Number.isFinite(current.magnitude)) continue;
    if (Math.abs(current.magnitude - snapshot.magnitude) < MAGNITUDE_CORRECTION_THRESHOLD - 1e-9) continue;
    out.push({ snapshot, current });
  }
  return out;
}

/// Revize edilen deprem bu cihaz için ne üretir?
///
/// - `correction`: cihaz ilk hâli almıştı; bildirim sessizce güncellenir.
/// - `new`: ilk hâl cihazın eşiğinin altındaydı, revize hâl üstünde; cihaz
///   olayı ilk kez duyar (normal bildirim).
/// - `null`: cihazı ilgilendirmiyor.
///
/// "Kim aldı" kaydı tutulmaz; ilk hâl eşleştiriciye yeniden verilerek bulunur.
export function magnitudeRevisionDecision(
  snapshot: DeliveredQuakeSnapshot,
  current: Earthquake,
  prefs: DevicePrefs,
  now: number,
  ignoreSource = false
): { kind: 'correction' | 'new'; match: NotificationMatch } | null {
  const original: Earthquake = {
    ...current,
    magnitude: snapshot.magnitude,
    depth: snapshot.depth,
    lat: snapshot.lat,
    lon: snapshot.lon,
    date: snapshot.date
  };
  const evaluate = (q: Earthquake) => snapshot.duplicateOf
    ? shouldDeliverDuplicate(q, snapshot.duplicateOf, prefs, now, ignoreSource)
    : notificationMatch(q, prefs, now, ignoreSource);
  const wasEligible = (prefs.registeredAt || 0) < snapshot.sentAt;
  const received = wasEligible ? evaluate(original) : null;
  const revised = evaluate(current);
  if (received) return { kind: 'correction', match: revised ?? received };
  // Olaydan sonra kaydolan cihaza eski deprem "yeni" diye gitmez (ana
  // teslim döngüsündeki `registeredAt` kuralıyla aynı).
  if (revised && new Date(current.date).getTime() > (prefs.registeredAt || 0)) {
    return { kind: 'new', match: revised };
  }
  return null;
}

export function normalizePushToken(value: string, transport: string = 'apns'): string {
  const token = String(value || '').trim();
  return transport === 'fcm' ? token : token.toLowerCase();
}

export function isValidPushToken(token: string, transport: string = 'apns'): boolean {
  if (transport === 'fcm') {
    return token.length >= 20 && token.length <= 4096 && !/[\s/\u0000-\u001f\u007f]/.test(token);
  }
  return /^[0-9a-f]{32,200}$/.test(token);
}

/// Cihazın istemciden gelen kalıcı alanları gerçekten değişmediyse Firestore
/// yazımını atlamamızı sağlar. `updated_at` ve doğrulama zamanı gibi yalnızca
/// sunucunun ürettiği alanlar `desired` içine konulmaz.
export function deviceRegistrationNeedsWrite(
  existing: Record<string, any> | undefined,
  desired: Record<string, any>,
  deletedFields: string[] = []
): boolean {
  if (!existing) return true;

  for (const [key, value] of Object.entries(desired)) {
    if (!isDeepStrictEqual(existing[key], value)) return true;
  }

  return deletedFields.some(field => {
    const val = existing[field];
    if (val === undefined) return false;
    // Mock / unit test ortamlarda FieldValue.delete() henüz işlenmemiş bir nesne olabilir
    if (val && typeof val === 'object' && val.constructor?.name?.includes('Delete')) return false;
    return true;
  });
}

/// Uzun süre tercih değiştirmeyen aktif cihazların inaktivite temizliğinde
/// kaybolmaması için kayıt canlılığının ne zaman yenileneceğini belirler.
export function deviceRegistrationHeartbeatDue(
  updatedAt: unknown,
  now: number = Date.now(),
  intervalMs: number = 7 * 86400000
): boolean {
  const value = Number(updatedAt || 0);
  return !Number.isFinite(value) || value <= 0 || now - value >= intervalMs;
}

/// Saatlik bakım turunun (her saat :05, İstanbul) hangi alt görevleri
/// yürüteceği: harita arşivi çift saatlerde, günlük temizlik 04:05'te,
/// haftalık özet pazartesi 09:05'te.
export function maintenanceTasksForInstant(
  now: number,
  timeZone: string = 'Europe/Istanbul'
): { refreshMap: boolean; cleanup: boolean; weeklyDigest: boolean } {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone,
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23'
  }).formatToParts(new Date(now));
  const value = (type: string) => Number(parts.find(part => part.type === type)?.value || -1);
  const hour = value('hour');
  const minute = value('minute');

  return {
    refreshMap: hour >= 0 && hour % 2 === 0 && minute >= 0 && minute < 15,
    cleanup: hour === 4 && minute >= 0 && minute < 15,
    weeklyDigest: parts.find(part => part.type === 'weekday')?.value === 'Mon'
      && hour === 9 && minute >= 0 && minute < 15
  };
}

// MARK: - Otomatik Twitter/X paylaşım metni
//
// Uygulamanın renk ölçeğiyle aynı aile (MagnitudeLevel.swift): M4 altı
// yeşil, M4–5.9 turuncu, M6+ kırmızı. Emoji paletinde ölçeğin yedi tonu
// yok; üç ana renk ailesi birebir eşlenir.
export function magnitudeTweetEmoji(magnitude: number): string {
  if (magnitude >= 6) return '🔴';
  if (magnitude >= 4) return '🟠';
  return '🟢';
}

/// MagnitudeLevel.swift `color` ile birebir aynı yedi ton (tweet kartı).
export function magnitudeHexColor(magnitude: number): string {
  if (magnitude >= 7) return '#8C0D14';   // bordo
  if (magnitude >= 6) return '#D92621';   // kırmızı
  if (magnitude >= 5) return '#E86608';   // koyu turuncu
  if (magnitude >= 4) return '#F89E17';   // açık turuncu
  if (magnitude >= 3) return '#8CAD1C';   // sarımsı yeşil
  if (magnitude >= 2) return '#33994A';   // yeşil
  return '#7DBF73';                       // açık yeşil
}


const EN_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function compactTweetValue(value: unknown, maxLength: number): string {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (Array.from(text).length <= maxLength) return text;
  return `${Array.from(text).slice(0, Math.max(1, maxLength - 1)).join('')}…`;
}

function tweetHashtag(value: unknown, maxLength = 18): string {
  const cleaned = String(value || '')
    .normalize('NFC')
    .replace(/[^\p{L}\p{N}_]+/gu, '')
    .slice(0, maxLength);
  return cleaned ? `#${cleaned}` : '';
}

function tweetMagnitudeType(value: unknown): string {
  const cleaned = String(value || '').replace(/[^a-z0-9]/gi, '').slice(0, 6).toUpperCase();
  return cleaned ? ` (${cleaned})` : '';
}

/// Tweet ve kart zamanı her zaman UTC: İngilizce şablon ve ajansların
/// (USGS, EMSC) uluslararası yayın biçimiyle aynı.
function worldDateTime(date: Date): string {
  const day = date.getUTCDate();
  const month = EN_MONTHS[date.getUTCMonth()];
  const year = date.getUTCFullYear();
  const hhmm = `${String(date.getUTCHours()).padStart(2, '0')}:${String(date.getUTCMinutes()).padStart(2, '0')}`;
  return `${day} ${month} ${year} · 🕒 ${hhmm} UTC`;
}

function coordinate(value: number, positive: string, negative: string): string {
  return `${Math.abs(value).toFixed(2)}° ${value >= 0 ? positive : negative}`;
}

/// Kademeli kısaltmalar aşırı uzun sağlayıcı adı/başlık kombinasyonlarında
/// yine de 280'i aşabilir; bu, X'in reddetmesi yerine son bir güvenlik ağı.
function hardCapTweet(text: string, max = 280): string {
  if (tweetLength(text) <= max) return text;
  let result = '';
  let weight = 0;
  for (const { segment } of tweetSegmenter.segment(text)) {
    const next = tweetSegmentWeight(segment);
    if (weight + next > max - 1) break;
    result += segment;
    weight += next;
  }
  return `${result}…`;
}

/// AFAD başlığı deniz/yurt dışı olaylarda "Yer - [12.3 km] İlçe (İl)"
/// biçiminde gelir: olayın yeri ile en yakın Türkiye ilçesi tek metne
/// sıkıştırılmış. Paylaşımda ikisi ayrı ayrı kullanılır — aksi hâlde
/// Santorini depremi "Bodrum" gibi görünür.
export function splitAfadLocation(title: unknown): {
  place: string;
  primary: string;
  secondary: string;
  nearest: string;
  distanceKm: number | null;
} {
  const text = String(title || '').replace(/\s+/g, ' ').trim();
  const match = /^(.*?)\s*-\s*\[(\d+(?:\.\d+)?) km\]\s*(.+)$/.exec(text);
  const place = match ? match[1].trim() : text;
  // AFAD deniz olaylarını "Ege Denizi, Santurin Adası (Thira)" diye, kara
  // olaylarını "Akhalkalaki, Samtskhe-Javakheti (Gürcistan)" diye yazıyor:
  // biri denizle, öteki yerleşimle başlıyor. Başlığa her zaman olayın en
  // belirgin yeri çıkar, deniz adı ikinci satıra düşer.
  const parts = place.split(',').map(part => part.trim()).filter(Boolean);
  const seaFirst = parts.length > 1 && /(deniz|denizi|körfez|boğaz)/i.test(parts[0]);
  const primary = seaFirst ? parts.slice(1).join(', ') : (parts[0] || place);
  const secondary = seaFirst ? parts[0] : parts.slice(1).join(', ');
  return {
    place,
    primary,
    secondary,
    nearest: match ? match[3].trim() : '',
    distanceKm: match ? Number(match[2]) : null
  };
}

/// Bildirimde gösterilen yer adı. AFAD deniz/yurt dışı başlıkları
/// ("Marmara Denizi - [16.46 km] Silivri (İstanbul)") okunaklı hâle
/// getirilir: "Marmara Denizi · Silivri (İstanbul) 16 km". Diğer başlıklar
/// olduğu gibi kalır.
export function notificationPlaceLabel(q: Pick<Earthquake, 'provider' | 'title'>): string {
  if (String(q.provider || '').toUpperCase() !== 'AFAD') return q.title;
  const { primary, secondary, nearest, distanceKm } = splitAfadLocation(q.title);
  if (!nearest || distanceKm === null) return q.title;
  const place = [primary, secondary].filter(Boolean).join(', ');
  return `${place} · ${nearest} ${Math.round(distanceKm)} km`;
}

/// Tweet ve kartın yer bilgisi. Kaynağın verdiği ad kullanılır; kaynak
/// yalnızca kaba bölge adı veriyorsa (EMSC/NOA Flinn-Engdahl bölgeleri) ya da
/// Türkçe deniz/yurt dışı başlığı veriyorsa (AFAD) yer koordinattan bulunur.
/// AFAD'ın Türkçe yazdığı komşu/bölge ülkeleri (ülke alanı).
const AFAD_COUNTRY_EN: Record<string, string> = {
  'Yunanistan': 'Greece', 'Gürcistan': 'Georgia', 'Ermenistan': 'Armenia', 'Azerbaycan': 'Azerbaijan',
  'İran': 'Iran', 'Irak': 'Iraq', 'Suriye': 'Syria', 'Lübnan': 'Lebanon', 'İsrail': 'Israel',
  'Ürdün': 'Jordan', 'Mısır': 'Egypt', 'Libya': 'Libya', 'Kıbrıs': 'Cyprus', 'Bulgaristan': 'Bulgaria',
  'Romanya': 'Romania', 'Arnavutluk': 'Albania', 'Kuzey Makedonya': 'North Macedonia', 'Makedonya': 'North Macedonia',
  'Karadağ': 'Montenegro', 'Sırbistan': 'Serbia', 'Bosna Hersek': 'Bosnia and Herzegovina', 'Hırvatistan': 'Croatia',
  'İtalya': 'Italy', 'Rusya': 'Russia', 'Ukrayna': 'Ukraine', 'Moldova': 'Moldova', 'Suudi Arabistan': 'Saudi Arabia',
  'Türkmenistan': 'Turkmenistan', 'Kazakistan': 'Kazakhstan'
};

export interface TweetLocation {
  /// Metindeki tam ad: "Saimbeyli, Adana, Türkiye" · "26 km SE of Kahramanmaraş, Türkiye"
  label: string;
  /// Kartın büyük satırı ve alt satırı.
  headline: string;
  sub: string;
  /// Yer etiketleri (en özelden en genele), # olmadan.
  tags: string[];
  inTurkiye: boolean;
}

function isTurkiyeName(value: unknown): boolean {
  const name = String(value || '').trim().toLocaleLowerCase('tr');
  return name === 'türkiye' || name === 'turkey' || name === 'turkiye';
}

export function describeTweetLocation(q: Earthquake): TweetLocation {
  // #Deprem etiketi ve Türkiye eşiği aynı karardan gelir.
  return { ...describeTweetPlace(q), inTurkiye: isTurkiyeQuake(q) };
}

function describeTweetPlace(q: Earthquake): TweetLocation {
  const provider = q.provider.toUpperCase();

  // AFAD'ın Türkiye kaydı: ilçe/il kaynağın kendi alanlarından.
  if (provider === 'AFAD' && isTurkiyeName(q.country) && (q.district || q.closestCity)) {
    const district = String(q.district || '').trim();
    const province = String(q.closestCity || '').trim();
    const parts = [...new Set([district, province].filter(Boolean))];
    return {
      label: [...parts, 'Türkiye'].join(', '),
      headline: parts[0],
      sub: [...parts.slice(1), 'Türkiye'].join(', '),
      tags: [...parts, 'Türkiye'],
      inTurkiye: true
    };
  }

  // AFAD'ın yurt dışı kaydı ülkesini kendisi verir: "Akhalkalaki,
  // Samtskhe-Javakheti (Gürcistan)". Şehir/bölge kaynaktan, Türkçe ülke adı
  // İngilizceye çevrilir. (Koordinattan adlandırma burada yanlış ülke
  // verebiliyordu: en yakın büyük yerleşim sınırın öte yanında olabilir.)
  const afadCountry = provider === 'AFAD' ? AFAD_COUNTRY_EN[String(q.country || '').trim()] : undefined;
  if (afadCountry) {
    const place = splitAfadLocation(q.title).place.replace(/\s*\([^)]*\)\s*$/, '').trim();
    const parts = place.split(',').map(part => part.trim()).filter(Boolean);
    if (parts.length) {
      return {
        label: [...parts, afadCountry].join(', '),
        headline: parts[0],
        sub: [...parts.slice(1), afadCountry].join(', '),
        tags: [parts[0], afadCountry],
        inTurkiye: false
      };
    }
  }

  // USGS başlığı İngilizce ve yere özgü ("14 km SSW of Honoka‘a, Hawaii").
  if (provider === 'USGS' && q.title) {
    const parts = String(q.title).split(',').map(part => part.trim()).filter(Boolean);
    const region = parts.length > 1 ? parts.at(-1)! : '';
    const place = (parts[0] || '').replace(/^\d+\s*km\s+[NSEW]{1,3}\s+of\s+/i, '');
    return {
      label: String(q.title).trim(),
      headline: region || place || String(q.title),
      sub: region ? String(q.title).trim() : '',
      tags: [place, region].filter(Boolean),
      inTurkiye: isTurkiyeName(region)
    };
  }

  // EMSC/NOA bölge adı ve AFAD'ın yurt dışı/deniz başlığı: koordinattan.
  const nearest = nearestPlace(q.lat, q.lon);
  if (nearest) {
    const where = describeNearest(nearest);
    return {
      label: `${where}, ${nearest.region}`,
      headline: nearest.region,
      sub: where,
      tags: [nearest.name, nearest.region],
      inTurkiye: isTurkiyeName(nearest.region)
    };
  }
  // Yakında yerleşim yok (açık deniz, okyanus sırtı): sağlayıcının bölgesi.
  const region = provider === 'AFAD' ? '' : titleCaseRegion(String(q.title || ''));
  const fallback = region || `${Math.abs(q.lat).toFixed(2)}°${q.lat >= 0 ? 'N' : 'S'}, ${Math.abs(q.lon).toFixed(2)}°${q.lon >= 0 ? 'E' : 'W'}`;
  return { label: fallback, headline: fallback, sub: '', tags: region ? [region] : [], inTurkiye: false };
}

/// Tek İngilizce şablon (22 Eyl 2026): bölge ve dünya ayrımı yok. Hashtag'ler
/// cümlenin doğal kelimelerine gömülür; Türkiye olaylarına yerel erişim için
/// #Deprem de eklenir.
/// Türkiye'deki M4.8+ depremlerde tweete uygulama bağlantısı eklenir: bu
/// büyüklük geniş bir bölgede hissedilir ve insanlar bilgi arar.
export const TWEET_APP_LINK_MIN_MAGNITUDE = 4.8;
export const APP_STORE_URL = 'https://apps.apple.com/app/id6787776158';

/// X'in ağırlıklı karakter sayımı (twitter-text v3): bağlantı uzunluğundan
/// bağımsız 23; emoji dizisi 2; Latin/Türkçe harfler ve tipografik
/// noktalama 1, diğer karakterler (CJK vb.) 2. Eskiden kod noktası sayılıyordu:
/// emojili bir tweet 280'in altında görünüp X'te sınırı aşabiliyordu.
const TWEET_LIGHT_RANGES: Array<[number, number]> = [[0, 4351], [8192, 8205], [8208, 8223], [8242, 8247]];
const tweetSegmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });

function tweetSegmentWeight(segment: string): number {
  if (/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(segment)) return 2;
  let weight = 0;
  for (const char of segment) {
    const code = char.codePointAt(0)!;
    weight += TWEET_LIGHT_RANGES.some(([low, high]) => code >= low && code <= high) ? 1 : 2;
  }
  return weight;
}

export function tweetLength(text: string): number {
  let total = 0;
  const parts = text.split(/(https?:\/\/\S+)/g);
  for (const [index, part] of parts.entries()) {
    if (index % 2 === 1) { total += 23; continue; }
    for (const { segment } of tweetSegmenter.segment(part)) total += tweetSegmentWeight(segment);
  }
  return total;
}

export function buildQuakeTweetText(q: Earthquake): string {
  const mag = q.magnitude.toFixed(1);
  const emoji = magnitudeTweetEmoji(q.magnitude);
  const depthKm = Math.round(q.depth);
  const magnitude = `M${mag}${tweetMagnitudeType(q.magType)}`;
  const providerTag = tweetHashtag(compactTweetValue(q.provider, 18), 24);
  const location = describeTweetLocation(q);
  const severityIcon = q.magnitude >= 5 ? '🚨' : '📢';
  const locationTags = location.tags.map(tag => tweetHashtag(tag, 24)).filter(Boolean);
  const tags = [...new Set([...locationTags, '#Earthquake', ...(location.inTurkiye ? ['#Deprem'] : [])])];

  const lines = [
    `${severityIcon} #Earthquake`,
    '',
    `${emoji} ${magnitude} — ${compactTweetValue(location.label, 70)}`,
    `📅 ${worldDateTime(new Date(q.date))}`,
    `⬇️ Depth: ${depthKm} km · 📍 ${coordinate(q.lat, 'N', 'S')}, ${coordinate(q.lon, 'E', 'W')}`,
    `🏛️ Source: ${providerTag}`
  ];
  if (q.magnitude >= 5) lines.push('🛡️ Stay away from damaged buildings.');
  // Bağlantı satırı hiçbir koşulda kesilmez: sığmazsa önce uyarı satırı düşer,
  // yine sığmazsa yalnızca üstteki metin kısaltılır.
  const linkLine = location.inTurkiye && q.magnitude >= TWEET_APP_LINK_MIN_MAGNITUDE
    ? `📲 Live alerts on Sismik: ${APP_STORE_URL}`
    : '';
  const withLink = (text: string) => linkLine ? `${text}\n${linkLine}` : text;
  let head = lines.join('\n');
  if (tweetLength(withLink(head)) > 280 && lines.length > 6) head = lines.slice(0, 6).join('\n');
  if (tweetLength(withLink(head)) > 280) head = hardCapTweet(head, 280 - (linkLine ? tweetLength(linkLine) + 1 : 0));
  const body = withLink(head);
  // Etiketler en sona ve yalnızca sığdığı kadar: uyarı satırı asla kesilmez.
  let tagRow = '';
  for (const tag of tags) {
    const next = tagRow ? `${tagRow} ${tag}` : tag;
    if (tweetLength(`${body}\n\n${next}`) > 280) continue;
    tagRow = next;
  }
  return tagRow ? `${body}\n\n${tagRow}` : body;
}

// MARK: - Otomatik tweet kartı (görsel)
//
// Tweet metniyle beraber ekli medya olarak paylaşılan, sunucuda SVG olarak
// oluşturulup PNG'ye dönüştürülen kart. Emoji/bayrak içermez (gömülü Inter
// fontunda renkli emoji glifi yok) — bayraklar sadece tweet metninde kalır.
// App Store rozeti ve uygulama ikonu gerçek marka varlıkları olarak base64
// üzerinden gömülür; çağıran taraf (index.ts) bunları dosyadan okuyup verir.
export interface QuakeCardWorldMap {
  path: string;
  width: number;
  height: number;
  scale: number;
  translate: [number, number];
}

export interface QuakeCardAssets {
  appIconBase64: string;
  storeBadgeBase64: string;
  worldMap: QuakeCardWorldMap;
}

// worldMap.path, `functions/assets/maps/world-110m.json` içinde bulunan,
// world-atlas'ın 110m çözünürlüklü kara verisinden d3-geo ile (geoEquirectangular,
// rotate/center=[0,0]) BİR KEZ, build zamanında üretilmiş statik bir SVG path'i.
// Üretimde d3-geo çalışmaz; aynı projeksiyonun matematiği (aşağıdaki
// projectOnCardMap) elle tekrarlanarak enlem/boylamdan bu path'in koordinat
// uzayına dönüşüm yapılır.
function projectOnCardMap(map: QuakeCardWorldMap, lat: number, lon: number): [number, number] {
  const x = map.translate[0] + map.scale * (lon * Math.PI / 180);
  const y = map.translate[1] - map.scale * (lat * Math.PI / 180);
  return [x, y];
}

function cardTierColor(magnitude: number): string {
  return magnitudeHexColor(magnitude);
}

function escSvg(value: unknown): string {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/// Deprem büyüklüğüne göre merkez üssü dalgalarının sıklığını (sayı ve yayılımını)
/// gerçekçi ve abartısız şekilde üretir. Büyük depremlerde dalga yoğunluğu ve sayısı dengeli artar.
function buildEpicenterWavesSVG(magnitude: number, color: string): string {
  const count = magnitude >= 6.0 ? 4 : (magnitude >= 5.0 ? 3 : (magnitude >= 4.0 ? 2 : 1));
  const step = 12 + Math.min(3, Math.max(0, (magnitude - 3) * 0.8));
  const baseR = 12;

  const circles: string[] = [];
  for (let i = 1; i <= count; i++) {
    const r = Math.round(baseR + i * step);
    const opacity = (0.75 - ((i - 1) / count) * 0.45).toFixed(2);
    const strokeWidth = i === 1 ? 1.8 : 1.4;
    circles.push(
      `<circle cx="600" cy="337.5" r="${r}" fill="none" stroke="${color}" stroke-width="${strokeWidth}" stroke-opacity="${opacity}"/>`
    );
  }
  circles.push(`<circle cx="600" cy="337.5" r="5" fill="${color}" stroke="#FFFFFF" stroke-width="2"/>`);
  return circles.join('\n  ');
}

function cardDateTime(date: Date): string {
  const day = date.getUTCDate();
  const month = EN_MONTHS[date.getUTCMonth()].slice(0, 3);
  const hhmm = `${String(date.getUTCHours()).padStart(2, '0')}:${String(date.getUTCMinutes()).padStart(2, '0')}`;
  return `${day} ${month} ${hhmm} UTC`;
}

// Apple'ın resmi rozeti 498×167 (~2.982:1). Ölçek korunarak, okunaklı ve
// yeterli boşluklu bir boyutta gösterilir.
const CARD_BADGE_W = 176;
const CARD_BADGE_H = Math.round(CARD_BADGE_W / (498 / 167));

export function buildQuakeCardSVG(q: Earthquake, assets: QuakeCardAssets): string {
  // Kart da tweet metniyle aynı kuralı izler: tek İngilizce şablon, yer
  // bilgisi `describeTweetLocation`'dan. Harita AFAD bölgesinde yakın çekim.
  const location = describeTweetLocation(q);
  const regional = isWithinSourceCoverage(q, 'afad');
  const color = cardTierColor(q.magnitude);
  const magText = `M${q.magnitude.toFixed(1)}`;
  const depthKm = Math.round(q.depth);
  const date = new Date(q.date);

  const nameLine1 = 'Sismik';
  const nameLine2 = 'Earthquake & Emergency';

  // Sağ alttaki CTA kümesi: [App Store rozeti] [boşluk] [ikon | Sismik / etiket],
  // x=1136'ya sağa hizalı. Konumu, kaynak/başlık metninden ÖNCE hesaplanır
  // ki metin uzunluğu bu kümeyle asla çakışmasın (bkz. aşağıdaki güvenli
  // karakter bütçesi).
  const clusterRight = 1136;
  const lockupIconSize = CARD_BADGE_H;
  const iconTextGap = 13;
  const lockupTextW = Math.max(nameLine1.length * 12, nameLine2.length * 8.6);
  const lockupW = lockupIconSize + iconTextGap + lockupTextW;
  const badgeGap = 22;
  const lockupX = clusterRight - lockupW;
  const badgeX = lockupX - badgeGap - CARD_BADGE_W;
  const badgeY = 555;
  const lockupTextX = lockupX + lockupIconSize + iconTextGap;
  const lockupLine1Y = badgeY + 20;
  const lockupLine2Y = badgeY + 39;

  // Şehir/ülke başlığı ve alt satır, hizalama nedeniyle artık CTA kümesiyle
  // aynı dikey bantta (bkz. headlineY/subY/metaY) — bu yüzden uzun il/ilçe
  // veya ham başlık metinlerinin rozet/logoya değmemesi için karakter
  // bütçesi, kümenin sol kenarına (badgeX) göre DİNAMİK hesaplanır.
  const textLeft = 80;
  const safeRight = badgeX - 24;
  const availableWidth = Math.max(160, safeRight - textLeft);
  const headlineMaxChars = Math.max(8, Math.floor(availableWidth / (0.58 * 52)));
  const subMaxChars = Math.max(12, Math.floor(availableWidth / (0.52 * 30)));
  const metaMaxChars = Math.max(24, Math.floor(availableWidth / 11.5));

  const headline = compactTweetValue(location.headline, headlineMaxChars);
  const sub = compactTweetValue(location.sub, subMaxChars);
  const rawMeta = `Depth ${depthKm} km · ${cardDateTime(date)} · Source: ${compactTweetValue(q.provider, 14)}`;
  const meta = compactTweetValue(rawMeta, metaMaxChars);

  // Şehir/derinlik/saat bloğunun alt marjı, sağdaki rozet kümesinin alt
  // marjıyla (badgeY + CARD_BADGE_H = 614) hizalanacak şekilde aşağı çekildi.
  const headlineY = 526;
  const subY = 569;
  const metaY = sub ? 610 : 569;

  // Harita ön planda: küçük bir köşe paneli değil, kartın TAMAMINI kaplayan
  // arka plan görseli. Epicenter merkeze sabitlenip yakınlaştırılır
  // (Türkiye depremlerinde daha yakın/bölgesel).
  const { worldMap } = assets;
  const mapZoom = regional ? 11 : 6.5;
  const [markerX, markerY] = projectOnCardMap(worldMap, q.lat, q.lon);
  const mapOffsetX = 1200 / 2 - mapZoom * markerX;
  const mapOffsetY = 675 / 2 - mapZoom * markerY;

  const magTextWidth = Math.round(magText.length * 68);
  const lineBreakX = Math.min(820, 1136 - magTextWidth - 25);

  return `
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675">
  <defs>
    <clipPath id="lockupIconClip">
      <rect width="${lockupIconSize}" height="${lockupIconSize}" rx="${Math.round(lockupIconSize * 0.223)}"/>
    </clipPath>
    <linearGradient id="oceanGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#5B8FAF"/>
      <stop offset="100%" stop-color="#477B9E"/>
    </linearGradient>
    <radialGradient id="wash" cx="82%" cy="18%" r="75%">
      <stop offset="0%" stop-color="${color}" stop-opacity="0.28"/>
      <stop offset="45%" stop-color="${color}" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="${color}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="scrimBottomLeft" x1="0%" y1="100%" x2="55%" y2="20%">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.95"/>
      <stop offset="60%" stop-color="#FFFFFF" stop-opacity="0.65"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="scrimTopRight" x1="100%" y1="0%" x2="35%" y2="65%">
      <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.85"/>
      <stop offset="65%" stop-color="#FFFFFF" stop-opacity="0.35"/>
      <stop offset="100%" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <rect width="1200" height="675" fill="url(#oceanGrad)"/>
  <g transform="translate(${mapOffsetX},${mapOffsetY}) scale(${mapZoom})">
    <path d="${worldMap.path}" fill="#F8F7F4" stroke="#9EA09C" stroke-width="0.7" vector-effect="non-scaling-stroke"/>
  </g>
  <rect width="1200" height="675" fill="url(#wash)"/>
  <rect width="1200" height="675" fill="url(#scrimBottomLeft)"/>
  <rect width="1200" height="675" fill="url(#scrimTopRight)"/>

  <!-- Merkezden Büyüklüğe Lider Çizgi (Büyüklük renginde, temiz büküm) -->
  <path d="M 600 337.5 L ${lineBreakX} 160 L 1136 160" fill="none" stroke="${color}" stroke-width="2.5" stroke-opacity="0.9" stroke-linejoin="round"/>

  <!-- Merkez Üssü Dalgaları (Büyüklüğe göre sıklık ve yoğunluk) -->
  ${buildEpicenterWavesSVG(q.magnitude, color)}

  <text x="1136" y="155" font-family="Inter" font-size="124" font-weight="900" fill="${color}" text-anchor="end" letter-spacing="-2">${escSvg(magText)}</text>

  <text x="${textLeft}" y="${headlineY}" font-family="Inter" font-size="52" font-weight="700" fill="#17181A">${escSvg(headline)}</text>
  ${sub ? `<text x="${textLeft}" y="${subY}" font-family="Inter" font-size="30" font-weight="500" fill="#17181A" fill-opacity="0.6">${escSvg(sub)}</text>` : ''}
  <text x="${textLeft}" y="${metaY}" font-family="Inter" font-size="23" font-weight="500" fill="#17181A" fill-opacity="0.5">${escSvg(meta)}</text>

  <image x="${badgeX}" y="${badgeY}" width="${CARD_BADGE_W}" height="${CARD_BADGE_H}" href="data:image/png;base64,${assets.storeBadgeBase64}"/>

  <g clip-path="url(#lockupIconClip)" transform="translate(${lockupX},${badgeY})">
    <image x="0" y="0" width="${lockupIconSize}" height="${lockupIconSize}" href="data:image/png;base64,${assets.appIconBase64}"/>
  </g>
  <text x="${lockupTextX}" y="${lockupLine1Y}" font-family="Inter" font-size="18" font-weight="900" fill="#17181A" fill-opacity="0.95" letter-spacing="0.1">${escSvg(nameLine1)}</text>
  <text x="${lockupTextX}" y="${lockupLine2Y}" font-family="Inter" font-size="15" font-weight="700" fill="#17181A" fill-opacity="0.72" letter-spacing="0.1">${escSvg(nameLine2)}</text>

  <rect width="1198" height="673" x="1" y="1" fill="none" stroke="#FFFFFF" stroke-opacity="0.45" stroke-width="2"/>
</svg>`.trim();
}

// MARK: - Sağlayıcı revizyonları
//
// AFAD/EMSC/USGS bir depremi ilk yayımladıktan sonra büyüklük/derinliği
// güncelleyebilir (aynı olay kimliğiyle). Paylaşılan tweet düzenlenmez;
// yeni değer oturunca aşağıdaki kısa düzeltme orijinale YANIT olarak atılır
// (twitter-posting.ts).
// Küçük ondalık gürültüsü kredi harcamasın diye eşik altı değişiklikler
// sessizce yok sayılır.
const MAGNITUDE_REVISION_THRESHOLD = 0.2;
const DEPTH_REVISION_RATIO_THRESHOLD = 0.2;

export interface QuakeRevisionSnapshot {
  magnitude: number;
  depth: number;
}

export function isMeaningfulQuakeRevision(
  previous: QuakeRevisionSnapshot,
  current: QuakeRevisionSnapshot
): boolean {
  const magnitudeChanged = Math.abs(current.magnitude - previous.magnitude) >= MAGNITUDE_REVISION_THRESHOLD;
  const previousDepth = Math.max(previous.depth, 0.001);
  const depthChanged = Math.abs(current.depth - previous.depth) / previousDepth >= DEPTH_REVISION_RATIO_THRESHOLD;
  return magnitudeChanged || depthChanged;
}

export function buildQuakeRevisionReplyText(q: Earthquake, previous: QuakeRevisionSnapshot): string {
  const provider = compactTweetValue(q.provider, 18);
  const magnitudeChanged = Math.abs(q.magnitude - previous.magnitude) >= MAGNITUDE_REVISION_THRESHOLD;
  const previousDepth = Math.max(previous.depth, 0.001);
  const depthChanged = Math.abs(q.depth - previous.depth) / previousDepth >= DEPTH_REVISION_RATIO_THRESHOLD;
  const parts: string[] = [];
  if (magnitudeChanged) {
    parts.push(`Magnitude revised from M${previous.magnitude.toFixed(1)} to M${q.magnitude.toFixed(1)}.`);
  }
  if (depthChanged) {
    parts.push(`Depth updated from ${Math.round(previous.depth)} km to ${Math.round(q.depth)} km.`);
  }
  return `🔄 Update: ${parts.join(' ') || 'Details updated.'} (Source: ${provider})`;
}

/// Push cihaz önbelleğinin delta birleştirme adımı. Firestore'a bağımlı
/// olmadığı için birim testle doğrulanabilir: değişen belgeleri önbelleğe
/// uygular (teslime uygun değilse siler) ve yeni senkronizasyon sınırını
/// döndürür. Sınır yalnızca ileri gider; böylece bir sonraki delta sorgusu
/// aynı belgeleri tekrar okumaz.
export function applyPushDeviceDelta<T>(
  cache: Map<string, T>,
  changes: Array<{ id: string; updatedAt: number; device: T | null }>,
  syncedAt: number
): number {
  let latest = syncedAt;
  for (const change of changes) {
    if (Number.isFinite(change.updatedAt) && change.updatedAt > latest) {
      latest = change.updatedAt;
    }
    if (change.device) cache.set(change.id, change.device);
    else cache.delete(change.id);
  }
  return latest;
}


// MARK: - Otomasyon kuralları
//
// `automations` koleksiyonundaki "şu koşuldaki kullanıcıya şunu gönder"
// kuralları (bilgi kartı bildirimleri Scripts/info-cards.mjs ile yazılır).
// Değerlendirme saf tutulur (Firestore'a bağımlı değil) ki birim testlerle
// doğrulanabilsin; okuma/yazma ve gönderim çağıran tarafta yapılır.

export type AutomationTrigger =
  | 'subscription_expiring'
  | 'scheduled';

/// Geçerli tetikleyicilerin TEK kaynağı. Hem kayıt doğrulaması hem de
/// çalıştırma kararı bunu okur; ikisi ayrı listelerde tutulduğunda biri
/// güncellenip diğeri unutuluyordu.
export const AUTOMATION_TRIGGERS: AutomationTrigger[] = [
  'subscription_expiring',
  'scheduled'
];

export type AutomationAudience = 'all' | 'premium' | 'free' | 'marketing_opt_in';

export interface AutomationRule {
  id: string;
  name: string;
  enabled: boolean;
  trigger: AutomationTrigger;
  audience: AutomationAudience;
  /// subscription_expiring için: bitişe kaç gün kala.
  daysBefore?: number;
  /// scheduled için: gönderim anı (epoch ms).
  runAt?: number;
  /// Dil kodu -> { title, body }. Cihazın dili yoksa 'en'e düşer.
  messages: Record<string, { title: string; body: string }>;
  /// Doluysa bildirime dokununca uygulamada bu bilgi kartı açılır
  /// (`Scripts/info-cards.mjs push`).
  infoCardId?: string;
  lastRunAt?: number;
  lastSentCount?: number;
}

export interface AutomationValidationResult {
  valid: boolean;
  errors: string[];
}

/// Kural gövdesini doğrular (Scripts/info-cards.mjs yazmadan önce çağırır).
/// Kötü kural kaydedilirse otomasyon turu her bakım turunda hata verir veya
/// yanlış kitleye gönderim yapar; bu yüzden kayıt anında reddedilir.
export function validateAutomationRule(rule: Partial<AutomationRule>): AutomationValidationResult {
  const errors: string[] = [];
  const triggers = AUTOMATION_TRIGGERS;
  const audiences: AutomationAudience[] = ['all', 'premium', 'free', 'marketing_opt_in'];

  if (!rule.name || !String(rule.name).trim()) errors.push('Kural adı gerekli');
  if (!rule.trigger || !triggers.includes(rule.trigger)) errors.push('Geçersiz tetikleyici');
  if (!rule.audience || !audiences.includes(rule.audience)) errors.push('Geçersiz hedef kitle');

  const messages = rule.messages || {};
  const langs = Object.keys(messages);
  if (!langs.length) errors.push('En az bir dilde mesaj gerekli');
  for (const lang of langs) {
    const m = messages[lang];
    if (!m || !String(m.title || '').trim() || !String(m.body || '').trim()) {
      errors.push(`${lang} için başlık ve metin gerekli`);
    }
  }
  if (!messages.en && !messages.tr) {
    errors.push('Yedek dil olarak en az tr veya en bulunmalı');
  }

  if (rule.trigger === 'subscription_expiring') {
    const days = Number(rule.daysBefore);
    if (!Number.isFinite(days) || days < 0 || days > 60) {
      errors.push('daysBefore 0-60 arasında olmalı');
    }
  }
  if (rule.infoCardId !== undefined && !/^[a-z0-9][a-z0-9._-]{1,63}$/.test(String(rule.infoCardId))) {
    errors.push('infoCardId geçersiz');
  }
  if (rule.trigger === 'scheduled') {
    const runAt = Number(rule.runAt);
    if (!Number.isFinite(runAt) || runAt <= 0) errors.push('Geçerli bir gönderim zamanı gerekli');
  }

  return { valid: errors.length === 0, errors };
}

/// Kural bu turda çalışmalı mı? Zaman bazlı tetikleyiciler için karar burada
/// verilir; koşul bazlı olanlarda (abonelik/deneme) her tur değerlendirilir
/// ama cihaz bazında tekrar gönderim engellenir.
export function shouldRunAutomation(rule: AutomationRule, now: number): boolean {
  if (!rule.enabled) return false;

  // Tanınmayan tetikleyici ASLA çalışmaz.
  //
  // Eskiden bilinmeyen her tetikleyici `return true`'ya düşüyordu; kaldırılan
  // `app_version_released` gibi bir tetikleyiciyle Firestore'da kalmış eski
  // bir kural, kod silindiği anda her bakım turunda ateşlenmeye başlardı.
  // İzin listesi, kod ile veritabanı arasındaki bu boşluğu kapatıyor.
  if (!AUTOMATION_TRIGGERS.includes(rule.trigger)) return false;

  if (rule.trigger === 'scheduled') {
    const runAt = Number(rule.runAt || 0);
    if (runAt <= 0 || now < runAt) return false;
    // Tek seferlik: bu gönderim anından sonra bir kez çalıştıysa tekrar
    // çalışmaz. İleri bir ana yeniden zamanlanan kural yine çalışır.
    return !(Number(rule.lastRunAt) >= runAt);
  }
  return true;
}

/// Cihazın bitiş tarihi kuralın penceresine giriyor mu? Pencere bir turluk
/// (1 saat) değil bir günlük tutulur: aksi hâlde tam o turda bakılmayan
/// cihaz hiç bildirim almazdı. Tekrar gönderimi `sentKey` engeller.
export function isWithinExpiryWindow(
  expiresAt: number,
  daysBefore: number,
  now: number
): boolean {
  if (!Number.isFinite(expiresAt) || expiresAt <= now) return false;
  const DAY = 86400000;
  const target = expiresAt - daysBefore * DAY;
  return now >= target && now < target + DAY;
}

/// Aynı kuralın aynı cihaza aynı dönem için tekrar gönderilmesini engelleyen
/// anahtar. Abonelik yenilendiğinde bitiş tarihi değiştiği için anahtar da
/// değişir ve bir sonraki dönemde yeniden gönderilebilir.
export function automationSentKey(ruleId: string, expiresAt: number): string {
  return `${ruleId}:${Math.floor(expiresAt / 1000)}`;
}

// MARK: - RevenueCat yetki çözümlemesi
//
// Abone verisinin kayıt yeri RevenueCat. Firestore yalnızca push
// yönlendirmesi için gereken iki alanı taşır: `is_premium` ve
// `premium_expires_at`. Buradaki fonksiyonlar ağ erişimi içermez; RevenueCat
// yanıtını yorumlayan saf mantık test edilebilir kalsın diye ayrıldı.

export interface RevenueCatEntitlement {
  /// Push hedeflemesi için tek belirleyici. `expiresAt` gelecekteyse true.
  isActive: boolean;
  /// Epoch ms. Süresiz (ömür boyu) yetkide 0.
  expiresAt: number;
  productId: string;
}

/// RevenueCat v2 `active_entitlements` yanıtından tek bir entitlement'ın
/// durumunu çıkarır.
///
/// v1 `/subscribers/{id}` yerine v2 kullanılıyor: v1 ucu tanımadığı bir
/// kimlik sorulduğunda 404 dönmüyor, aboneyi OLUŞTURUP 201 dönüyor (ölçüldü).
/// Bu, her ücretsiz kullanıcı için RevenueCat'te boş müşteri kaydı açardı.
/// v2 aynı durumda 404 döner.
///
/// Yanıtta yalnızca AKTİF yetkiler listelenir; süresi dolmuş bir yetki hiç
/// gelmez. Yine de `expires_at` ayrıca kontrol edilir — listelenme ile bizim
/// saatimiz arasındaki sınır durumunda yanlış tarafta kalmayalım.
export function entitlementFromActiveEntitlements(
  body: any,
  entitlementId: string,
  now: number
): RevenueCatEntitlement {
  const inactive: RevenueCatEntitlement = {
    isActive: false, expiresAt: 0, productId: ''
  };

  const items = body?.items;
  if (!Array.isArray(items)) return inactive;

  const match = items.find(
    (item: any) => item && String(item.entitlement_id || '') === entitlementId
  );
  if (!match) return inactive;

  // `expires_at: null` ömür boyu yetki demek; süresi dolmuş değil.
  if (match.expires_at === null || match.expires_at === undefined) {
    return { isActive: true, expiresAt: 0, productId: '' };
  }

  const expiresAt = Number(match.expires_at);
  if (!Number.isFinite(expiresAt) || expiresAt <= 0) return inactive;

  return {
    isActive: expiresAt > now,
    expiresAt,
    productId: String(match.product_id || '')
  };
}

/// Webhook gövdesinden etkilenen RevenueCat kullanıcı kimliklerini toplar.
///
/// Tek bir `app_user_id` yetmiyor: RevenueCat takma adları (`aliases`)
/// birleştirebiliyor ve `TRANSFER` olayında abonelik bir kimlikten diğerine
/// geçiyor. İki taraf da güncellenmezse eski kimlik premium kalır, yenisi
/// premium olmaz.
export function revenueCatEventUserIds(body: any): string[] {
  const event = body?.event;
  if (!event || typeof event !== 'object') return [];

  const ids = new Set<string>();
  const add = (value: unknown) => {
    const id = String(value || '').trim();
    if (id) ids.add(id);
  };

  add(event.app_user_id);
  add(event.original_app_user_id);
  if (Array.isArray(event.aliases)) event.aliases.forEach(add);
  if (Array.isArray(event.transferred_from)) event.transferred_from.forEach(add);
  if (Array.isArray(event.transferred_to)) event.transferred_to.forEach(add);

  return Array.from(ids);
}

/// RevenueCat'in bağlantı testinde gönderdiği olay. Abone kaydı yok, yetki
/// çözümlemeye çalışmak 404 üretir; 200 dönüp geçilmeli.
export function isRevenueCatTestEvent(body: any): boolean {
  return String(body?.event?.type || '').toUpperCase() === 'TEST';
}

/// Cihaz belgesine yazılacak yetki alanları. Push yolu bu iki alandan
/// başkasına bakmıyor (`toCachedPushDevice`), bu yüzden abone verisinin
/// geri kalanı Firestore'a hiç girmiyor.
export function entitlementDeviceFieldsFor(
  entitlement: RevenueCatEntitlement,
  now: number
): { set: Record<string, unknown>; unset: string[] } {
  if (!entitlement.isActive) {
    return {
      set: { is_premium: false, entitlement_source: 'revenuecat', entitlement_verified_at: now },
      unset: ['premium_expires_at']
    };
  }
  // Ömür boyu yetkide bitiş alanı yazılmaz; `toCachedPushDevice` yokluğu
  // "süresiz" olarak yorumluyor.
  if (entitlement.expiresAt <= 0) {
    return {
      set: { is_premium: true, entitlement_source: 'revenuecat', entitlement_verified_at: now },
      unset: ['premium_expires_at']
    };
  }
  return {
    set: {
      is_premium: true,
      entitlement_source: 'revenuecat',
      premium_expires_at: entitlement.expiresAt,
      entitlement_verified_at: now
    },
    unset: []
  };
}

/// `/register` içindeki yetki dalı, saf ve test edilebilir biçimde.
///
/// Union kuralı: kaynaklardan HERHANGİ biri aktif abonelik gösteriyorsa
/// premium verilir. RevenueCat'in "bu müşteriyi tanımıyorum" (404) yanıtı,
/// aynı istekte gelen geçerli Apple imzalı işlemi EZEMEZ — aksi hâlde
/// RevenueCat'e henüz aktarılmamış ödeme yapan abone, deprem bildirimlerini
/// sessizce kaybederdi.
///
/// Kanıt yokluğu kuralı: appUserId de imzalı Apple işlemi de yoksa istemcinin
/// "premium'um" iddiası TEK BAŞINA ne yetki üretebilir ne de var olanı
/// silebilir — böyle bir istek PRESERVE'e düşer.
///
/// İstemcinin "premium değilim" iddiası yetki icat etmediği için güvenli
/// SAYILIRDI; ama istemci yanılabiliyor (RevenueCat'e aktarılmamış eski
/// abonede SDK bir süreliğine "yetki yok" diyebiliyor). Bu yüzden appUserId
/// gönderen bir istemcinin olumsuz iddiası, RevenueCat'e HİÇ sorulmadan
/// sunucuda KAYITLI bir premium yetkisini düşüremez: `storedIsPremium` true
/// ise karar PRESERVE olur ve çağıran RevenueCat'e sorup yeniden karar verir.
/// Kesin bir RevenueCat cevabı (`revenueCat.isActive === false`) ise düşürmeyi
/// her zaman yapar — gerçekten süresi dolmuş abone push hedefinde kalmaz.
export interface AppleEntitlementInput {
  isActive: boolean;
  expiresDate: number;
  productId: string;
  status: string;
  originalTransactionId: string;
}

export type EntitlementDecision =
  | { action: 'preserve'; reason: string }
  | {
      action: 'write';
      set: Record<string, unknown>;
      unset: string[];
      /// true ise: abone Apple'a göre aktif ama RevenueCat'te yok.
      /// Geçmiş aktarımının eksik olduğunu gösteren teşhis sinyali.
      unmigrated: boolean;
    };

export function decideDeviceEntitlement(input: {
  appUserId: string;
  clientClaimsPremium: boolean;
  revenueCat: RevenueCatEntitlement | null;
  appleJws: AppleEntitlementInput | null;
  /// Firestore'daki cihaz belgesinde `is_premium === true` mi? Yalnızca
  /// doğrulanmamış bir "premium değilim" iddiasının mevcut yetkiyi silmesini
  /// engellemek için okunur; yeni yetki VERMEK için asla kullanılmaz.
  storedIsPremium?: boolean;
  now: number;
}): EntitlementDecision {
  const { appUserId, clientClaimsPremium, revenueCat, appleJws, now } = input;
  const storedIsPremium = input.storedIsPremium === true;

  if (revenueCat?.isActive) {
    const { set, unset } = entitlementDeviceFieldsFor(revenueCat, now);
    return { action: 'write', set, unset, unmigrated: false };
  }

  // `expiresDate === 0` ömür boyu satın alma: bitiş yok, alan yazılmaz.
  const appleLifetime = Boolean(appleJws?.isActive) && appleJws!.expiresDate === 0;
  const appleActive = appleLifetime || (Boolean(appleJws?.isActive) && appleJws!.expiresDate > now);
  if (appleActive) {
    return {
      action: 'write',
      set: {
        is_premium: true,
        entitlement_source: 'apple_jws',
        subscription_id: appleJws!.originalTransactionId,
        subscription_product_id: appleJws!.productId,
        ...(appleLifetime ? {} : { premium_expires_at: appleJws!.expiresDate }),
        entitlement_verified_at: now
      },
      unset: appleLifetime ? ['premium_expires_at'] : [],
      // RevenueCat kesin "yetki yok" dediyse abone aktarılmamış demektir.
      unmigrated: revenueCat !== null
    };
  }

  // RevenueCat'e ulaşılamadı ve Apple kanıtı da yok: karar verecek veri
  // yok. Mevcut yetkiyi düşürmek, geçici bir kesintide ödeyen kullanıcının
  // bildirimlerini susturur.
  if (revenueCat === null && clientClaimsPremium && appUserId) {
    return { action: 'preserve', reason: 'revenuecat_unreachable' };
  }

  // Doğrulanmamış olumsuz iddia: istemci "premium değilim" diyor ama bu istekte
  // RevenueCat'e hiç sorulmadı (ya da yanıt alınamadı) ve sunucuda bu cihaz
  // premium kayıtlı. İstemci yanılıyor olabilir; yetkiyi silmek deprem
  // bildirimlerini ve cihaz kaydını götürür. Çağıran bu kararı görünce
  // RevenueCat'e sorup yeniden karar verir.
  if (revenueCat === null && !clientClaimsPremium && appUserId && storedIsPremium) {
    return { action: 'preserve', reason: 'negative_claim_unverified' };
  }

  if (appUserId || appleJws) {
    const inactive = entitlementDeviceFieldsFor(
      { isActive: false, expiresAt: 0, productId: '' }, now
    );
    return { action: 'write', set: inactive.set, unset: inactive.unset, unmigrated: false };
  }

  // Kanıtsız istemci: ne appUserId ne imzalı Apple işlemi var. Premium
  // iddiası tek başına kanıt değil; ama var olan yetkiyi silmeye de
  // yetmemeli — eski bir App Store sürümünde kalmış gerçek bir abone her
  // register çağrısında `is_premium: false` yazılıp deprem bildirimlerini
  // kaybetmesin. Bu yüzden kanıtsız POZİTİF iddia PRESERVE'e düşer: daha
  // önce doğrulanmış bir yol ne yazdıysa o korunur, yeni yetki de icat
  // edilmez, var olan da silinmez. Yepyeni bir cihaz belgesinde zaten
  // `is_premium` alanı yok — bu da doğru biçimde "premium değil" demektir.
  if (clientClaimsPremium) {
    return { action: 'preserve', reason: 'no_evidence_client_claims_premium' };
  }

  // İstemci kendi kendini premium DEĞİL ilan ediyor: kanıtsız da olsa bir
  // kendi-kendine-düşürmeye güvenmek güvenlidir — yetki icat etmiyor,
  // yalnızca kaldırıyor.
  return {
    action: 'write',
    set: {
      is_premium: false,
      entitlement_source: 'legacy_client'
    },
    unset: ['premium_expires_at'],
    unmigrated: false
  };
}

// MARK: - Artçı alanı
//
// Artçılar ana şokun kırılma alanında yoğunlaşır. Uygulama sabit ve geniş bir
// çember istiyor (M5–6 için 150 km); 24 Eylül 2026 Şanlıurfa M5.8'de bu çember
// Adıyaman–Malatya'daki 2023 dizisinin süren depremlerini de "artçı" sayıyordu.
// Alan büyüklüğe göre seçilir: Gardner–Knopoff (1974) artçı penceresi ile
// Wells–Coppersmith (1994) yeraltı kırılma uzunluğunun büyüğü. Örnek: M4.0 →
// 30 km, M5.8 → 50 km, M7.0 → 71 km, M7.8 → 145 km.
export function aftershockZoneRadiusKm(magnitude: number): number {
  const gardnerKnopoff = Math.pow(10, 0.1238 * magnitude + 0.983);
  const ruptureLength = Math.pow(10, -2.44 + 0.59 * magnitude);
  return Math.round(Math.min(400, Math.max(10, gardnerKnopoff, ruptureLength)));
}

/// Eski istemcilerin büyüklüğe göre seçtiği yarıçaptan (EarthquakeDetailView
/// `aftershockRadiusKm`) büyüklük aralığının alt sınırı; ana şok kataloğda
/// bulunamazsa kullanılır.
function magnitudeFromLegacyRadius(radiusKm: number): number {
  if (radiusKm >= 250) return 6.5;
  if (radiusKm >= 200) return 6.0;
  if (radiusKm >= 150) return 5.0;
  return 4.0;
}

/// `/aftershocks` yanıtını ana şokun artçı alanına indirger. Ana şokun diğer
/// ajans kopyaları (180 sn, 30 km) artçı sayılmasın diye çıkarılır; yalnızca
/// ana şok anında (≤ start) olan kayıt kalır — istemci onu zaten saymaz ama
/// liste boş dönmediği için geniş çemberli yedek sorguya düşmez.
export function selectAftershockSequence(
  quakes: readonly Earthquake[],
  mainshock: { lat: number; lon: number; start: number; requestedRadiusKm: number }
): { quakes: Earthquake[]; radiusKm: number; magnitude: number } {
  const isMainshockCopy = (q: Earthquake) => {
    const time = Date.parse(q.date);
    return Number.isFinite(time) && Math.abs(time - mainshock.start) <= 180_000
      && getDistanceKm(mainshock.lat, mainshock.lon, q.lat, q.lon) <= 30;
  };
  const copies = quakes.filter(isMainshockCopy);
  const magnitude = copies.length
    ? Math.max(...copies.map(q => q.magnitude))
    : magnitudeFromLegacyRadius(mainshock.requestedRadiusKm);
  const radiusKm = Math.min(mainshock.requestedRadiusKm, aftershockZoneRadiusKm(magnitude));
  const selected = quakes.filter(q => {
    if (isMainshockCopy(q)) return Date.parse(q.date) <= mainshock.start;
    return getDistanceKm(mainshock.lat, mainshock.lon, q.lat, q.lon) <= radiusKm;
  });
  return { quakes: selected, radiusKm, magnitude };
}

// MARK: - Ajans kopyaları

/// Bölgenin resmî ajansı önce (uygulamadaki `authorityRank` ile aynı):
/// 0 bölgenin ajansı, 1 Kandilli (Türkiye), 2 USGS/EMSC, 3 bölge dışı ajans.
export function authorityRank(q: Pick<Earthquake, 'provider' | 'lat' | 'lon'>): number {
  const inBox = (minLat: number, maxLat: number, minLon: number, maxLon: number) =>
    q.lat >= minLat && q.lat <= maxLat && q.lon >= minLon && q.lon <= maxLon;
  switch (String(q.provider).toUpperCase()) {
    case 'AFAD': return inBox(35.5, 42.5, 25.5, 45) ? 0 : 3;
    case 'KANDILLI': return inBox(35.5, 42.5, 25.5, 45) ? 1 : 3;
    case 'NOA': return inBox(34.5, 42, 19, 30) ? 0 : 3;
    case 'JMA': return inBox(24, 46, 122, 146) ? 0 : 3;
    case 'CENC': return inBox(18, 54, 73, 135) ? 0 : 3;
    case 'BMKG': return inBox(-11, 6, 95, 141) ? 0 : 3;
    case 'GEONET': return q.lat >= -48 && q.lat <= -33 && (q.lon >= 165 || q.lon <= -175) ? 0 : 3;
    case 'USGS': case 'EMSC': return 2;
    default: return 3;
  }
}

/// Aynı fiziksel depremin farklı ajans kayıtları: 75 sn ve 20 km içinde ya da
/// 20 sn ve 45 km içinde (küçük depremlerde ajans konumları 20 km'den fazla
/// ayrışabiliyor). Kalan kayıt bölgenin resmî ajansınınki (`authorityRank`),
/// eşitlikte büyüklüğü yüksek olan. Uygulamadaki `AftershockSequence` ile aynı.
export function isAgencyCopy(
  a: Pick<Earthquake, 'provider' | 'date' | 'lat' | 'lon'>,
  b: Pick<Earthquake, 'provider' | 'date' | 'lat' | 'lon'>
): boolean {
  // Bir ajans aynı depremi iki kez yayımlamaz: aynı ajansın iki kaydı iki depremdir.
  if (String(a.provider).toUpperCase() === String(b.provider).toUpperCase()) return false;
  const rule = agencyCopyRule();
  const dt = Math.abs(Date.parse(String(a.date)) - Date.parse(String(b.date)));
  if (dt > rule.seconds * 1000) return false;
  const km = getDistanceKm(a.lat, a.lon, b.lat, b.lon);
  return km <= rule.km || (dt <= rule.wide_seconds * 1000 && km <= rule.wide_km);
}

/// Ajans kopyası eşikleri. Uzak yapılandırmanın `client.dedupe` bölümü
/// (remote-config.ts) uygulamayla aynı kuralı sunucuya da uygular.
export function agencyCopyRule(): { seconds: number; km: number; wide_seconds: number; wide_km: number } {
  const remote = remoteClientConfig().dedupe;
  return {
    seconds: remote?.seconds ?? 75,
    km: remote?.km ?? 20,
    wide_seconds: remote?.wide_seconds ?? 20,
    wide_km: remote?.wide_km ?? 45
  };
}

export function dedupeAgencyCopies(quakes: Earthquake[]): Earthquake[] {
  const bucketMs = agencyCopyRule().seconds * 1000;
  const ranked = [...quakes].sort((a, b) => authorityRank(a) - authorityRank(b) || b.magnitude - a.magnitude);
  const buckets = new Map<number, Earthquake[]>();
  const kept: Earthquake[] = [];
  for (const q of ranked) {
    const time = Date.parse(String(q.date));
    const key = Math.floor(time / bucketMs);
    let duplicate = false;
    for (let k = key - 1; k <= key + 1 && !duplicate; k++) {
      duplicate = (buckets.get(k) ?? []).some(other => isAgencyCopy(other, q));
    }
    if (duplicate) continue;
    kept.push(q);
    const list = buckets.get(key);
    if (list) list.push(q); else buckets.set(key, [q]);
  }
  return kept;
}

