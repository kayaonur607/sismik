import * as admin from 'firebase-admin';
import { FieldValue, Firestore } from 'firebase-admin/firestore';
import express from 'express';
import {
  AutomationRule,
  automationSentKey,
  isWithinExpiryWindow,
  maintenanceTasksForInstant,
  shouldRunAutomation
} from './worker-utils';
import { bumpDeviceRegistryRevision } from './push-routes';
import { withApnsTarget } from './apns';
import { collectDigestQuakes, refreshMapArchiveIfDue, refreshedLatestAppVersion } from './earthquake-routes';
import { runWeeklyDigest } from './weekly-digest';
import { expirePremiumEntitlements } from './subscription-routes';
import { APP_RELEASE_RULE_ID, APP_STORE_URL, runAppReleaseRule } from './app-update';

// MARK: - Basit IP bazlı istek sınırlama (instance içi)
//
// App Check zorlaması eski uygulama sürümlerini kıracağı için bu sürümde
// devreye alınamıyor; pahalı uçlar (Gemini) ve yazma uçları en azından IP
// başına pencere sınırıyla korunur. Sınır örnek başınadır (maxInstances 40);
// kötüye kullanım için yine de yeterli fren.
const rateBuckets = new Map<string, { count: number; resetAt: number }>();

export function isRateLimited(req: express.Request, scope: string, limit: number, windowMs: number): boolean {
  const forwarded = String(req.headers['x-forwarded-for'] || '');
  const ip = (forwarded.split(',')[0].trim() || req.ip || 'unknown').slice(0, 64);
  const key = `${scope}:${ip}`;
  const now = Date.now();

  const bucket = rateBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    rateBuckets.set(key, { count: 1, resetAt: now + windowMs });
    if (rateBuckets.size > 5000) {
      const oldest = rateBuckets.keys().next().value;
      if (oldest !== undefined) rateBuckets.delete(oldest);
    }
    return false;
  }
  bucket.count += 1;
  return bucket.count > limit;
}

/// Bildirim gönderiminin çağrı imzası. Fonksiyonun kendisi `index.ts`'te
/// kurulur; buradaki rotalar yalnızca çağırır.
type SendFcmMessages = (messages: admin.messaging.Message[], reason: string) => Promise<{
  successCount: number;
  failureCount: number;
  errorCodes: Record<string, number>;
  deadTokenDeviceIds?: string[];
}>;

// MARK: - Otomasyon motoru
//
// `automations` koleksiyonundaki kurallar (bilgi kartı bildirimleri:
// Scripts/info-cards.mjs; sürüm duyurusu: app-update.ts) saatlik bakım
// turunda değerlendirilir.
// Her kural için cihaz bazında "gönderildi" kaydı tutulur; aynı kural aynı
// aboneye aynı dönemde ikinci kez bildirim göndermez.

function automationMessageFor(
  rule: AutomationRule,
  lang: string
): { title: string; body: string } {
  return rule.messages[lang]
    || rule.messages.en
    || rule.messages.tr
    || { title: 'Sismik', body: '' };
}

function isExpiryTrigger(rule: AutomationRule): boolean {
  return rule.trigger === 'subscription_expiring';
}

/// Kuralın hedef kitlesini okuyan sorgu.
///
/// Süre sonu tetikleyicileri her bakım turunda çalışıyor. Eskiden tüm
/// kitleyi (ör. bütün premium cihazları) her turda okuyup bitiş penceresini
/// bellekte süzüyordu: tek bir hatırlatma kuralı günde 96 × cihaz sayısı okuma
/// demekti. Artık yalnızca bitişi bugünkü pencereye düşen cihazlar okunur
/// (`isWithinExpiryWindow` ile aynı sınırlar); kitle eşitliği bellekte
/// süzülür — aralık + eşitlik bileşik indeks isterdi.
function automationAudienceQuery(db: Firestore, rule: AutomationRule, now: number): FirebaseFirestore.Query {
  let query: FirebaseFirestore.Query = db.collection('devices');
  if (isExpiryTrigger(rule)) {
    const windowEnd = now + Number(rule.daysBefore || 0) * 86400000;
    return query
      .where('premium_expires_at', '>', Math.max(now, windowEnd - 86400000))
      .where('premium_expires_at', '<=', windowEnd);
  }
  if (rule.audience === 'premium') query = query.where('is_premium', '==', true);
  else if (rule.audience === 'free') query = query.where('is_premium', '==', false);
  else if (rule.audience === 'marketing_opt_in') query = query.where('product_updates_enabled', '==', true);
  return query;
}

