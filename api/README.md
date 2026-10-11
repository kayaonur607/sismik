# Sismik Open Data API

**English** · [Türkçe](#türkçe)

Free, read-only earthquake feeds merged from nine seismological agencies: AFAD, Kandilli (KOERI), EMSC, USGS, NOA, GeoNet, BMKG, JMA and CENC. You don't need an API key or an account, and CORS is enabled.

- **Documentation:** https://kayaonur607.github.io/sismik/
- **Base URL:** `https://kayaonur607.github.io/sismik/v1`
- **Refresh:** about every 10 minutes
- **Specification:** [`openapi.yaml`](openapi.yaml) (OpenAPI 3.1)

| Endpoint | Content |
|---|---|
| `/earthquakes/latest.json` · `.geojson` | All agency records from the last 24 hours, newest first |
| `/earthquakes/turkiye.json` | Last 24 hours in Türkiye and surroundings (35.5–42.5°N, 25.5–45°E) |
| `/earthquakes/significant.json` · `.geojson` | Worldwide M4.0+ over the last 7 days |
| `/earthquakes/sources/{source}.json` | One agency: `afad`, `kandilli`, `emsc`, `usgs`, `noa`, `geonet`, `bmkg`, `jma`, `cenc` |
| `/stats/turkiye-24h.json` · `/stats/world-24h.json` | 24-hour statistics |
| `/major-event.json` | Active major event (Türkiye M5.5+, world M7.0+) or `active: false` |
| `/index.json` | Machine-readable catalogue |

```js
const res = await fetch('https://kayaonur607.github.io/sismik/v1/earthquakes/turkiye.json');
const { earthquakes } = await res.json();
```

### How it works

[`build.mjs`](build.mjs) runs in GitHub Actions ([`open-data-api.yml`](../.github/workflows/open-data-api.yml)). It reads the Sismik backend through its CDN-cached endpoint, maps every record to the stable public schema and publishes static files to GitHub Pages. User traffic is served entirely by GitHub's CDN, so it adds no load or cost to the backend. If the upstream request fails, the job fails and the previous snapshot stays online.

To run it locally (Node 22, no dependencies):

```sh
node api/build.mjs            # writes api/dist/
```

### Terms

- Every record keeps its originating agency in `source`. Agency values are never modified.
- The same physical earthquake can appear once per agency.
- Cite the agency together with Sismik, and follow each agency's own terms of use.
- New fields may be added within `v1`. Existing fields keep their meaning.
- **Information only.** This feed is not an early-warning system and must not be used for life-safety decisions.

---

## Türkçe

Dokuz sismoloji ajansının (AFAD, Kandilli/KRDAE, EMSC, USGS, NOA, GeoNet, BMKG, JMA, CENC) verisini birleştiren ücretsiz, salt okunur deprem akışları. API anahtarı ya da hesap gerekmez, CORS açıktır.

- **Belgeler:** https://kayaonur607.github.io/sismik/
- **Temel adres:** `https://kayaonur607.github.io/sismik/v1`
- **Yenilenme:** yaklaşık 10 dakikada bir
- **Şartname:** [`openapi.yaml`](openapi.yaml) (OpenAPI 3.1)

| Uç nokta | İçerik |
|---|---|
| `/earthquakes/latest.json` · `.geojson` | Son 24 saatin tüm ajans kayıtları, en yeni önce |
| `/earthquakes/turkiye.json` | Türkiye ve çevresinde son 24 saat (35,5–42,5°K, 25,5–45°D) |
| `/earthquakes/significant.json` · `.geojson` | Dünya genelinde son 7 günün M4,0+ depremleri |
| `/earthquakes/sources/{kaynak}.json` | Tek ajans: `afad`, `kandilli`, `emsc`, `usgs`, `noa`, `geonet`, `bmkg`, `jma`, `cenc` |
| `/stats/turkiye-24h.json` · `/stats/world-24h.json` | 24 saatlik istatistik |
| `/major-event.json` | Etkin büyük olay (Türkiye M5,5+, dünya M7,0+) ya da `active: false` |
| `/index.json` | Makine okunur uç nokta listesi |

### Nasıl çalışır

[`build.mjs`](build.mjs), GitHub Actions üzerinde çalışır ([`open-data-api.yml`](../.github/workflows/open-data-api.yml)). Sismik sunucusunu CDN önbellekli ucundan okur, her kaydı sabit açık şemaya çevirir ve statik dosyaları GitHub Pages'e yayımlar. Kullanıcı trafiğinin tamamı GitHub CDN'inden karşılanır; sunucuya ek yük ya da maliyet getirmez. Kaynaktan veri alınamazsa iş başarısız olur ve bir önceki anlık görüntü yayında kalır.

### Koşullar

- Her kayıt, kaynak ajansını `source` alanında taşır. Ajans değerleri değiştirilmez.
- Aynı fiziksel deprem her ajans için ayrı bir kayıt olarak görünebilir.
- Kaynak ajansı ve Sismik'i birlikte belirtin, her ajansın kendi kullanım koşullarına uyun.
- `v1` içinde yeni alanlar eklenebilir. Mevcut alanların anlamı değişmez.
- **Yalnızca bilgilendirme amaçlıdır.** Bu akış bir erken uyarı sistemi değildir; can güvenliği kararlarında kullanılmamalıdır.
