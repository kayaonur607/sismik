import { TwitterApi, EUploadMimeType } from 'twitter-api-v2';
import { Resvg } from '@resvg/resvg-js';
import * as path from 'path';
import * as fs from 'fs';
import {
  Earthquake,
  selectFreshQuakes,
  QuakeFingerprint,
  toQuakeFingerprint,
  buildQuakeTweetText,
  buildQuakeCardSVG,
  QuakeCardAssets,
  isQuakeEligibleForTwitter,
  isQuakePreviouslyTweeted,
  isLikelyCrossProviderDuplicate,
  isMeaningfulQuakeRevision,
  buildQuakeRevisionReplyText,
  isTurkiyeQuake
} from './worker-utils';
import { buildEmergencyInfoCardSVG, buildEmergencyInfoTweetText } from './emergency-card';
import { filterPublicQuakes, remoteServerConfig } from './remote-config';

// Otomatik Twitter/X paylaşımı: paylaşım defteri, X kredisi koruması ve
// tweet kartı görseli. `runAutomaticTwitterPosting`, push-routes.ts'teki
// `runScheduledPushCheck`'e index.ts tarafından bağımlılık olarak geçirilir;
// böylece iki modül arasında dairesel bağımlılık oluşmaz.

// MARK: - Otomatik Twitter/X paylaşımı
//
// Konuma göre: Türkiye'de M3.0+, diğer her yerde M5.5+
// (`isQuakeEligibleForTwitter`). Bölge/dünya diye kaynak ayrımı yok:
// aynı olayın hangi ajans kaydı ÖNCE görülürse o paylaşılır, diğer ajans
// kopyaları fiziksel olay parmak iziyle atlanır. Paylaşım hızlı taramada,
// gerçek zamanlı akışta (EMSC WebSocket, USGS) ve dakikalık tam turda
// tetiklenir; hepsi tek sırada çalışır, aynı olay iki kez paylaşılmaz.
// Her X gönderisi krediden düşer; eşikler bu yüzden yüksek tutulur.
const TWITTER_TURKIYE_MIN_MAGNITUDE = 3.0;
const TWITTER_WORLD_MIN_MAGNITUDE = 5.5;
const TWITTER_FRESH_CANDIDATE_LIMIT = 50;
/// Türkiye'de bu büyüklük ve üzerindeki depremlerin tweetine, Türkçe "ilk
/// adımlar" acil bilgi kartı YANIT olarak eklenir (emergency-card.ts).
const TWITTER_EMERGENCY_CARD_MIN_MAGNITUDE = 5.5;
// Küçük depremlerde sağlayıcılar büyüklüğü genelde ilk birkaç dakika içinde
// düşük/belirsiz verir, sonra dakikalar içinde yukarı revize eder (ör. M2.3 →
// M2.6). Push bildirimiyle aynı 15 dk'lık tazelik penceresi kullanılırsa,
// büyüklük eşiği (2.5) ancak pencere kapandıktan SONRA aşılan depremler hiç
// paylaşılmadan kalıcı olarak atlanır. Twitter'ın push gibi anlık teslim
// baskısı olmadığından burada daha geniş, ayrı bir pencere kullanılıyor.
const TWITTER_MAX_EVENT_AGE_MS = 45 * 60 * 1000;
// MARK: - Paylaşım defteri (yalnızca bellek)
//
// Twitter'a gönderilen paylaşımlar veritabanına YAZILMAZ. Otomatik paylaşım
// yalnızca tek örnekli `scheduledPushCheck` sürecinde çalışır ve bir deprem
// ancak 45 dakikalık aday penceresinde yeniden gündeme gelebilir; mükerrer
// koruması ve revizyon yanıtı için süreç belleği yeterli. (Eskiden her
// paylaşım `_system/twitter_posting_v1` belgesine süresiz yazılıyor, belge
// 110 KB'a ulaşmıştı; durum alanlarını okuyan kod da yoktu.)
//
// Süreç yeniden başladığında (dağıtım, örnek yenilenmesi) önceki sürecin
// paylaşmış olabileceği bir depremi tekrar paylaşmamak için olay zamanı bu
// sürecin başlangıcından ÖNCE olan depremler otomatik paylaşılmaz. Bedeli:
// yeniden başlatmaya denk gelen ve henüz paylaşılmamış bir deprem atlanabilir.
const tweetedQuakeIds = new Set<string>();
let tweetedQuakeFingerprints: QuakeFingerprint[] = [];
// Bir depremin orijinal tweet ID'sini ve o tweette paylaşılan büyüklük/derinliği
// tutar; sağlayıcı sonradan revize ederse orijinal tweete yanıt atmak ve bir
// sonraki karşılaştırmayı son bildirilen değere göre yapmak için kullanılır.
interface TweetedQuakeState {
  /// Orijinal tweet: güncellemeler hep buna yanıt olarak atılır.
  tweetId: string;
  magnitude: number;
  depth: number;
  time: number;
}

