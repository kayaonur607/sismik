import * as admin from 'firebase-admin';
import { Firestore } from 'firebase-admin/firestore';
import { withApnsTarget } from './apns';
import {
  DevicePlace,
  Earthquake,
  getDistanceKm,
  notificationPlaceLabel,
  placesFromDeviceData
} from './worker-utils';

// MARK: - Haftalık bölge özeti (Premium)
//
// Pazartesi 09:05'te (İstanbul) bakım turunda bir kez çalışır: son 7 günde
// kullanıcının kayıtlı yerlerinin yarıçapı içinde M2.0+ kaç deprem olduğunu ve
// en büyüğünü tek, sessiz bir bildirimle söyler. Yalnızca özeti açıkça açık
// bildiren (2.2+ istemci `weekly_digest_enabled` yazar) premium cihazlara
// gider; eski sürüm bu bildirim türünü tanımıyor.
//
// Maliyet: haftada bir premium cihaz okuması + tek deprem toplaması. Aynı
// hafta iki kez gönderilmesin diye hafta anahtarı `_system/weekly_digest_v1`
// belgesinde tutulur (bakım turu yeniden denenirse).

export const WEEKLY_DIGEST_MIN_MAGNITUDE = 2.0;
/// Çok küçük yarıçaplı yerde (ör. 10 km) hafta çoğu zaman boş geçer; özet
/// bölgeyi anlatsın diye yarıçap en az bu kadar sayılır.
const DIGEST_MIN_RADIUS_KM = 50;

export interface WeeklyDigestSummary {
  count: number;
  largest?: { quake: Earthquake; placeName: string; distanceKm: number };
  busiestPlace?: { name: string; count: number };
}

/// Saf hesaplama: bir cihazın yerleri için haftalık sayım.
export function summarizeWeek(quakes: readonly Earthquake[], places: readonly DevicePlace[]): WeeklyDigestSummary {
  const perPlace = new Map<string, number>();
  let count = 0;
  let largest: WeeklyDigestSummary['largest'];
  for (const quake of quakes) {
    if (quake.magnitude < WEEKLY_DIGEST_MIN_MAGNITUDE) continue;
    let nearest: { place: DevicePlace; distanceKm: number } | null = null;
    for (const place of places) {
      const distanceKm = getDistanceKm(place.lat, place.lon, quake.lat, quake.lon);
      if (distanceKm > Math.max(DIGEST_MIN_RADIUS_KM, place.radiusKm)) continue;
      perPlace.set(place.id, (perPlace.get(place.id) || 0) + 1);
      if (!nearest || distanceKm < nearest.distanceKm) nearest = { place, distanceKm };
    }
    if (!nearest) continue;
    count++;
    if (!largest || quake.magnitude > largest.quake.magnitude) {
      largest = { quake, placeName: nearest.place.name, distanceKm: nearest.distanceKm };
    }
  }
  let busiestPlace: WeeklyDigestSummary['busiestPlace'];
  if (places.length > 1) {
    for (const place of places) {
      const placeCount = perPlace.get(place.id) || 0;
      if (placeCount && (!busiestPlace || placeCount > busiestPlace.count)) {
        busiestPlace = { name: place.name, count: placeCount };
      }
    }
  }
  return { count, largest, busiestPlace };
}

type Lang = 'tr' | 'en' | 'de' | 'es' | 'fr' | 'it' | 'ja' | 'ru' | 'ar';

const DIGEST_COPY: Record<Lang, {
  title: string;
  none: string;
  some: (count: number) => string;
  largest: (mag: string, place: string, km: number, name: string) => string;
}> = {
  tr: {
    title: 'Haftalık deprem özeti',
    none: 'Kayıtlı yerlerinin yakınında bu hafta M2.0 ve üzeri deprem olmadı.',
    some: n => `Kayıtlı yerlerinin yakınında bu hafta ${n} deprem oldu.`,
    largest: (m, p, km, name) => `En büyüğü M${m}, ${p} (${name} yerine ${km} km).`
  },
  en: {
    title: 'Weekly earthquake summary',
    none: 'No M2.0+ earthquakes near your saved places this week.',
    some: n => `${n} earthquake${n === 1 ? '' : 's'} near your saved places this week.`,
    largest: (m, p, km, name) => `Largest: M${m}, ${p} (${km} km from ${name}).`
  },
  de: {
    title: 'Wöchentliche Erdbebenübersicht',
    none: 'Diese Woche gab es keine Erdbeben ab M2.0 in der Nähe deiner Orte.',
    some: n => `Diese Woche ${n} Erdbeben in der Nähe deiner Orte.`,
    largest: (m, p, km, name) => `Das stärkste: M${m}, ${p} (${km} km von ${name}).`
  },
  es: {
    title: 'Resumen semanal de sismos',
    none: 'Esta semana no hubo sismos de M2.0 o más cerca de tus lugares.',
    some: n => `Esta semana hubo ${n} sismo${n === 1 ? '' : 's'} cerca de tus lugares.`,
    largest: (m, p, km, name) => `El mayor: M${m}, ${p} (a ${km} km de ${name}).`
  },
  fr: {
    title: 'Résumé sismique de la semaine',
    none: 'Aucun séisme de M2.0 ou plus près de vos lieux cette semaine.',
    some: n => `${n} séisme${n === 1 ? '' : 's'} près de vos lieux cette semaine.`,
    largest: (m, p, km, name) => `Le plus fort : M${m}, ${p} (à ${km} km de ${name}).`
  },
  it: {
    title: 'Riepilogo settimanale dei terremoti',
    none: 'Nessun terremoto di M2.0 o superiore vicino ai tuoi luoghi questa settimana.',
    some: n => `${n} terremot${n === 1 ? 'o' : 'i'} vicino ai tuoi luoghi questa settimana.`,
    largest: (m, p, km, name) => `Il più forte: M${m}, ${p} (a ${km} km da ${name}).`
  },
  ja: {
    title: '今週の地震まとめ',
    none: '今週、登録した場所の近くでM2.0以上の地震はありませんでした。',
    some: n => `今週、登録した場所の近くで${n}回の地震がありました。`,
    largest: (m, p, km, name) => `最大はM${m}、${p}（${name}から${km} km）。`
  },
  ru: {
    title: 'Сводка землетрясений за неделю',
    none: 'На этой неделе рядом с вашими местами не было землетрясений M2.0+.',
    some: n => `На этой неделе рядом с вашими местами: ${n} землетрясений.`,
    largest: (m, p, km, name) => `Самое сильное: M${m}, ${p} (${km} км от «${name}»).`
  },
  ar: {
    title: 'ملخص الزلازل الأسبوعي',
    none: 'لم تقع هذا الأسبوع زلازل بقوة M2.0 أو أكثر قرب أماكنك.',
    some: n => `وقع هذا الأسبوع ${n} زلزال قرب أماكنك المحفوظة.`,
    largest: (m, p, km, name) => `الأقوى: M${m}، ${p} (على بعد ${km} كم من ${name}).`
  }
};

