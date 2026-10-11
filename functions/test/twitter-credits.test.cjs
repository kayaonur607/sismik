const test = require('node:test');
const assert = require('node:assert/strict');

// X kredisi bitince (402) kart görseli her dakika yeniden üretilip
// yüklenmemeli; başarısız gönderi sınırsız denenmemeli.
test('credit depletion stops rendering until a cheap probe confirms credits are back', async t => {
  for (const key of ['TWITTER_API_KEY', 'TWITTER_API_SECRET', 'TWITTER_ACCESS_TOKEN', 'TWITTER_ACCESS_SECRET']) {
    process.env[key] = 'test-value';
  }
  const { TwitterApi } = require('twitter-api-v2');
  const probe = new TwitterApi({ appKey: 'a', appSecret: 'b', accessToken: 'c', accessSecret: 'd' });
  const owner = (object, name) => {
    for (let proto = Object.getPrototypeOf(object); proto; proto = Object.getPrototypeOf(proto)) {
      if (Object.hasOwn(proto, name)) return proto;
    }
    throw new Error(`${name} not found`);
  };
  const depleted = () => Object.assign(new Error('credits depleted'), { code: 402, data: { title: 'credits depleted' } });
  let credits = false;
  let uploads = 0;
  let probes = 0;
  const posted = [];
  t.mock.method(owner(probe.v1, 'uploadMedia'), 'uploadMedia', async () => { uploads++; return `media-${uploads}`; });
  t.mock.method(owner(probe.v2, 'tweet'), 'tweet', async (text, payload) => {
    if (!credits) throw depleted();
    posted.push(payload?.media?.media_ids?.[0] ?? null);
    return { data: { id: `tweet-${posted.length}` } };
  });
  t.mock.method(owner(probe.v2, 'me'), 'me', async () => {
    probes++;
    if (!credits) throw depleted();
    return { data: { id: '1', username: 'sismik_app' } };
  });

  const { runAutomaticTwitterPosting } = require('../lib/twitter-posting');
  await new Promise(resolve => setTimeout(resolve, 5));
  const start = Date.now();
  const at = minutes => start + minutes * 60000;
  const turkey = (id, minute) => ({
    id, provider: 'AFAD', country: 'Türkiye', title: 'Sındırgı (Balıkesir)', magnitude: 3.4, depth: 7,
    lat: 39.2, lon: 28.2, date: new Date(at(minute)).toISOString()
  });

  // İlk deneme 402: kart bir kez üretilir, deprem her dakika yeniden denenmez.
  await runAutomaticTwitterPosting([turkey('afad-a', 0)], at(1));
  for (let minute = 2; minute <= 40; minute++) {
    await runAutomaticTwitterPosting([turkey('afad-a', 0), turkey('afad-b', 30)], at(minute));
  }
  assert.equal(uploads, 1, 'kredi yokken görsel yeniden üretilmez');
  assert.equal(probes, 0, 'yoklama saatte en fazla bir kez');

  // Bir saat sonra yeni deprem: önce ucuz yoklama; kredi hâlâ yoksa görsel yok.
  await runAutomaticTwitterPosting([turkey('afad-c', 61)], at(62));
  assert.equal(probes, 1);
  assert.equal(uploads, 1);

  // Kredi yüklendi: sonraki yoklama başarılı, deprem görselle paylaşılır.
  credits = true;
  await runAutomaticTwitterPosting([turkey('afad-d', 125)], at(126));
  assert.equal(probes, 2);
  assert.equal(uploads, 2);
  assert.deepEqual(posted, ['media-2']);
});

test('other failures reuse the uploaded card and stop after three attempts', async t => {
  const { TwitterApi } = require('twitter-api-v2');
  const probe = new TwitterApi({ appKey: 'a', appSecret: 'b', accessToken: 'c', accessSecret: 'd' });
  const owner = (object, name) => {
    for (let proto = Object.getPrototypeOf(object); proto; proto = Object.getPrototypeOf(proto)) {
      if (Object.hasOwn(proto, name)) return proto;
    }
    throw new Error(`${name} not found`);
  };
  let uploads = 0;
  let tweets = 0;
  t.mock.method(owner(probe.v1, 'uploadMedia'), 'uploadMedia', async () => { uploads++; return 'media-x'; });
  t.mock.method(owner(probe.v2, 'tweet'), 'tweet', async () => {
    tweets++;
    throw Object.assign(new Error('Service Unavailable'), { code: 503 });
  });
  const { runAutomaticTwitterPosting } = require('../lib/twitter-posting');
  const now = Date.now() + 10 * 60 * 60000;
  const world = {
    id: 'usgs-big', provider: 'USGS', country: null, title: 'Kamchatka, Russia', magnitude: 6.4, depth: 30,
    lat: 52.5, lon: 160.1, date: new Date(now).toISOString()
  };
  for (let minute = 1; minute <= 10; minute++) {
    await runAutomaticTwitterPosting([world], now + minute * 60000);
  }
  assert.equal(tweets, 3);
  assert.equal(uploads, 1);
});