// MARK: - Güncellemeler yanıt olarak
//
// Paylaşılan tweet düzenlenmez: ajans büyüklüğü/derinliği anlamlı biçimde
// değiştirince orijinal tweete yanıt atılır, böylece ilk bilgi ve düzeltme
// zaman akışında birlikte görünür. Ajanslar ilk dakikalarda değeri gidip
// getirebilir (24 Eylül 2026 Şanlıurfa: 3 dk içinde M5.6 → 5.2 → 5.8, tweet 5
// kez düzenlendi). Her yanıt krediden düştüğü ve akışı kalabalıklaştırdığı
// için yeni değer TWITTER_REVISION_SETTLE_MS boyunca aynı kalınca tek yanıt
// atılır; arada değer yine değişirse bekleme baştan başlar.
const TWITTER_REVISION_SETTLE_MS = 2 * 60 * 1000;
interface PendingRevision { magnitude: number; depth: number; since: number; }
const pendingRevisions = new Map<string, PendingRevision>();
const tweetedQuakeState = new Map<string, TweetedQuakeState>();
/// Aday penceresi (45 dk) artı pay; defter bundan eski kayıtları tutmaz.
const TWEET_LEDGER_RETENTION_MS = 2 * 60 * 60 * 1000;
const twitterProcessStartedAt = Date.now();

// MARK: - X kredisi koruması
//
// X API kullandıkça öder: her başarılı istek önceden yüklenen krediden düşer,
// kredi bitince gönderi 402 döner. Eskiden başarısız deprem her dakikalık
// turda yeniden denendiği için kart görseli kredi yokken de her dakika
// üretilip yükleniyordu (14-15 Eylül 2026: 443 deneme, 0 paylaşım). Artık:
// - 402 alınınca otomatik paylaşım durur. TWITTER_CREDIT_RECHECK_MS sonra,
//   paylaşılacak bir deprem varsa, görsel ÜRETİLMEDEN önce ucuz bir okumayla
//   (users/me) kredi yoklanır; kredi yoksa görsel hiç üretilmez.
// - Diğer hatalarda deprem en fazla TWITTER_MAX_POST_ATTEMPTS kez denenir ve
//   ilk denemede yüklenen kart medyası yeniden kullanılır.
const TWITTER_CREDIT_RECHECK_MS = 60 * 60 * 1000;
const TWITTER_MAX_POST_ATTEMPTS = 3;
let twitterCreditsDepletedAt: number | null = null;
/// Henüz paylaşılamamış bir gönderinin deneme sayısı ve (yeni paylaşımlarda)
/// yüklenmiş kart medyası: undefined henüz yüklenmedi, null görsel
/// yüklenemedi (metin-only). Yalnızca bellekte; paylaşım olunca ya da aday
/// penceresi geçince silinir.
interface PendingTweet { attempts: number; time: number; mediaId?: string | null; }
const pendingTweets = new Map<string, PendingTweet>();

// undefined: henüz denenmedi, null: secret'lar eksik/geçersiz (paylaşım kapalı)
let twitterClient: TwitterApi | null | undefined;

