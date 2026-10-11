import axios from 'axios';
import { Earthquake } from './worker-utils';

// MARK: - Tsunami uyarıları
//
// Resmî tsunami merkezlerinin yayımladığı uyarılar, uyarı bölgesine yakın
// kayıtlı yeri olan kullanıcılara bildirim olarak gider:
//
//  - NOAA NTWC (Alaska; ABD/Kanada kıyıları) ve PTWC (Hawaii; Pasifik, Karayip):
//    Atom akışları. `Last-Modified` ile koşullu istenir; değişiklik yoksa 304
//    döner (gövde yok).
//  - JMA (Japonya): deprem listesindeki tsunami notu (津波警報 / 注意報).
//  - BMKG (Endonezya): deprem kaydındaki "Berpotensi tsunami".
//
// Akdeniz/Ege için (KOERI, NEAMTWS) herkese açık makine okunur akış yok.
//
// Maliyet: dakikada iki küçük koşullu istek; Firestore okuması yok. Gönderilen
// uyarıların kimliği push teslim durumuyla aynı yazımda saklanır.

export type TsunamiLevel = 'warning' | 'threat' | 'advisory' | 'watch';

export interface TsunamiAlert {
  /// Olay + seviye: aynı olayın seviyesi yükselirse yeni bir uyarı sayılır.
  id: string;
  agency: 'NTWC' | 'PTWC' | 'JMA' | 'BMKG';
  level: TsunamiLevel;
  region: string;
  lat: number;
  lon: number;
  magnitude: number | null;
  issuedAt: number;
}

/// Uyarı merkezinden bu yarıçaptaki kayıtlı yerler bildirimi alır. Uyarı ve
/// tehdit mesajları okyanus ölçeğinde olabildiği için daha geniş tutulur.
export function tsunamiAlertRadiusKm(level: TsunamiLevel): number {
  return level === 'warning' || level === 'threat' ? 1000 : 500;
}

/// Uyarılar bu süreden eskiyse gönderilmez (soğuk açılışta eski bülten).
export const TSUNAMI_ALERT_MAX_AGE_MS = 3 * 60 * 60 * 1000;

const NOAA_FEEDS: Array<{ agency: 'NTWC' | 'PTWC'; url: string }> = [
  { agency: 'NTWC', url: 'https://www.tsunami.gov/events/xml/PAAQAtom.xml' },
  { agency: 'PTWC', url: 'https://www.tsunami.gov/events/xml/PHEBAtom.xml' }
];

function tagValue(xml: string, tag: string): string {
  const match = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i').exec(xml);
  return match ? match[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';
}

function summaryField(summary: string, label: string): string {
  const match = new RegExp(`<strong>\\s*${label}:?\\s*</strong>\\s*([^<]*)`, 'i').exec(summary);
  return match ? match[1].replace(/\s+/g, ' ').trim() : '';
}

/// NOAA kategori metnini seviyeye çevirir. Bilgi bülteni ve iptal `null`.
export function noaaLevel(category: string): TsunamiLevel | null {
  const value = category.toLowerCase();
  if (value.includes('cancel')) return null;
  if (value.includes('warning')) return 'warning';
  if (value.includes('threat')) return 'threat';
  if (value.includes('advisory')) return 'advisory';
  if (value.includes('watch')) return 'watch';
  return null;
}

export function parseNOAAAtom(xml: string, agency: 'NTWC' | 'PTWC'): TsunamiAlert[] {
  const alerts: TsunamiAlert[] = [];
  const entries = xml.split(/<entry>/i).slice(1);
  for (const raw of entries) {
    const entry = raw.split(/<\/entry>/i)[0];
    const summary = /<summary[^>]*>([\s\S]*?)<\/summary>/i.exec(entry)?.[1] ?? '';
    const level = noaaLevel(summaryField(summary, 'Category'));
    if (!level) continue;
    const lat = Number(tagValue(entry, 'geo:lat'));
    const lon = Number(tagValue(entry, 'geo:long'));
    const issuedAt = Date.parse(tagValue(entry, 'updated'));
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(issuedAt)) continue;
    // Bülten yolu olayı tanımlar: .../events/PAAQ/2026/09/17/tliih5/1/WEAK53/...
    const bulletin = /href="[^"]*\/events\/(\w+\/\d{4}\/\d{2}\/\d{2}\/\w+)\//i.exec(entry)?.[1]
      ?? `${agency}-${Math.round(lat * 10)}-${Math.round(lon * 10)}-${new Date(issuedAt).toISOString().slice(0, 13)}`;
    const magnitude = parseFloat(summaryField(summary, 'Preliminary Magnitude'));
    alerts.push({
      id: `tsunami-${bulletin.replace(/\//g, '-')}-${level}`,
      agency,
      level,
      region: summaryField(summary, 'Affected Region') || tagValue(entry, 'title'),
      lat,
      lon,
      magnitude: Number.isFinite(magnitude) ? magnitude : null,
      issuedAt
    });
  }
  return alerts;
}

