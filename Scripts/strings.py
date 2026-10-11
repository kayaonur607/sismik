#!/usr/bin/env python3
"""Sismik çeviri kataloğu aracı (Sismik/AppStrings.xcstrings).

Uygulamanın metinleri Xcode'un String Catalog biçiminde tutulur; derlemede her
dil için `.lproj` paketleri üretilir ve uygulama bunları Apple'ın standart
yerelleştirme altyapısıyla okur (`L()` → `Bundle.localizedString`). Çeviri
yapay zekâ ile değil, katalog üzerinde (Xcode'un String Catalog düzenleyicisi,
XLIFF dışa/içe aktarımı ya da bu araç) yapılır.

Kullanım:
    python3 Scripts/strings.py check              # eksik çeviri ve yer tutucu uyumsuzluğu
    python3 Scripts/strings.py missing el         # bir dilde eksik anahtarlar (JSON, İngilizce kaynakla)
    python3 Scripts/strings.py merge ceviri.json  # {"anahtar": {"el": "...", ...}} dosyasını kataloğa ekler
    python3 Scripts/strings.py export en > en.json  # bir dilin tüm metinleri (çevirmene göndermek için)

Yeni dil eklerken: LANGUAGES listesine ekle, `missing <dil>` çıktısını çevir,
`merge` ile ekle, AppLanguage'a (AppPreferences.swift) durumu ekle ve
`python3 Scripts/generate-widget-strings.py` çalıştır.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sismik" / "AppStrings.xcstrings"
SOURCE_LANGUAGE = "en"
# Katalogdaki dil kimlikleri (Xcode/lproj adları).
LANGUAGES = ["tr", "en", "de", "es", "fr", "it", "ja", "ru", "ar",
             "el", "pt-BR", "id", "ko", "zh-Hans"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfFeEgGcCsSpaA]")


def load() -> dict:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def save(catalog: dict) -> None:
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    CATALOG.write_text(text + "\n", encoding="utf-8")


def value(entry: dict, language: str) -> str | None:
    unit = entry.get("localizations", {}).get(language, {}).get("stringUnit")
    return unit.get("value") if unit else None


def set_value(entry: dict, language: str, text: str) -> None:
    entry.setdefault("localizations", {})[language] = {
        "stringUnit": {"state": "translated", "value": text}
    }


def placeholders(text: str) -> list[str]:
    # Konumlu (%1$@) ve konumsuz yer tutucular tür bazında karşılaştırılır.
    found = [re.sub(r"\d+\$", "", match) for match in PLACEHOLDER.findall(text.replace("%%", ""))]
    return sorted(found)


def check() -> int:
    catalog = load()
    problems = 0
    for key, entry in catalog["strings"].items():
        source = value(entry, SOURCE_LANGUAGE) or value(entry, "tr") or key
        expected = placeholders(source)
        for language in LANGUAGES:
            text = value(entry, language)
            if text is None:
                print(f"eksik  [{language}] {key}")
                problems += 1
            elif placeholders(text) != expected:
                print(f"yer tutucu [{language}] {key}: {placeholders(text)} ≠ {expected}")
                problems += 1
    print(f"{len(catalog['strings'])} anahtar, {len(LANGUAGES)} dil, {problems} sorun.")
    return 1 if problems else 0


def missing(language: str) -> int:
    catalog = load()
    result = {}
    for key, entry in catalog["strings"].items():
        if value(entry, language) is None:
            result[key] = value(entry, SOURCE_LANGUAGE) or value(entry, "tr") or key
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


def export(language: str) -> int:
    catalog = load()
    print(json.dumps({k: value(e, language) for k, e in catalog["strings"].items()},
                     ensure_ascii=False, indent=1))
    return 0


def merge(path: str) -> int:
    catalog = load()
    updates = json.loads(Path(path).read_text(encoding="utf-8"))
    count = 0
    for key, languages in updates.items():
        entry = catalog["strings"].setdefault(key, {"extractionState": "manual"})
        for language, text in languages.items():
            if language not in LANGUAGES:
                raise SystemExit(f"Bilinmeyen dil: {language}")
            set_value(entry, language, text)
            count += 1
    save(catalog)
    print(f"{count} çeviri eklendi.")
    return 0


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "check":
        sys.exit(check())
    if command == "missing" and len(sys.argv) > 2:
        sys.exit(missing(sys.argv[2]))
    if command == "export" and len(sys.argv) > 2:
        sys.exit(export(sys.argv[2]))
    if command == "merge" and len(sys.argv) > 2:
        sys.exit(merge(sys.argv[2]))
    print(__doc__)
    sys.exit(2)
