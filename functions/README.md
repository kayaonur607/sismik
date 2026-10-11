# Sismik Backend · Sismik Sunucusu

**English** · [Türkçe](#türkçe)

The Sismik backend runs on Firebase Cloud Functions v2 (Node 22, TypeScript). It collects earthquakes from nine agencies, publishes the live list, delivers push notifications and Live Activity updates, and serves the HTTP API used by the iOS app.

> **Third-party developers:** please use the free [Open Data API](../api/README.md). The endpoints below exist for the iOS client only. They are rate-limited per IP and may change without notice.

## Functions

| Function | Trigger | Responsibility |
|---|---|---|
| `sismikApi` | HTTPS (Express) | HTTP API for the app, served behind Firebase Hosting `/api/**` with a CDN cache |
| `scheduledPushCheck` | Every minute + realtime feeds (EMSC WebSocket, USGS) | Full collection, live snapshot publishing, push delivery, Live Activity broadcasts, X/Twitter posting |
| `fastPushScan` | Cloud Tasks at :15 / :30 / :45 | Fast scans between minute runs, so alerts go out sooner |
| `maintenanceSweep` | Hourly (`5 * * * *`, Europe/Istanbul) | Premium expiry, automations, map archive (every 2 h), device cleanup (04:05), weekly digest (Mon 09:05) |
| `premiumEngagementCampaign` | Weekly (Sun 18:00) | Opt-in product announcements, with a frequency cap |

## Source layout

| File | Purpose |
|---|---|
| `index.ts` | Composition: Express app, function definitions, resource settings |
| `earthquake-providers.ts` | Agency clients (AFAD, Kandilli, EMSC, USGS, NOA, GeoNet, BMKG, JMA, CENC) |
| `earthquake-routes.ts` | Live snapshot, map archives, list/map/stats/aftershock routes |
| `push-routes.ts` · `spatial-index.ts` · `notification-templates.ts` | Device cache, spatial matching, delivery, templates in 14 languages |
| `apns.ts` · `live-activity.ts` | Direct APNs (HTTP/2, ES256 JWT) and Live Activity broadcast channels |
| `device-routes.ts` · `subscription-routes.ts` · `subscription-verification.ts` | Device registration, entitlements (RevenueCat, App Store JWS) |
| `ai-routes.ts` | Gemini summaries with a Firestore + in-memory cache |
| `major-event.ts` · `tsunami-alerts.ts` · `gdacs.ts` | Major-event mode, tsunami warnings, GDACS alert levels |
| `safety-places.ts` | OpenStreetMap assembly points and hospitals, cached per 0.1° cell |
| `admin-routes.ts` · `app-update.ts` · `weekly-digest.ts` · `premium-campaign.ts` | Maintenance, release announcements, digests |
| `worker-utils.ts` | Pure helpers (matching, de-duplication, aftershock zones), covered by tests |

## Data model (Firestore)

| Path | Contents | Lifecycle |
|---|---|---|
| `devices/{token}` | Anonymous push token, notification places/preferences, entitlement flags | Deleted after 60 days of inactivity |
| `_public/live_quakes_v1` | gzip-compressed 24-hour list, major event, info cards, mirrored remote config | Overwritten (≤ 1 write / 10 s) |
| `_public/{afad,noa}_map_90d_v1` | gzip-compressed 34-day map archives | Rebuilt every 2 h |
| `_system/*` | Delivery ledger, push event locks, device snapshot, leases, campaign/digest state | Single documents |
| `ai_cache`, `felt_reports`, `safety_cells` | Caches and "felt" counters (sharded) | TTL on `expire_at` |

Clients cannot access Firestore directly ([`firestore.rules`](../firestore.rules) denies all access). Every field queried by the backend has a single-field index declared in [`firestore.indexes.json`](../firestore.indexes.json). When you add a new query field, add its index too.

## HTTP API (iOS client)

Base URL: `https://sismik-app-ea600.web.app/api`. Responses are gzip-compressed JSON, and list routes support `ETag` / `If-None-Match`.

### Earthquake data (CDN-cached)

| Method & path | Parameters | Cache | Description |
|---|---|---|---|
| `GET /` | `sources=all` | 15 s | 24-hour list (all agencies with `sources=all`; the 4 classic agencies otherwise) |
| `GET /recent` | `sources=all` | 15 s | Most recent entries only (incremental polling) |
| `GET /history` | `before`, `limit` (20–200), `source` | 30 min | Older entries, paginated |
| `GET /map` | `days` (1–34), `minmag` | 10 min | Dense map dataset |
| `GET /map-range` | `lat`, `lon`, `radius`, `start`, `end`, `minmag`, `source` | 10 min | Spatial and time range query |
| `GET /aftershocks` | `lat`, `lon`, `radius`, `start`, `end` | 10 min | Aftershock sequence (Gardner–Knopoff zone). Header `X-Sismik-Aftershock-Radius-Km` |
| `GET /stats` | `hours` (1, 24, 168, 720), `region=TR` | 10 min | Statistics and distributions |
| `GET /faults` | — | long | GEM active faults (GeoJSON) |
| `GET /major-event` | — | 15 s | Active major event or `{ "event": null }` |

### App support

| Method & path | Limit (per IP / 10 min) | Description |
|---|---|---|
| `POST /register` · `POST /unregister` | 300 | Device registration and notification preferences |
| `GET /felt` · `POST /felt` | 600 (POST) | "Felt" counters and the coarse 0.1° felt map |
| `GET /safety-places` | 120 | Assembly areas and health facilities near `lat`, `lon` |
| `GET /ai` · `/ai/ask` · `/ai/stats-summary` | 120 · 15 · 20 | Gemini summaries (cached; the limits protect cost) |
| `GET /info-cards` · `/app-config` · `/config` | — | Announcements, remote config, legacy version check |
| `GET /health` | — | Liveness check (`?deep=1` measures Firestore latency) |
| `POST /revenuecat/webhook` · `/app-store/notifications` · `/app-store-connect/webhook` | signed | Store webhooks (signature or secret verified) |

Response headers on list routes: `X-Sismik-Latest-Version`, `X-Sismik-Info-Revision`, `X-Sismik-Config-Revision`, `X-Sismik-Major-Event`.

## Development

```sh
npm ci
npm test          # tsc + node --test (300+ tests)
npm run serve     # Functions emulator
npm run deploy    # firebase deploy --only functions
```

Secrets are stored in Google Secret Manager (`firebase functions:secrets:set NAME`): `GEMINI_API_KEY`, `REVENUECAT_API_KEY`, `REVENUECAT_WEBHOOK_SECRET`, `REVENUECAT_PROJECT_ID`, `ASC_WEBHOOK_SECRET`, `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, and the optional `TWITTER_*`. Never commit credentials.

After a deploy, check that push runs are healthy:

```sh
npx firebase functions:log --only scheduledPushCheck
```

---

## Türkçe

Sismik sunucusu Firebase Cloud Functions v2 (Node 22, TypeScript) üzerinde çalışır. Dokuz ajanstan depremleri toplar, canlı listeyi yayımlar, push bildirimlerini ve Canlı Etkinlik güncellemelerini iletir, iOS uygulamasının kullandığı HTTP API'sini sunar.

> **Üçüncü taraf geliştiriciler:** lütfen ücretsiz [Açık Veri API'sini](../api/README.md) kullanın. Yukarıdaki uçlar yalnızca iOS istemcisi içindir; IP başına hız sınırlıdır ve haber verilmeden değişebilir.

### Fonksiyonlar

- **`sismikApi`:** Uygulamanın HTTP API'si; Firebase Hosting `/api/**` arkasında, CDN önbellekli.
- **`scheduledPushCheck`:** Dakikalık tur ve anlık akışlar. Tam toplama, canlı anlık görüntü, push teslimi, Canlı Etkinlik yayınları ve X paylaşımı burada yapılır.
- **`fastPushScan`:** :15/:30/:45 hızlı taramaları; bildirimleri hızlandırır.
- **`maintenanceSweep`:** Saatlik bakım. Premium süre sonu, otomasyonlar, harita arşivi, cihaz temizliği ve haftalık özeti yürütür.
- **`premiumEngagementCampaign`:** Haftalık, izin veren kullanıcılara sıklık sınırlı ürün duyurusu.

### Veri modeli

- `devices/{token}`: Anonim token, bildirim yerleri ve tercihler, yetki bayrakları. 60 gün etkin olmayan cihaz silinir.
- `_public/live_quakes_v1`: gzip'li 24 saatlik liste, büyük olay, bilgi kartları ve uzak yapılandırma yansıması.
- `_public/{afad,noa}_map_90d_v1`: gzip'li 34 günlük harita arşivleri; 2 saatte bir yenilenir.
- `_system/*`: Teslim defteri, olay kilitleri, cihaz anlık görüntüsü, kiralar.
- `ai_cache`, `felt_reports`, `safety_cells`: Önbellekler ve "hissettim" sayaçları. `expire_at` alanıyla TTL ile silinir.

İstemciler Firestore'a doğrudan erişemez ([`firestore.rules`](../firestore.rules) tüm erişimi reddeder). Sunucunun sorguladığı her alanın tek alan indeksi [`firestore.indexes.json`](../firestore.indexes.json) dosyasında tanımlıdır; yeni bir sorgu alanı eklerken indeksini de ekleyin.

### Geliştirme

```sh
npm ci && npm test        # derleme + 300'den fazla test
npm run deploy            # yalnızca fonksiyonlar
```

Sırlar Google Secret Manager'da tutulur (`firebase functions:secrets:set AD`). Deploy sonrası push turlarının sağlığını `npx firebase functions:log --only scheduledPushCheck` ile kontrol edin.
