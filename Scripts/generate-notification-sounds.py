#!/usr/bin/env python3
"""Sismik bildirim seslerini sentezler (Sismik/Resources/*.caf).

Kullanım: python3 Scripts/generate-notification-sounds.py

Standart sesler (4) deprem bildirimlerinde, kritik sesler (3) sessiz modu aşan
kritik uyarılarda çalar. Dosya adları sunucuyla sözleşmedir
(functions/src/push-routes.ts `IOS_NOTIFICATION_SOUNDS` /
`IOS_CRITICAL_SOUNDS`): eski adlar korunur, yoksa önceki sürümdeki cihaz
tanımadığı adı alır ve iOS varsayılan sese düşer.

Yalnızca standart kütüphane kullanır; WAV üretir, macOS `afconvert` ile
16 bit PCM CAF'a çevirir. iOS bildirim sesi 30 sn'den kısa olmalı.
"""
import math
import os
import random
import struct
import subprocess
import tempfile
import wave

RATE = 44_100
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Sismik', 'Resources')


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def mix_into(buffer, samples, at):
    start = int(at * RATE)
    if len(buffer) < start + len(samples):
        buffer.extend([0.0] * (start + len(samples) - len(buffer)))
    for i, value in enumerate(samples):
        buffer[start + i] += value


def tone(freq, seconds, partials=((1, 1.0),), attack=0.004, decay=None, release=0.02, gain=1.0):
    """Toplamsal ton. `decay` verilirse üstel sönüm (s), yoksa düz gövde."""
    count = int(seconds * RATE)
    out = []
    for i in range(count):
        t = i / RATE
        env = min(1.0, t / attack) if attack > 0 else 1.0
        if decay:
            env *= math.exp(-t / decay)
        remaining = seconds - t
        if remaining < release:
            env *= max(0.0, remaining / release)
        value = 0.0
        for ratio, amp in partials:
            f = freq * ratio
            if f < RATE / 2:
                value += amp * math.sin(2 * math.pi * f * t)
        out.append(value * env * gain)
    return out


def fm_bell(freq, seconds, index=2.2, ratio=1.4, decay=0.5, gain=1.0):
    count = int(seconds * RATE)
    out = []
    for i in range(count):
        t = i / RATE
        env = min(1.0, t / 0.003) * math.exp(-t / decay)
        mod = index * math.exp(-t / (decay * 0.6)) * math.sin(2 * math.pi * freq * ratio * t)
        out.append(gain * env * math.sin(2 * math.pi * freq * t + mod))
    return out


def sweep(f0, f1, seconds, partials=((1, 1.0), (2, 0.35), (3, 0.2)), gain=1.0):
    count = int(seconds * RATE)
    out = []
    phase = 0.0
    for i in range(count):
        t = i / RATE
        f = f0 + (f1 - f0) * (t / seconds)
        phase += 2 * math.pi * f / RATE
        value = sum(amp * math.sin(ratio * phase) for ratio, amp in partials)
        out.append(gain * value)
    return out


def room(samples, delays=(0.031, 0.047, 0.071), feedback=0.28, wet=0.18):
    """Hafif oda yankısı: sesin kuru ve 'dijital' duyulmasını önler."""
    out = list(samples) + [0.0] * int(0.4 * RATE)
    taps = [int(d * RATE) for d in delays]
    reverb = [0.0] * len(out)
    for i in range(len(out)):
        acc = 0.0
        for tap in taps:
            if i >= tap:
                acc += out[i - tap] + feedback * reverb[i - tap]
        reverb[i] = acc / len(taps)
    return [dry + wet * rev for dry, rev in zip(out, reverb)]


def normalize(samples, peak_db):
    peak = max(abs(v) for v in samples) or 1.0
    target = 10 ** (peak_db / 20)
    return [v / peak * target for v in samples]


def fade_tail(samples, seconds=0.03):
    n = int(seconds * RATE)
    for i in range(min(n, len(samples))):
        samples[-1 - i] *= i / n
    return samples


def write(name, samples, peak_db):
    samples = fade_tail(normalize(samples, peak_db))
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, 'sound.wav')
        with wave.open(wav_path, 'wb') as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, v)) * 32767)) for v in samples))
        target = os.path.join(ROOT, name)
        subprocess.run(['afconvert', '-f', 'caff', '-d', 'LEI16', wav_path, target], check=True)
    print(f'{name}: {len(samples) / RATE:.2f} sn')


MARIMBA = ((1, 1.0), (3.93, 0.28), (9.2, 0.06))


# MARK: - Standart sesler (-3 dBFS)

