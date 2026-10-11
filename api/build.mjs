#!/usr/bin/env node
// Sismik Open Data API — static snapshot builder.
//
// Fetches the latest data from the Sismik backend (through its CDN-cached
// Firebase Hosting endpoint) and writes versioned, schema-stable JSON/GeoJSON
// files to `api/dist/`. A GitHub Actions workflow publishes `api/dist/` to
// GitHub Pages every 10 minutes, so public traffic never reaches the backend.
//
// Sismik Açık Veri API'si — statik anlık görüntü üreticisi. Sunucudan (CDN
// önbellekli Firebase Hosting ucu üzerinden) güncel veriyi alır, sürümlü ve
// şeması sabit JSON/GeoJSON dosyalarını `api/dist/` klasörüne yazar. GitHub
// Actions bu klasörü 10 dakikada bir GitHub Pages'e yayımlar; kullanıcı
// trafiği sunucuya hiç ulaşmaz.
//
// Usage / Kullanım:  node api/build.mjs [--out api/dist]

import { mkdir, writeFile, copyFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = process.argv.includes('--out')
  ? process.argv[process.argv.indexOf('--out') + 1]
  : join(HERE, 'dist');
const UPSTREAM = process.env.SISMIK_UPSTREAM || 'https://sismik-app-ea600.web.app/api';
const API_VERSION = 'v1';
const SITE = 'https://kayaonur607.github.io/sismik';
const SCHEMA_VERSION = 1;

/** Agencies whose catalogues are merged by Sismik. / Sismik'in birleştirdiği ajanslar. */
const SOURCES = {
  AFAD: { name: 'AFAD — Disaster and Emergency Management Authority (Türkiye)', url: 'https://deprem.afad.gov.tr' },
  KANDILLI: { name: 'Boğaziçi University Kandilli Observatory (KOERI)', url: 'http://www.koeri.boun.edu.tr' },
  EMSC: { name: 'European-Mediterranean Seismological Centre', url: 'https://www.emsc-csem.org' },
  USGS: { name: 'U.S. Geological Survey', url: 'https://earthquake.usgs.gov' },
  NOA: { name: 'National Observatory of Athens, Institute of Geodynamics', url: 'https://www.gein.noa.gr' },
  GEONET: { name: 'GeoNet (GNS Science, New Zealand)', url: 'https://www.geonet.org.nz' },
  BMKG: { name: 'BMKG — Meteorology, Climatology and Geophysics Agency (Indonesia)', url: 'https://www.bmkg.go.id' },
  JMA: { name: 'Japan Meteorological Agency', url: 'https://www.jma.go.jp' },
  CENC: { name: 'China Earthquake Networks Center', url: 'https://www.cenc.ac.cn' }
};

const ATTRIBUTION = 'Earthquake parameters are published by the originating agencies listed in `sources`; '
  + 'each record keeps its agency. Respect each agency\'s terms of use and cite the agency together with Sismik. '
  + 'Data is provided for information only and must not be used for life-safety decisions.';

/** Türkiye and its immediate surroundings (the region AFAD/Kandilli monitor). */
const TURKIYE_BOX = { minLat: 35.5, maxLat: 42.5, minLon: 25.5, maxLon: 45.0 };

async function fetchJSON(path) {
  const url = `${UPSTREAM}${path}`;
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const response = await fetch(url, {
        headers: { 'User-Agent': 'sismik-open-data-builder/1 (+https://github.com/kayaonur607/sismik)' },
        signal: AbortSignal.timeout(45_000)
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, attempt * 2_000));
    }
  }
  throw new Error(`${url}: ${lastError?.message || lastError}`);
}

const round = (value, digits) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  const factor = 10 ** digits;
  return Math.round(number * factor) / factor;
};
const text = value => (typeof value === 'string' && value.trim() ? value.trim() : null);
const isoTime = value => {
  const time = typeof value === 'number' ? value : Date.parse(String(value ?? ''));
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
};

