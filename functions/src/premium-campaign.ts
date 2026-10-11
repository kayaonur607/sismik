import * as admin from 'firebase-admin';
import { FieldPath, FieldValue, Firestore } from 'firebase-admin/firestore';
import {
  Earthquake,
  isTurkeyFastLaneQuake,
  isVersionOlder,
  normalizeLang,
  SupportedLang
} from './worker-utils';
import { bumpDeviceRegistryRevision, sendFcmMessages } from './push-routes';
import { withApnsTarget } from './apns';
import { recentLiveQuakes } from './earthquake-routes';

// MARK: - İzinli Premium tanıtım bildirimleri
//
// Apple 4.5.4 gereği yalnızca uygulamada "ürün güncellemeleri" iznini açıkça
// veren, Premium hakkı olmayan üretim cihazları hedeflenir. Ayrı Scheduler işi
// (`premiumEngagementCampaign`, pazar 18:00) deprem ve abonelik görevlerini
// yavaşlatmaz; iki gönderim arasında en az 12 gün vardır.
//
// Okuma bütçesi: sıklık sınırına takılan haftada TEK okuma (durum belgesi).
// Gönderim haftasında buna son 24 saatin deprem listesi (liste ucunun
// kullandığı anlık görüntü, bir okuma) ve kitle sorgusu eklenir. Yeni kurulum
// ve dil ayrımı zaten okunan cihaz belgesinden yapılır; ek okuma yok.

const PREMIUM_CAMPAIGN_MIN_INTERVAL_MS = 12 * 86400000;
const PREMIUM_CAMPAIGN_PAGE_SIZE = 500;
const PREMIUM_CAMPAIGN_MAX_DEVICES = 10000;
/// Kurulumunun ilk 3 gününde kullanıcıya tanıtım gitmez.
const NEW_INSTALL_GRACE_MS = 3 * 86400000;
/// Son 24 saatte Türkiye ve çevresinde bu büyüklükte deprem olduysa o haftanın
/// kampanyası atlanır (slot harcanmaz, bir sonraki pazar yeniden denenir).
const QUIET_AFTER_MAGNITUDE = 6.0;
const QUIET_WINDOW_MS = 24 * 60 * 60 * 1000;
/// Kayıtlı yerler 2.1.0'da geldi; o metin eski sürümlere gönderilmez.
const PLACES_MIN_APP_VERSION = '2.1.0';

type CampaignCopy = Record<SupportedLang, { title: string; body: string }>;

interface CampaignMessage {
  copy: CampaignCopy;
  minAppVersion?: string;
}

