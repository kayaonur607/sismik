// MARK: - Bilgi kartları
//
// Uygulama açıldığında bir kez gösterilen "yenilikler / duyuru" kartları.
//
// Maliyet: kartlar ayrı bir koleksiyonda DEĞİL, HTTP örneklerinin liste için
// zaten dakikada bir okuduğu canlı anlık görüntü belgesinde
// (`_public/live_quakes_v1`) iki alan olarak durur:
//   - `info_cards`: kart dizisinin JSON metni
//   - `info_cards_revision`: her yayında artan sayı
// Sunucu revizyonu liste yanıtının `X-Sismik-Info-Revision` başlığında
// gönderir; istemci yalnızca revizyon değişince `GET /info-cards` çeker (CDN
// önbellekli, bellekten). Dolayısıyla kart yayınlamak Firestore okuma
// sayısını hiç artırmaz.
//
// Kartlar `Scripts/info-cards.mjs` ile yayınlanır; betik bu dosyadaki
// doğrulamayı kullanır (derlenmiş `lib/info-cards.js`).

export type InfoCardAudience = 'all' | 'free' | 'premium';

export const INFO_CARD_LANGS = ['tr', 'en', 'de', 'es', 'fr', 'it', 'ja', 'ru', 'ar'] as const;

export type LocalizedText = Partial<Record<string, string>>;

export interface InfoCardItem {
  icon: string;
  title: LocalizedText;
  body: LocalizedText;
}

export interface InfoCard {
  id: string;
  audience?: InfoCardAudience;
  /// Dahil. Bu sürümden eski uygulamada kart görünmez.
  minVersion?: string;
  /// Dahil. Bu sürümden yeni uygulamada kart görünmez.
  maxVersion?: string;
  /// ISO 8601; gösterim penceresi.
  startAt?: string;
  endAt?: string;
  /// SF Symbol adı.
  icon?: string;
  /// orange | green | blue | red | purple | teal
  tint?: string;
  title: LocalizedText;
  subtitle?: LocalizedText;
  /// Serbest metin; "- " ile başlayan satırlar madde olarak gösterilir.
  body?: LocalizedText;
  items?: InfoCardItem[];
  action?: { label: LocalizedText; url: string };
  /// Kartı açan push bildiriminin metni (betiğin `push` komutu kullanır).
  push?: { title: LocalizedText; body: LocalizedText };
}

export const INFO_CARD_TINTS = ['orange', 'green', 'blue', 'red', 'purple', 'teal'];
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{1,63}$/;
const VERSION_PATTERN = /^\d+(\.\d+){0,2}$/;
/// Canlı anlık görüntü belgesi 1 MiB sınırına ortak; kartlar küçük kalmalı.
export const INFO_CARDS_MAX_BYTES = 64 * 1024;
export const INFO_CARDS_MAX_COUNT = 20;

function hasText(value: unknown): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

function validateLocalized(value: unknown, field: string, errors: string[], maxLength: number): void {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    errors.push(`${field}: dil → metin nesnesi olmalı`);
    return;
  }
  const map = value as Record<string, unknown>;
  if (!hasText(map.tr) && !hasText(map.en)) errors.push(`${field}: en az tr veya en gerekli`);
  for (const [lang, text] of Object.entries(map)) {
    if (!(INFO_CARD_LANGS as readonly string[]).includes(lang)) errors.push(`${field}.${lang}: bilinmeyen dil`);
    else if (typeof text !== 'string') errors.push(`${field}.${lang}: metin olmalı`);
    else if (text.length > maxLength) errors.push(`${field}.${lang}: en fazla ${maxLength} karakter`);
  }
}

function isValidURL(url: unknown): boolean {
  if (typeof url !== 'string') return false;
  return /^sismik:\/\/[a-z]/.test(url) || /^https:\/\/\S+$/.test(url);
}

