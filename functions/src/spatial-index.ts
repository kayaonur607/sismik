import {
  CachedPushDevice,
  Earthquake,
  NotificationMatch,
  feltReachKm,
  notificationMatch
} from './worker-utils';

/// 1 derece enlem yaklaşık 111.19 km'dir.
const KM_PER_DEG_LAT = 111.19;
/// Ekvatorda 1 derece boylam yaklaşık 111.32 km'dir.
const KM_PER_DEG_LON_EQUATOR = 111.32;
/// Kullanıcının seçebildiği en düşük dünya geneli eşik (`/register` 5.0–8.0
/// arasına sıkıştırır). Aday kapısı bundan yüksek olursa eşiğini 5.x seçen
/// cihaz o büyüklükteki uzak depremleri hiç duymaz; kesin eşik kontrolü
/// `notificationMatch`'te.
const WORLD_MAJOR_MIN_THRESHOLD = 5.0;

function cellKey(latFloor: number, lonFloor: number): string {
  return `${latFloor},${lonFloor}`;
}

function normalizeLon(lon: number): number {
  let l = lon;
  while (l < -180) l += 360;
  while (l >= 180) l -= 360;
  return Math.floor(l);
}

/// Bounding box hücrelerini hesaplar.
function computeBoundingCells(lat: number, lon: number, radiusKm: number): string[] {
  const cells: string[] = [];
  const deltaLat = Math.min(90, Math.ceil(radiusKm / KM_PER_DEG_LAT));
  const minLat = Math.max(-90, Math.floor(lat - deltaLat));
  const maxLat = Math.min(89, Math.floor(lat + deltaLat));

  const maxAbsLat = Math.max(Math.abs(lat - deltaLat), Math.abs(lat + deltaLat));
  
  // Kutuplara çok yakın bölgelerde (>= 80°) boylam derecesi aşırı daralır.
  // Bu durumda o enlem dilimindeki tüm boylam hücrelerini dahil ederiz.
  if (maxAbsLat >= 80) {
    for (let cLat = minLat; cLat <= maxLat; cLat++) {
      for (let cLon = -180; cLon < 180; cLon++) {
        cells.push(cellKey(cLat, cLon));
      }
    }
    return cells;
  }

  const cosLat = Math.cos(maxAbsLat * Math.PI / 180);
  const kmPerDegLon = KM_PER_DEG_LON_EQUATOR * Math.max(0.1, cosLat);
  const deltaLon = Math.min(180, Math.ceil(radiusKm / kmPerDegLon));

  const baseLonFloor = Math.floor(lon);
  const minLon = baseLonFloor - deltaLon;
  const maxLon = baseLonFloor + deltaLon;

  for (let cLat = minLat; cLat <= maxLat; cLat++) {
    for (let rawLon = minLon; rawLon <= maxLon; rawLon++) {
      cells.push(cellKey(cLat, normalizeLon(rawLon)));
    }
  }

  return cells;
}

/**
 * SpatialGridIndex:
 * Dünya koordinat sistemini 1°x1° hücrelere ayıran, bellek içi yüksek başarımlı uzamsal indeks.
 * Cihazların konum ve yarıçaplarını hücrelere bağlayarak, yeni bir deprem olduğunda
 * on binlerce cihazı O(N) ile gezmek yerine O(1) hücre sorgusuyla adayları tespit eder.
 */
export class SpatialGridIndex {
  /// Hücre anahtarı -> Bu hücreyi kapsayan cihaz anahtarları kümesi
  private grid = new Map<string, Set<string>>();
  /// Cihaz anahtarı -> Cihazın dahil olduğu hücre anahtarları kümesi (ters indeks)
  private deviceCells = new Map<string, Set<string>>();
  /// Cihaz anahtarı -> CachedPushDevice nesnesi
  private devices = new Map<string, CachedPushDevice>();
  /// Dünya geneli büyük deprem bildirimlerini açık tutan cihazlar
  private worldMajorDeviceKeys = new Set<string>();
  /// Eski kuraldaki (2.0.9 ve öncesi) cihazlar: kuralları bir yarıçapa
  /// indirgenemiyor — "tüm bölgeler" akışı, Türkiye kutusundaki öncelikli
  /// deprem eşiği yakınlık filtresini aşıyor. Her depremde aday sayılırlar;
  /// asıl eleme `notificationMatch`'te. Izgaraya konmadıklarında üretimde
  /// push alan cihazların çoğu (koordinatsız "tüm bölgeler") hiç bildirim
  /// almıyordu.
  private legacyDeviceKeys = new Set<string>();

  get size(): number {
    return this.devices.size;
  }