const CAMPAIGN_MESSAGES: CampaignMessage[] = [
  {
    minAppVersion: PLACES_MIN_APP_VERSION,
    copy: {
      tr: { title: 'Sevdiklerinin şehrini de takip et', body: 'Ev, iş, ailenin şehri: 8 yere kadar kaydet, her biri için ayrı yarıçap ve büyüklük eşiği belirle. Sismik Premium’da.' },
      en: { title: 'Follow the cities of those you love', body: 'Home, work, your family’s city: save up to 8 places, each with its own radius and magnitude threshold. In Sismik Premium.' },
      de: { title: 'Behalte auch die Stadt deiner Liebsten im Blick', body: 'Zuhause, Arbeit, die Stadt deiner Familie: Speichere bis zu 8 Orte mit eigenem Radius und eigener Magnitudenschwelle. In Sismik Premium.' },
      es: { title: 'Sigue también la ciudad de tus seres queridos', body: 'Casa, trabajo, la ciudad de tu familia: guarda hasta 8 lugares, cada uno con su propio radio y umbral de magnitud. En Sismik Premium.' },
      fr: { title: 'Suivez aussi la ville de vos proches', body: 'Maison, travail, la ville de votre famille : enregistrez jusqu’à 8 lieux, chacun avec son rayon et son seuil de magnitude. Dans Sismik Premium.' },
      it: { title: 'Segui anche la città dei tuoi cari', body: 'Casa, lavoro, la città della tua famiglia: salva fino a 8 luoghi, ognuno con il proprio raggio e soglia di magnitudo. In Sismik Premium.' },
      ja: { title: '大切な人の街も見守ろう', body: '自宅、職場、家族の街など最大8か所を登録し、場所ごとに半径とマグニチュードのしきい値を設定できます。Sismik Premiumで。' },
      ru: { title: 'Следите и за городом близких', body: 'Дом, работа, город семьи: сохраните до 8 мест, для каждого — свой радиус и порог магнитуды. В Sismik Premium.' },
      ar: { title: 'تابع مدن أحبائك أيضًا', body: 'المنزل والعمل ومدينة عائلتك: احفظ حتى 8 أماكن، لكل منها نصف قطر وحد أدنى للقوة. في Sismik Premium.' }
    }
  },
  {
    copy: {
      tr: { title: 'Artçıları kilit ekranından izle', body: 'Canlı Artçı Takibi, seçtiğin depremden sonraki 24 saati Kilit Ekranı ve Dynamic Island’da gösterir. Sismik Premium’da.' },
      en: { title: 'Watch aftershocks from your Lock Screen', body: 'Live Aftershock Tracking shows the 24 hours after a chosen quake on your Lock Screen and Dynamic Island. In Sismik Premium.' },
      de: { title: 'Nachbeben auf dem Sperrbildschirm verfolgen', body: 'Die Live-Nachbebenverfolgung zeigt die 24 Stunden nach einem gewählten Beben auf dem Sperrbildschirm und in der Dynamic Island. In Sismik Premium.' },
      es: { title: 'Sigue las réplicas desde la pantalla de bloqueo', body: 'El seguimiento de réplicas en vivo muestra las 24 horas posteriores al sismo que elijas en la pantalla de bloqueo y la Dynamic Island. En Sismik Premium.' },
      fr: { title: 'Suivez les répliques depuis l’écran verrouillé', body: 'Le suivi des répliques en direct affiche les 24 heures suivant le séisme choisi sur l’écran verrouillé et la Dynamic Island. Dans Sismik Premium.' },
      it: { title: 'Segui le repliche dalla schermata di blocco', body: 'Il monitoraggio delle repliche in tempo reale mostra le 24 ore successive al terremoto scelto sulla schermata di blocco e nella Dynamic Island. In Sismik Premium.' },
      ja: { title: '余震をロック画面で追跡', body: 'ライブ余震追跡では、選んだ地震後の24時間をロック画面とDynamic Islandに表示します。Sismik Premiumで。' },
      ru: { title: 'Афтершоки на экране блокировки', body: 'Отслеживание афтершоков в реальном времени показывает 24 часа после выбранного землетрясения на экране блокировки и в Dynamic Island. В Sismik Premium.' },
      ar: { title: 'تابع الهزات الارتدادية من شاشة القفل', body: 'تعرض ميزة تتبع الهزات الارتدادية المباشرة الساعات الأربع والعشرين التالية للزلزال الذي تختاره على شاشة القفل وDynamic Island. في Sismik Premium.' }
    }
  },
  {
    copy: {
      tr: { title: 'Her depremin arkasındaki hikâye', body: 'Sismolojik Analiz Raporu fay hattını, odak derinliğini ve bölgesel bağlamı sade bir dille anlatır. Sismik Premium’da.' },
      en: { title: 'The story behind every earthquake', body: 'The Seismological Analysis Report explains the fault, focal depth and regional context in plain language. In Sismik Premium.' },
      de: { title: 'Die Geschichte hinter jedem Erdbeben', body: 'Der seismologische Analysebericht erklärt Verwerfung, Herdtiefe und regionalen Kontext in einfacher Sprache. In Sismik Premium.' },
      es: { title: 'La historia detrás de cada sismo', body: 'El informe de análisis sismológico explica la falla, la profundidad focal y el contexto regional con palabras sencillas. En Sismik Premium.' },
      fr: { title: 'L’histoire derrière chaque séisme', body: 'Le rapport d’analyse sismologique explique la faille, la profondeur du foyer et le contexte régional en termes simples. Dans Sismik Premium.' },
      it: { title: 'La storia dietro ogni terremoto', body: 'Il rapporto di analisi sismologica spiega faglia, profondità ipocentrale e contesto regionale in modo semplice. In Sismik Premium.' },
      ja: { title: '地震の背景を知る', body: '地震学的分析レポートが、断層、震源の深さ、地域の特徴をわかりやすく解説します。Sismik Premiumで。' },
      ru: { title: 'История каждого землетрясения', body: 'Сейсмологический отчёт простым языком объясняет разлом, глубину очага и региональный контекст. В Sismik Premium.' },
      ar: { title: 'القصة وراء كل زلزال', body: 'يشرح تقرير التحليل الزلزالي الصدع وعمق البؤرة والسياق الإقليمي بلغة بسيطة. في Sismik Premium.' }
    }
  },
  {
    copy: {
      tr: { title: 'Fay hatlarını ve geçmişi keşfet', body: 'Diri fay hatları, ShakeMap katmanları, zaman oynatıcısı ve sınırsız deprem arşivi Sismik Premium’da seni bekliyor.' },
      en: { title: 'Explore fault lines and the past', body: 'Active fault lines, ShakeMap layers, the time player and an unlimited earthquake archive await you in Sismik Premium.' },
      de: { title: 'Entdecke Verwerfungen und die Vergangenheit', body: 'Aktive Verwerfungen, ShakeMap-Ebenen, der Zeitplayer und ein unbegrenztes Erdbebenarchiv warten in Sismik Premium auf dich.' },
      es: { title: 'Explora las fallas y el pasado', body: 'Fallas activas, capas ShakeMap, el reproductor temporal y un archivo ilimitado de sismos te esperan en Sismik Premium.' },
      fr: { title: 'Explorez les failles et le passé', body: 'Failles actives, couches ShakeMap, lecteur temporel et archive illimitée des séismes vous attendent dans Sismik Premium.' },
      it: { title: 'Esplora le faglie e il passato', body: 'Faglie attive, livelli ShakeMap, il lettore temporale e un archivio illimitato di terremoti ti aspettano in Sismik Premium.' },
      ja: { title: '断層と過去の地震を探索', body: '活断層、ShakeMapレイヤー、タイムプレーヤー、無制限の地震アーカイブがSismik Premiumで利用できます。' },
      ru: { title: 'Разломы и история землетрясений', body: 'Активные разломы, слои ShakeMap, проигрыватель времени и неограниченный архив землетрясений ждут вас в Sismik Premium.' },
      ar: { title: 'استكشف خطوط الصدع والتاريخ', body: 'خطوط الصدع النشطة وطبقات ShakeMap ومشغّل الزمن وأرشيف زلازل غير محدود بانتظارك في Sismik Premium.' }
    }
  }
];

