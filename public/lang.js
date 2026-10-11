/* Dil seçimi: kayıtlı tercih → ?lang → tarayıcı dili → Türkçe.
   Sayfa yeniden yüklenmez; her belge iki dili de içerir ve yalnızca biri
   görünür. Böylece /privacy/ gibi adresler dilden bağımsız tek URL kalır. */
(function () {
  var KEY = 'sismik.lang';
  var qs = new URLSearchParams(location.search).get('lang');
  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  var nav = (navigator.language || 'tr').toLowerCase();
  var lang = (qs === 'tr' || qs === 'en') ? qs
           : (saved === 'tr' || saved === 'en') ? saved
           : (nav.indexOf('tr') === 0 ? 'tr' : 'en');

  function apply(next) {
    lang = next;
    document.documentElement.lang = next;
    document.querySelectorAll('[data-lang]').forEach(function (el) {
      el.classList.toggle('on', el.getAttribute('data-lang') === next);
    });
    document.querySelectorAll('.langswitch button').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.dataset.set === next));
    });
    var t = document.querySelector('title[data-title-' + next + ']');
    if (t) document.title = t.getAttribute('data-title-' + next);
  }

  document.addEventListener('DOMContentLoaded', function () {
    apply(lang);
    document.querySelectorAll('.langswitch button').forEach(function (b) {
      b.addEventListener('click', function () {
        try { localStorage.setItem(KEY, b.dataset.set); } catch (e) {}
        apply(b.dataset.set);
      });
    });
  });
})();