function matchesAutomationAudience(data: FirebaseFirestore.DocumentData, audience: string): boolean {
  if (audience === 'premium') return data.is_premium === true;
  if (audience === 'free') return data.is_premium === false;
  if (audience === 'marketing_opt_in') return data.product_updates_enabled === true;
  return true;
}

export async function runAutomationRule(db: Firestore, sendFcmMessages: SendFcmMessages, rule: AutomationRule, now: number): Promise<number> {
  const snapshot = await automationAudienceQuery(db, rule, now).get();
  if (snapshot.empty) return 0;

  const messages: admin.messaging.Message[] = [];
  const sentMarks: { ref: FirebaseFirestore.DocumentReference; key: string }[] = [];

  snapshot.forEach(doc => {
    const data = doc.data();
    if (!data?.token) return;
    if (!matchesAutomationAudience(data, rule.audience)) return;

    // Koşullu tetikleyicilerde cihazın bitiş tarihi pencereye girmeli.
    let periodKey = String(rule.runAt || rule.id);
    if (isExpiryTrigger(rule)) {
      const expiresAt = Number(data.premium_expires_at || 0);
      if (!isWithinExpiryWindow(expiresAt, Number(rule.daysBefore || 0), now)) return;
      periodKey = String(expiresAt);
    }

    const sentKey = automationSentKey(rule.id, Number(periodKey) || now);
    const alreadySent: string[] = Array.isArray(data.automations_sent) ? data.automations_sent : [];
    if (alreadySent.includes(sentKey)) return;

    const text = automationMessageFor(rule, String(data.lang || 'tr').toLowerCase());
    messages.push(withApnsTarget({
      token: data.token,
      notification: { title: text.title, body: text.body },
      apns: {
        headers: {
          'apns-priority': '5',
          'apns-push-type': 'alert',
          'apns-collapse-id': `automation-${rule.id}`.slice(0, 64),
          'apns-topic': 'com.kayasoftware.sismik'
        },
        payload: { aps: { sound: 'default', 'interruption-level': 'passive' } }
      },
      data: {
        type: 'automation',
        ruleId: rule.id,
        // 2.1.2+: dokununca bilgi kartını açar; eski sürüm yok sayar.
        ...(rule.infoCardId ? { infoCard: String(rule.infoCardId) } : {})
      }
    }, data));
    sentMarks.push({ ref: doc.ref, key: sentKey });
  });

  if (!messages.length) return 0;

  const summary = await sendFcmMessages(messages, `automation:${rule.id}`);

  // Gönderim kaydı. Firestore toplu yazımı en fazla 500 işlem alır; kitle
  // 500'ü aşınca tek parti reddediliyor, kayıt düşmüyor ve kural bir sonraki
  // turda aynı kitleye yeniden bildirim gönderiyordu. 450'lik partilere bölünür.
  for (let index = 0; index < sentMarks.length; index += 450) {
    const batch = db.batch();
    sentMarks.slice(index, index + 450).forEach(mark => {
      // `update`: arada silinen cihaz yalnızca bu alanla yeniden oluşmasın.
      batch.update(mark.ref, { automations_sent: FieldValue.arrayUnion(mark.key) });
    });
    try {
      await batch.commit();
    } catch (error: any) {
      // NOT_FOUND: partideki bir cihaz arada silinmiş. Kalanlar tek tek yazılır.
      if (Number(error?.code) !== 5) throw error;
      await Promise.all(sentMarks.slice(index, index + 450).map(mark =>
        mark.ref.update({ automations_sent: FieldValue.arrayUnion(mark.key) }).catch(() => undefined)
      ));
    }
  }

  return summary.successCount;
}

