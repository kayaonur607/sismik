// MARK: - Bildirim şablonları (23 Eylül 2026 düzeni)
//
// İki biçim, kullanıcı ayarlardan seçer (`notification_style`):
//
// Ayrıntılı (varsayılan) — kilit ekranında ilk okunan büyüklük:
//   başlık     — renk + büyüklük + ne oldu ("🟠 M4.2 · Ev yakınında deprem")
//   alt başlık — ajansın yer adı ve uzaklık ("Saimbeyli (Adana) · 12 km uzakta")
//   gövde      — saat · derinlik · kaynak; ikinci satırda düz bir cümle
//                ("Bu uzaklıkta hissedilmiş olabilir.")
//
// Sade — tek bakışta:
//   başlık     — "🟠 M4.2 · Saimbeyli (Adana)"
//   gövde      — "Ev: 12 km uzakta · 10:44"
//
// Renk uygulamanın büyüklük ölçeğiyle aynı: yalnızca yeşil/turuncu/kırmızı.
// Yer adının sonuna ek gelmez ("Ev yakınında", "Annemler yakınında"):
// kullanıcının yazdığı her isimle Türkçe dilbilgisi bozulmadan okunur.

import { estimatedMMIAtDistance, normalizeLang, SupportedLang } from './worker-utils';

export type NotificationStyle = 'detailed' | 'compact';

export function normalizeNotificationStyle(value: unknown): NotificationStyle {
  return value === 'compact' ? 'compact' : 'detailed';
}

/// Bildirim şablonları uygulamanın 14 dilinin hepsinde var; sunucunun diğer
/// metinleri (kampanya, özet) 9 dilde kalır ve İngilizceye düşer.
type TemplateLang = SupportedLang | 'el' | 'pt' | 'id' | 'ko' | 'zh';

function templateLang(code: string): TemplateLang {
  const l = String(code || '').toLowerCase().slice(0, 2);
  if (['el', 'pt', 'id', 'ko', 'zh'].includes(l)) return l as TemplateLang;
  return normalizeLang(code);
}

export type TemplateKind =
  | 'place'
  | 'world_major'
  | 'aftershock'
  | 'regular'
  | 'felt'
  | 'correction';

export interface TemplateInput {
  kind: TemplateKind;
  magnitude: number;
  depth: number;
  /// Ajansın verdiği konum adı ("Dulkadiroğlu (Kahramanmaraş)").
  place: string;
  /// Cihazın saat dilimindeki olay saati ("15:04").
  hhmm: string;
  provider: string;
  /// Yer eşleşmesinde yere, artçıda ana depreme, eski kuralda kullanıcıya uzaklık.
  distanceKm?: number;
  placeName?: string;
  /// Artçı takibindeki ana depremin büyüklüğü.
  watchMagnitude?: number;
  /// Eski kural: mesafe yakınlık yarıçapından geçerek mi bulundu?
  isNearbyMatch?: boolean;
  /// Yer yarıçapın dışında; deprem orada hissedilebilir (hissedilir şiddet kuralı).
  feltAtPlace?: boolean;
  /// Olaydan bu yana geçen dakika; 10 ve üstüyse "geç" etiketi basılır.
  lateMinutes?: number;
  /// Türkiye'deki güçlü depremde dokununca toplanma alanları açılır.
  assemblyCta?: boolean;
  /// Düzeltme bildiriminde önceki büyüklük.
  previousMagnitude?: number;
  /// Düzeltme hangi eşleşmenin güncellemesi? Yer adı varsa yer biçimi kullanılır.
  hasSavedPlaces?: boolean;
  style?: NotificationStyle;
}

export interface NotificationContent {
  title: string;
  subtitle: string;
  body: string;
}

/// Deprem bildirimlerinin iOS kategorisi: istemci "Hissettim / Hissetmedim"
/// eylemlerini bu kimlikle kaydeder.
export const QUAKE_FEEDBACK_CATEGORY = 'QUAKE_FEEDBACK';

