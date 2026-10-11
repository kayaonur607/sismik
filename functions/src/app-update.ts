import { createHmac, timingSafeEqual } from 'node:crypto';
import * as admin from 'firebase-admin';
import express from 'express';
import { FieldPath, Firestore } from 'firebase-admin/firestore';
import { isVersionOlder, normalizeLang, SupportedLang } from './worker-utils';
import { bumpDeviceRegistryRevision, sendFcmMessages } from './push-routes';
import { withApnsTarget } from './apns';
import { publishLatestAppVersion, refreshedLatestAppVersion } from './earthquake-routes';


// MARK: - Uygulama güncellemesi: webhook → otomasyon kuralı → duyuru + banner
//
// Sürekli sürüm yoklaması YOK. Akış olay güdümlü:
//
//  1. App Store Connect webhook'u (APP_STORE_VERSION_APP_VERSION_STATE_UPDATED)
//     sürüm "READY_FOR_DISTRIBUTION" olduğunda `/app-store-connect/webhook`'u
//     çağırır. İmza (HMAC-SHA256, `ASC_WEBHOOK_SECRET`) doğrulanır ve
//     `automations/app-release` kuralı açılır. Olay yükü sürüm numarasını
//     taşımadığı için numara 2. adımda mağazadan okunur.
//  2. Saatlik bakım turu otomasyonları ZATEN sorguluyor (kural yokken tek
//     boş sorgu); ek Firestore okuması eklenmez. Kural açıkken tur, Apple'ın
//     herkese açık lookup ucuna bakar. Yeni sürüm mağazada göründüğü anda
//     (Apple onayı + dağıtım) sürümü yayımlar, eski sürümlere duyuruyu
//     gönderir ve kuralı kapatır. Mağaza gecikmesi bu bekleme ile karşılanır.
//  3. Yayımlanan sürüm canlı anlık görüntü belgesinin `latest_app_version`
//     alanına yazılır. Bunu HTTP örnekleri liste için zaten okuyor: 1.0.8 –
//     2.0.9 istemcileri `/config`'teki `latestVersion`'dan, 2.1.1+ istemcileri
//     liste yanıtının `X-Sismik-Latest-Version` başlığından banner açar.

export const APP_STORE_ID = '6787776158';
export const APP_STORE_URL = `https://apps.apple.com/app/id${APP_STORE_ID}`;
export const APP_RELEASE_RULE_ID = 'app-release';
/// Mağaza bu süre içinde yeni sürümü göstermezse kural zaman aşımıyla kapanır.
const APP_RELEASE_WAIT_MS = 72 * 60 * 60 * 1000;

type ReleaseCopy = Record<SupportedLang, { title: string; body: string }>;