/// Yayından önce tam doğrulama. Hatalı kart istemcide boş/garip bir sayfa
/// açardı; betik kaydetmeden reddeder.
export function validateInfoCard(card: unknown): { valid: boolean; errors: string[] } {
  const errors: string[] = [];
  if (!card || typeof card !== 'object' || Array.isArray(card)) {
    return { valid: false, errors: ['Kart bir JSON nesnesi olmalı'] };
  }
  const c = card as Record<string, unknown>;
  if (typeof c.id !== 'string' || !ID_PATTERN.test(c.id)) {
    errors.push('id: küçük harf, rakam, . _ - (2–64 karakter)');
  }
  if (c.audience !== undefined && !['all', 'free', 'premium'].includes(String(c.audience))) {
    errors.push('audience: all | free | premium');
  }
  for (const key of ['minVersion', 'maxVersion']) {
    if (c[key] !== undefined && (typeof c[key] !== 'string' || !VERSION_PATTERN.test(c[key] as string))) {
      errors.push(`${key}: "2.1.3" biçiminde olmalı`);
    }
  }
  for (const key of ['startAt', 'endAt']) {
    if (c[key] !== undefined && (typeof c[key] !== 'string' || !Number.isFinite(Date.parse(c[key] as string)))) {
      errors.push(`${key}: ISO 8601 tarih olmalı (ör. 2026-10-01T09:00:00+03:00)`);
    }
  }
  if (typeof c.startAt === 'string' && typeof c.endAt === 'string' && Date.parse(c.endAt) <= Date.parse(c.startAt)) {
    errors.push('endAt, startAt\'tan sonra olmalı');
  }
  if (c.icon !== undefined && !hasText(c.icon)) errors.push('icon: SF Symbol adı olmalı');
  if (c.tint !== undefined && !INFO_CARD_TINTS.includes(String(c.tint))) {
    errors.push(`tint: ${INFO_CARD_TINTS.join(' | ')}`);
  }
  validateLocalized(c.title, 'title', errors, 80);
  if (c.subtitle !== undefined) validateLocalized(c.subtitle, 'subtitle', errors, 240);
  if (c.body !== undefined) validateLocalized(c.body, 'body', errors, 2000);

  if (c.items !== undefined) {
    if (!Array.isArray(c.items) || c.items.length > 8) {
      errors.push('items: en fazla 8 öğelik dizi');
    } else {
      c.items.forEach((item: any, index: number) => {
        if (!item || typeof item !== 'object') { errors.push(`items[${index}]: nesne olmalı`); return; }
        if (!hasText(item.icon)) errors.push(`items[${index}].icon: SF Symbol adı gerekli`);
        validateLocalized(item.title, `items[${index}].title`, errors, 80);
        validateLocalized(item.body, `items[${index}].body`, errors, 280);
      });
    }
  }
  if (!c.subtitle && !c.body && !(Array.isArray(c.items) && c.items.length)) {
    errors.push('subtitle, body veya items gerekli: kart boş kalmasın');
  }
  if (c.action !== undefined) {
    const action = c.action as any;
    if (!action || typeof action !== 'object') errors.push('action: { label, url } olmalı');
    else {
      validateLocalized(action.label, 'action.label', errors, 40);
      if (!isValidURL(action.url)) errors.push('action.url: sismik://… veya https://… olmalı');
    }
  }
  if (c.push !== undefined) {
    const push = c.push as any;
    if (!push || typeof push !== 'object') errors.push('push: { title, body } olmalı');
    else {
      validateLocalized(push.title, 'push.title', errors, 80);
      validateLocalized(push.body, 'push.body', errors, 200);
    }
  }
  return { valid: errors.length === 0, errors };
}

/// Belgedeki JSON metnini okur. Bozuk metin tüm kartları düşürür ama liste
/// ucunu asla bozmaz; tek tek geçersiz kartlar atlanır.
export function parseInfoCards(raw: unknown): InfoCard[] {
  if (typeof raw !== 'string' || !raw) return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(card => validateInfoCard(card).valid).slice(0, INFO_CARDS_MAX_COUNT) as InfoCard[];
  } catch {
    return [];
  }
}

/// İstemciye giden sürüm: `push` metni uygulamada kullanılmaz, taşınmaz.
export function publicInfoCards(cards: InfoCard[]): Omit<InfoCard, 'push'>[] {
  return cards.map(({ push: _push, ...rest }) => rest);
}

/// Betik: kartı ekler ya da aynı kimliklisini değiştirir.
export function upsertInfoCard(cards: InfoCard[], card: InfoCard): InfoCard[] {
  const next = cards.filter(existing => existing.id !== card.id);
  next.push(card);
  return next;
}

/// Push bildirimi metinlerini otomasyon kuralının `messages` biçimine çevirir.
export function infoCardPushMessages(card: InfoCard): Record<string, { title: string; body: string }> {
  const messages: Record<string, { title: string; body: string }> = {};
  if (!card.push) return messages;
  for (const lang of INFO_CARD_LANGS) {
    const title = card.push.title[lang];
    const body = card.push.body[lang];
    if (hasText(title) && hasText(body)) messages[lang] = { title: title!.trim(), body: body!.trim() };
  }
  return messages;
}