/// Gönderimler arasında metinler sırayla döner. Cihazın sürümü o metnin
/// özelliğini desteklemiyorsa sıradaki uygun metin kullanılır.
export function campaignCopyFor(
  rotation: number,
  lang: string | undefined,
  appVersion: string | undefined
): { title: string; body: string } {
  const version = String(appVersion || '0');
  for (let offset = 0; offset < CAMPAIGN_MESSAGES.length; offset++) {
    const message = CAMPAIGN_MESSAGES[(rotation + offset) % CAMPAIGN_MESSAGES.length];
    if (message.minAppVersion && isVersionOlder(version, message.minAppVersion)) continue;
    return message.copy[normalizeLang(lang)];
  }
  return CAMPAIGN_MESSAGES[1].copy[normalizeLang(lang)];
}

/// Kitle sorgusunun döndürdüğü cihaz bu gönderimi almalı mı?
export function isCampaignRecipient(data: FirebaseFirestore.DocumentData, now: number): boolean {
  if (typeof data.token !== 'string' || !data.token) return false;
  if (data.is_premium === true) return false;
  const registeredAt = Number(data.registered_at || 0);
  // Kayıt zamanı bilinmeyen eski belge yeni kurulum sayılmaz.
  return !(registeredAt > 0 && now - registeredAt < NEW_INSTALL_GRACE_MS);
}

/// Son 24 saatte Türkiye ve çevresinde M6.0+ deprem var mı?
export function hasRecentMajorRegionalQuake(quakes: Earthquake[], now: number): boolean {
  return quakes.some(q => {
    const time = new Date(q.date).getTime();
    return q.magnitude >= QUIET_AFTER_MAGNITUDE
      && Number.isFinite(time) && now - time <= QUIET_WINDOW_MS
      && isTurkeyFastLaneQuake(q);
  });
}

function campaignMessage(
  token: string,
  copy: { title: string; body: string },
  campaignID: string,
  now: number
): admin.messaging.Message {
  return {
    token,
    notification: copy,
    apns: {
      headers: {
        'apns-priority': '5',
        'apns-push-type': 'alert',
        'apns-expiration': String(Math.floor(now / 1000) + 24 * 60 * 60),
        'apns-collapse-id': campaignID.slice(0, 64),
        'apns-topic': 'com.kayasoftware.sismik'
      },
      payload: {
        aps: { sound: 'default', 'thread-id': 'premium-updates', 'interruption-level': 'passive' },
        // Dokununca Premium ekranı açılır (eski ve yeni istemciler tanır).
        notificationKind: 'premium_offer',
        campaignId: campaignID,
        deepLink: 'sismik://paywall'
      }
    }
  };
}