// Secret Manager boş payload kabul etmediği için secret'lar henüz gerçek
// değerler girilmeden önce bu sentinel ile oluşturulur (bkz. deploy notları).
const TWITTER_SECRET_PLACEHOLDER = 'not-configured-yet';

function getTwitterClient(): TwitterApi | null {
  if (twitterClient !== undefined) return twitterClient;
  const { TWITTER_API_KEY, TWITTER_API_SECRET, TWITTER_ACCESS_TOKEN, TWITTER_ACCESS_SECRET } = process.env;
  if (!TWITTER_API_KEY || !TWITTER_API_SECRET || !TWITTER_ACCESS_TOKEN || !TWITTER_ACCESS_SECRET
      || TWITTER_API_KEY === TWITTER_SECRET_PLACEHOLDER || TWITTER_API_SECRET === TWITTER_SECRET_PLACEHOLDER
      || TWITTER_ACCESS_TOKEN === TWITTER_SECRET_PLACEHOLDER || TWITTER_ACCESS_SECRET === TWITTER_SECRET_PLACEHOLDER) {
    twitterClient = null;
    return null;
  }
  twitterClient = new TwitterApi({
    appKey: TWITTER_API_KEY,
    appSecret: TWITTER_API_SECRET,
    accessToken: TWITTER_ACCESS_TOKEN,
    accessSecret: TWITTER_ACCESS_SECRET
  });
  return twitterClient;
}

// MARK: - Tweet kartı görseli (SVG → PNG, medya yükleme)
//
// `functions/assets/` altındaki dosyalar deploy paketine dahil edilir (bkz.
// firebase.json'daki functions.ignore listesi — assets/ hariç tutulmuyor).
// Inter fontu sunucuya gömülü olduğu için hangi ortamda çalışırsa çalışsın
// aynı görünür; Apple sistem fontlarına bağımlı değildir.
function resolveAssetPath(relativePath: string): string {
  const primary = path.join(__dirname, relativePath);
  if (fs.existsSync(primary)) return primary;
  const fallback = path.join(__dirname, '..', relativePath);
  if (fs.existsSync(fallback)) return fallback;
  throw new Error(`Asset not found: ${relativePath}`);
}

let cardAssetsCache: (QuakeCardAssets & { fontFiles: string[] }) | null = null;

// Uygulama ikonu kaynakta 1024 px ama kartta ~59 px çiziliyor. Her render'da
// 1024 px PNG'yi (64 KB base64) çözüp küçültmemek için süreç başına bir kez,
// kartın ölçüsünün iki katına indirilir (render ~%13 kısalır).
const CARD_ICON_PX = 128;