async function runDueAutomations(db: Firestore, sendFcmMessages: SendFcmMessages, now: number): Promise<void> {
  const automationsRef = db.collection('automations');
  let snapshot;
  try {
    snapshot = await automationsRef.where('enabled', '==', true).get();
  } catch (error: any) {
    console.error('Otomasyon kuralları okunamadı:', error?.message || error);
    return;
  }
  if (snapshot.empty) return;

  for (const doc of snapshot.docs) {
    const data = doc.data();
    // Sürüm yayını kuralı panelden değil App Store Connect webhook'undan açılır
    // (app-update.ts); kendi çalıştırıcısı var.
    if (data.trigger === 'app_release' && doc.id === APP_RELEASE_RULE_ID) {
      try {
        await runAppReleaseRule(db, doc.ref, data, now);
      } catch (error: any) {
        console.error('Sürüm yayını kuralı çalıştırılamadı:', error?.message || error);
      }
      continue;
    }
    // Belge `last_run_at` taşıyor; kural modeli `lastRunAt` bekliyor. Eşleme
    // olmadığında tek seferlik zamanlanmış kural "hiç çalışmadı" sayılıp her
    // turda tüm kitleyi yeniden okuyordu.
    const rule = { id: doc.id, ...data, lastRunAt: data.last_run_at ?? data.lastRunAt } as AutomationRule;
    if (!shouldRunAutomation(rule, now)) continue;
    try {
      const sent = await runAutomationRule(db, sendFcmMessages, rule, now);
      await doc.ref.set({ last_run_at: now, last_sent_count: sent }, { merge: true });
      if (sent > 0) console.log(`Otomasyon "${rule.name}": ${sent} bildirim gönderildi.`);
    } catch (error: any) {
      // Bir kuralın hatası diğerlerini durdurmaz.
      console.error(`Otomasyon "${rule.name}" çalıştırılamadı:`, error?.message || error);
      await doc.ref.set({ last_error: String(error?.message || error).slice(0, 300), last_run_at: now }, { merge: true });
    }
  }
}

// MARK: - Günlük temizlik (04:05)
//
// Yalnızca `devices`: silinen cihaz push önbelleğine kayıt defteri sayacıyla
// duyurulmalı, TTL bunu yapamaz. ai_cache, felt_reports ve _system_push_claims
// belgelerini Firestore TTL politikası `expire_at` alanından okuma maliyeti
// olmadan siler (firestore.indexes.json); onlar için sorgu yapılmaz.
async function runDailyCleanup(db: Firestore): Promise<void> {
  const BATCH_SIZE = 450;
  const MAX_BATCHES = 10; // koşu başına en fazla ~4500 silme (maliyet sınırı)
  // 60 gün görülmeyen cihazlar (gizlilik politikası). Haftalık kayıt
  // yenilemesi etkin cihazların `updated_at` alanını taze tutar.
  const deviceCutoff = Date.now() - 60 * 86400000;
  let deleted = 0;
  try {
    for (let i = 0; i < MAX_BATCHES; i++) {
      const snap = await db.collection('devices')
        .where('updated_at', '<', deviceCutoff)
        .limit(BATCH_SIZE)
        .get();
      if (snap.empty) break;

      const batch = db.batch();
      snap.docs.forEach(doc => batch.delete(doc.ref, { lastUpdateTime: doc.updateTime }));
      await bumpDeviceRegistryRevision({ deletion: true, writer: batch });
      try {
        await batch.commit();
      } catch (error: any) {
        // FAILED_PRECONDITION: partideki bir cihaz sorgudan sonra kaydını
        // yeniledi. Eskiden bu tüm temizliği durduruyordu; yeniden sorgu o
        // cihazı (artık taze `updated_at`) dışarıda bırakır.
        if (Number(error?.code) !== 9) throw error;
        continue;
      }
      deleted += snap.size;
      if (snap.size < BATCH_SIZE) break;
    }
    console.log(`Temizlik tamam: ${deleted} eski cihaz kaydı silindi.`);
  } catch (error) {
    console.error('Günlük temizlik hatası:', error);
  }
}