/// JMA ve BMKG deprem kayıtlarındaki tsunami işareti (earthquake-providers.ts
/// `tsunami` alanı) uyarıya dönüşür.
export function alertsFromQuakes(quakes: Earthquake[]): TsunamiAlert[] {
  const alerts: TsunamiAlert[] = [];
  for (const q of quakes) {
    const provider = String(q.provider).toUpperCase();
    if (!q.tsunami || (provider !== 'JMA' && provider !== 'BMKG')) continue;
    const issuedAt = Date.parse(q.date);
    if (!Number.isFinite(issuedAt)) continue;
    alerts.push({
      id: `tsunami-${q.id}`,
      agency: provider as 'JMA' | 'BMKG',
      // JMA'da 津波警報 uyarı, 注意報 ihtiyat; BMKG yalnızca "potansiyel" der.
      level: provider === 'JMA' ? 'warning' : 'threat',
      region: String(q.title || ''),
      lat: q.lat,
      lon: q.lon,
      magnitude: q.magnitude,
      issuedAt
    });
  }
  return alerts;
}

const feedState = new Map<string, { lastModified?: string; alerts: TsunamiAlert[] }>();

/// NOAA akışlarını koşullu ister. Değişmeyen akış için önceki ayrıştırma
/// kullanılır; hata eski sonucu korur.
export async function fetchNOAATsunamiAlerts(timeoutMs = 8000): Promise<TsunamiAlert[]> {
  const results = await Promise.all(NOAA_FEEDS.map(async feed => {
    const state = feedState.get(feed.url) ?? { alerts: [] };
    try {
      const response = await axios.get(feed.url, {
        timeout: timeoutMs,
        responseType: 'text',
        validateStatus: status => status === 200 || status === 304,
        headers: {
          'User-Agent': 'Sismik/2.1.4 (+https://sismik-app.web.app; sismikapplication@gmail.com)',
          ...(state.lastModified ? { 'If-Modified-Since': state.lastModified } : {})
        }
      });
      if (response.status === 200) {
        state.alerts = parseNOAAAtom(String(response.data || ''), feed.agency);
        state.lastModified = String(response.headers['last-modified'] || '') || undefined;
        feedState.set(feed.url, state);
      }
    } catch (error: any) {
      console.warn(`Tsunami akışı okunamadı (${feed.agency}):`, error?.message || error);
    }
    return state.alerts;
  }));
  return results.flat();
}

// MARK: Bildirim metni (14 dil)

type Lang = 'tr' | 'en' | 'de' | 'es' | 'fr' | 'it' | 'ja' | 'ru' | 'ar' | 'el' | 'pt' | 'id' | 'ko' | 'zh';

const LEVEL_WORDS: Record<Lang, Record<TsunamiLevel, string>> = {
  tr: { warning: 'Tsunami uyarısı', threat: 'Tsunami tehlikesi', advisory: 'Tsunami ikazı', watch: 'Tsunami izlemesi' },
  en: { warning: 'Tsunami warning', threat: 'Tsunami threat', advisory: 'Tsunami advisory', watch: 'Tsunami watch' },
  de: { warning: 'Tsunamiwarnung', threat: 'Tsunamigefahr', advisory: 'Tsunami-Hinweis', watch: 'Tsunami-Vorwarnung' },
  es: { warning: 'Alerta de tsunami', threat: 'Amenaza de tsunami', advisory: 'Aviso de tsunami', watch: 'Vigilancia de tsunami' },
  fr: { warning: 'Alerte tsunami', threat: 'Menace de tsunami', advisory: 'Avis de tsunami', watch: 'Veille tsunami' },
  it: { warning: 'Allerta tsunami', threat: 'Minaccia di tsunami', advisory: 'Avviso di tsunami', watch: 'Sorveglianza tsunami' },
  ja: { warning: '津波警報', threat: '津波の危険', advisory: '津波注意報', watch: '津波監視' },
  ru: { warning: 'Угроза цунами', threat: 'Опасность цунами', advisory: 'Предупреждение о цунами', watch: 'Наблюдение за цунами' },
  ar: { warning: 'تحذير من تسونامي', threat: 'خطر تسونامي', advisory: 'تنبيه من تسونامي', watch: 'مراقبة تسونامي' },
  el: { warning: 'Προειδοποίηση τσουνάμι', threat: 'Κίνδυνος τσουνάμι', advisory: 'Επιφυλακή τσουνάμι', watch: 'Παρακολούθηση τσουνάμι' },
  pt: { warning: 'Alerta de tsunami', threat: 'Ameaça de tsunami', advisory: 'Aviso de tsunami', watch: 'Vigilância de tsunami' },
  id: { warning: 'Peringatan tsunami', threat: 'Potensi tsunami', advisory: 'Imbauan tsunami', watch: 'Pemantauan tsunami' },
  ko: { warning: '쓰나미 경보', threat: '쓰나미 위험', advisory: '쓰나미 주의보', watch: '쓰나미 감시' },
  zh: { warning: '海啸警报', threat: '海啸威胁', advisory: '海啸提醒', watch: '海啸监测' }
};