/// Sürüme özel duyuru metni. Listede olmayan sürüm genel metinle duyurulur.
const RELEASE_COPY: Record<string, ReleaseCopy> = {
  '2.1.4': {
    tr: { title: '🌊 Sismik 2.1.4 yayında', body: '🌊 Tsunami uyarıları, 🔒 kilit ekranında canlı artçı takibi ve Kandilli dahil 9 kaynak. 📲 App Store\'dan hemen güncelle.' },
    en: { title: '🌊 Sismik 2.1.4 is out', body: '🌊 Tsunami warnings, 🔒 live aftershock tracking on your Lock Screen and 9 official sources. 📲 Update now on the App Store.' },
    de: { title: '🌊 Sismik 2.1.4 ist da', body: '🌊 Tsunamiwarnungen, 🔒 Nachbeben live auf dem Sperrbildschirm und 9 offizielle Quellen. 📲 Jetzt im App Store aktualisieren.' },
    es: { title: '🌊 Sismik 2.1.4 ya está disponible', body: '🌊 Alertas de tsunami, 🔒 réplicas en directo en la pantalla bloqueada y 9 fuentes oficiales. 📲 Actualízala ya en la App Store.' },
    fr: { title: '🌊 Sismik 2.1.4 est disponible', body: '🌊 Alertes tsunami, 🔒 répliques en direct sur l’écran verrouillé et 9 sources officielles. 📲 Mettez-la à jour sur l’App Store.' },
    it: { title: '🌊 Sismik 2.1.4 è disponibile', body: '🌊 Allerte tsunami, 🔒 repliche dal vivo sulla schermata di blocco e 9 fonti ufficiali. 📲 Aggiornala subito dall’App Store.' },
    ja: { title: '🌊 Sismik 2.1.4 を公開しました', body: '🌊 津波警報、🔒 ロック画面での余震ライブ追跡、気象庁を含む9つの公式情報源。📲 今すぐ App Store でアップデート。' },
    ru: { title: '🌊 Вышла Sismik 2.1.4', body: '🌊 Предупреждения о цунами, 🔒 афтершоки на экране блокировки и 9 официальных источников. 📲 Обновите в App Store.' },
    ar: { title: '🌊 إصدار Sismik 2.1.4 متاح الآن', body: '🌊 تحذيرات التسونامي، 🔒 متابعة الهزات الارتدادية مباشرة على شاشة القفل و9 مصادر رسمية. 📲 حدّث الآن من App Store.' }
  },
  '2.1.0': {
    tr: {
      title: 'Bildirim altyapımız yenilendi',
      body: 'Sismik 2.1.0 ile konum bazlı bildirimlere geçtik: kaydettiğin yerlere göre uyarı alırsın. Kesintisiz bildirim için uygulamayı güncelle.'
    },
    en: {
      title: 'Our alert system has changed',
      body: 'Sismik 2.1.0 moves to location-based notifications: you get alerts for the places you save. Update the app to keep receiving alerts.'
    },
    de: {
      title: 'Unser Benachrichtigungssystem ist neu',
      body: 'Mit Sismik 2.1.0 gibt es standortbasierte Benachrichtigungen: Du erhältst Warnungen für deine gespeicherten Orte. Aktualisiere die App, um weiter Warnungen zu erhalten.'
    },
    es: {
      title: 'Hemos renovado nuestras notificaciones',
      body: 'Sismik 2.1.0 pasa a notificaciones basadas en la ubicación: recibes alertas de los lugares que guardas. Actualiza la app para seguir recibiendo alertas.'
    },
    fr: {
      title: 'Notre système d’alertes a changé',
      body: 'Sismik 2.1.0 passe aux notifications basées sur la localisation : vous recevez des alertes pour vos lieux enregistrés. Mettez l’app à jour pour continuer à les recevoir.'
    },
    it: {
      title: 'Il sistema di notifiche è cambiato',
      body: 'Sismik 2.1.0 passa alle notifiche basate sulla posizione: ricevi avvisi per i luoghi che salvi. Aggiorna l’app per continuare a riceverli.'
    },
    ja: {
      title: '通知システムを刷新しました',
      body: 'Sismik 2.1.0 から位置情報に基づく通知に移行し、保存した場所に応じて通知が届きます。引き続き通知を受け取るにはアプリをアップデートしてください。'
    },
    ru: {
      title: 'Мы обновили систему оповещений',
      body: 'В Sismik 2.1.0 оповещения теперь привязаны к местоположению: вы получаете их для сохранённых мест. Обновите приложение, чтобы продолжать получать оповещения.'
    },
    ar: {
      title: 'جدّدنا نظام الإشعارات',
      body: 'انتقل Sismik 2.1.0 إلى إشعارات تعتمد على الموقع: تصلك التنبيهات للأماكن التي تحفظها. حدّث التطبيق لتستمر في تلقي التنبيهات.'
    }
  }
};