function downscaledPNGBase64(file: string, size: number): string {
  const source = fs.readFileSync(file).toString('base64');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><image width="${size}" height="${size}" href="data:image/png;base64,${source}"/></svg>`;
  return new Resvg(svg).render().asPng().toString('base64');
}

function loadCardAssets(): QuakeCardAssets & { fontFiles: string[] } {
  if (cardAssetsCache) return cardAssetsCache;
  const worldMap = JSON.parse(fs.readFileSync(resolveAssetPath('assets/maps/world-110m.json'), 'utf8'));
  cardAssetsCache = {
    appIconBase64: downscaledPNGBase64(resolveAssetPath('assets/images/app-icon.png'), CARD_ICON_PX),
    storeBadgeBase64: fs.readFileSync(resolveAssetPath('assets/images/app-store-badge.png')).toString('base64'),
    worldMap,
    fontFiles: [
      resolveAssetPath('assets/fonts/Inter-Black.ttf'),
      resolveAssetPath('assets/fonts/Inter-Bold.ttf'),
      resolveAssetPath('assets/fonts/Inter-Medium.ttf')
    ]
  };
  return cardAssetsCache;
}

// 1200×675 (16:9) — Twitter'ın kart için önerdiği ölçü. Kaynak SVG zaten bu
// boyutta olduğu için 1:1 render edilir; yükseltmenin görünür bir faydası
// yoktu, yalnızca dosya boyutunu ve render belleğini artırıyordu.
function renderQuakeCardPNG(q: Earthquake): Buffer {
  const assets = loadCardAssets();
  const svg = buildQuakeCardSVG(q, assets);
  const resvg = new Resvg(svg, {
    font: {
      loadSystemFonts: false,
      fontFiles: assets.fontFiles,
      defaultFontFamily: 'Inter'
    },
    background: 'transparent',
    fitTo: { mode: 'zoom', value: 1 }
  });
  return resvg.render().asPng();
}

function renderEmergencyCardPNG(q: Earthquake): Buffer {
  const assets = loadCardAssets();
  return new Resvg(buildEmergencyInfoCardSVG(q, assets), {
    font: { loadSystemFonts: false, fontFiles: assets.fontFiles, defaultFontFamily: 'Inter' },
    fitTo: { mode: 'zoom', value: 1 }
  }).render().asPng();
}

/// Kart PNG'si yalnızca bellekte üretilir; diske, veritabanına ya da Storage'a
/// yazılmaz ve yükleme bitince bırakılır. X'e yüklenmiş ama gönderiye
/// bağlanmamış medya X tarafında 24 saatte kendiliğinden silinir.
async function uploadQuakeCardMedia(client: TwitterApi, q: Earthquake): Promise<string> {
  return client.v1.uploadMedia(renderQuakeCardPNG(q), { mimeType: EUploadMimeType.Png });
}

/// Acil bilgi kartı yanıtı atılmış orijinal tweetler (olay başına bir kez).
const emergencyCardReplies = new Set<string>();

function isEmergencyCardEligible(q: Earthquake): boolean {
  return isTurkiyeQuake(q) && q.magnitude >= TWITTER_EMERGENCY_CARD_MIN_MAGNITUDE;
}

/// Türkiye'deki büyük depremin tweetine acil bilgi kartını yanıt olarak ekler.
/// Büyüklük sonradan eşiğin üstüne revize edilirse de bir kez gönderilir.
/// Kredi bittiyse `stop` döner.
async function replyEmergencyCard(client: TwitterApi, q: Earthquake, tweetId: string, now: number): Promise<{ stop?: boolean }> {
  if (!isEmergencyCardEligible(q) || emergencyCardReplies.has(tweetId)) return {};
  const { tweetId: replyId, stop } = await attemptPost(client, `${tweetId}#acil`, q, now, async pending => {
    if (pending.mediaId === undefined) {
      try {
        pending.mediaId = await client.v1.uploadMedia(renderEmergencyCardPNG(q), { mimeType: EUploadMimeType.Png });
      } catch (error: any) {
        if (isCreditsDepletedError(error)) throw error;
        pending.mediaId = null;
        console.error(`Acil bilgi kartı üretilemedi/yüklenemedi (${q.id}), metin-only yanıt: ${twitterErrorMessage(error)}`);
      }
    }
    const text = buildEmergencyInfoTweetText(q);
    const result = pending.mediaId
      ? await client.v2.reply(text, tweetId, { media: { media_ids: [pending.mediaId] } })
      : await client.v2.reply(text, tweetId);
    return result.data.id;
  });
  if (replyId) {
    emergencyCardReplies.add(tweetId);
    console.log(`Acil bilgi kartı yanıtı başarılı: ${q.id} -> ${replyId} (orijinal: ${tweetId})`);
  }
  return { stop };
}

