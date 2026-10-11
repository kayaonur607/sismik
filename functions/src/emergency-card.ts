import { Earthquake, QuakeCardAssets, describeTweetLocation, APP_STORE_URL } from './worker-utils';

// MARK: - Büyük deprem sonrası acil bilgi kartı (Türkiye)
//
// Türkiye'deki büyük depremlerin (M5.5+) tweetine YANIT olarak paylaşılan
// Türkçe "ilk adımlar" kartı (twitter-posting.ts). Deprem kartıyla aynı font
// (Inter) ve rozetleri kullanır; 1080 × 1350 (4:5) — X mobil akışta
// kırpmadan gösterir.

const W = 1080;
const H = 1350;
const INK = '#17181A';
const ORANGE = '#FF6A00';
const RED = '#E5372B';

interface Step { title: string; detail: string; }

const STEPS: Step[] = [
  { title: 'Sarsıntı tekrarlarsa: Çök · Kapan · Tutun', detail: 'Artçılar saatlerce sürebilir; pencerelerden uzak durun.' },
  { title: 'Hasarlı binalara girmeyin', detail: 'Asansör kullanmayın; merdivenden inip açık alana çıkın.' },
  { title: 'Gazı, elektriği ve suyu kapatın', detail: 'Gaz kokusu varsa ateş yakmayın, düğmelere dokunmayın.' },
  { title: 'Toplanma alanına gidin', detail: 'Resmî toplanma alanları e-Devlet ve AFAD\'da yer alır.' },
  { title: 'Hatları meşgul etmeyin', detail: 'Yakınlarınıza mesajla ulaşın; aramayı acil durumlara bırakın.' },
  { title: 'Resmî açıklamaları takip edin', detail: 'AFAD ve valiliğin duyurularını esas alın, söylentiye inanmayın.' }
];

function esc(value: unknown): string {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const TR_MONTHS = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];

/// Türkiye saati (UTC+3, yaz saati uygulanmıyor).
function turkeyDateTime(date: Date): string {
  const local = new Date(date.getTime() + 3 * 60 * 60 * 1000);
  const hh = String(local.getUTCHours()).padStart(2, '0');
  const mm = String(local.getUTCMinutes()).padStart(2, '0');
  return `${local.getUTCDate()} ${TR_MONTHS[local.getUTCMonth()]} ${hh}:${mm}`;
}

export function buildEmergencyInfoCardSVG(q: Earthquake, assets: Pick<QuakeCardAssets, 'appIconBase64' | 'storeBadgeBase64'>): string {
  const location = describeTweetLocation(q);
  const place = [location.headline, location.sub].filter(Boolean).join(', ').replace(/, Türkiye$/, '');
  const summary = `${place} · M${q.magnitude.toFixed(1)} · ${turkeyDateTime(new Date(q.date))}`;

  const listTop = 390;
  const rowH = 118;
  const rows = STEPS.map((step, index) => {
    const y = listTop + index * rowH;
    return `
  <g transform="translate(72,${y})">
    <circle cx="30" cy="30" r="30" fill="${ORANGE}"/>
    <text x="30" y="41" font-family="Inter" font-size="30" font-weight="900" fill="#FFFFFF" text-anchor="middle">${index + 1}</text>
    <text x="88" y="27" font-family="Inter" font-size="33" font-weight="700" fill="${INK}">${esc(step.title)}</text>
    <text x="88" y="68" font-family="Inter" font-size="25" font-weight="500" fill="${INK}" fill-opacity="0.62">${esc(step.detail)}</text>
  </g>`;
  }).join('');

  const badgeW = 204;
  const badgeH = Math.round(badgeW / (498 / 167));
  const footerY = 1150;

  return `
<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <clipPath id="iconClip"><rect width="84" height="84" rx="19"/></clipPath>
  </defs>
  <rect width="${W}" height="${H}" fill="#FFF8F2"/>

  <!-- Başlık bandı -->
  <rect width="${W}" height="330" fill="${INK}"/>
  <rect x="72" y="72" width="190" height="48" rx="24" fill="${RED}"/>
  <text x="167" y="105" font-family="Inter" font-size="24" font-weight="900" fill="#FFFFFF" text-anchor="middle" letter-spacing="2">ACİL BİLGİ</text>
  <text x="72" y="208" font-family="Inter" font-size="68" font-weight="900" fill="#FFFFFF" letter-spacing="-1.5">Deprem sonrası ilk adımlar</text>
  <text x="72" y="268" font-family="Inter" font-size="30" font-weight="500" fill="#FFFFFF" fill-opacity="0.72">${esc(summary)}</text>

  ${rows}

  <!-- Alt bant: 112 ve uygulama -->
  <line x1="72" y1="${footerY - 36}" x2="${W - 72}" y2="${footerY - 36}" stroke="${INK}" stroke-opacity="0.1" stroke-width="2"/>
  <rect x="72" y="${footerY}" width="220" height="112" rx="26" fill="${RED}"/>
  <text x="182" y="${footerY + 50}" font-family="Inter" font-size="22" font-weight="700" fill="#FFFFFF" fill-opacity="0.85" text-anchor="middle">Acil çağrı</text>
  <text x="182" y="${footerY + 94}" font-family="Inter" font-size="46" font-weight="900" fill="#FFFFFF" text-anchor="middle">112</text>

  <g clip-path="url(#iconClip)" transform="translate(324,${footerY + 14})">
    <image width="84" height="84" href="data:image/png;base64,${assets.appIconBase64}"/>
  </g>
  <text x="428" y="${footerY + 50}" font-family="Inter" font-size="30" font-weight="900" fill="${INK}">Sismik</text>
  <text x="428" y="${footerY + 86}" font-family="Inter" font-size="21" font-weight="500" fill="${INK}" fill-opacity="0.62">Toplanma alanı · Acil çanta · SOS</text>
  <image x="${W - 72 - badgeW}" y="${footerY + (112 - badgeH) / 2}" width="${badgeW}" height="${badgeH}" href="data:image/png;base64,${assets.storeBadgeBase64}"/>
</svg>`.trim();
}

/// Kartla birlikte atılacak Türkçe metin (bağlantı 23 karakter sayılır).
export function buildEmergencyInfoTweetText(q: Earthquake): string {
  const location = describeTweetLocation(q);
  const place = location.headline;
  return [
    `🆘 ${place} M${q.magnitude.toFixed(1)} depremi sonrası ilk adımlar:`,
    '',
    '• Hasarlı binalara girmeyin, açık alanda kalın',
    '• Artçılara karşı: Çök · Kapan · Tutun',
    '• Hatları meşgul etmeyin; acil durumda 112',
    '',
    `📲 Toplanma alanları ve acil araçlar: ${APP_STORE_URL}`,
    '',
    '#Deprem #AcilDurum'
  ].join('\n');
}
