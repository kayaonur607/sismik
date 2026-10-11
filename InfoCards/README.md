# Bilgi kartları

Uygulama açıldığında bir kez görünen duyuru kartları. Yönetim: `Scripts/info-cards.mjs`.

```bash
cd functions && npm run build && cd ..                       # doğrulama modülü
node Scripts/info-cards.mjs list                              # yayındakiler + zamanlanmış bildirimler
node Scripts/info-cards.mjs publish InfoCards/ornek-kart.json # kuru çalışma
node Scripts/info-cards.mjs publish InfoCards/ornek-kart.json --apply
node Scripts/info-cards.mjs push 2026-10-deprem-hazirlik-ayi --at 2026-10-01T10:00:00+03:00 --apply
node Scripts/info-cards.mjs push-cancel 2026-10-deprem-hazirlik-ayi --apply
node Scripts/info-cards.mjs remove 2026-10-deprem-hazirlik-ayi --apply
```

## Alanlar

| Alan | Zorunlu | Açıklama |
|---|---|---|
| `id` | ✓ | küçük harf/rakam/`.`/`_`/`-`. Her cihaz bir kimliği **bir kez** görür; tekrar göstermek için yeni id. |
| `title` | ✓ | `{ "tr": …, "en": … }` — en az tr veya en. Diğer diller: de es fr it ja ru ar. Eksik dil → en → tr. |
| `subtitle` / `body` / `items` | biri ✓ | `body`: serbest metin, "- " ile başlayan satırlar madde olur. `items`: en fazla 8 `{ icon, title, body }`. |
| `audience` | | `all` (varsayılan) · `free` · `premium` |
| `minVersion` / `maxVersion` | | Uygulama sürümü aralığı (dahil). |
| `startAt` / `endAt` | | ISO 8601 gösterim penceresi. |
| `icon` / `tint` | | SF Symbol · `orange green blue red purple teal` |
| `action` | | `{ label, url }` — `sismik://risk`, `sismik://paywall`, `sismik://map`, `sismik://assembly`, `sismik://emergency`, `sismik://stats` ya da `https://…` |
| `push` | | `push` komutunun bildirim metni `{ title, body }`. Uygulamaya gönderilmez. |

## Yeni sürüm sonrası kart (otomatik)

Elle bir şey yapılmaz. Kullanıcı güncelledikten sonraki ilk açılışta uygulama, App Store'daki
"Bu Sürümdeki Yenilikler" metnini mağazadan okur ve bir kez gösterir
(`Sismik/Services/InfoCardCenter.swift`, `ReleaseNotes`). Metni App Store Connect'te her dil
için ayrı yaz; uygulama dili o dilin mağazasından okunur. Satır başında `- ` veya `• ` olan
satırlar madde olarak görünür. Mağaza yeni sürümü geç gösterirse 7 güne kadar yeniden denenir.

## Maliyet

Kartlar, sunucunun zaten dakikada bir okuduğu `_public/live_quakes_v1` belgesinde durur;
yayın ek okuma getirmez. Uygulama yalnızca revizyon değişince `/info-cards` çeker (CDN
önbellekli). `push` ise mevcut otomasyon motorunu kullanır: kitle bir kez okunur ve her
cihaza "gönderildi" işareti yazılır.