/// Defterden aday penceresinin gerisinde kalan kayıtları düşer.
export function pruneTweetedState(now: number): void {
  const cutoff = now - TWEET_LEDGER_RETENTION_MS;
  tweetedQuakeFingerprints = tweetedQuakeFingerprints.filter(item => item.time >= cutoff);
  const retainedIds = new Set(tweetedQuakeFingerprints.map(item => item.id));
  for (const id of tweetedQuakeIds) {
    if (!retainedIds.has(id)) tweetedQuakeIds.delete(id);
  }
  for (const [id, value] of tweetedQuakeState) {
    if (value.time < cutoff) tweetedQuakeState.delete(id);
  }
  for (const [key, value] of pendingTweets) {
    if (value.time < cutoff) pendingTweets.delete(key);
  }
  for (const [id, value] of pendingRevisions) {
    if (value.since < cutoff) pendingRevisions.delete(id);
  }
  const liveTweetIds = new Set([...tweetedQuakeState.values()].map(state => state.tweetId));
  for (const id of emergencyCardReplies) {
    if (!liveTweetIds.has(id)) emergencyCardReplies.delete(id);
  }
}

function eventTime(q: Earthquake): number {
  const time = new Date(q.date).getTime();
  return Number.isFinite(time) ? time : Date.now();
}

function recordTweet(q: Earthquake, tweetId: string, now: number): void {
  tweetedQuakeIds.add(q.id);
  const fingerprint = toQuakeFingerprint(q);
  if (fingerprint && !tweetedQuakeFingerprints.some(item => item.id === fingerprint.id)) {
    tweetedQuakeFingerprints.push(fingerprint);
  }
  recordTweetState(q, tweetId);
}

/// Paylaşılan son değerleri saklar. Tweet kimliği hep orijinaldir: yanıtlar
/// ilk tweete eklenir, zincir derinleşmez.
function recordTweetState(q: Earthquake, tweetId: string): void {
  tweetedQuakeState.delete(q.id); // Map ekleme sırasını korur; en son güncelleneni sona taşır.
  tweetedQuakeState.set(q.id, { tweetId, magnitude: q.magnitude, depth: q.depth, time: eventTime(q) });
  pendingRevisions.delete(q.id);
}

/// Yeni değer yeterince uzun süredir aynı mı? Değer değiştiyse bekleme
/// baştan başlar.
function revisionSettled(q: Earthquake, now: number): boolean {
  const pending = pendingRevisions.get(q.id);
  if (!pending || isMeaningfulQuakeRevision(pending, q)) {
    pendingRevisions.set(q.id, { magnitude: q.magnitude, depth: q.depth, since: now });
    return false;
  }
  return now - pending.since >= TWITTER_REVISION_SETTLE_MS;
}

function twitterErrorMessage(error: any): string {
  const data = error?.data;
  const message = data?.detail
    || data?.title
    || data?.errors?.[0]?.message
    || data?.errors?.[0]?.detail
    || error?.message
    || 'Bilinmeyen hata';
  return String(message).slice(0, 500);
}

function twitterErrorStatus(error: any): number | null {
  const status = Number(error?.code || error?.status || error?.data?.status);
  return Number.isFinite(status) ? status : null;
}

function isCreditsDepletedError(error: any): boolean {
  return twitterErrorStatus(error) === 402 || /credits?\s+depleted/i.test(twitterErrorMessage(error));
}

function markTwitterCreditsDepleted(now: number): void {
  if (twitterCreditsDepletedAt === null) {
    console.error('X kredisi bitti (402): otomatik paylaşım durdu, kart görseli üretilmeyecek. Kredi yüklenince saatlik yoklamayla kendiliğinden sürer.');
  }
  twitterCreditsDepletedAt = now;
}

/// Kredi bittiyse, paylaşılacak bir gönderi olduğunda saatte en fazla bir kez
/// görsel üretmeden önce kredinin geri gelip gelmediğini yoklar.
async function twitterCreditsAvailable(client: TwitterApi, now: number): Promise<boolean> {
  if (twitterCreditsDepletedAt === null) return true;
  if (now - twitterCreditsDepletedAt < TWITTER_CREDIT_RECHECK_MS) return false;
  try {
    await client.v2.me();
  } catch (error: any) {
    if (isCreditsDepletedError(error)) {
      twitterCreditsDepletedAt = now;
      return false;
    }
    // Başka bir yoklama hatası kredi durumunu söylemez; paylaşım denenir.
  }
  twitterCreditsDepletedAt = null;
  console.log('X kredisi yeniden kullanılabilir; otomatik paylaşım sürüyor.');
  return true;
}

