#!/usr/bin/env python3
"""Tweet için yer verisini üretir (Natural Earth, kamu malı, atıf gerekmez):
- functions/assets/data/places.json: dünya yerleşimleri
  [ad, eyalet/il, ülke, enlem, boylam] — depremi koordinattan adlandırmak için.
- functions/assets/data/turkiye.json: Türkiye sınır poligonları
  [[[boylam, enlem], ...], ...] — "Türkiye'de mi?" kararı için.

Kullanım: python3 Scripts/build-places.py [places.geojson] [admin0_50m.geojson]
Dosya verilmezse GitHub'daki natural-earth-vector deposundan indirilir.
"""
import json, sys, urllib.request, os

URL = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_populated_places_simple.geojson'
ADMIN0_URL = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson'
src = sys.argv[1] if len(sys.argv) > 1 else None
data = json.load(open(src)) if src else json.load(urllib.request.urlopen(URL))
rows = []
for feature in data['features']:
    p = feature['properties']
    name = (p.get('name') or p.get('nameascii') or '').strip()
    if not name:
        continue
    rows.append([name, (p.get('adm1name') or '').strip(), (p.get('adm0name') or '').strip(),
                 round(float(p['latitude']), 3), round(float(p['longitude']), 3)])
rows.sort(key=lambda r: (r[2], r[0]))
out = os.path.join(os.path.dirname(__file__), '..', 'functions', 'assets', 'data', 'places.json')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(rows, f, ensure_ascii=False, separators=(',', ':'))
print(len(rows), 'yer ->', os.path.relpath(out))

admin_src = sys.argv[2] if len(sys.argv) > 2 else None
admin = json.load(open(admin_src)) if admin_src else json.load(urllib.request.urlopen(ADMIN0_URL))
turkey = next(f for f in admin['features'] if f['properties'].get('ADM0_A3') == 'TUR')['geometry']
polygons = turkey['coordinates'] if turkey['type'] == 'MultiPolygon' else [turkey['coordinates']]
rings = [[[round(x, 3), round(y, 3)] for x, y in polygon[0]] for polygon in polygons]
out = os.path.join(os.path.dirname(__file__), '..', 'functions', 'assets', 'data', 'turkiye.json')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(rings, f, separators=(',', ':'))
print(len(rings), 'poligon,', sum(len(r) for r in rings), 'nokta ->', os.path.relpath(out))
