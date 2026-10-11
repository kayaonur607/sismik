const test = require('node:test');
const assert = require('node:assert/strict');

// Twitter paylaşımları veritabanına yazılmaz; defter yalnızca süreç
// belleğinde, aday penceresi kadar tutulur.
test('automatic posting keeps no database state, never double posts and skips pre-restart quakes', async t => {
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
  const posted = [];
  const replies = [];
  const emergency = [];
  t.mock.method(owner(probe.v1, 'uploadMedia'), 'uploadMedia', async () => 'media-1');
  t.mock.method(owner(probe.v2, 'tweet'), 'tweet', async (text, payload) => {
    assert.equal(typeof text, 'string', 'tweet düzenlenmez (edit_options gönderilmez)');
    posted.push(text);
    return { data: { id: `tweet-${posted.length}` } };
  });
  t.mock.method(owner(probe.v2, 'reply'), 'reply', async (text, id, payload) => {
    // Acil bilgi kartı yanıtları ayrı izlenir.
    if (text.startsWith('🆘')) { emergency.push({ id, text, payload }); return { data: { id: `acil-${emergency.length}` } }; }
    replies.push({ id, text });
    return { data: { id: `reply-${replies.length}` } };
  });

  const { runAutomaticTwitterPosting } = require('../lib/twitter-posting');
  await new Promise(resolve => setTimeout(resolve, 5));
  const now = Date.now();
  const beforeRestart = {
    id: 'afad-before', provider: 'AFAD', country: 'Türkiye', title: 'Pütürge (Malatya)', magnitude: 4.1, depth: 7,
    lat: 38.2, lon: 38.87, date: new Date(now - 10 * 60000).toISOString()
  };
  const fresh = { ...beforeRestart, id: 'afad-fresh', lat: 39.9, lon: 32.8, date: new Date(now).toISOString() };

  await runAutomaticTwitterPosting([beforeRestart, fresh], now + 1000);
  assert.equal(posted.length, 1, 'yalnızca süreç başladıktan sonraki deprem paylaşılır');

  await runAutomaticTwitterPosting([fresh], now + 60000);
  assert.equal(posted.length, 1, 'aynı deprem ikinci kez paylaşılmaz');

  // Büyüklük anlamlı biçimde revize edilince orijinal tweete yanıt atılır;
  // tweet düzenlenmez. Yanıt, yeni değer 2 dk aynı kalınca gider.
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.8 }], now + 120000);
  assert.equal(replies.length, 0, 'yeni değer henüz oturmadı');
  // Ajans değeri gidip getirirse (Şanlıurfa: 5.6 → 5.2 → 5.8) bekleme baştan başlar.
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.4 }], now + 150000);
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.8 }], now + 180000);
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.8 }], now + 270000);
  assert.equal(replies.length, 0, 'değer değişince bekleme sıfırlanır');
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.8 }], now + 300000);
  assert.equal(replies.length, 1, 'oturan değer için tek yanıt');
  assert.equal(replies[0].id, 'tweet-1');
  assert.match(replies[0].text, /M4\.1 to M4\.8/);
  assert.equal(posted.length, 1, 'yeni tweet atılmaz');
  // Sonraki yanıt da orijinal tweete eklenir ve son yanıtlanan değerle kıyaslanır.
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 4.8 }], now + 400000);
  assert.equal(replies.length, 1, 'aynı değer ikinci kez yanıtlanmaz');
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 5.2 }], now + 410000);
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 5.2 }], now + 540000);
  assert.equal(replies.length, 2);
  assert.equal(replies[1].id, 'tweet-1');
  assert.match(replies[1].text, /M4\.8 to M5\.2/);
  // Değer paylaşılan hâline dönerse bekleyen yanıt düşer.
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 5.6 }], now + 550000);
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 5.2 }], now + 560000);
  await runAutomaticTwitterPosting([{ ...fresh, magnitude: 5.2 }], now + 700000);
  assert.equal(replies.length, 2, 'geri dönen değer için yanıt yok');
  // M5.5 eşiğini aşınca acil bilgi kartı orijinal tweete bir kez yanıtlanır.
  assert.equal(emergency.length, 1);
  assert.equal(emergency[0].id, 'tweet-1');
  assert.deepEqual(emergency[0].payload, { media: { media_ids: ['media-1'] } }, 'kart görseliyle');

  // Başka bir ajansın aynı olay için verdiği farklı derinlik revizyon değildir.
  const big = { ...fresh, id: 'afad-big', magnitude: 6.3, depth: 7, lat: 38.0, lon: 37.2, date: new Date(now + 2000).toISOString() };
  await runAutomaticTwitterPosting([big], now + 180000);
  assert.equal(posted.length, 2);
  await runAutomaticTwitterPosting([{ ...big, id: 'emsc-big', provider: 'EMSC', country: null, magnitude: 6.4, depth: 12 }], now + 240000);
  assert.equal(posted.length, 2, 'aynı olayın EMSC kopyası yeniden paylaşılmaz');
  assert.equal(replies.length, 2, 'ajanslar arası farka yanıt yok');
  // Türkiye'deki M6.3: deprem tweetinin hemen ardından acil bilgi kartı; EMSC
  // kopyası ikinci kart göndermez.
  assert.equal(emergency.length, 2);
  assert.equal(emergency[1].id, 'tweet-2');

  // En hızlı kaynak: Türkiye bölgesindeki M3.6'yı EMSC önce yayımlar. Eskiden
  // M6 altı EMSC kaydı uygun değildi ve AFAD'ın (bazen 53 dk geç) kaydı
  // beklenirdi; artık ilk görülen EMSC kaydı hemen paylaşılır, sonra gelen
  // AFAD kopyası tekrar paylaşılmaz.
  const emscFirst = {
    id: 'emsc-fast', provider: 'EMSC', title: 'CENTRAL TURKEY', country: null, magnitude: 3.6, depth: 10,
    lat: 37.83, lon: 36.21, date: new Date(now + 3000).toISOString()
  };
  await runAutomaticTwitterPosting([emscFirst], now + 250000);
  assert.equal(posted.length, 3, 'bölgedeki M3+ EMSC kaydı hemen paylaşılır');
  assert.match(posted[2], /M3\.6 — 69 km WNW of Kahramanmaraş, Türkiye/);
  await runAutomaticTwitterPosting([{ ...emscFirst, id: 'afad-late', provider: 'AFAD', title: 'Göksun (Kahramanmaraş)', country: 'Türkiye',
    district: 'Göksun', closestCity: 'Kahramanmaraş', magnitude: 3.4, depth: 7 }], now + 300000);
  assert.equal(posted.length, 3, 'geç gelen AFAD kopyası paylaşılmaz');
  assert.equal(emergency.length, 2, 'M5.5 altı depremde acil bilgi kartı yok');
});