/// Bildirimin "geç" sayıldığı eşik. Altında olay "şimdi olmuş" gibi okunur.
export const LATE_NOTIFICATION_MINUTES = 10;
/// Başlıkta "güçlü deprem" denmesinin eşiği; kritik uyarıyla aynı.
export const STRONG_QUAKE_MAGNITUDE = 5.0;

/// Yer bildiriminde renk o yerdeki tahmini şiddetten gelir; "hissedildi mi"
/// cümlesiyle aynı ölçek, ikisi hiç çelişmez.
export function feltLevel(mmi: number): 0 | 1 | 2 | 3 | 4 {
  if (mmi < 2) return 0;
  if (mmi < 3.5) return 1;
  if (mmi < 5) return 2;
  if (mmi < 6.5) return 3;
  return 4;
}

function intensityDot(level: number): string {
  if (level >= 4) return '🔴';
  if (level >= 2) return '🟠';
  return '🟢';
}

/// Yere bağlı olmayan bildirimde renk büyüklükten gelir; uygulamanın
/// büyüklük ölçeği (MagnitudeLevel) ve tweet emojisiyle aynı: <4 yeşil,
/// 4–5.9 turuncu, 6+ kırmızı.
export function magnitudeDot(magnitude: number): string {
  if (magnitude >= 6) return '🔴';
  if (magnitude >= 4) return '🟠';
  return '🟢';
}

interface Phrases {
  near: (name: string) => string;
  nearStrong: (name: string) => string;
  nearUpdated: (name: string) => string;
  /// Hissedilir şiddet kuralı: deprem yere uzak ama orada hissedilebilir.
  feltAt: (name: string) => string;
  updated: string;
  worldMajor: string;
  aftershock: string;
  quake: string;
  placeFallback: string;
  away: (km: number) => string;
  depth: (km: number) => string;
  ago: (min: number) => string;
  fromMain: (km: number) => string;
  late: (provider: string) => string;
  revised: (provider: string) => string;
  felt: [string, string, string, string, string];
  assembly: string;
  farFromPlaces: string;
  tapDetails: string;
  watchRegion: (mag?: string) => string;
}