/// Kart görseli yalnızca ilk denemede üretilip yüklenir; yeniden denemede
/// aynı medya kullanılır. Görsel başarısız olursa deprem paylaşımını
/// engellememesi için metin-only paylaşıma düşülür — kredi bitmesi hariç.
async function postQuakeTweet(client: TwitterApi, q: Earthquake, pending: PendingTweet): Promise<string> {
  if (pending.mediaId === undefined) {
    try {
      pending.mediaId = await uploadQuakeCardMedia(client, q);
    } catch (error: any) {
      if (isCreditsDepletedError(error)) throw error;
      pending.mediaId = null;
      console.error(`Kart görseli oluşturulamadı/yüklenemedi (${q.id}), metin-only paylaşılıyor: ${twitterErrorStatus(error) ?? ''} ${twitterErrorMessage(error)}`);
    }
  }
  const text = buildQuakeTweetText(q);
  const result = pending.mediaId
    ? await client.v2.tweet(text, { media: { media_ids: [pending.mediaId] } })
    : await client.v2.tweet(text);
  return result.data.id;
}

/// Gönderiyi deneme sınırı ve kredi korumasıyla bir kez dener; başarıda
/// `tweetId` döner. Kredi yoksa `stop` true olur: turun geri kalanı hiçbir
/// istek atmaz, görsel üretmez.
async function attemptPost(
  client: TwitterApi,
  key: string,
  q: Earthquake,
  now: number,
  post: (pending: PendingTweet) => Promise<string>
): Promise<{ tweetId?: string; stop?: boolean }> {
  const pending = pendingTweets.get(key) ?? { attempts: 0, time: eventTime(q) };
  if (pending.attempts >= TWITTER_MAX_POST_ATTEMPTS) return {};
  if (!(await twitterCreditsAvailable(client, now))) return { stop: true };
  pendingTweets.set(key, pending);
  try {
    const tweetId = await post(pending);
    pendingTweets.delete(key);
    return { tweetId };
  } catch (error: any) {
    if (isCreditsDepletedError(error)) {
      markTwitterCreditsDepleted(now);
      return { stop: true };
    }
    pending.attempts++;
    console.error(`Twitter hatası (${key}, deneme ${pending.attempts}/${TWITTER_MAX_POST_ATTEMPTS}): ${twitterErrorStatus(error) ?? ''} ${twitterErrorMessage(error)}`);
    return {};
  }
}

/// Her kaydın bu süreçte İLK görüldüğü an. Aynı olayın birden fazla ajans
/// kaydı aynı turda gelirse en önce görülen paylaşılır (eskiden en büyük
/// büyüklük seçiliyordu — en hızlı kaynak değil).
const firstSeenAt = new Map<string, number>();

function noteFirstSeen(quakes: Earthquake[], now: number): void {
  for (const quake of quakes) if (!firstSeenAt.has(quake.id)) firstSeenAt.set(quake.id, now);
  if (firstSeenAt.size > 5000) {
    const cutoff = now - TWEET_LEDGER_RETENTION_MS;
    for (const [id, seenAt] of firstSeenAt) if (seenAt < cutoff) firstSeenAt.delete(id);
  }
}

/// Paylaşım çağrıları tek sırada çalışır: tarama, gerçek zamanlı akış ve tam
/// tur aynı anda aynı depremi görüp iki kez paylaşmasın.
let twitterQueue: Promise<void> = Promise.resolve();