// MARK: - Saatlik bakım turu
//
// Tek bir Scheduler işi (`maintenanceSweep`, index.ts) birden fazla bakım
// görevini sırayla yürütür: süresi dolan yetkileri kapatır
// (subscription-routes.ts), otomasyonları ve sürüm kuralını çalıştırır (bu
// dosyada), harita arşivini tazeler (earthquake-routes.ts) ve günlük
// temizliği tetikler (yukarıda). Ayrı işler açmamak bilinçli — her biri kendi
// Cloud Run örneğini ayağa kaldırırdı.
export async function runMaintenanceSweep(db: Firestore, sendFcmMessages: SendFcmMessages, now: number): Promise<void> {
  // Görevler birbirinden bağımsız: birinin hatası (ör. geçici Firestore
  // hatasıyla süre sonu taraması) eskiden turun geri kalanını — otomasyonlar,
  // harita arşivi, günlük temizlik, haftalık özet — o saat için iptal ediyordu.
  const step = async (name: string, work: () => Promise<unknown>) => {
    try {
      await work();
    } catch (error: any) {
      console.error(`Bakım görevi başarısız (${name}):`, error?.message || error);
    }
  };

  let devicesExpired = 0;
  await step('premium-expiry', async () => { devicesExpired = await expirePremiumEntitlements(db, now); });

  console.log(JSON.stringify({
    event: 'maintenance_sweep',
    devicesExpired,
    at: new Date(now).toISOString()
  }));

  await step('automations', () => runDueAutomations(db, sendFcmMessages, now));

  const maintenance = maintenanceTasksForInstant(now);
  await step('map-archive', () => refreshMapArchiveIfDue(maintenance.refreshMap));
  if (maintenance.cleanup) await step('daily-cleanup', () => runDailyCleanup(db));
  if (maintenance.weeklyDigest) {
    await step('weekly-digest', () => runWeeklyDigest(db, collectDigestQuakes, sendFcmMessages, now));
  }
}

// MARK: - Eski istemcilerin sürüm kontrolü

/// `/config` rotasını kaydeder.
export function registerConfigRoute(app: express.Express): void {
  // Yalnızca 1.0.8 – 2.0.9 istemcileri okur (2.1.1+ liste başlığını kullanır;
  // 2.1.0'da sürüm kontrolü yok).
  // `latestVersion` kendi sürümlerinden yeniyse ana sayfada güncelleme
  // banner'ı gösterirler; `minVersion` zorunlu güncelleme kapısıdır ve bilerek
  // 1.0.0'da kalır. Sürüm, listenin zaten okuduğu anlık görüntüden gelir
  // (15 sn bellek; ek Firestore okuması yok). İstemci her istekte
  // benzersiz `?check=` ekliyor; kısa CDN süresi yalnızca sorgusuz istekler
  // için ve sürüm artırıldığında eski değerin günlerce kalmaması için.
  app.get('/config', async (_req, res) => {
    res.setHeader('Cache-Control', 'public, max-age=300, s-maxage=3600');
    res.json({
      minVersion: '1.0.0',
      latestVersion: await refreshedLatestAppVersion(),
      storeURL: APP_STORE_URL
    });
  });
}