export async function runPremiumEngagementCampaign(
  db: Firestore,
  now: number = Date.now(),
  loadRecentQuakes: () => Promise<Earthquake[]> = recentLiveQuakes
): Promise<void> {
  const stateRef = db.collection('_system').doc('premium_campaign_v1');
  const lastStartedAt = Number((await stateRef.get()).data()?.last_started_at || 0);
  if (now - lastStartedAt < PREMIUM_CAMPAIGN_MIN_INTERVAL_MS) {
    console.log('Premium tanıtım kampanyası sıklık sınırı nedeniyle atlandı.');
    return;
  }
  if (hasRecentMajorRegionalQuake(await loadRecentQuakes(), now)) {
    console.log(`Son 24 saatte Türkiye ve çevresinde M${QUIET_AFTER_MAGNITUDE}+ deprem var; premium kampanyası bu hafta atlandı.`);
    return;
  }

  const campaignID = `premium-${new Date(now).toISOString().slice(0, 10)}`;
  let claimed = false;
  let audienceCursor = '';
  // Gönderimden önce slot atomik olarak sahiplenilir: yarıda kalan bir koşu
  // yeniden başlayıp aynı kullanıcılara ikinci bildirim atamaz.
  await db.runTransaction(async transaction => {
    const data = (await transaction.get(stateRef)).data();
    if (now - Number(data?.last_started_at || 0) < PREMIUM_CAMPAIGN_MIN_INTERVAL_MS) return;
    claimed = true;
    audienceCursor = String(data?.audience_cursor || '');
    transaction.set(stateRef, { campaign_id: campaignID, status: 'sending', last_started_at: now, updated_at: now }, { merge: true });
  });
  if (!claimed) return;

  const rotation = Math.floor(now / (14 * 86400000)) % CAMPAIGN_MESSAGES.length;
  let scanned = 0;
  let targeted = 0;
  let sent = 0;
  let failed = 0;
  let lastDocumentID = audienceCursor;
  let reachedEnd = false;
  const deadDeviceIds: string[] = [];

  try {
    while (scanned < PREMIUM_CAMPAIGN_MAX_DEVICES) {
      let query: admin.firestore.Query = db.collection('devices')
        .where('environment', '==', 'prod')
        .where('is_premium', '==', false)
        .where('product_updates_enabled', '==', true)
        .orderBy(FieldPath.documentId())
        .limit(PREMIUM_CAMPAIGN_PAGE_SIZE);
      if (lastDocumentID) query = query.startAfter(lastDocumentID);

      const snapshot = await query.get();
      if (snapshot.empty) {
        reachedEnd = true;
        break;
      }

      const messages: admin.messaging.Message[] = [];
      const deviceIds: string[] = [];
      for (const doc of snapshot.docs) {
        const data = doc.data();
        if (!isCampaignRecipient(data, now)) continue;
        messages.push(withApnsTarget(campaignMessage(data.token, campaignCopyFor(rotation, data.lang, data.app_version), campaignID, now), data));
        deviceIds.push(doc.id);
      }
      if (messages.length) {
        targeted += messages.length;
        const summary = await sendFcmMessages(messages, 'premium-campaign', deviceIds);
        sent += summary.successCount;
        failed += summary.failureCount;
        deadDeviceIds.push(...(summary.deadTokenDeviceIds || []));
      }

      scanned += snapshot.size;
      lastDocumentID = snapshot.docs[snapshot.docs.length - 1].id;
      if (snapshot.size < PREMIUM_CAMPAIGN_PAGE_SIZE) {
        reachedEnd = true;
        break;
      }
    }

    for (let index = 0; index < deadDeviceIds.length; index += 450) {
      const batch = db.batch();
      deadDeviceIds.slice(index, index + 450).forEach(id => batch.delete(db.collection('devices').doc(id)));
      await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
      await batch.commit();
    }

    await stateRef.set({
      status: 'completed',
      last_completed_at: Date.now(),
      scanned,
      targeted,
      sent,
      failed,
      invalid_tokens: deadDeviceIds.length,
      audience_cursor: reachedEnd ? FieldValue.delete() : lastDocumentID,
      updated_at: Date.now()
    }, { merge: true });
    console.log(JSON.stringify({ event: 'premium_campaign', campaignID, scanned, targeted, sent, failed, invalid: deadDeviceIds.length }));
  } catch (error: any) {
    // İmleç kaydedilir: bir sonraki koşu bu çalışmanın başındaki eski
    // imleçten devam edip zaten gönderilmiş sayfaları tekrar göndermesin.
    await stateRef.set({
      status: 'failed',
      error: String(error?.message || error).slice(0, 500),
      scanned,
      targeted,
      sent,
      failed,
      audience_cursor: lastDocumentID,
      updated_at: Date.now()
    }, { merge: true });
    console.error('Premium tanıtım kampanyası tamamlanamadı:', error);
  }
}