/** Upstream record → stable public schema. / Sunucu kaydı → sabit açık şema. */
function normalize(quake) {
  const source = String(quake.provider || '').toUpperCase();
  const record = {
    id: String(quake.id),
    source,
    magnitude: round(quake.magnitude, 1),
    magnitudeType: text(quake.magType),
    depthKm: round(quake.depth, 1),
    latitude: round(quake.lat, 4),
    longitude: round(quake.lon, 4),
    time: isoTime(quake.date),
    updatedAt: isoTime(quake.updatedAt),
    place: text(quake.title),
    district: text(quake.district),
    province: text(quake.closestCity?.name ?? quake.closestCity),
    country: text(quake.country),
    tsunami: quake.tsunami === true,
    status: text(quake.status),
    url: text(quake.sourceURL) ?? text(quake.detailURL)
  };
  const valid = record.id && record.source && record.time
    && record.magnitude !== null && record.latitude !== null && record.longitude !== null;
  return valid ? record : null;
}

function normalizeAll(list) {
  const seen = new Set();
  return (Array.isArray(list) ? list : [])
    .map(normalize)
    .filter(record => record && !seen.has(`${record.source}:${record.id}`) && seen.add(`${record.source}:${record.id}`))
    .sort((a, b) => Date.parse(b.time) - Date.parse(a.time));
}

function envelope(generatedAt, extra, earthquakes) {
  return {
    apiVersion: API_VERSION,
    schemaVersion: SCHEMA_VERSION,
    generatedAt,
    ...extra,
    count: earthquakes.length,
    attribution: ATTRIBUTION,
    earthquakes
  };
}

function toGeoJSON(generatedAt, earthquakes) {
  return {
    type: 'FeatureCollection',
    metadata: { apiVersion: API_VERSION, generatedAt, count: earthquakes.length, attribution: ATTRIBUTION },
    features: earthquakes.map(({ latitude, longitude, depthKm, ...properties }) => ({
      type: 'Feature',
      id: `${properties.source}:${properties.id}`,
      geometry: { type: 'Point', coordinates: [longitude, latitude, depthKm === null ? 0 : -depthKm] },
      properties: { ...properties, depthKm }
    }))
  };
}

const STAT_FIELDS = [
  'rangeHours', 'last24h', 'felt24h', 'm45plus', 'm60plus', 'maxMagnitude',
  'strongestTitle', 'strongestTime', 'avgMagnitude', 'avgDepth', 'medianMagnitude', 'medianDepth'
];
function trimStats(stats, region, generatedAt) {
  const out = { apiVersion: API_VERSION, schemaVersion: SCHEMA_VERSION, generatedAt, region };
  for (const field of STAT_FIELDS) {
    const target = { last24h: 'total', felt24h: 'feltM3plus', m45plus: 'm45plus', m60plus: 'm60plus',
      strongestTitle: 'strongestPlace' }[field] || field;
    out[target] = stats?.[field] ?? null;
  }
  out.updatedAt = isoTime(stats?.updatedAt);
  out.attribution = ATTRIBUTION;
  return out;
}

function inBox(quake, box) {
  return quake.latitude >= box.minLat && quake.latitude <= box.maxLat
    && quake.longitude >= box.minLon && quake.longitude <= box.maxLon;
}

async function write(relativePath, data) {
  const path = join(OUT, API_VERSION, relativePath);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(data));
  return `${SITE}/${API_VERSION}/${relativePath}`;
}