const PHRASES: Record<TemplateLang, Phrases> = {
  tr: {
    feltAt: n => `${n} konumunda hissedilebilir deprem`,
    near: n => `${n} yakınında deprem`,
    nearStrong: n => `${n} yakınında güçlü deprem`,
    nearUpdated: n => `${n} yakınındaki deprem güncellendi`,
    updated: 'Deprem bilgisi güncellendi',
    worldMajor: 'Dünyada büyük deprem',
    aftershock: 'Olası artçı deprem',
    quake: 'Deprem',
    placeFallback: 'Kayıtlı yerin',
    away: km => `${km} km uzakta`,
    depth: km => `${km} km derinlik`,
    ago: m => `${m} dk önce`,
    fromMain: km => `ana depreme ${km} km`,
    late: p => `${p} bu kaydı geç yayımladı.`,
    revised: p => `${p} büyüklüğü düzeltti.`,
    felt: [
      'Bu uzaklıkta muhtemelen hissedilmedi.',
      'Bu uzaklıkta hafifçe hissedilmiş olabilir.',
      'Bu uzaklıkta hissedilmiş olabilir.',
      'Bu uzaklıkta güçlü hissedilmiş olabilir.',
      'Bu uzaklıkta çok güçlü hissedilmiş olabilir.'
    ],
    assembly: 'Toplanma alanları için dokun.',
    farFromPlaces: 'Kayıtlı yerlerinden uzakta. Detaylar için dokun.',
    tapDetails: 'Detaylar için dokun.',
    watchRegion: m => m ? `Takip ettiğin M${m} depremin bölgesinde.` : 'Takip ettiğin depremin bölgesinde.'
  },
  en: {
    feltAt: n => `Earthquake likely felt at ${n}`,
    near: n => `Earthquake near ${n}`,
    nearStrong: n => `Strong earthquake near ${n}`,
    nearUpdated: n => `Update: earthquake near ${n}`,
    updated: 'Earthquake details updated',
    worldMajor: 'Major earthquake worldwide',
    aftershock: 'Possible aftershock',
    quake: 'Earthquake',
    placeFallback: 'your place',
    away: km => `${km} km away`,
    depth: km => `${km} km deep`,
    ago: m => `${m} min ago`,
    fromMain: km => `${km} km from the mainshock`,
    late: p => `${p} published this record late.`,
    revised: p => `${p} revised the magnitude.`,
    felt: [
      'Probably not felt at this distance.',
      'May have been felt lightly at this distance.',
      'May have been felt at this distance.',
      'May have been felt strongly at this distance.',
      'May have been felt very strongly at this distance.'
    ],
    assembly: 'Tap for assembly areas.',
    farFromPlaces: 'Far from your saved places. Tap for details.',
    tapDetails: 'Tap for details.',
    watchRegion: m => m ? `In the area of the M${m} earthquake you follow.` : 'In the area of the earthquake you follow.'
  },
  de: {
    feltAt: n => `Erdbeben wohl spürbar bei ${n}`,
    near: n => `Erdbeben nahe ${n}`,
    nearStrong: n => `Starkes Erdbeben nahe ${n}`,
    nearUpdated: n => `Aktualisiert: Erdbeben nahe ${n}`,
    updated: 'Erdbebendaten aktualisiert',
    worldMajor: 'Schweres Erdbeben weltweit',
    aftershock: 'Mögliches Nachbeben',
    quake: 'Erdbeben',
    placeFallback: 'deinem Ort',
    away: km => `${km} km entfernt`,
    depth: km => `${km} km Tiefe`,
    ago: m => `vor ${m} Min.`,
    fromMain: km => `${km} km vom Hauptbeben`,
    late: p => `${p} hat diese Meldung verspätet veröffentlicht.`,
    revised: p => `${p} hat die Magnitude korrigiert.`,
    felt: [
      'In dieser Entfernung wahrscheinlich nicht spürbar.',
      'In dieser Entfernung womöglich leicht spürbar.',
      'In dieser Entfernung womöglich spürbar.',
      'In dieser Entfernung womöglich stark spürbar.',
      'In dieser Entfernung womöglich sehr stark spürbar.'
    ],
    assembly: 'Tippen für Sammelplätze.',
    farFromPlaces: 'Weit entfernt von deinen Orten. Tippen für Details.',
    tapDetails: 'Tippen für Details.',
    watchRegion: m => m ? `Im Gebiet des M${m}-Bebens, dem du folgst.` : 'Im Gebiet des Bebens, dem du folgst.'
  },
  es: {
    feltAt: n => `Sismo que puede sentirse en ${n}`,
    near: n => `Terremoto cerca de ${n}`,
    nearStrong: n => `Fuerte terremoto cerca de ${n}`,
    nearUpdated: n => `Actualizado: terremoto cerca de ${n}`,
    updated: 'Datos del terremoto actualizados',
    worldMajor: 'Gran terremoto en el mundo',
    aftershock: 'Posible réplica',
    quake: 'Terremoto',
    placeFallback: 'tu lugar',
    away: km => `a ${km} km`,
    depth: km => `${km} km de profundidad`,
    ago: m => `hace ${m} min`,
    fromMain: km => `a ${km} km del sismo principal`,
    late: p => `${p} publicó este registro con retraso.`,
    revised: p => `${p} corrigió la magnitud.`,
    felt: [
      'Probablemente no se sintió a esta distancia.',
      'Pudo sentirse levemente a esta distancia.',
      'Pudo sentirse a esta distancia.',
      'Pudo sentirse con fuerza a esta distancia.',
      'Pudo sentirse con mucha fuerza a esta distancia.'
    ],
    assembly: 'Toca para ver puntos de encuentro.',
    farFromPlaces: 'Lejos de tus lugares guardados. Toca para ver detalles.',
    tapDetails: 'Toca para ver detalles.',
    watchRegion: m => m ? `En la zona del sismo M${m} que sigues.` : 'En la zona del sismo que sigues.'
  },
  fr: {
    feltAt: n => `Séisme sans doute ressenti à ${n}`,
    near: n => `Séisme près de ${n}`,
    nearStrong: n => `Fort séisme près de ${n}`,
    nearUpdated: n => `Mise à jour : séisme près de ${n}`,
    updated: 'Données du séisme mises à jour',
    worldMajor: 'Séisme majeur dans le monde',
    aftershock: 'Réplique possible',
    quake: 'Séisme',
    placeFallback: 'votre lieu',
    away: km => `à ${km} km`,
    depth: km => `${km} km de profondeur`,
    ago: m => `il y a ${m} min`,
    fromMain: km => `à ${km} km du séisme principal`,
    late: p => `${p} a publié cet enregistrement en retard.`,
    revised: p => `${p} a corrigé la magnitude.`,
    felt: [
      'Probablement pas ressenti à cette distance.',
      'A pu être légèrement ressenti à cette distance.',
      'A pu être ressenti à cette distance.',
      'A pu être fortement ressenti à cette distance.',
      'A pu être très fortement ressenti à cette distance.'
    ],
    assembly: 'Touchez pour les points de rassemblement.',
    farFromPlaces: 'Loin de vos lieux enregistrés. Touchez pour les détails.',
    tapDetails: 'Touchez pour les détails.',
    watchRegion: m => m ? `Dans la zone du séisme M${m} que vous suivez.` : 'Dans la zone du séisme que vous suivez.'
  },
  it: {
    feltAt: n => `Terremoto probabilmente avvertito a ${n}`,
    near: n => `Terremoto vicino a ${n}`,
    nearStrong: n => `Forte terremoto vicino a ${n}`,
    nearUpdated: n => `Aggiornato: terremoto vicino a ${n}`,
    updated: 'Dati del terremoto aggiornati',
    worldMajor: 'Forte terremoto nel mondo',
    aftershock: 'Possibile replica',
    quake: 'Terremoto',
    placeFallback: 'il tuo luogo',
    away: km => `a ${km} km`,
    depth: km => `${km} km di profondità`,
    ago: m => `${m} min fa`,
    fromMain: km => `a ${km} km dalla scossa principale`,
    late: p => `${p} ha pubblicato questo dato in ritardo.`,
    revised: p => `${p} ha corretto la magnitudo.`,
    felt: [
      'Probabilmente non avvertito a questa distanza.',
      'Potrebbe essere stato avvertito lievemente a questa distanza.',
      'Potrebbe essere stato avvertito a questa distanza.',
      'Potrebbe essere stato avvertito con forza a questa distanza.',
      'Potrebbe essere stato avvertito con molta forza a questa distanza.'
    ],
    assembly: 'Tocca per le aree di raccolta.',
    farFromPlaces: 'Lontano dai tuoi luoghi salvati. Tocca per i dettagli.',
    tapDetails: 'Tocca per i dettagli.',
    watchRegion: m => m ? `Nell'area del terremoto M${m} che segui.` : 'Nell\'area del terremoto che segui.'
  },
  ja: {
    feltAt: n => `${n}で揺れを感じる可能性のある地震`,
    near: n => `${n}付近で地震`,
    nearStrong: n => `${n}付近で強い地震`,
    nearUpdated: n => `${n}付近の地震情報を更新`,
    updated: '地震情報を更新',
    worldMajor: '世界で大きな地震',
    aftershock: '余震の可能性',
    quake: '地震',
    placeFallback: '保存した場所',
    away: km => `${km} km`,
    depth: km => `深さ${km} km`,
    ago: m => `${m}分前`,
    fromMain: km => `本震から${km} km`,
    late: p => `${p}の発表が遅れました。`,
    revised: p => `${p}がマグニチュードを修正しました。`,
    felt: [
      'この距離ではおそらく揺れを感じなかったでしょう。',
      'この距離では弱い揺れを感じた可能性があります。',
      'この距離では揺れを感じた可能性があります。',
      'この距離では強い揺れを感じた可能性があります。',
      'この距離では非常に強い揺れを感じた可能性があります。'
    ],
    assembly: 'タップして避難場所を表示。',
    farFromPlaces: '保存した場所からは離れています。タップして詳細を表示。',
    tapDetails: 'タップして詳細を表示。',
    watchRegion: m => m ? `フォロー中のM${m}の地震の震源域です。` : 'フォロー中の地震の震源域です。'
  },
  ru: {
    feltAt: n => `Землетрясение, ощутимое в «${n}»`,
    near: n => `Землетрясение рядом с «${n}»`,
    nearStrong: n => `Сильное землетрясение рядом с «${n}»`,
    nearUpdated: n => `Обновлено: землетрясение рядом с «${n}»`,
    updated: 'Данные о землетрясении обновлены',
    worldMajor: 'Крупное землетрясение в мире',
    aftershock: 'Возможный афтершок',
    quake: 'Землетрясение',
    placeFallback: 'ваше место',
    away: km => `${km} км`,
    depth: km => `глубина ${km} км`,
    ago: m => `${m} мин назад`,
    fromMain: km => `${km} км от основного толчка`,
    late: p => `${p} опубликовал эти данные с опозданием.`,
    revised: p => `${p} уточнил магнитуду.`,
    felt: [
      'На этом расстоянии, вероятно, не ощущалось.',
      'На этом расстоянии могло ощущаться слабо.',
      'На этом расстоянии могло ощущаться.',
      'На этом расстоянии могло ощущаться сильно.',
      'На этом расстоянии могло ощущаться очень сильно.'
    ],
    assembly: 'Нажмите, чтобы увидеть пункты сбора.',
    farFromPlaces: 'Далеко от сохранённых мест. Нажмите для подробностей.',
    tapDetails: 'Нажмите для подробностей.',
    watchRegion: m => m ? `В районе отслеживаемого землетрясения M${m}.` : 'В районе отслеживаемого землетрясения.'
  },
  ar: {
    feltAt: n => `زلزال قد يُشعر به في ${n}`,
    near: n => `زلزال قرب ${n}`,
    nearStrong: n => `زلزال قوي قرب ${n}`,
    nearUpdated: n => `تحديث: زلزال قرب ${n}`,
    updated: 'تم تحديث بيانات الزلزال',
    worldMajor: 'زلزال كبير في العالم',
    aftershock: 'هزة ارتدادية محتملة',
    quake: 'زلزال',
    placeFallback: 'مكانك',
    away: km => `على بعد ${km} كم`,
    depth: km => `عمق ${km} كم`,
    ago: m => `منذ ${m} د`,
    fromMain: km => `على بعد ${km} كم من الزلزال الرئيسي`,
    late: p => `نشرت ${p} هذا السجل متأخرًا.`,
    revised: p => `صحّحت ${p} قوة الزلزال.`,
    felt: [
      'على الأرجح لم يُشعر به على هذه المسافة.',
      'ربما شُعر به بشكل خفيف على هذه المسافة.',
      'ربما شُعر به على هذه المسافة.',
      'ربما شُعر به بقوة على هذه المسافة.',
      'ربما شُعر به بقوة شديدة على هذه المسافة.'
    ],
    assembly: 'اضغط لعرض مناطق التجمع.',
    farFromPlaces: 'بعيد عن أماكنك المحفوظة. اضغط للتفاصيل.',
    tapDetails: 'اضغط للتفاصيل.',
    watchRegion: m => m ? `في منطقة زلزال M${m} الذي تتابعه.` : 'في منطقة الزلزال الذي تتابعه.'
  },
  el: {
    feltAt: n => `Σεισμός πιθανώς αισθητός σε: ${n}`,
    near: n => `Σεισμός κοντά σε «${n}»`,
    nearStrong: n => `Ισχυρός σεισμός κοντά σε «${n}»`,
    nearUpdated: n => `Ενημέρωση: σεισμός κοντά σε «${n}»`,
    updated: 'Τα στοιχεία του σεισμού ενημερώθηκαν',
    worldMajor: 'Μεγάλος σεισμός στον κόσμο',
    aftershock: 'Πιθανός μετασεισμός',
    quake: 'Σεισμός',
    placeFallback: 'Αποθηκευμένη τοποθεσία',
    away: km => `${km} km μακριά`,
    depth: km => `βάθος ${km} km`,
    ago: m => `πριν από ${m} λ.`,
    fromMain: km => `${km} km από τον κύριο σεισμό`,
    late: p => `Το ${p} δημοσίευσε την εγγραφή με καθυστέρηση.`,
    revised: p => `Το ${p} διόρθωσε το μέγεθος.`,
    felt: [
      'Μάλλον δεν έγινε αισθητός σε αυτή την απόσταση.',
      'Ίσως έγινε ελαφρά αισθητός σε αυτή την απόσταση.',
      'Ίσως έγινε αισθητός σε αυτή την απόσταση.',
      'Ίσως έγινε έντονα αισθητός σε αυτή την απόσταση.',
      'Ίσως έγινε πολύ έντονα αισθητός σε αυτή την απόσταση.'
    ],
    assembly: 'Πάτα για χώρους συγκέντρωσης.',
    farFromPlaces: 'Μακριά από τις τοποθεσίες σου. Πάτα για λεπτομέρειες.',
    tapDetails: 'Πάτα για λεπτομέρειες.',
    watchRegion: m => m ? `Στην περιοχή του σεισμού M${m} που παρακολουθείς.` : 'Στην περιοχή του σεισμού που παρακολουθείς.'
  },
  pt: {
    feltAt: n => `Terremoto que pode ser sentido em ${n}`,
    near: n => `Terremoto perto de ${n}`,
    nearStrong: n => `Terremoto forte perto de ${n}`,
    nearUpdated: n => `Atualização: terremoto perto de ${n}`,
    updated: 'Dados do terremoto atualizados',
    worldMajor: 'Grande terremoto no mundo',
    aftershock: 'Possível réplica',
    quake: 'Terremoto',
    placeFallback: 'seu lugar',
    away: km => `a ${km} km`,
    depth: km => `${km} km de profundidade`,
    ago: m => `há ${m} min`,
    fromMain: km => `a ${km} km do tremor principal`,
    late: p => `${p} publicou este registro com atraso.`,
    revised: p => `${p} corrigiu a magnitude.`,
    felt: [
      'Provavelmente não foi sentido a esta distância.',
      'Pode ter sido sentido de leve a esta distância.',
      'Pode ter sido sentido a esta distância.',
      'Pode ter sido sentido com força a esta distância.',
      'Pode ter sido sentido com muita força a esta distância.'
    ],
    assembly: 'Toque para ver pontos de encontro.',
    farFromPlaces: 'Longe dos seus lugares salvos. Toque para ver detalhes.',
    tapDetails: 'Toque para ver detalhes.',
    watchRegion: m => m ? `Na área do terremoto M${m} que você acompanha.` : 'Na área do terremoto que você acompanha.'
  },
  id: {
    feltAt: n => `Gempa yang mungkin terasa di ${n}`,
    near: n => `Gempa dekat ${n}`,
    nearStrong: n => `Gempa kuat dekat ${n}`,
    nearUpdated: n => `Pembaruan: gempa dekat ${n}`,
    updated: 'Data gempa diperbarui',
    worldMajor: 'Gempa besar di dunia',
    aftershock: 'Kemungkinan gempa susulan',
    quake: 'Gempa',
    placeFallback: 'tempatmu',
    away: km => `${km} km jauhnya`,
    depth: km => `kedalaman ${km} km`,
    ago: m => `${m} mnt lalu`,
    fromMain: km => `${km} km dari gempa utama`,
    late: p => `${p} menerbitkan data ini terlambat.`,
    revised: p => `${p} merevisi magnitudo.`,
    felt: [
      'Kemungkinan tidak terasa pada jarak ini.',
      'Mungkin terasa ringan pada jarak ini.',
      'Mungkin terasa pada jarak ini.',
      'Mungkin terasa kuat pada jarak ini.',
      'Mungkin terasa sangat kuat pada jarak ini.'
    ],
    assembly: 'Ketuk untuk titik kumpul.',
    farFromPlaces: 'Jauh dari tempat tersimpanmu. Ketuk untuk detail.',
    tapDetails: 'Ketuk untuk detail.',
    watchRegion: m => m ? `Di area gempa M${m} yang kamu pantau.` : 'Di area gempa yang kamu pantau.'
  },
  ko: {
    feltAt: n => `${n}에서 느낄 수 있는 지진`,
    near: n => `${n} 인근 지진`,
    nearStrong: n => `${n} 인근 강한 지진`,
    nearUpdated: n => `${n} 인근 지진 정보 업데이트`,
    updated: '지진 정보 업데이트',
    worldMajor: '세계 대형 지진',
    aftershock: '여진 가능성',
    quake: '지진',
    placeFallback: '저장한 장소',
    away: km => `${km} km 거리`,
    depth: km => `깊이 ${km} km`,
    ago: m => `${m}분 전`,
    fromMain: km => `본진에서 ${km} km`,
    late: p => `${p}이(가) 이 기록을 늦게 발표했습니다.`,
    revised: p => `${p}이(가) 규모를 수정했습니다.`,
    felt: [
      '이 거리에서는 아마 느껴지지 않았을 것입니다.',
      '이 거리에서는 약하게 느껴졌을 수 있습니다.',
      '이 거리에서는 느껴졌을 수 있습니다.',
      '이 거리에서는 강하게 느껴졌을 수 있습니다.',
      '이 거리에서는 매우 강하게 느껴졌을 수 있습니다.'
    ],
    assembly: '눌러서 대피 장소 보기.',
    farFromPlaces: '저장한 장소와 멀리 떨어져 있습니다. 눌러서 자세히 보기.',
    tapDetails: '눌러서 자세히 보기.',
    watchRegion: m => m ? `추적 중인 M${m} 지진 지역입니다.` : '추적 중인 지진 지역입니다.'
  },
  zh: {
    feltAt: n => `${n}可能有震感的地震`,
    near: n => `${n}附近发生地震`,
    nearStrong: n => `${n}附近发生强烈地震`,
    nearUpdated: n => `${n}附近地震信息已更新`,
    updated: '地震信息已更新',
    worldMajor: '全球大地震',
    aftershock: '可能的余震',
    quake: '地震',
    placeFallback: '你的地点',
    away: km => `距离 ${km} 公里`,
    depth: km => `深度 ${km} 公里`,
    ago: m => `${m} 分钟前`,
    fromMain: km => `距主震 ${km} 公里`,
    late: p => `${p} 较晚发布了此记录。`,
    revised: p => `${p} 修正了震级。`,
    felt: [
      '在此距离可能无震感。',
      '在此距离可能有轻微震感。',
      '在此距离可能有震感。',
      '在此距离可能有强烈震感。',
      '在此距离可能有非常强烈的震感。'
    ],
    assembly: '点按查看集合点。',
    farFromPlaces: '距离你保存的地点较远。点按查看详情。',
    tapDetails: '点按查看详情。',
    watchRegion: m => m ? `位于你关注的 M${m} 地震区域。` : '位于你关注的地震区域。'
  }
};