/// Genel duyuru şablonu: başlık 🚀, gövde ✨ … 📲. Metin "App Store'dan
/// güncelle" der; 2.1.1+ istemcide bildirime dokunmak App Store'u doğrudan
/// açar, eski istemcilerde de metin doğru kalır. `RELEASE_COPY`'ye eklenecek
/// sürüme özel metinler de aynı emoji düzenini izlemeli.
function genericReleaseCopy(version: string): ReleaseCopy {
  return {
    tr: { title: `🚀 Sismik ${version} yayında`, body: '✨ Yeni sürümde iyileştirmeler ve düzeltmeler var. 📲 App Store\'dan hemen güncelle.' },
    en: { title: `🚀 Sismik ${version} is out`, body: '✨ The new version brings improvements and fixes. 📲 Update now on the App Store.' },
    de: { title: `🚀 Sismik ${version} ist da`, body: '✨ Die neue Version bringt Verbesserungen und Fehlerbehebungen. 📲 Jetzt im App Store aktualisieren.' },
    es: { title: `🚀 Sismik ${version} ya está disponible`, body: '✨ La nueva versión incluye mejoras y correcciones. 📲 Actualízala ya en la App Store.' },
    fr: { title: `🚀 Sismik ${version} est disponible`, body: '✨ La nouvelle version apporte des améliorations et des correctifs. 📲 Mettez-la à jour dès maintenant sur l’App Store.' },
    it: { title: `🚀 Sismik ${version} è disponibile`, body: '✨ La nuova versione include miglioramenti e correzioni. 📲 Aggiornala subito dall’App Store.' },
    ja: { title: `🚀 Sismik ${version} を公開しました`, body: '✨ 新しいバージョンでは改善と修正を行いました。📲 今すぐ App Store でアップデートしてください。' },
    ru: { title: `🚀 Вышла Sismik ${version}`, body: '✨ В новой версии — улучшения и исправления. 📲 Обновите приложение в App Store прямо сейчас.' },
    ar: { title: `🚀 إصدار Sismik ${version} متاح الآن`, body: '✨ يتضمن الإصدار الجديد تحسينات وإصلاحات. 📲 حدّث التطبيق الآن من App Store.' }
  };
}

/// Cihaz belgesi duyuruyu almalı mı? Sürümü bilinmeyen ya da FCM token'ı
/// olmayan kayıtlar atlanır.
export function needsAppUpdateNotice(
  data: FirebaseFirestore.DocumentData | undefined,
  latestVersion: string
): boolean {
  if (!data || data.transport !== 'fcm' || typeof data.token !== 'string' || !data.token) return false;
  const version = String(data.app_version || '').trim();
  return Boolean(version) && isVersionOlder(version, latestVersion);
}

export function appUpdateMessage(
  token: string,
  lang: string | undefined,
  now: number,
  latestVersion: string
): admin.messaging.Message {
  const copy = (RELEASE_COPY[latestVersion] ?? genericReleaseCopy(latestVersion))[normalizeLang(lang)];
  return {
    token,
    notification: copy,
    apns: {
      headers: {
        'apns-priority': '10',
        'apns-push-type': 'alert',
        'apns-expiration': String(Math.floor(now / 1000) + 3 * 86400),
        'apns-collapse-id': `app-update-${latestVersion}`,
        'apns-topic': 'com.kayasoftware.sismik'
      },
      payload: {
        aps: { sound: 'default', 'thread-id': 'app-updates', 'interruption-level': 'active' },
        // Eski istemci tanımadığı türe dokunulunca bildirim kimliğini deprem
        // kimliği sanıp boş bir detay açıyor. `admin_manual`'ı tanıyor:
        // uygulama açıkken de gösterir, dokununca ana sayfayı açar. 2.1.1+
        // `announcement`'ı tanır: dokununca App Store açılır ve banner hemen
        // görünür (`latestVersion`). 2.1.0'da sürüm/banner kodu yok.
        notificationKind: 'admin_manual',
        announcement: 'app_update',
        latestVersion
      }
    }
  };
}

const PAGE_SIZE = 500;
let announcedInProcess = '';