/// Otomatik Twitter/X paylaşımı. Push bildirim ayarlarından bağımsızdır;
/// veritabanına hiç dokunmaz. push-routes.ts bunu index.ts üzerinden
/// bağımlılık olarak alır (dairesel bağımlılık yok).
export function runAutomaticTwitterPosting(allQuakes: Earthquake[], now: number): Promise<void> {
  // Uzak yapılandırma: X paylaşımı duraklatılabilir; gizlenen deprem ve
  // kaynaklar hiç paylaşılmaz (remote-config.ts).
  if (remoteServerConfig().twitter_paused) return twitterQueue;
  const quakes = filterPublicQuakes(allQuakes);
  noteFirstSeen(quakes, now);
  twitterQueue = twitterQueue
    .then(() => postEligibleQuakes(quakes, now))
    .catch(error => console.error('Otomatik Twitter paylaşımı başarısız:', error?.message || error));
  return twitterQueue;
}

async function postEligibleQuakes(quakes: Earthquake[], now: number): Promise<void> {
  const client = getTwitterClient();
  if (!client) return;
  // En önce görülen kayıt önce işlenir; aynı olayın sonraki ajans kopyaları
  // ilk kayıt paylaşılınca parmak iziyle atlanır (aşağıdaki döngü).
  const twitterFresh = selectFreshQuakes(
    quakes.filter(q => isQuakeEligibleForTwitter(q, TWITTER_TURKIYE_MIN_MAGNITUDE, TWITTER_WORLD_MIN_MAGNITUDE)),
    now,
    TWITTER_MAX_EVENT_AGE_MS,
    TWITTER_FRESH_CANDIDATE_LIMIT
  ).sort((a, b) => (firstSeenAt.get(a.id) ?? now) - (firstSeenAt.get(b.id) ?? now));
  if (!twitterFresh.length) return;
  pruneTweetedState(now);
  for (const q of twitterFresh) {
    // Önce doğrudan ID ile, bulunamazsa aynı fiziksel olayın önceki tweet
    // parmak iziyle eşleştir.
    let previousState = tweetedQuakeState.get(q.id);
    if (!previousState) {
      const matchingFingerprint = tweetedQuakeFingerprints.find(item =>
        item.id === q.id || isLikelyCrossProviderDuplicate(q, item)
      );
      // Başka bir ajansın aynı olay için verdiği farklı büyüklük/derinlik
      // revizyon değildir (AFAD 7 km / EMSC 10 km gibi farklar olağan);
      // yanıt atmak yalnızca kredi harcardı.
      if (matchingFingerprint && matchingFingerprint.provider !== q.provider) continue;
      if (matchingFingerprint) previousState = tweetedQuakeState.get(matchingFingerprint.id);
    }

    if (previousState) {
      // Önceki denemede gidemediyse ya da büyüklük eşiğin üstüne çıktıysa.
      if ((await replyEmergencyCard(client, q, previousState.tweetId, now)).stop) return;
      if (!isMeaningfulQuakeRevision(previousState, q)) {
        // Değer paylaşılan hâline döndü: bekleyen güncelleme gereksiz.
        pendingRevisions.delete(q.id);
        continue;
      }
      if (!revisionSettled(q, now)) continue;
      const original = previousState;
      const { tweetId: replyId, stop } = await attemptPost(client, `${q.id}#revizyon`, q, now, async () => {
        const result = await client.v2.reply(buildQuakeRevisionReplyText(q, original), original.tweetId);
        return result.data.id;
      });
      if (stop) return;
      if (replyId) {
        recordTweetState(q, original.tweetId);
        console.log(`Twitter güncelleme yanıtı başarılı: ${q.id} -> ${replyId} (orijinal: ${original.tweetId})`);
      }
      continue;
    }
    if (isQuakePreviouslyTweeted(q, tweetedQuakeIds, tweetedQuakeFingerprints)) continue;
    // Önceki süreç paylaşmış olabilir (bkz. `twitterProcessStartedAt`).
    if (eventTime(q) < twitterProcessStartedAt) continue;
    const { tweetId, stop } = await attemptPost(client, q.id, q, now, pending => postQuakeTweet(client, q, pending));
    if (stop) return;
    if (tweetId) {
      recordTweet(q, tweetId, now);
      console.log(`Twitter paylaşımı başarılı: ${q.id} -> ${tweetId}`);
      if ((await replyEmergencyCard(client, q, tweetId, now)).stop) return;
    }
  }
}