  clear(): void {
    this.grid.clear();
    this.deviceCells.clear();
    this.devices.clear();
    this.worldMajorDeviceKeys.clear();
    this.legacyDeviceKeys.clear();
  }

  addOrUpdateDevice(device: CachedPushDevice): void {
    this.removeDevice(device.key);

    this.devices.set(device.key, device);
    const assignedCells = new Set<string>();

    if (device.prefs.worldMajorEnabled) {
      this.worldMajorDeviceKeys.add(device.key);
    }
    if (device.prefs.legacy) {
      this.legacyDeviceKeys.add(device.key);
    }

    const registerLocation = (lat: number, lon: number, radiusKm: number) => {
      if (!Number.isFinite(lat) || !Number.isFinite(lon) || !Number.isFinite(radiusKm)) return;
      if (Math.abs(lat) > 90 || Math.abs(lon) > 180 || radiusKm <= 0) return;
      const cells = computeBoundingCells(lat, lon, radiusKm);
      for (const cell of cells) {
        assignedCells.add(cell);
        let cellSet = this.grid.get(cell);
        if (!cellSet) {
          cellSet = new Set();
          this.grid.set(cell, cellSet);
        }
        cellSet.add(device.key);
      }
    };

    // 1. Kayıtlı Yerler (Places)
    if (Array.isArray(device.prefs.places)) {
      for (const place of device.prefs.places) {
        // Hissedilir şiddet kurallı yer, uzaktaki güçlü depremde de aday olmalı.
        registerLocation(place.lat, place.lon,
          place.feltIntensity ? Math.max(place.radiusKm, feltReachKm(place.feltIntensity)) : place.radiusKm);
      }
    }

    // 2. Artçı Takibi (Aftershock Watch)
    const watch = device.prefs.aftershockWatch;
    if (watch && Number.isFinite(watch.latitude) && Number.isFinite(watch.longitude)) {
      registerLocation(watch.latitude, watch.longitude, watch.radiusKm || 150);
    }

    this.deviceCells.set(device.key, assignedCells);
  }

  removeDevice(deviceKey: string): void {
    this.devices.delete(deviceKey);
    this.worldMajorDeviceKeys.delete(deviceKey);
    this.legacyDeviceKeys.delete(deviceKey);

    const assignedCells = this.deviceCells.get(deviceKey);
    if (assignedCells) {
      for (const cell of assignedCells) {
        const cellSet = this.grid.get(cell);
        if (cellSet) {
          cellSet.delete(deviceKey);
          if (cellSet.size === 0) {
            this.grid.delete(cell);
          }
        }
      }
      this.deviceCells.delete(deviceKey);
    }
  }

  /**
   * Depremin merkez üssünü içeren hücredeki cihazları, eski kuraldaki
   * cihazları ve (büyüklük yetiyorsa) dünya geneli dinleyenleri döner.
   */
  queryCandidates(lat: number, lon: number, magnitude: number): CachedPushDevice[] {
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return [];

    const latFloor = Math.max(-90, Math.min(89, Math.floor(lat)));
    const lonFloor = normalizeLon(lon);
    const primaryCell = cellKey(latFloor, lonFloor);

    const candidateKeys = new Set<string>();

    const cellSet = this.grid.get(primaryCell);
    if (cellSet) {
      for (const key of cellSet) {
        candidateKeys.add(key);
      }
    }

    for (const key of this.legacyDeviceKeys) {
      candidateKeys.add(key);
    }

    if (magnitude >= WORLD_MAJOR_MIN_THRESHOLD) {
      for (const key of this.worldMajorDeviceKeys) {
        candidateKeys.add(key);
      }
    }

    const result: CachedPushDevice[] = [];
    for (const key of candidateKeys) {
      const dev = this.devices.get(key);
      if (dev) result.push(dev);
    }
    return result;
  }

  /**
   * Bir deprem için aday cihazları çeker ve tam notificationMatch filtrelemesinden
   * geçirerek sadece gerçekten bildirim alması gereken cihazları döner.
   */
  findMatches(
    quake: Earthquake,
    now: number = Date.now(),
    isProviderUnavailable?: (provider: string) => boolean
  ): Array<{ device: CachedPushDevice; match: NotificationMatch }> {
    const candidates = this.queryCandidates(quake.lat, quake.lon, quake.magnitude);
    const matches: Array<{ device: CachedPushDevice; match: NotificationMatch }> = [];

    for (const device of candidates) {
      const legacy = device.prefs.legacy;
      const ignoreSource = Boolean(legacy?.sourceFallbackEnabled)
        && Boolean(isProviderUnavailable && isProviderUnavailable(legacy!.source));

      const match = notificationMatch(quake, device.prefs, now, ignoreSource);
      if (match) {
        matches.push({ device, match });
      }
    }

    return matches;
  }
}