const mag1 = (value: number) => (Math.round(value * 10) / 10).toFixed(1);

/// Şablonların tamamı. Saf fonksiyon: testlerden doğrudan çağrılır.
/// Bildirimde görünen kaynak adı: kısaltmalar olduğu gibi, uzun adlar okunur.
const PROVIDER_DISPLAY: Record<string, string> = {
  KANDILLI: 'Kandilli',
  GEONET: 'GeoNet'
};

export function providerDisplayName(provider: string): string {
  const key = String(provider || '').toUpperCase();
  return PROVIDER_DISPLAY[key] ?? String(provider || '');
}

export function buildNotificationContent(langCode: string, input: TemplateInput): NotificationContent {
  input = { ...input, provider: providerDisplayName(input.provider) };
  const t = PHRASES[templateLang(langCode)];
  const mag = mag1(input.magnitude);
  const depthKm = Math.max(0, Math.round(input.depth));
  const km = input.distanceKm !== undefined ? Math.round(input.distanceKm) : undefined;
  const late = input.lateMinutes !== undefined && input.lateMinutes >= LATE_NOTIFICATION_MINUTES
    ? Math.round(input.lateMinutes) : undefined;
  const lateSuffix = late !== undefined ? ` · ${t.ago(late)}` : '';
  const detailLine = `${input.hhmm} · ${t.depth(depthKm)} · ${input.provider}`;
  const name = input.placeName?.trim() || t.placeFallback;
  // Şiddet, uzaklık bilindiğinde o noktadaki tahmini MMI'dan gelir.
  const level = km !== undefined
    ? feltLevel(estimatedMMIAtDistance(input.magnitude, input.depth, input.distanceKm!))
    : undefined;
  const dot = input.kind === 'place' || (input.kind === 'correction' && input.placeName)
    ? (level !== undefined ? intensityDot(level) : magnitudeDot(input.magnitude))
    : magnitudeDot(input.magnitude);
  const lines = (...items: string[]) => items.filter(Boolean).join('\n');

  if (input.kind === 'correction') {
    const previous = input.previousMagnitude !== undefined ? `M${mag1(input.previousMagnitude)} → ` : '';
    const distance = input.placeName && km !== undefined ? ` · ${t.away(km)}` : '';
    const feltLine = input.placeName && level !== undefined ? t.felt[level] : '';
    return {
      title: `${dot} ${input.placeName ? t.nearUpdated(name) : t.updated}`,
      subtitle: `${previous}M${mag}${distance}`,
      body: lines(`${input.place} · ${input.hhmm} · ${input.provider}`, [t.revised(input.provider), feltLine].filter(Boolean).join(' '))
    };
  }

  if (input.style === 'compact') {
    // Uzaklık varsa kime göre olduğu yazılır; yoksa ne tür bir uyarı olduğu.
    const context = km !== undefined && (input.kind === 'place' || input.isNearbyMatch)
      ? (input.kind === 'place' ? `${name}: ${t.away(km)}` : t.away(km))
      : input.kind === 'aftershock'
        ? (km !== undefined ? `${t.aftershock}: ${t.fromMain(km)}` : t.aftershock)
        : input.kind === 'world_major' ? t.worldMajor : '';
    return {
      title: `${dot} M${mag} · ${input.place}`,
      subtitle: '',
      body: lines(
        [context, input.hhmm, late !== undefined ? t.ago(late) : ''].filter(Boolean).join(' · '),
        input.assemblyCta ? t.assembly : ''
      )
    };
  }

  switch (input.kind) {
    case 'place': {
      const strong = input.magnitude >= STRONG_QUAKE_MAGNITUDE;
      const second = late !== undefined && (level ?? 0) < 2
        ? t.late(input.provider)
        : [level !== undefined ? t.felt[level] : '', input.assemblyCta ? t.assembly : ''].filter(Boolean).join(' ');
      return {
        title: `${dot} M${mag} · ${input.feltAtPlace ? t.feltAt(name) : strong ? t.nearStrong(name) : t.near(name)}`,
        subtitle: `${input.place}${km !== undefined ? ` · ${t.away(km)}` : ''}${lateSuffix}`,
        body: lines(detailLine, second)
      };
    }
    case 'world_major':
      return {
        title: `${dot} M${mag} · ${t.worldMajor}`,
        subtitle: `${input.place}${lateSuffix}`,
        body: lines(detailLine, input.hasSavedPlaces ? t.farFromPlaces : t.tapDetails)
      };
    case 'aftershock':
      return {
        title: `${dot} M${mag} · ${t.aftershock}`,
        subtitle: `${input.place}${km !== undefined ? ` · ${t.fromMain(km)}` : ''}${lateSuffix}`,
        body: lines(detailLine, t.watchRegion(input.watchMagnitude ? mag1(input.watchMagnitude) : undefined))
      };
    case 'felt':
    case 'regular':
    default: {
      // Eski kural (henüz yer kaydetmemiş kullanıcı): eşleşme mantığı aynı.
      const nearby = Boolean(input.isNearbyMatch) && km !== undefined;
      const feltLine = input.kind === 'felt' && level !== undefined ? t.felt[level] : '';
      return {
        title: `${dot} M${mag} · ${t.quake}`,
        subtitle: `${input.place}${nearby ? ` · ${t.away(km!)}` : ''}${lateSuffix}`,
        body: lines(detailLine, feltLine)
      };
    }
  }
}