const ADVICE: Record<Lang, { urgent: string; calm: string }> = {
  tr: { urgent: 'Kıyıdan hemen uzaklaşın, yüksek yere çıkın.', calm: 'Kıyıdan uzak durun ve resmî duyuruları izleyin.' },
  en: { urgent: 'Move away from the coast to high ground now.', calm: 'Stay away from the shore and follow official updates.' },
  de: { urgent: 'Verlassen Sie sofort die Küste, suchen Sie höheres Gelände auf.', calm: 'Meiden Sie den Strand und verfolgen Sie offizielle Meldungen.' },
  es: { urgent: 'Aléjese de la costa y suba a un terreno alto ya.', calm: 'Manténgase lejos de la orilla y siga los avisos oficiales.' },
  fr: { urgent: 'Quittez la côte et gagnez les hauteurs maintenant.', calm: 'Éloignez-vous du rivage et suivez les consignes officielles.' },
  it: { urgent: 'Allontanatevi subito dalla costa e salite in alto.', calm: 'State lontani dalla riva e seguite gli avvisi ufficiali.' },
  ja: { urgent: 'すぐに海岸から離れ、高い場所へ避難してください。', calm: '海岸に近づかず、公式情報を確認してください。' },
  ru: { urgent: 'Немедленно уйдите от побережья на возвышенность.', calm: 'Держитесь подальше от берега и следите за официальными сообщениями.' },
  ar: { urgent: 'ابتعد عن الساحل فورًا واتجه إلى مكان مرتفع.', calm: 'ابتعد عن الشاطئ وتابع البيانات الرسمية.' },
  el: { urgent: 'Απομακρυνθείτε αμέσως από την ακτή, σε ψηλό σημείο.', calm: 'Μείνετε μακριά από την ακτή και ακολουθήστε τις επίσημες οδηγίες.' },
  pt: { urgent: 'Afaste-se da costa e vá para um lugar alto agora.', calm: 'Fique longe da orla e acompanhe os avisos oficiais.' },
  id: { urgent: 'Segera jauhi pantai dan menuju tempat tinggi.', calm: 'Jauhi pantai dan ikuti informasi resmi.' },
  ko: { urgent: '즉시 해안에서 벗어나 높은 곳으로 대피하세요.', calm: '해안에 가까이 가지 말고 공식 발표를 확인하세요.' },
  zh: { urgent: '请立即远离海岸，前往高处。', calm: '请远离海边并关注官方通报。' }
};

function tsunamiLang(lang: string): Lang {
  const code = String(lang || '').toLowerCase();
  if (code.startsWith('pt')) return 'pt';
  if (code.startsWith('zh')) return 'zh';
  const short = code.slice(0, 2) as Lang;
  return short in LEVEL_WORDS ? short : 'en';
}

export function buildTsunamiNotification(alert: TsunamiAlert, lang: string): { title: string; body: string } {
  const code = tsunamiLang(lang);
  const urgent = alert.level === 'warning' || alert.level === 'threat';
  const magnitude = alert.magnitude ? ` · M${alert.magnitude.toFixed(1)}` : '';
  return {
    title: `🌊 ${LEVEL_WORDS[code][alert.level]}`,
    body: `${alert.agency}: ${alert.region}${magnitude}\n${urgent ? ADVICE[code].urgent : ADVICE[code].calm}`
  };
}
