const test = require('node:test');
const assert = require('node:assert/strict');
const {
  sanitizeRemoteConfig,
  configHash,
  filterPublicQuakes,
  isMajorEventSuppressed,
  setRemoteConfigForTesting,
  remoteClientRevision,
  remoteServerConfig,
  remoteClientConfig,
  initRemoteConfig,
  refreshRemoteConfigFromSource,
  absorbRemoteConfigMirror,
  remoteConfigMirrorFields
} = require('../lib/remote-config');
const { quakesForVariant } = require('../lib/earthquake-routes');

const quakes = [
  { id: 'afad-1', provider: 'AFAD', magnitude: 5.4 },
  { id: 'kandilli-1', provider: 'KANDILLI', magnitude: 5.5 },
  { id: 'emsc-1', provider: 'EMSC', magnitude: 5.6 },
  { id: 'noa-1', provider: 'NOA', magnitude: 3.1 }
];

test.afterEach(() => setRemoteConfigForTesting(undefined));

test('empty or broken document yields safe defaults', () => {
  for (const raw of [undefined, {}, { server: 'x', client: 42 }, { server: [], client: [] }]) {
    const config = sanitizeRemoteConfig(raw);
    assert.equal(config.server.push_paused, false);
    assert.deepEqual(config.server.disabled_sources, []);
    assert.deepEqual(config.client, {});
  }
});

test('server section: only true booleans pause, sources are normalized and validated', () => {
  const { server } = sanitizeRemoteConfig({
    server: {
      push_paused: 'true',
      twitter_paused: true,
      disabled_sources: ['noa', 'NOA', 'unknown', 42, 'Kandilli'],
      hidden_quakes: ['afad-1', '', 'bad id with spaces', 7]
    }
  });
  assert.equal(server.push_paused, false, 'string "true" must not pause pushes');
  assert.equal(server.twitter_paused, true);
  assert.deepEqual(server.disabled_sources, ['NOA', 'KANDILLI']);
  assert.deepEqual(server.hidden_quakes, ['afad-1']);
});

test('client numbers are clamped, unknown keys and wrong types dropped', () => {
  const { client } = sanitizeRemoteConfig({
    client: {
      felt_card: { nearby_radius_km: 5000, felt_min_mmi: 'x', bogus: 3 },
      refresh: { interval_seconds: 1 },
      features: { felt_card: false, ai_analysis: 'no', unknown_flag: false },
      min_version: '2.1.4',
      hidden_sources: ['bmkg'],
      extra: { anything: true }
    }
  });
  assert.deepEqual(client.felt_card, { nearby_radius_km: 200 });
  assert.deepEqual(client.refresh, { interval_seconds: 15 });
  assert.deepEqual(client.features, { felt_card: false });
  assert.equal(client.min_version, '2.1.4');
  assert.deepEqual(client.hidden_sources, ['BMKG']);
  assert.equal(client.extra, undefined);
});

test('notice requires id and title; accepts plain string title', () => {
  assert.equal(sanitizeRemoteConfig({ client: { notice: { title: 'x' } } }).client.notice, undefined);
  const { notice } = sanitizeRemoteConfig({
    client: {
      notice: {
        id: 'afad-gecikme',
        title: { tr: 'AFAD verisi gecikiyor', en: 'AFAD data is delayed' },
        body: 'Details',
        tint: 'neon',
        url: 'javascript:alert(1)',
        dismissible: false
      }
    }
  }).client;
  assert.equal(notice.id, 'afad-gecikme');
  assert.equal(notice.title.tr, 'AFAD verisi gecikiyor');
  assert.deepEqual(notice.body, { en: 'Details' });
  assert.equal(notice.tint, undefined, 'unknown tint dropped');
  assert.equal(notice.url, undefined, 'only https/sismik links allowed');
  assert.equal(notice.dismissible, false);
});

test('hash is independent of key order', () => {
  assert.equal(configHash({ a: 1, b: { c: 2, d: 3 } }), configHash({ b: { d: 3, c: 2 }, a: 1 }));
  assert.notEqual(configHash({ a: 1 }), configHash({ a: 2 }));
});

test('filterPublicQuakes returns the same array when nothing is hidden', () => {
  setRemoteConfigForTesting(undefined);
  assert.equal(filterPublicQuakes(quakes), quakes);
});

test('hidden sources and quakes disappear from the list variants', () => {
  setRemoteConfigForTesting({ server: { disabled_sources: ['NOA'], hidden_quakes: ['emsc-1'] } });
  const ids = quakesForVariant(quakes, 'all').map(q => q.id);
  assert.deepEqual(ids, ['afad-1', 'kandilli-1']);
  // Eski istemci görünümü de aynı filtreden geçer.
  assert.deepEqual(quakesForVariant(quakes, 'legacy').map(q => q.id), ['afad-1']);
  // Aynı dizi ve yapılandırma için tek hesap.
  assert.equal(filterPublicQuakes(quakes), filterPublicQuakes(quakes));
});

test('major event suppression by id and global switch', () => {
  setRemoteConfigForTesting({ server: { major_event_suppress: ['afad-1'] } });
  assert.equal(isMajorEventSuppressed('afad-1'), true);
  assert.equal(isMajorEventSuppressed('afad-2'), false);
  setRemoteConfigForTesting({ server: { major_event_disabled: true } });
  assert.equal(isMajorEventSuppressed('anything'), true);
});

test('client revision changes only when the client section changes', () => {
  setRemoteConfigForTesting({ client: { features: { felt_card: false } } });
  const first = remoteClientRevision();
  setRemoteConfigForTesting({ server: { push_paused: true }, client: { features: { felt_card: false } } });
  assert.equal(remoteClientRevision(), first, 'server-only change must not make clients refetch');
  setRemoteConfigForTesting({ client: { features: { felt_card: true } } });
  assert.notEqual(remoteClientRevision(), first);
});

test('source document is read at most once per minute', async () => {
  let reads = 0;
  const db = {
    collection: (name) => ({
      doc: (id) => ({
        get: async () => {
          assert.equal(name, '_system');
          assert.equal(id, 'remote_config_v1');
          reads++;
          return { data: () => ({ server: { push_paused: true } }) };
        }
      })
    })
  };
  initRemoteConfig(db);
  await refreshRemoteConfigFromSource(true);
  await refreshRemoteConfigFromSource();
  await refreshRemoteConfigFromSource();
  assert.equal(reads, 1);
  assert.equal(remoteServerConfig().push_paused, true);
});

test('mirror from live snapshot applies on API instances', () => {
  setRemoteConfigForTesting({ server: { twitter_paused: true }, client: { min_version: '2.1.4' } });
  const mirror = remoteConfigMirrorFields();
  setRemoteConfigForTesting(undefined);
  assert.equal(remoteServerConfig().twitter_paused, false);
  absorbRemoteConfigMirror(mirror);
  assert.equal(remoteServerConfig().twitter_paused, true);
  assert.equal(remoteClientConfig().min_version, '2.1.4');
  // Bozuk yansıma mevcut değeri bozmaz.
  absorbRemoteConfigMirror({ remote_config: '{not json', remote_config_hash: 'x' });
  assert.equal(remoteServerConfig().twitter_paused, true);
});