export function buildDigestText(lang: string, summary: WeeklyDigestSummary): { title: string; body: string } {
  const copy = DIGEST_COPY[(lang in DIGEST_COPY ? lang : 'en') as Lang];
  if (!summary.count || !summary.largest) return { title: copy.title, body: copy.none };
  const { quake, placeName, distanceKm } = summary.largest;
  const body = `${copy.some(summary.count)} ${copy.largest(
    quake.magnitude.toFixed(1), notificationPlaceLabel(quake), Math.round(distanceKm), placeName
  )}`;
  return { title: copy.title, body };
}

/// ISO hafta anahtarı ("2026-W39"); aynı haftada ikinci gönderimi engeller.
export function isoWeekKey(now: number): string {
  const date = new Date(now);
  const day = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - day + 3);
  const firstThursday = new Date(Date.UTC(date.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round(((date.getTime() - firstThursday.getTime()) / 86400000 - 3 + ((firstThursday.getUTCDay() + 6) % 7)) / 7);
  return `${date.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

type SendFcm = (messages: admin.messaging.Message[], reason: string, deviceIds?: string[]) => Promise<{
  successCount: number;
  failureCount: number;
}>;

export async function runWeeklyDigest(
  db: Firestore,
  collectWeekQuakes: () => Promise<Earthquake[]>,
  sendFcmMessages: SendFcm,
  now: number
): Promise<void> {
  const stateRef = db.collection('_system').doc('weekly_digest_v1');
  const week = isoWeekKey(now);
  if ((await stateRef.get()).data()?.last_week === week) {
    console.log(`Haftalık özet ${week} zaten gönderilmiş.`);
    return;
  }

  const snapshot = await db.collection('devices').where('is_premium', '==', true).get();
  const recipients = snapshot.docs.flatMap(doc => {
    const data = doc.data();
    const expiry = Number(data.premium_expires_at || 0);
    if (expiry > 0 && expiry <= now) return [];
    if (data.transport !== 'fcm' || !data.token) return [];
    if (data.weekly_digest_enabled !== true || data.earthquake_notifications_enabled === false) return [];
    const places = placesFromDeviceData(data);
    return places.length ? [{ id: doc.id, token: String(data.token), lang: String(data.lang || 'tr'), places, data }] : [];
  });

  const since = now - 7 * 86400000;
  const quakes = recipients.length
    ? (await collectWeekQuakes()).filter(q => new Date(q.date).getTime() >= since)
    : [];

  // Hafta, gönderimden hemen ÖNCE transaction ile sahiplenilir (sürüm
  // duyurusu ve kampanyayla aynı desen). Eskiden kilit gönderimden SONRA
  // yazılıyordu: arada süreç çökerse ya da yazım başarısız olursa sonraki
  // tur aynı haftanın özetini herkese ikinci kez gönderiyordu. Hazırlık
  // (cihaz okuması, deprem toplama) kilitten önce: orada çıkan hata haftayı
  // "gönderildi" diye işaretlemez.
  let claimed = false;
  await db.runTransaction(async transaction => {
    if ((await transaction.get(stateRef)).data()?.last_week === week) return;
    claimed = true;
    transaction.set(stateRef, { last_week: week, status: 'sending', at: now }, { merge: true });
  });
  if (!claimed) return;
  if (!recipients.length) {
    await stateRef.set({ last_week: week, status: 'completed', sent: 0, failed: 0, at: now });
    return;
  }

  const messages: admin.messaging.Message[] = recipients.map(recipient => {
    const { title, body } = buildDigestText(recipient.lang, summarizeWeek(quakes, recipient.places));
    return withApnsTarget({
      token: recipient.token,
      notification: { title, body },
      apns: {
        headers: { 'apns-priority': '5', 'apns-push-type': 'alert', 'apns-topic': 'com.kayasoftware.sismik' },
        // Sessiz: özet bir deprem uyarısı değil, sesle dikkat çekmemeli.
        payload: { aps: { 'interruption-level': 'passive', 'thread-id': 'weekly-digest' }, notificationKind: 'weekly_digest' }
      }
    }, recipient.data);
  });
  const result = await sendFcmMessages(messages, 'Haftalık özet', recipients.map(r => r.id));
  await stateRef.set({ last_week: week, status: 'completed', sent: result.successCount, failed: result.failureCount, at: now });
  console.log(`Haftalık özet ${week}: ${result.successCount} gönderildi, ${result.failureCount} başarısız, ${quakes.length} deprem.`);
}
