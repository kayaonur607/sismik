import express from 'express';
import { Firestore } from 'firebase-admin/firestore';
import axios from 'axios';
import { createHash } from 'node:crypto';
import { SupportedLang, normalizeLang } from './worker-utils';

// MARK: - AI Analizi (Gemini ile)
//
// index.ts'ten taşındı (Task 10a): `callGemini`, AI önbelleği (bellek içi +
// Firestore `ai_cache` koleksiyonu) ve `/ai`, `/ai/ask`, `/ai/stats-summary`
// uçları. `isRateLimited` admin-routes.ts'te tanımlı kalır (birçok başka
// rotaca da kullanılıyor); dairesel bağımlılık yaratmamak için buraya
// parametre olarak geçirilir — admin-routes.ts'in `sendFcmMessages`'ı almasıyla
// aynı desen.

const GEMINI_MODEL = 'gemini-3.5-flash';

/// Gemini çağrısı — paylaşılan 10 sn'lik axios istemcisi YERİNE özel 30 sn
/// zaman aşımı kullanır ve düşünme (thinking) bütçesini kapatır: yanıt
/// ~2 sn'ye iner, "yapay zekaya bağlanılamıyor" zaman aşımı hataları biter,
/// düşünme token'ı ücreti de ödenmez.
async function callGemini(apiKey: string, prompt: string, maxOutputTokens: number): Promise<string> {
  const modelName = process.env.GEMINI_MODEL || GEMINI_MODEL;
  const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/${modelName}:generateContent?key=${apiKey}`;
  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      thinkingConfig: { thinkingBudget: 0 },
      maxOutputTokens,
      temperature: 0.3
    }
  };
  try {
    const response = await axios.post(geminiUrl, body, { timeout: 30_000 });
    return String(response.data?.candidates?.[0]?.content?.parts?.[0]?.text || '');
  } catch (error: any) {
    // Model thinkingConfig'i reddederse (ileride model değişirse) yapılandırmasız dene.
    if (error?.response?.status === 400) {
      const fallback = await axios.post(geminiUrl, {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          maxOutputTokens,
          temperature: 0.3
        }
      }, { timeout: 30_000 });
      return String(fallback.data?.candidates?.[0]?.content?.parts?.[0]?.text || '');
    }
    throw error;
  }
}

const aiMemoryCache = new Map<string, any>();
const AI_MEMORY_CACHE_MAX = 300;

/// AI önbelleğini sınırlı tutar — uzun ömürlü instance'larda bellek sızıntısını önler.
function setAiMemoryCache(key: string, value: any): void {
  aiMemoryCache.set(key, value);
  if (aiMemoryCache.size > AI_MEMORY_CACHE_MAX) {
    const firstKey = aiMemoryCache.keys().next().value;
    if (firstKey !== undefined) aiMemoryCache.delete(firstKey);
  }
}

interface AiResponse {
  status: number;
  body: unknown;
  cacheControl?: string;
}

/// Aynı önbellek anahtarı için eşzamanlı ıskalar tek Firestore okumasında ve
/// tek Gemini çağrısında birleşir. Büyük bir depremden hemen sonra aynı
/// analizi aynı anda açan yüzlerce kullanıcının her biri ayrı okuma, ayrı
/// (ücretli) Gemini çağrısı ve ayrı yazım üretiyordu; CDN yanıtı ancak ilk
/// istek bittikten sonra önbellekleyebiliyor.
const aiInFlight = new Map<string, Promise<AiResponse>>();

function singleFlightAi(key: string, work: () => Promise<AiResponse>): Promise<AiResponse> {
  const pending = aiInFlight.get(key);
  if (pending) return pending;
  const promise = work().finally(() => aiInFlight.delete(key));
  aiInFlight.set(key, promise);
  return promise;
}

function sendAiResponse(res: express.Response, response: AiResponse): void {
  if (response.cacheControl) res.setHeader('Cache-Control', response.cacheControl);
  res.status(response.status).json(response.body);
}

const AI_CACHE_CONTROL = 'public, max-age=3600, s-maxage=86400';

/// Firestore önbelleği yalnızca maliyet kalkanı; erişilemediğinde yanıt
/// engellenmez. Eskiden okuma hatası Gemini'ye hiç gitmeden, yazım hatası ise
/// ücretli Gemini yanıtı ELDEYKEN istemciye 502 döndürüyordu.
async function readAiCacheDoc(
  ref: FirebaseFirestore.DocumentReference
): Promise<FirebaseFirestore.DocumentSnapshot | null> {
  try {
    return await ref.get();
  } catch (error: any) {
    console.warn(`AI önbelleği okunamadı (${ref.id}); üretime geçiliyor:`, error?.message || error);
    return null;
  }
}

async function writeAiCacheDoc(ref: FirebaseFirestore.DocumentReference, data: Record<string, unknown>): Promise<void> {
  try {
    await ref.set(data);
  } catch (error: any) {
    console.warn(`AI önbelleği yazılamadı (${ref.id}):`, error?.message || error);
  }
}
const AI_STATS_CACHE_CONTROL = 'public, max-age=300, s-maxage=1200';

const languageNames: Record<SupportedLang, string> = {
  tr: 'Turkish / Türkçe',
  en: 'English',
  de: 'German / Deutsch',
  es: 'Spanish / Español',
  fr: 'French / Français',
  it: 'Italian / Italiano',
  ja: 'Japanese / 日本語',
  ru: 'Russian / Русский',
  ar: 'Arabic / العربية'
};

// İstatistik ekranındaki sayıları sade dilde özetleyen "Sismolog AI" uç
// noktası. Tekil deprem analizinden ("/ai") farklı olarak veri sürekli
// değiştiği için sonuç kalıcı değil, bölge+dil başına 20 dakikalık bir
// pencere boyunca önbelleklenir — her istekte yeniden üretmek yerine kısa
// süre aynı özet sunulur.
const AI_STATS_SUMMARY_TTL_MS = 20 * 60 * 1000;

export function registerAiRoutes(
  app: express.Express,
  db: Firestore,
  isRateLimited: (req: express.Request, scope: string, limit: number, windowMs: number) => boolean
): void {
  // 6) AI Analizi (Gemini ile)
  app.get('/ai', async (req, res) => {
    const id = (req.query.id as string || '').slice(0, 120);
    const lang = normalizeLang(req.query.lang as string);
    const mag = Number(req.query.mag);
    const depth = Number(req.query.depth);
    const lat = Number(req.query.lat);
    const lon = Number(req.query.lon);
    const place = (req.query.place as string || '').slice(0, 120);

    if (!id || !Number.isFinite(mag) || !Number.isFinite(depth) || !Number.isFinite(lat) || !Number.isFinite(lon)
        || Math.abs(lat) > 90 || Math.abs(lon) > 180 || mag < -2 || mag > 10 || depth < -10 || depth > 1000) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }

    // '/' Firestore belge kimliğinde geçersiz; kötü niyetli/bozuk id 502 üretmesin.
    // Büyüklük/derinlik revizyonu eski analizi geçersiz kılsın.
    const magKey = Number.isFinite(mag) ? mag.toFixed(1) : 'x';
    const depthKey = Number.isFinite(depth) ? depth.toFixed(0) : 'x';
    const cacheKey = `ai:v4:${id.replace(/\//g, '_')}:${lang}:${magKey}:${depthKey}`;
    const cacheDocRef = db.collection('ai_cache').doc(cacheKey);

    // Bellek önbelleği rate limit'ten önce: büyük depremde aynı analizi
    // isteyen, aynı operatör IP'sini (CGNAT) paylaşan kullanıcılar Gemini'ye
    // hiç gitmeyen bir yanıt için 429 almasın.
    if (aiMemoryCache.has(cacheKey)) {
      res.setHeader('Cache-Control', AI_CACHE_CONTROL);
      res.json(aiMemoryCache.get(cacheKey));
      return;
    }

    // Gemini kredisi koruması (önbellek ıskası).
    if (isRateLimited(req, 'ai', 120, 600000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }

    sendAiResponse(res, await singleFlightAi(cacheKey, async () => {
      try {
        const cachedDoc = await readAiCacheDoc(cacheDocRef);
        if (cachedDoc?.exists) {
          // Bozuk/eksik bir önbellek kaydı JSON.parse'ı fırlatırsa bunu önbellek
          // ıskası say ve aşağıda yeniden üret; aksi halde bu anahtar her istekte
          // aynı şekilde 502 vermeye devam eder ve kendi kendini asla onarmaz.
          try {
            const parsed = JSON.parse(cachedDoc.data()?.result);
            const faultZone = typeof parsed?.faultZone === 'string' ? parsed.faultZone.trim() : '';
            const commentary = typeof parsed?.commentary === 'string' ? parsed.commentary.trim() : '';
            if (!faultZone || !commentary) {
              throw new Error('incomplete analysis cache');
            }
            setAiMemoryCache(cacheKey, parsed);
            return { status: 200, cacheControl: AI_CACHE_CONTROL, body: parsed };
          } catch {
            console.warn(`Bozuk AI önbellek kaydı yok sayıldı: ${cacheKey}`);
          }
        }

        const apiKey = process.env.GEMINI_API_KEY;
        if (!apiKey) {
          return { status: 503, body: { error: 'AI not configured' } };
        }

        let prompt: string;
        if (lang === 'tr') {
          prompt = `Saha jeoloğu gibi yaz; pazarlama veya sohbet asistanı gibi değil. Olay: M${mag}, ${place}, ${depth} km derinlik, koordinatlar ${lat},${lon}.
YALNIZCA şu 4 anahtarı içeren geçerli JSON döndür:
1. "faultZone": bu koordinatlar için iyi bilinen fay veya tektonik alan adı. Emin değilsen "Bölgesel tektonik yapı".
2. "quakeType": sığ / orta / derin odak ve olası kırılma türünü bir cümlede, günlük dille.
3. "commentary": tam 3 kısa cümle. 1) bu büyüklük bu yerde ne anlama gelir, 2) odak derinliğinin yüzey sarsıntısına etkisi, 3) bölgenin bilinen fay düzeni. Artçıları yalnızca M5+ ve sığ odaklarda, belirsizliği belirterek an. "Büyüleyici", "sürükleyici", "Omori yasası", emoji, güvenlik tavsiyesi, uydurma tarih veya hasar yok.
4. "questions": tam 3 somut soru; bu büyüklük, bu yer veya bu derinliğe özel. Tıklama yemi değil.
DOĞRULUK: yalnızca bu koordinatlar için yerleşmiş bir fay adı ver. Emin olmadığın bilgiyi açıkça belirt.`;
        } else {
          const languageName = languageNames[lang] || 'English';
          prompt = `Write like a field seismologist, not a chatbot. Event: M${mag}, ${place}, depth ${depth} km, coordinates ${lat},${lon}.
Write every field entirely in ${languageName}. Return ONLY a valid JSON object with these 4 keys:
1. "faultZone": the well-established fault or tectonic setting for these coordinates in ${languageName}. If uncertain, the ${languageName} equivalent of "Regional tectonic setting".
2. "quakeType": one plain sentence on shallow/intermediate/deep focus and likely slip.
3. "commentary": exactly 3 short sentences covering (1) what this magnitude means here, (2) how focal depth affects surface shaking, (3) the known fault setting. Mention aftershocks only for M5+ shallow events, and say when that is uncertain. No "fascinating", "intriguing", Omori's Law, emojis, safety advice, or invented dates/damage.
4. "questions": exactly 3 concrete questions specific to this magnitude, place, or depth — not clickbait.
ACCURACY: name a fault only when well established for these coordinates. Say when something is uncertain.`;
        }

        let cleanedText = (await callGemini(apiKey, prompt, 1024)).trim();
        if (cleanedText.startsWith('```')) {
          cleanedText = cleanedText
            .replace(/^```json\s*/i, '')
            .replace(/```$/, '')
            .trim();
        }

        const parsedJson = JSON.parse(cleanedText);
        const faultZone = typeof parsedJson?.faultZone === 'string' ? parsedJson.faultZone.trim() : '';
        const commentary = typeof parsedJson?.commentary === 'string' ? parsedJson.commentary.trim() : '';
        const quakeType = typeof parsedJson?.quakeType === 'string' ? parsedJson.quakeType.trim() : '';
        if (!faultZone || !commentary || !quakeType) {
          return { status: 502, body: { error: 'AI failed' } };
        }
        if (Array.isArray(parsedJson.questions)) {
          parsedJson.questions = parsedJson.questions
            .filter((item: unknown) => typeof item === 'string' && item.trim())
            .slice(0, 3);
        }

        await writeAiCacheDoc(cacheDocRef, {
          result: JSON.stringify(parsedJson),
          created_at: Date.now(),
          expire_at: new Date(Date.now() + 30 * 86400000)
        });

        setAiMemoryCache(cacheKey, parsedJson);

        return { status: 200, cacheControl: AI_CACHE_CONTROL, body: parsedJson };
      } catch (error: any) {
        // Ayrıntılı sağlayıcı yanıtı yalnızca loglanır; istemciye sızdırılmaz.
        console.error('Gemini analizi hatası:', error, error.response?.data);
        return { status: 502, body: { error: 'AI failed' } };
      }
    }));
  });

  app.get('/ai/ask', async (req, res) => {
    // Soru-cevap daha pahalı: IP başına 10 dakikada 15 istek.
    if (isRateLimited(req, 'ai-ask', 15, 600000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }
    const id = (req.query.id as string || '').slice(0, 120);
    const lang = normalizeLang(req.query.lang as string);
    const mag = Number(req.query.mag);
    const depth = Number(req.query.depth);
    const lat = Number(req.query.lat);
    const lon = Number(req.query.lon);
    const place = (req.query.place as string || '').slice(0, 120);
    const question = (req.query.q as string || '').slice(0, 500);

    if (!id || !Number.isFinite(mag) || !Number.isFinite(depth) || !Number.isFinite(lat) || !Number.isFinite(lon) || !question
        || Math.abs(lat) > 90 || Math.abs(lon) > 180 || mag < -2 || mag > 10 || depth < -10 || depth > 1000) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }

    // SHA-256: base64 '/' içerebildiği için Firestore belge kimliğini bozuyordu;
    // hash ayrıca uzun sorularda öneki aynı olan soruların çakışmasını da önler.
    const questionHash = createHash('sha256').update(question).digest('hex').slice(0, 40);
    const cacheKey = `ai_ask:v2:${id.replace(/\//g, '_')}:${lang}:${questionHash}`;
    const cacheDocRef = db.collection('ai_cache').doc(cacheKey);

    // Bellek önbelleği rate limit'ten önce: büyük depremde aynı analizi
    // isteyen, aynı operatör IP'sini (CGNAT) paylaşan kullanıcılar Gemini'ye
    // hiç gitmeyen bir yanıt için 429 almasın.
    if (aiMemoryCache.has(cacheKey)) {
      res.setHeader('Cache-Control', AI_CACHE_CONTROL);
      res.json(aiMemoryCache.get(cacheKey));
      return;
    }

    // Gemini kredisi koruması (önbellek ıskası).
    if (isRateLimited(req, 'ai', 120, 600000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }

    sendAiResponse(res, await singleFlightAi(cacheKey, async () => {
      try {
        const cachedDoc = await readAiCacheDoc(cacheDocRef);
        if (cachedDoc?.exists) {
          // Bozuk/eksik bir önbellek kaydı JSON.parse'ı fırlatırsa bunu önbellek
          // ıskası say ve aşağıda yeniden üret; aksi halde bu anahtar her istekte
          // aynı şekilde 502 vermeye devam eder ve kendi kendini asla onarmaz.
          try {
            const parsed = JSON.parse(cachedDoc.data()?.result);
            const answer = typeof parsed?.answer === 'string' ? parsed.answer.trim() : '';
            if (!answer) {
              throw new Error('empty answer cache');
            }
            setAiMemoryCache(cacheKey, parsed);
            return { status: 200, cacheControl: AI_CACHE_CONTROL, body: parsed };
          } catch {
            console.warn(`Bozuk AI önbellek kaydı yok sayıldı: ${cacheKey}`);
          }
        }

        const apiKey = process.env.GEMINI_API_KEY;
        if (!apiKey) {
          return { status: 503, body: { error: 'AI not configured' } };
        }

        let prompt: string;
        if (lang === 'tr') {
          prompt = `Kısa, düz bir sismolog notu yaz. Olay: M${mag}, ${place}, ${depth} km, ${lat},${lon}.
Soru: "${question}"
En fazla 2 kısa cümle, 45 kelime. Günlük dil. Yalnızca bu olayın bilinen verisi. Tahmin, güvenlik tavsiyesi, emoji yok. Emin değilsen söyle.`;
        } else {
          const languageName = languageNames[lang] || 'English';
          prompt = `Write a short seismologist note, not a chatbot reply. Event: M${mag}, ${place}, depth ${depth} km, ${lat},${lon}.
Question: "${question}"
Answer in ${languageName} in at most 2 short sentences and 45 words. Everyday language. Use only this event's known details. No guesses, safety advice, or emojis. Say when something is uncertain.`;
        }

        const answer = (await callGemini(apiKey, prompt, 160)).trim();
        if (!answer) {
          return { status: 502, body: { error: 'AI failed' } };
        }

        const parsedJson = { answer };

        await writeAiCacheDoc(cacheDocRef, {
          result: JSON.stringify(parsedJson),
          created_at: Date.now(),
          expire_at: new Date(Date.now() + 30 * 86400000)
        });

        setAiMemoryCache(cacheKey, parsedJson);

        return { status: 200, cacheControl: AI_CACHE_CONTROL, body: parsedJson };
      } catch (error: any) {
        console.error('Gemini soru-cevap hatası:', error);
        return { status: 502, body: { error: 'AI failed' } };
      }
    }));
  });

  app.get('/ai/stats-summary', async (req, res) => {
    if (isRateLimited(req, 'ai-stats', 20, 600000)) {
      res.status(429).json({ error: 'Too many requests' });
      return;
    }

    const region = req.query.region === 'TR' ? 'TR' : 'global';
    const lang = normalizeLang(req.query.lang as string);
    const rangeLabel = String(req.query.rangeLabel || '').slice(0, 40);
    const total = Number(req.query.total);
    const last24h = Number(req.query.last24h);
    const maxMagnitude = Number(req.query.maxMagnitude);
    const avgMagnitude = Number(req.query.avgMagnitude);
    const avgDepth = Number(req.query.avgDepth);
    const m45plus = Number(req.query.m45plus);
    const activityChangePercent = Number(req.query.activityChangePercent);
    const strongestTitle = String(req.query.strongestTitle || '').slice(0, 160);
    const topRegionName = String(req.query.topRegionName || '').slice(0, 120);
    const topRegionCount = Number(req.query.topRegionCount);

    if (!rangeLabel || ![total, last24h, maxMagnitude, avgMagnitude, avgDepth, m45plus, activityChangePercent]
      .every(Number.isFinite)) {
      res.status(400).json({ error: 'Bad request' });
      return;
    }

    const statsFingerprint = createHash('sha256')
      .update([
        rangeLabel,
        total,
        last24h,
        maxMagnitude.toFixed(1),
        avgMagnitude.toFixed(1),
        avgDepth.toFixed(0),
        m45plus,
        activityChangePercent.toFixed(0),
        strongestTitle,
        topRegionName,
        Number.isFinite(topRegionCount) ? topRegionCount : ''
      ].join('|'))
      .digest('hex')
      .slice(0, 16);
    const cacheKey = `ai_stats:v2:${region}:${lang}:${statsFingerprint}`;

    const cachedMemory = aiMemoryCache.get(cacheKey);
    if (cachedMemory && Date.now() - cachedMemory.at < AI_STATS_SUMMARY_TTL_MS) {
      res.setHeader('Cache-Control', AI_STATS_CACHE_CONTROL);
      res.json({ summary: cachedMemory.summary });
      return;
    }

    const cacheDocRef = db.collection('ai_cache').doc(cacheKey);

    sendAiResponse(res, await singleFlightAi(cacheKey, async () => {
      try {
        const cachedDoc = await readAiCacheDoc(cacheDocRef);
        if (cachedDoc?.exists) {
          const cachedData = cachedDoc.data();
          const createdAt = Number(cachedData?.created_at || 0);
          if (typeof cachedData?.summary === 'string' && cachedData.summary.trim() && Date.now() - createdAt < AI_STATS_SUMMARY_TTL_MS) {
            setAiMemoryCache(cacheKey, { summary: cachedData.summary, at: createdAt });
            return { status: 200, cacheControl: AI_STATS_CACHE_CONTROL, body: { summary: cachedData.summary } };
          }
        }

        const apiKey = process.env.GEMINI_API_KEY;
        if (!apiKey) {
          return { status: 503, body: { error: 'AI not configured' } };
        }

        const scopeTR = region === 'TR';
        const regionSuffix = topRegionName
          ? (lang === 'tr' ? `, en aktif bölge ${topRegionName} (${topRegionCount} olay)` : `, most active region ${topRegionName} (${topRegionCount} events)`)
          : '';

        let prompt: string;
        if (lang === 'tr') {
          prompt = `${scopeTR ? 'Türkiye' : 'Dünya'} için ${rangeLabel} dönemi: ${total} deprem, son 24 saatte ${last24h}, en büyük M${maxMagnitude.toFixed(1)}${strongestTitle ? ` (${strongestTitle})` : ''}, ortalama M${avgMagnitude.toFixed(1)}, ortalama derinlik ${avgDepth.toFixed(0)} km, M4.5+ ${m45plus} olay, değişim %${activityChangePercent.toFixed(0)}${regionSuffix}.
2-3 kısa cümle. Sayıları ezberletme; etkinlik yüksek mi sakin mi, hangi yer öne çıkıyor onu söyle. Gelecek deprem tahmini yok. Emoji yok.`;
        } else {
          const languageName = languageNames[lang] || 'English';
          prompt = `Write entirely in ${languageName}. ${scopeTR ? 'Turkey' : 'Worldwide'} for ${rangeLabel}: ${total} earthquakes, ${last24h} in the last 24 hours, largest M${maxMagnitude.toFixed(1)}${strongestTitle ? ` (${strongestTitle})` : ''}, average M${avgMagnitude.toFixed(1)}, average depth ${avgDepth.toFixed(0)} km, ${m45plus} at M4.5+, change ${activityChangePercent.toFixed(0)}%${regionSuffix}.
2-3 short sentences on whether activity is quiet or elevated and which place stands out. Do not recap every number. No future-earthquake prediction, no emojis.`;
        }

        const summary = (await callGemini(apiKey, prompt, 220)).trim();
        if (!summary) {
          return { status: 502, body: { error: 'AI failed' } };
        }
        const createdAt = Date.now();

        await writeAiCacheDoc(cacheDocRef, {
          summary,
          created_at: createdAt,
          region,
          lang,
          expire_at: new Date(createdAt + 7 * 86400000)
        });
        setAiMemoryCache(cacheKey, { summary, at: createdAt });

        return { status: 200, cacheControl: AI_STATS_CACHE_CONTROL, body: { summary } };
      } catch (error: any) {
        console.error('Gemini istatistik özeti hatası:', error);
        return { status: 502, body: { error: 'AI failed' } };
      }
    }));
  });
}