/// Güncelleme duyurusunu sürüm başına bir kez gönderir. Slot, gönderimden
/// ÖNCE transaction ile sahiplenilir: yarıda kalan bir koşu yeniden
/// başlayıp aynı kullanıcılara ikinci kez bildirim atamaz.
export async function runAppUpdateAnnouncement(
  db: Firestore,
  now: number,
  latestVersion: string
): Promise<void> {
  if (announcedInProcess === latestVersion) return;
  const stateRef = db.collection('_system').doc('app_update_v1');
  let claimed = false;
  await db.runTransaction(async transaction => {
    const announced = String((await transaction.get(stateRef)).data()?.announced_version || '');
    if (announced && !isVersionOlder(announced, latestVersion)) return;
    claimed = true;
    transaction.set(stateRef, {
      announced_version: latestVersion,
      status: 'sending',
      started_at: now,
      updated_at: now
    }, { merge: true });
  });
  announcedInProcess = latestVersion;
  if (!claimed) return;

  let scanned = 0;
  let targeted = 0;
  let sent = 0;
  let failed = 0;
  const deadDeviceIds: string[] = [];
  try {
    let cursor = '';
    while (true) {
      let query = db.collection('devices')
        .where('environment', '==', 'prod')
        .orderBy(FieldPath.documentId())
        .limit(PAGE_SIZE);
      if (cursor) query = query.startAfter(cursor);
      const page = await query.get();
      if (page.empty) break;
      scanned += page.size;
      cursor = page.docs[page.docs.length - 1].id;

      const messages: admin.messaging.Message[] = [];
      const deviceIds: string[] = [];
      for (const doc of page.docs) {
        const data = doc.data();
        if (!needsAppUpdateNotice(data, latestVersion)) continue;
        messages.push(withApnsTarget(appUpdateMessage(data.token, data.lang, now, latestVersion), data));
        deviceIds.push(doc.id);
      }
      if (messages.length) {
        targeted += messages.length;
        const summary = await sendFcmMessages(messages, 'app-update', deviceIds);
        sent += summary.successCount;
        failed += summary.failureCount;
        deadDeviceIds.push(...(summary.deadTokenDeviceIds || []));
      }
      if (page.size < PAGE_SIZE) break;
    }

    for (let index = 0; index < deadDeviceIds.length; index += 450) {
      const batch = db.batch();
      deadDeviceIds.slice(index, index + 450).forEach(id => batch.delete(db.collection('devices').doc(id)));
      await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
      await batch.commit();
    }

    await stateRef.set({
      status: 'completed',
      scanned,
      targeted,
      sent,
      failed,
      invalid_tokens: deadDeviceIds.length,
      completed_at: Date.now(),
      updated_at: Date.now()
    }, { merge: true });
    console.log(JSON.stringify({ event: 'app_update_announcement', version: latestVersion, scanned, targeted, sent, failed, invalid: deadDeviceIds.length }));
  } catch (error: any) {
    await stateRef.set({
      status: 'failed',
      error: String(error?.message || error).slice(0, 500),
      scanned,
      targeted,
      sent,
      failed,
      updated_at: Date.now()
    }, { merge: true });
    console.error('Güncelleme duyurusu tamamlanamadı:', error);
  }
}

/// App Store'daki yayında sürüm (herkese açık lookup ucu; kimlik gerekmez).
/// Hata ya da beklenmeyen yanıtta `null` — kural bir sonraki turu bekler.
export async function fetchAppStoreVersion(): Promise<string | null> {
  try {
    const response = await fetch(
      `https://itunes.apple.com/lookup?id=${APP_STORE_ID}&country=tr&t=${Date.now()}`,
      { signal: AbortSignal.timeout(8000) }
    );
    if (!response.ok) return null;
    const body: any = await response.json();
    const version = body?.results?.[0]?.version;
    return typeof version === 'string' && /^\d+(\.\d+)*$/.test(version) ? version : null;
  } catch {
    return null;
  }
}

