"""Анализ записей с динамика гарнитуры (уровень L4 протокола spike).

Для каждого WAV-файла выводит:
  * верхнюю границу спектра — главный объективный признак профиля:
    ~4 кГц → HFP CVSD, ~8 кГц → HFP mSBC, >=14 кГц → A2DP;
  * общий уровень RMS и разницу с базовой записью (--baseline, обычно P0) — для оценки ducking;
  * для стерео-файлов — корреляцию каналов (около 1.0 означает моно);
  * провалы сигнала (паузы музыки) длиннее --gap-ms. Надёжно только на непрерывном
    сигнале, поэтому для T7b используйте розовый шум, а не музыку.

Пример:
  python -I tools/analyze_capture.py rec/P4_run1.wav rec/P3_run1.wav --baseline rec/P0_run1.wav
"""

import argparse
import json
import sys

import numpy as np
from scipy.io import wavfile
from scipy.signal import welch


def load(path):
    rate, data = wavfile.read(path)
    if data.dtype.kind == "i":
        data = data.astype(np.float64) / np.iinfo(data.dtype).max
    elif data.dtype.kind == "u":
        data = (data.astype(np.float64) - 128.0) / 128.0
    else:
        data = data.astype(np.float64)
    if data.ndim == 1:
        data = data[:, None]
    return rate, data


def db(x):
    return 10.0 * np.log10(np.maximum(x, 1e-20))


def bandwidth_edge(signal, rate, threshold_db):
    """Самая высокая частота, где сглаженная PSD не ниже (уровень 300–3000 Гц − threshold_db)."""
    freqs, psd = welch(signal, fs=rate, nperseg=min(8192, len(signal)))
    # Края дополняем крайними значениями: нули при mode="same" завысили бы уровень в дБ у Найквиста.
    level = np.convolve(np.pad(db(psd), 4, mode="edge"), np.ones(9) / 9, mode="valid")
    band = (freqs >= 300) & (freqs <= 3000)
    reference = np.median(level[band])
    above = np.nonzero(level >= reference - threshold_db)[0]
    return float(freqs[above[-1]]) if len(above) else 0.0


def classify(edge_hz):
    # Пороги с запасом: переходная полоса ресемплера и сглаживание сдвигают границу вверх
    # (на синтетике 8 кГц → ~4.5 кГц, 16 кГц → ~9 кГц).
    if edge_hz < 6000:
        return "узкая полоса — похоже на HFP CVSD"
    if edge_hz < 11000:
        return "~8 кГц — похоже на HFP mSBC (wideband speech)"
    if edge_hz < 14000:
        return "промежуточная полоса — проверить вручную"
    return "широкая полоса — похоже на A2DP"


def rms_dbfs(signal):
    return float(db(np.mean(signal**2)))


def find_gaps(signal, rate, gap_ms):
    frame = max(1, int(rate * 0.01))
    count = len(signal) // frame
    if count == 0:
        return []
    frames = signal[: count * frame].reshape(count, frame)
    levels = db(np.mean(frames**2, axis=1))
    silence = levels < max(np.median(levels) - 35.0, -90.0)
    gaps, start = [], None
    for i, quiet in enumerate(np.append(silence, False)):
        if quiet and start is None:
            start = i
        elif not quiet and start is not None:
            duration = (i - start) * 10
            if duration >= gap_ms:
                gaps.append({"start_s": round(start * 0.01, 2), "duration_ms": duration})
            start = None
    return gaps


def analyze(path, threshold_db, gap_ms, baseline_rms):
    rate, data = load(path)
    mono = data.mean(axis=1)
    edge = bandwidth_edge(mono, rate, threshold_db)
    result = {
        "file": path,
        "sample_rate": rate,
        "channels": data.shape[1],
        "duration_s": round(len(mono) / rate, 2),
        "bandwidth_edge_hz": round(edge),
        "bandwidth_verdict": classify(edge),
        "rms_dbfs": round(rms_dbfs(mono), 1),
        "gaps": find_gaps(mono, rate, gap_ms),
    }
    if baseline_rms is not None:
        result["delta_vs_baseline_db"] = round(result["rms_dbfs"] - baseline_rms, 1)
    if data.shape[1] >= 2:
        left, right = data[:, 0], data[:, 1]
        result["channel_correlation"] = round(float(np.corrcoef(left, right)[0, 1]), 3)
        result["left_minus_right_db"] = round(rms_dbfs(left) - rms_dbfs(right), 1)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", help="WAV-записи с динамика гарнитуры")
    parser.add_argument("--baseline", help="базовая запись (P0) для расчёта разницы уровня")
    parser.add_argument("--threshold", type=float, default=30.0,
                        help="на сколько дБ ниже уровня 300–3000 Гц считать границу полосы (по умолчанию 30)")
    parser.add_argument("--gap-ms", type=int, default=50, help="минимальная длительность провала, мс")
    parser.add_argument("--json", action="store_true", help="вывести JSON вместо текста")
    args = parser.parse_args()
    # Консоль Windows по умолчанию не в UTF-8.
    sys.stdout.reconfigure(encoding="utf-8")

    baseline_rms = None
    if args.baseline:
        _, base = load(args.baseline)
        baseline_rms = rms_dbfs(base.mean(axis=1))

    results = [analyze(f, args.threshold, args.gap_ms, baseline_rms) for f in args.files]
    if args.json:
        json.dump(results, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return
    for r in results:
        print(f"\n{r['file']}  ({r['sample_rate']} Гц, {r['channels']} кан., {r['duration_s']} с)")
        print(f"  Граница спектра: {r['bandwidth_edge_hz']} Гц — {r['bandwidth_verdict']}")
        print(f"  RMS: {r['rms_dbfs']} dBFS", end="")
        if "delta_vs_baseline_db" in r:
            print(f"  (Δ к базе: {r['delta_vs_baseline_db']:+} дБ)", end="")
        print()
        if "channel_correlation" in r:
            print(f"  Корреляция L/R: {r['channel_correlation']} · L−R: {r['left_minus_right_db']:+} дБ")
        if r["gaps"]:
            listed = ", ".join(f"{g['start_s']} с/{g['duration_ms']} мс" for g in r["gaps"][:20])
            print(f"  Провалы ({len(r['gaps'])}): {listed}")
        else:
            print("  Провалов нет")


if __name__ == "__main__":
    main()
