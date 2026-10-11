#!/usr/bin/env python3
"""Widget metin tablosunu Sismik/AppStrings.xcstrings'ten üretir.

Widget uzantısı uygulamanın çeviri tablosunu göremez; kullandığı birkaç
anahtar bu betikle SismikWidget/WidgetStrings.swift'e aktarılır. Anahtar
eklendiğinde ya da çeviri değiştiğinde yeniden çalıştır:

    python3 Scripts/generate-widget-strings.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEYS = [
    "recent.title",
    "widget.empty", "widget.emptyFiltered", "widget.badge.all",
    "widget.stats.last24h", "widget.stats.totalCount", "widget.stats.feltCount",
    "widget.stats.activeRegion", "widget.stats.maxQuake",
    "widget.time.justnow", "widget.time.min", "widget.time.hour", "widget.time.day",
    "magnitude.micro", "magnitude.minor", "magnitude.light", "magnitude.moderate",
    "magnitude.strong", "magnitude.major", "magnitude.great",
    "depth",
    "activity.forecast", "activity.title", "activity.aftershocks", "activity.largest",
    "activity.last", "activity.none", "activity.updating", "activity.ended",
]
# Uygulama dil kodu → katalogdaki dil (AppLanguage.bundleLocalizations ile aynı).
LANGS = {"tr": "tr", "en": "en", "de": "de", "es": "es", "fr": "fr", "it": "it",
         "ja": "ja", "ru": "ru", "ar": "ar", "el": "el", "pt": "pt-BR",
         "id": "id", "ko": "ko", "zh": "zh-Hans"}

catalog = json.loads((ROOT / "Sismik/AppStrings.xcstrings").read_text(encoding="utf-8"))["strings"]
missing = [k for k in KEYS if k not in catalog]
if missing:
    raise SystemExit(f"AppStrings.xcstrings'te eksik anahtar: {missing}")

def value(key: str, language: str):
    unit = catalog[key].get("localizations", {}).get(language, {}).get("stringUnit")
    return unit["value"] if unit else None

def literal(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)

lines = [
    "// Bu dosya Scripts/generate-widget-strings.py ile üretilir; elle düzenleme.",
    "// Kaynak: Sismik/AppStrings.xcstrings",
    "",
    "enum WidgetStrings {",
    "    static let table: [String: [String: String]] = [",
]
for key in KEYS:
    values = ", ".join(f"{literal(code)}: {literal(value(key, lang) or value(key, 'en') or value(key, 'tr'))}"
                       for code, lang in LANGS.items())
    lines.append(f"        {literal(key)}: [{values}],")
lines += ["    ]", "}", ""]
(ROOT / "SismikWidget/WidgetStrings.swift").write_text("\n".join(lines), encoding="utf-8")
print(f"{len(KEYS)} anahtar yazıldı.")