/// `automations/app-release` kuralı: bakım turu açıkken her turda bir kez
/// çağırır. Yeni sürüm mağazada görününce banner'ı açar, duyuruyu gönderir
/// ve kuralı kapatır.
export async function runAppReleaseRule(
  db: Firestore,
  ruleRef: FirebaseFirestore.DocumentReference,
  rule: FirebaseFirestore.DocumentData,
  now: number,
  fetchStoreVersion: () => Promise<string | null> = fetchAppStoreVersion
): Promise<void> {
  const newerThan = String(rule.newer_than || '');
  const storeVersion = await fetchStoreVersion();
  if (!storeVersion || !newerThan || !isVersionOlder(newerThan, storeVersion)) {
    if (now - Number(rule.requested_at || now) > APP_RELEASE_WAIT_MS) {
      await ruleRef.set({ enabled: false, status: 'timeout', last_run_at: now, updated_at: now }, { merge: true });
      console.warn(`Yeni sürüm ${Math.round(APP_RELEASE_WAIT_MS / 3600000)} saatte mağazada görünmedi; sürüm kuralı kapatıldı.`);
    }
    return;
  }
  await publishLatestAppVersion(storeVersion);
  await runAppUpdateAnnouncement(db, now, storeVersion);
  await ruleRef.set({
    enabled: false,
    status: 'completed',
    version: storeVersion,
    last_run_at: now,
    completed_at: now,
    updated_at: now
  }, { merge: true });
  console.log(`Sürüm ${storeVersion} mağazada: banner açıldı, duyuru tamamlandı.`);
}

/// App Store Connect imzası: `x-apple-signature: hmacsha256=<hex>`, ham gövdenin
/// HMAC-SHA256'sı. Karşılaştırma sabit sürelidir.
export function isValidAscSignature(rawBody: unknown, header: unknown, secret: string): boolean {
  if (!Buffer.isBuffer(rawBody) || !secret) return false;
  const match = /^hmacsha256=([0-9a-f]{64})$/i.exec(String(header || '').trim());
  if (!match) return false;
  const expected = createHmac('sha256', secret).update(rawBody).digest();
  const received = Buffer.from(match[1], 'hex');
  return received.length === expected.length && timingSafeEqual(received, expected);
}

export function registerAppUpdateRoutes(app: express.Express, db: Firestore): void {
  app.post('/app-store-connect/webhook', async (req, res) => {
    const secret = process.env.ASC_WEBHOOK_SECRET || '';
    if (!secret) {
      console.error('ASC_WEBHOOK_SECRET tanımsız; App Store Connect webhook reddedildi.');
      res.status(503).json({ error: 'Webhook not configured' });
      return;
    }
    // Cloud Functions ham gövdeyi `rawBody` olarak taşır; imza onun üzerinden.
    if (!isValidAscSignature((req as any).rawBody, req.headers['x-apple-signature'], secret)) {
      console.warn('App Store Connect webhook imzası geçersiz.');
      res.status(401).json({ error: 'Invalid signature' });
      return;
    }

    const data = req.body?.data;
    const state = data?.attributes?.newValue;
    if (data?.type !== 'appStoreVersionAppVersionStateUpdated' || state !== 'READY_FOR_DISTRIBUTION') {
      // Ping ve diğer durum geçişleri (inceleme, red...) yalnızca onaylanır.
      console.log(`App Store Connect olayı: ${String(data?.type || 'unknown')} ${String(state || '')}`.trim());
      res.status(200).json({ ok: true, ignored: true });
      return;
    }

    try {
      const now = Date.now();
      const newerThan = await refreshedLatestAppVersion();
      await db.collection('automations').doc(APP_RELEASE_RULE_ID).set({
        name: 'Yeni sürüm yayını',
        trigger: 'app_release',
        audience: 'all',
        enabled: true,
        status: 'waiting_for_store',
        newer_than: newerThan,
        app_store_version_id: String(data?.relationships?.instance?.data?.id || ''),
        requested_at: now,
        created_at: now,
        updated_at: now,
        updated_by: 'app_store_connect'
      }, { merge: true });
      console.log(`App Store Connect: yeni sürüm dağıtıma hazır; ${newerThan} sonrası sürüm mağazada beklenecek.`);
      res.status(200).json({ ok: true });
    } catch (error: any) {
      console.error('Sürüm kuralı açılamadı:', error?.message || error);
      res.status(500).json({ error: 'Rule could not be saved' });
    }
  });
}