def sismik():
    """İmza ses: yükselen iki notalı marimba (La5 → Mi6), yumuşak tekrar."""
    out = silence(1.6)
    mix_into(out, tone(880.0, 0.9, MARIMBA, decay=0.28), 0.0)
    mix_into(out, tone(1318.5, 1.1, MARIMBA, decay=0.34), 0.16)
    mix_into(out, tone(1318.5, 0.8, MARIMBA, decay=0.3, gain=0.35), 0.62)
    return room(out)


def pulse():
    """Nabız: üç kısa vuruş, ardından daha pes, uzun bir son vuruş."""
    out = silence(1.5)
    beat = ((1, 1.0), (2, 0.3), (3, 0.08))
    for k, at in enumerate((0.0, 0.2, 0.4)):
        mix_into(out, tone(740.0, 0.16, beat, attack=0.003, decay=0.06, gain=0.9 - 0.1 * k), at)
    mix_into(out, tone(554.4, 0.8, beat, attack=0.004, decay=0.25), 0.62)
    return room(out, wet=0.14)


def signal():
    """Sinyal: parlak çan arpeji (Do6–Mi6–Sol6)."""
    out = silence(2.0)
    for at, freq in ((0.0, 1046.5), (0.11, 1318.5), (0.22, 1568.0)):
        mix_into(out, fm_bell(freq, 1.4, decay=0.45, gain=0.8), at)
    mix_into(out, fm_bell(2093.0, 1.2, index=1.2, decay=0.35, gain=0.3), 0.36)
    return room(out, wet=0.22)


def deep():
    """Derin: tok, gong benzeri iki vuruş. Telefon hoparlörü 300 Hz altını
    zayıf verdiği için temel frekansın üst harmonikleri güçlü tutulur."""
    out = silence(2.5)
    body = ((1, 0.7), (2, 0.9), (3, 0.6), (4.2, 0.35), (5.4, 0.2))
    mix_into(out, tone(196.0, 2.2, body, attack=0.012, decay=0.75), 0.0)
    mix_into(out, tone(261.6, 1.6, body, attack=0.012, decay=0.55, gain=0.7), 0.42)
    rng = random.Random(7)
    rumble = [rng.uniform(-1, 1) * math.exp(-i / (0.12 * RATE)) * 0.12 for i in range(int(0.4 * RATE))]
    smooth = 0.0
    for i, value in enumerate(rumble):  # kaba alçak geçiren
        smooth += 0.08 * (value - smooth)
        rumble[i] = smooth * 4
    mix_into(out, rumble, 0.0)
    return room(out, wet=0.2)


# MARK: - Kritik sesler (-0.5 dBFS, ~7 sn)

ALARM = ((1, 1.0), (3, 0.33), (5, 0.18), (7, 0.1))


def critical_alarm():
    """Alarm: iki tonlu (Si5/Sol5) kesintisiz uyarı; sirenden daha dar bantlı,
    uzaktan bile 'acil' diye tanınır."""
    out = []
    step = 0.26
    for k in range(int(7.0 / step)):
        out.extend(tone(987.8 if k % 2 == 0 else 784.0, step, ALARM, attack=0.006, release=0.012))
    return out


def critical_siren():
    """Siren: 650 → 1500 Hz yükselip alçalan tarama, beş devir."""
    out = []
    for _ in range(5):
        out.extend(sweep(650, 1500, 0.7))
        out.extend(sweep(1500, 650, 0.7))
    return out


def critical_beacon():
    """İşaret: üç hızlı bip + iki notalı çan, 1,2 sn'de bir tekrar."""
    out = silence(7.2)
    beep = ((1, 1.0), (2, 0.25), (3, 0.15))
    for cycle in range(6):
        base = cycle * 1.2
        for k in range(3):
            mix_into(out, tone(1397.0, 0.075, beep, attack=0.002, release=0.01), base + k * 0.12)
        mix_into(out, fm_bell(880.0, 0.5, decay=0.25, gain=0.8), base + 0.42)
        mix_into(out, fm_bell(1174.7, 0.6, decay=0.3, gain=0.8), base + 0.62)
    return out


if __name__ == '__main__':
    write('bildirim.caf', sismik(), -3)
    write('sismik_pulse.caf', pulse(), -3)
    write('sismik_signal.caf', signal(), -3)
    write('sismik_deep.caf', deep(), -3)
    write('sismik_critical_alarm.caf', critical_alarm(), -0.5)
    write('sismik_critical_siren.caf', critical_siren(), -0.5)
    write('sismik_critical_beacon.caf', critical_beacon(), -0.5)