async function main() {
  const generatedAt = new Date().toISOString();
  const [latestRaw, weekRaw, statsTR, statsWorld, major] = await Promise.all([
    fetchJSON('/?sources=all'),
    fetchJSON('/map?days=7&minmag=4'),
    fetchJSON('/stats?hours=24&region=TR'),
    fetchJSON('/stats?hours=24'),
    fetchJSON('/major-event').catch(() => ({ event: null }))
  ]);

  const latest = normalizeAll(latestRaw);
  const week = normalizeAll(weekRaw);
  // Guard: never publish an empty snapshot over a good one (the job fails and
  // the previous deployment stays live). / Boş anlık görüntü yayımlanmaz.
  if (latest.length < 10) throw new Error(`Upstream returned only ${latest.length} earthquakes; refusing to publish.`);

  const windowInfo = { window: { hours: 24 } };
  const endpoints = {};
  endpoints.latest = await write('earthquakes/latest.json', envelope(generatedAt, windowInfo, latest));
  endpoints.latestGeoJSON = await write('earthquakes/latest.geojson', toGeoJSON(generatedAt, latest));
  endpoints.turkiye = await write('earthquakes/turkiye.json',
    envelope(generatedAt, { window: { hours: 24 }, region: { name: 'Türkiye and surroundings', bbox: TURKIYE_BOX } },
      latest.filter(quake => inBox(quake, TURKIYE_BOX))));
  endpoints.significant = await write('earthquakes/significant.json',
    envelope(generatedAt, { window: { days: 7 }, minMagnitude: 4.0 }, week.filter(quake => quake.magnitude >= 4)));
  endpoints.significantGeoJSON = await write('earthquakes/significant.geojson',
    toGeoJSON(generatedAt, week.filter(quake => quake.magnitude >= 4)));

  endpoints.bySource = {};
  for (const source of Object.keys(SOURCES)) {
    endpoints.bySource[source.toLowerCase()] = await write(`earthquakes/sources/${source.toLowerCase()}.json`,
      envelope(generatedAt, { window: { hours: 24 }, source }, latest.filter(quake => quake.source === source)));
  }

  endpoints.statsTurkiye = await write('stats/turkiye-24h.json', trimStats(statsTR, 'turkiye', generatedAt));
  endpoints.statsWorld = await write('stats/world-24h.json', trimStats(statsWorld, 'world', generatedAt));

  const event = major?.event ?? null;
  endpoints.majorEvent = await write('major-event.json', {
    apiVersion: API_VERSION,
    schemaVersion: SCHEMA_VERSION,
    generatedAt,
    active: Boolean(event),
    event: event ? {
      id: String(event.id),
      source: String(event.provider || '').toUpperCase(),
      magnitude: round(event.magnitude, 1),
      depthKm: round(event.depth, 1),
      latitude: round(event.lat, 4),
      longitude: round(event.lon, 4),
      time: isoTime(event.date),
      place: text(event.title),
      region: text(event.region),
      expiresAt: isoTime(event.expires_at ?? event.expiresAt)
    } : null,
    attribution: ATTRIBUTION
  });

  const index = {
    name: 'Sismik Open Data API',
    apiVersion: API_VERSION,
    schemaVersion: SCHEMA_VERSION,
    generatedAt,
    updateIntervalMinutes: 10,
    documentation: `${SITE}/`,
    openapi: `${SITE}/openapi.yaml`,
    repository: 'https://github.com/kayaonur607/sismik',
    license: 'Data: see `sources` and `attribution`. Code: MIT.',
    attribution: ATTRIBUTION,
    sources: SOURCES,
    counts: { latest: latest.length, significant7d: week.filter(quake => quake.magnitude >= 4).length },
    endpoints
  };
  await write('index.json', index);

  await mkdir(OUT, { recursive: true });
  await copyFile(join(HERE, 'site', 'index.html'), join(OUT, 'index.html'));
  await copyFile(join(HERE, 'openapi.yaml'), join(OUT, 'openapi.yaml'));
  await writeFile(join(OUT, '.nojekyll'), '');
  await writeFile(join(OUT, '404.html'), '<!doctype html><meta charset="utf-8"><title>Not found</title><p>Not found. See <a href="./">API documentation</a>.</p>');

  console.log(`Published snapshot ${generatedAt}: ${latest.length} latest, ${index.counts.significant7d} significant (7d).`);
}

main().catch(error => {
  console.error('Build failed:', error?.message || error);
  process.exit(1);
});
