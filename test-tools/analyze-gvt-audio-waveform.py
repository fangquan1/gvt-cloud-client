#!/usr/bin/env python3
"""Analyze recorded GVT audio for waveform mismatch and short pop/crackle events.

This tool intentionally uses only the Python standard library so it can run on
plain Windows test clients. It reads 16-bit PCM WAV files, aligns recorded audio
to the deterministic reference pulses, detects short high-frequency impulses,
and writes JSON/CSV/SVG artifacts for the HTML report.
"""

from __future__ import annotations

import argparse
import array
import csv
import datetime as _dt
import html
import json
import math
import os
import statistics
import sys
import wave


def read_pcm16_wav(path: str) -> dict:
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        sample_rate = wav.getframerate()
        sample_width = wav.getsampwidth()
        frames = wav.getnframes()
        if sample_width != 2:
            raise ValueError(f"{path} must be 16-bit PCM WAV, got sample width {sample_width}")
        raw = wav.readframes(frames)

    values = array.array("h")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()

    samples = []
    scale = 32768.0
    for i in range(frames):
        acc = 0.0
        base = i * channels
        for ch in range(channels):
            acc += values[base + ch] / scale
        samples.append(acc / channels)

    return {
        "path": path,
        "channels": channels,
        "sample_rate": sample_rate,
        "frames": frames,
        "duration_sec": frames / float(sample_rate),
        "samples": samples,
    }


def rms(values: list[float]) -> float:
    if not values:
        return 0.0
    return math.sqrt(sum(v * v for v in values) / float(len(values)))


def detect_pulses(samples: list[float], sample_rate: int, min_gap_sec: float = 1.0) -> list[float]:
    window = max(64, int(sample_rate * 0.010))
    hop = max(16, int(sample_rate * 0.005))
    frames = []
    max_rms = 0.0

    for i in range(0, len(samples) - window + 1, hop):
        total = 0.0
        for value in samples[i : i + window]:
            total += value * value
        frame_rms = math.sqrt(total / float(window))
        max_rms = max(max_rms, frame_rms)
        frames.append((i, frame_rms))

    if max_rms < 0.005:
        return []

    threshold = max(0.025, max_rms * 0.42)
    pulses = []
    last_time = -999.0
    in_pulse = False
    for index, frame_rms in frames:
        time_sec = index / float(sample_rate)
        if frame_rms >= threshold:
            if not in_pulse and (time_sec - last_time) >= min_gap_sec:
                pulses.append(time_sec)
                last_time = time_sec
            in_pulse = True
        else:
            in_pulse = False
    return pulses


def align_by_pulses(reference: dict, recorded: dict) -> dict:
    ref_pulses = detect_pulses(reference["samples"], reference["sample_rate"])
    rec_pulses = detect_pulses(recorded["samples"], recorded["sample_rate"])
    if reference["sample_rate"] != recorded["sample_rate"]:
        raise ValueError(
            f"sample rates differ: reference={reference['sample_rate']} recorded={recorded['sample_rate']}"
        )

    sample_rate = reference["sample_rate"]
    offset_sec = 0.0
    if ref_pulses and rec_pulses:
        offset_sec = rec_pulses[0] - ref_pulses[0]
    offset_samples = int(round(offset_sec * sample_rate))
    ref_start = max(0, -offset_samples)
    rec_start = max(0, offset_samples)
    count = min(len(reference["samples"]) - ref_start, len(recorded["samples"]) - rec_start)
    if count <= sample_rate:
        raise ValueError(f"not enough overlap after alignment: count={count}")

    return {
        "sample_rate": sample_rate,
        "reference_pulses_sec": ref_pulses,
        "recorded_pulses_sec": rec_pulses,
        "offset_sec": offset_sec,
        "offset_samples": offset_samples,
        "reference_start": ref_start,
        "recorded_start": rec_start,
        "count": count,
        "duration_sec": count / float(sample_rate),
    }


def excluded_time_fn(pulse_times: list[float], radius_sec: float):
    pulse_times = sorted(pulse_times)
    cursor = 0

    def excluded(time_sec: float) -> bool:
        nonlocal cursor
        while cursor + 1 < len(pulse_times) and pulse_times[cursor] < time_sec - radius_sec:
            cursor += 1
        for idx in (cursor - 1, cursor, cursor + 1):
            if 0 <= idx < len(pulse_times) and abs(time_sec - pulse_times[idx]) <= radius_sec:
                return True
        return False

    return excluded


def is_edge_excluded(time_sec: float, duration_sec: float, edge_ms: float) -> bool:
    edge_sec = edge_ms / 1000.0
    return time_sec < edge_sec or time_sec > (duration_sec - edge_sec)


def robust_threshold(recorded_samples: list[float], start: int, count: int, sample_rate: int, pulses: list[float], args) -> dict:
    excluded = excluded_time_fn(pulses, args.exclude_pulse_ms / 1000.0)
    duration_sec = count / float(sample_rate)
    sampled = []
    for i in range(1, count, max(1, args.threshold_stride)):
        time_sec = i / float(sample_rate)
        if excluded(time_sec) or is_edge_excluded(time_sec, duration_sec, args.edge_exclude_ms):
            continue
        delta = abs(recorded_samples[start + i] - recorded_samples[start + i - 1])
        sampled.append(delta)

    if not sampled:
        median = 0.0
        mad = 0.0
    else:
        median = statistics.median(sampled)
        mad = statistics.median(abs(value - median) for value in sampled)
    threshold = max(args.min_pop_delta, median + args.pop_mad * max(mad, 1e-7))
    return {"median_delta": median, "mad_delta": mad, "threshold_delta": threshold, "sampled_deltas": len(sampled)}


def detect_pop_events(recorded_samples: list[float], align: dict, pulses: list[float], args) -> dict:
    sample_rate = align["sample_rate"]
    start = align["recorded_start"]
    count = align["count"]
    duration_sec = align["duration_sec"]
    threshold_info = robust_threshold(recorded_samples, start, count, sample_rate, pulses, args)
    threshold = threshold_info["threshold_delta"]
    excluded = excluded_time_fn(pulses, args.exclude_pulse_ms / 1000.0)
    merge_gap = max(1, int(sample_rate * args.merge_gap_ms / 1000.0))
    max_duration_ms = args.max_pop_duration_ms

    events = []
    current = None
    last_hit = -999999
    max_score = 0.0
    score_series = []
    score_window = max(1, int(sample_rate * args.score_hop_ms / 1000.0))
    score_max = 0.0
    score_start = 1

    def finish_event(event):
        if not event:
            return
        duration_ms = (event["end_index"] - event["start_index"] + 1) * 1000.0 / sample_rate
        if duration_ms <= max_duration_ms:
            event["time_sec"] = event["peak_index"] / float(sample_rate)
            event["duration_ms"] = duration_ms
            event["peak_delta"] = event["peak_delta"]
            event["peak_abs"] = event["peak_abs"]
            event["score"] = event["peak_delta"] / threshold if threshold > 0 else 0.0
            event["severe"] = event["score"] >= args.severe_score
            events.append(event)

    for i in range(1, count):
        time_sec = i / float(sample_rate)
        if excluded(time_sec) or is_edge_excluded(time_sec, duration_sec, args.edge_exclude_ms):
            hit = False
            delta = 0.0
            abs_value = 0.0
        else:
            value = recorded_samples[start + i]
            prev = recorded_samples[start + i - 1]
            delta = abs(value - prev)
            abs_value = abs(value)
            hit = delta >= threshold

        score = delta / threshold if threshold > 0 else 0.0
        max_score = max(max_score, score)
        score_max = max(score_max, score)
        if i - score_start >= score_window:
            score_series.append((score_start / float(sample_rate), score_max))
            score_start = i
            score_max = 0.0

        if hit:
            if current is None or (i - last_hit) > merge_gap:
                finish_event(current)
                current = {
                    "start_index": i,
                    "end_index": i,
                    "peak_index": i,
                    "peak_delta": delta,
                    "peak_abs": abs_value,
                }
            else:
                current["end_index"] = i
                if delta > current["peak_delta"]:
                    current["peak_delta"] = delta
                    current["peak_abs"] = abs_value
                    current["peak_index"] = i
            last_hit = i
    finish_event(current)
    if score_start < count:
        score_series.append((score_start / float(sample_rate), score_max))

    event_times = [event["time_sec"] for event in events]
    intervals = [event_times[i] - event_times[i - 1] for i in range(1, len(event_times))]
    periodic = False
    periodic_confidence = 0.0
    interval_mean = None
    interval_cv = None
    if len(intervals) >= 3:
        filtered = [value for value in intervals if args.min_period_ms / 1000.0 <= value <= args.max_period_ms / 1000.0]
        if len(filtered) >= 3:
            interval_mean = sum(filtered) / len(filtered)
            stdev = statistics.pstdev(filtered) if len(filtered) > 1 else 0.0
            interval_cv = stdev / interval_mean if interval_mean > 0 else None
            if interval_cv is not None:
                periodic_confidence = max(0.0, min(1.0, 1.0 - interval_cv / args.periodic_cv_for_zero_confidence))
                periodic = periodic_confidence >= args.periodic_confidence_threshold

    severe_count = sum(1 for event in events if event["severe"])
    passed = (
        len(events) <= args.max_pop_events
        and severe_count <= args.max_severe_pop_events
        and not periodic
    )

    return {
        "pass": passed,
        "events": events,
        "event_count": len(events),
        "severe_event_count": severe_count,
        "max_score": max_score,
        "threshold": threshold_info,
        "score_series": score_series,
        "periodic": {
            "detected": periodic,
            "confidence": periodic_confidence,
            "mean_interval_ms": interval_mean * 1000.0 if interval_mean is not None else None,
            "interval_cv": interval_cv,
        },
        "thresholds": {
            "max_pop_events": args.max_pop_events,
            "max_severe_pop_events": args.max_severe_pop_events,
            "severe_score": args.severe_score,
            "periodic_confidence_threshold": args.periodic_confidence_threshold,
            "exclude_pulse_ms": args.exclude_pulse_ms,
            "edge_exclude_ms": args.edge_exclude_ms,
        },
    }


def downsample_waveforms(reference: dict, recorded: dict, align: dict, points: int, pop_scores: list[tuple[float, float]]):
    ref = reference["samples"]
    rec = recorded["samples"]
    ref_start = align["reference_start"]
    rec_start = align["recorded_start"]
    count = align["count"]
    sample_rate = align["sample_rate"]
    buckets = max(1, min(points, count))
    step = max(1, count // buckets)
    score_index = 0
    rows = []
    for i in range(0, count, step):
        end = min(count, i + step)
        ref_slice = ref[ref_start + i : ref_start + end]
        rec_slice = rec[rec_start + i : rec_start + end]
        t0 = i / float(sample_rate)
        t1 = end / float(sample_rate)
        score_max = 0.0
        while score_index < len(pop_scores) and pop_scores[score_index][0] < t1:
            if pop_scores[score_index][0] >= t0:
                score_max = max(score_max, pop_scores[score_index][1])
            score_index += 1
        rows.append(
            {
                "t_start": t0,
                "t_end": t1,
                "ref_min": min(ref_slice),
                "ref_max": max(ref_slice),
                "recorded_min": min(rec_slice),
                "recorded_max": max(rec_slice),
                "pop_score_max": score_max,
            }
        )
    return rows


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def is_power_of_two(value: int) -> bool:
    return value > 0 and (value & (value - 1)) == 0


def fft_in_place(values: list[complex]):
    n = len(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            values[i], values[j] = values[j], values[i]

    length = 2
    while length <= n:
        angle = -2.0 * math.pi / length
        w_len = complex(math.cos(angle), math.sin(angle))
        half = length // 2
        for start in range(0, n, length):
            w = 1.0 + 0.0j
            for offset in range(half):
                even = values[start + offset]
                odd = values[start + offset + half] * w
                values[start + offset] = even + odd
                values[start + offset + half] = even - odd
                w *= w_len
        length *= 2


def select_spectrum_starts(align: dict, pulse_times: list[float], fft_size: int, windows: int, args) -> list[int]:
    sample_rate = align["sample_rate"]
    count = align["count"]
    if count <= fft_size:
        return [0]

    edge = int(sample_rate * args.edge_exclude_ms / 1000.0)
    start_min = min(max(0, edge), count - fft_size)
    start_max = max(start_min, count - edge - fft_size)
    pulse_radius_sec = args.exclude_pulse_ms / 1000.0 + (fft_size / sample_rate / 2.0)
    candidates = max(windows * 8, windows, 1)
    starts = []

    for index in range(candidates):
        if candidates == 1:
            start = int((count - fft_size) / 2)
        else:
            start = int(start_min + (start_max - start_min) * index / float(candidates - 1))
        center_sec = (start + fft_size / 2.0) / sample_rate
        if any(abs(center_sec - pulse_time) <= pulse_radius_sec for pulse_time in pulse_times):
            continue
        starts.append(start)
        if len(starts) >= windows:
            break

    if not starts:
        starts.append(int((count - fft_size) / 2))
    return starts


def compute_average_spectrum(reference: dict, recorded: dict, align: dict, pulse_times: list[float], args) -> dict:
    fft_size = int(args.spectrum_fft_size)
    if not is_power_of_two(fft_size):
        raise ValueError(f"spectrum FFT size must be a power of two, got {fft_size}")

    sample_rate = align["sample_rate"]
    fft_size = min(fft_size, 1 << int(math.floor(math.log2(max(2, align["count"])))))
    fft_size = max(1024, fft_size)
    starts = select_spectrum_starts(align, pulse_times, fft_size, max(1, args.spectrum_windows), args)
    window = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (fft_size - 1)) for i in range(fft_size)]
    window_gain = sum(window) / fft_size
    scale = max(1e-12, fft_size * window_gain)
    bins = fft_size // 2 + 1
    ref_acc = [0.0] * bins
    rec_acc = [0.0] * bins

    for start in starts:
        ref_values = [
            complex(reference["samples"][align["reference_start"] + start + i] * window[i], 0.0)
            for i in range(fft_size)
        ]
        rec_values = [
            complex(recorded["samples"][align["recorded_start"] + start + i] * window[i], 0.0)
            for i in range(fft_size)
        ]
        fft_in_place(ref_values)
        fft_in_place(rec_values)
        for bin_index in range(bins):
            ref_acc[bin_index] += abs(ref_values[bin_index]) / scale
            rec_acc[bin_index] += abs(rec_values[bin_index]) / scale

    rows = []
    max_hz = min(float(args.spectrum_max_hz), sample_rate / 2.0)
    max_bin = min(bins - 1, int(max_hz * fft_size / sample_rate))
    for bin_index in range(0, max_bin + 1):
        freq_hz = bin_index * sample_rate / float(fft_size)
        ref_mag = ref_acc[bin_index] / len(starts)
        rec_mag = rec_acc[bin_index] / len(starts)
        ref_db = 20.0 * math.log10(max(ref_mag, 1e-10))
        rec_db = 20.0 * math.log10(max(rec_mag, 1e-10))
        rows.append(
            {
                "freq_hz": freq_hz,
                "reference_db": ref_db,
                "recorded_db": rec_db,
                "delta_db": rec_db - ref_db,
            }
        )

    active = [row for row in rows if row["reference_db"] > -90.0]
    delta_rms = math.sqrt(sum(row["delta_db"] ** 2 for row in active) / len(active)) if active else 0.0
    high_band = [row for row in rows if row["freq_hz"] >= args.spectrum_high_band_hz]
    high_delta = sum(row["delta_db"] for row in high_band) / len(high_band) if high_band else 0.0

    return {
        "fft_size": fft_size,
        "windows": len(starts),
        "max_hz": max_hz,
        "bin_hz": sample_rate / float(fft_size),
        "delta_rms_db": delta_rms,
        "high_band_start_hz": args.spectrum_high_band_hz,
        "high_band_delta_avg_db": high_delta,
        "rows": rows,
    }


def downsample_spectrum_rows(rows: list[dict], points: int) -> list[dict]:
    if not rows:
        return []
    buckets = max(1, min(points, len(rows)))
    step = max(1, len(rows) // buckets)
    out = []
    for index in range(0, len(rows), step):
        chunk = rows[index : index + step]
        if not chunk:
            continue
        ref_db = max(row["reference_db"] for row in chunk)
        rec_db = max(row["recorded_db"] for row in chunk)
        out.append(
            {
                "freq_hz": sum(row["freq_hz"] for row in chunk) / len(chunk),
                "reference_db": ref_db,
                "recorded_db": rec_db,
                "delta_db": rec_db - ref_db,
            }
        )
    return out


def write_spectrum_svg(path: str, rows: list[dict], spectrum: dict):
    width, height = 1280, 420
    left, right, top, bottom = 72, 28, 48, 58
    plot_w = width - left - right
    plot_h = height - top - bottom
    db_min, db_max = -100.0, 0.0
    max_hz = max(1.0, spectrum["max_hz"])

    def x_for(freq_hz):
        return left + clamp(freq_hz / max_hz, 0.0, 1.0) * plot_w

    def y_for(db_value):
        return top + (1.0 - ((clamp(db_value, db_min, db_max) - db_min) / (db_max - db_min))) * plot_h

    ref_points = [f'{x_for(row["freq_hz"]):.1f},{y_for(row["reference_db"]):.1f}' for row in rows]
    rec_points = [f'{x_for(row["freq_hz"]):.1f},{y_for(row["recorded_db"]):.1f}' for row in rows]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<style>text{font-family:Segoe UI,Arial,sans-serif;font-size:14px;fill:#172033}.grid{stroke:#d8dee9;stroke-width:1}.axis{stroke:#6b7280;stroke-width:1}.ref{fill:none;stroke:#2563eb;stroke-width:1.4}.rec{fill:none;stroke:#dc2626;stroke-width:1.4;opacity:.9}.muted{fill:#5b6475}</style>",
        f'<text x="{left}" y="28">输入/输出频域对比（FFT {spectrum["fft_size"]}，平均 {spectrum["windows"]} 个窗口）</text>',
    ]
    for db_value in (-100, -80, -60, -40, -20, 0):
        y = y_for(db_value)
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}"/>')
        parts.append(f'<text class="muted" x="18" y="{y+4:.1f}">{db_value} dB</text>')
    for freq_hz in range(0, int(max_hz) + 1, 2000):
        x = x_for(freq_hz)
        parts.append(f'<line class="grid" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height-bottom}"/>')
        parts.append(f'<text class="muted" x="{x-22:.1f}" y="{height-24}">{freq_hz // 1000}k</text>')
    parts.append(f'<line class="axis" x1="{left}" y1="{height-bottom}" x2="{width-right}" y2="{height-bottom}"/>')
    if ref_points:
        parts.append(f'<polyline class="ref" points="{" ".join(ref_points)}"/>')
    if rec_points:
        parts.append(f'<polyline class="rec" points="{" ".join(rec_points)}"/>')
    parts.append(f'<text x="{left}" y="{height-8}">蓝色=输入参考频谱，红色=客户端录制输出频谱；频域差异用于观察高频噪声、削波和音色变化，不单独作为硬失败条件</text>')
    parts.append("</svg>")
    write_text(path, "\n".join(parts))


def write_waveform_svg(path: str, title: str, rows: list[dict], duration_sec: float, events: list[dict]):
    width, height = 1280, 420
    left, right, top, bottom = 64, 24, 48, 52
    plot_w = width - left - right
    plot_h = height - top - bottom

    def x_for(t):
        return left + (t / duration_sec) * plot_w if duration_sec > 0 else left

    def y_for(v):
        return top + (1.0 - ((clamp(v, -1.0, 1.0) + 1.0) / 2.0)) * plot_h

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<style>text{font-family:Segoe UI,Arial,sans-serif;font-size:14px;fill:#172033}.grid{stroke:#d8dee9;stroke-width:1}.axis{stroke:#6b7280;stroke-width:1}.ref{stroke:#2563eb;stroke-width:1;opacity:.55}.rec{stroke:#dc2626;stroke-width:1;opacity:.55}.event{stroke:#111827;stroke-width:1.5;stroke-dasharray:4 4}</style>",
        f"<text x=\"{left}\" y=\"28\">{html.escape(title)}</text>",
    ]
    for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = top + frac * plot_h
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}"/>')
    for t in range(0, int(math.ceil(duration_sec)) + 1, 2):
        x = x_for(t)
        parts.append(f'<line class="grid" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height-bottom}"/>')
        parts.append(f'<text x="{x-8:.1f}" y="{height-24}">{t}s</text>')
    parts.append(f'<line class="axis" x1="{left}" y1="{y_for(0):.1f}" x2="{width-right}" y2="{y_for(0):.1f}"/>')

    for row in rows:
        x = x_for((row["t_start"] + row["t_end"]) / 2.0)
        parts.append(f'<line class="ref" x1="{x:.1f}" y1="{y_for(row["ref_min"]):.1f}" x2="{x:.1f}" y2="{y_for(row["ref_max"]):.1f}"/>')
    for row in rows:
        x = x_for((row["t_start"] + row["t_end"]) / 2.0)
        parts.append(f'<line class="rec" x1="{x:.1f}" y1="{y_for(row["recorded_min"]):.1f}" x2="{x:.1f}" y2="{y_for(row["recorded_max"]):.1f}"/>')
    for event in events:
        x = x_for(event["time_sec"])
        parts.append(f'<line class="event" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height-bottom}"/>')
    parts.append(f'<text x="{left}" y="{height-8}">蓝色=输入参考波形，红色=客户端录制输出波形，虚线=疑似爆音候选点</text>')
    parts.append("</svg>")
    write_text(path, "\n".join(parts))


def write_detail_svg(path: str, reference: dict, recorded: dict, align: dict, center_sec: float, window_ms: float):
    sample_rate = align["sample_rate"]
    half = int(sample_rate * window_ms / 1000.0 / 2.0)
    center = int(center_sec * sample_rate)
    start = max(0, center - half)
    end = min(align["count"], center + half)
    count = max(1, end - start)
    step = max(1, count // 1800)
    width, height = 1280, 420
    left, right, top, bottom = 64, 24, 48, 52
    plot_w = width - left - right
    plot_h = height - top - bottom

    def x_for(i):
        return left + ((i - start) / float(count)) * plot_w

    def y_for(v):
        return top + (1.0 - ((clamp(v, -1.0, 1.0) + 1.0) / 2.0)) * plot_h

    ref_points = []
    rec_points = []
    for i in range(start, end, step):
        ref_v = reference["samples"][align["reference_start"] + i]
        rec_v = recorded["samples"][align["recorded_start"] + i]
        ref_points.append(f"{x_for(i):.1f},{y_for(ref_v):.1f}")
        rec_points.append(f"{x_for(i):.1f},{y_for(rec_v):.1f}")

    t0 = start / float(sample_rate)
    t1 = end / float(sample_rate)
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<style>text{font-family:Segoe UI,Arial,sans-serif;font-size:14px;fill:#172033}.grid{stroke:#d8dee9;stroke-width:1}.axis{stroke:#6b7280;stroke-width:1}.ref{fill:none;stroke:#2563eb;stroke-width:1.3}.rec{fill:none;stroke:#dc2626;stroke-width:1.3;opacity:.85}</style>",
        f'<text x="{left}" y="28">局部细节波形 {t0:.3f}s - {t1:.3f}s</text>',
    ]
    for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = top + frac * plot_h
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}"/>')
    parts.append(f'<line class="axis" x1="{left}" y1="{y_for(0):.1f}" x2="{width-right}" y2="{y_for(0):.1f}"/>')
    parts.append(f'<polyline class="ref" points="{" ".join(ref_points)}"/>')
    parts.append(f'<polyline class="rec" points="{" ".join(rec_points)}"/>')
    parts.append(f'<text x="{left}" y="{height-8}">蓝色=输入参考，红色=输出录制；这里按原始采样点降采样绘制</text>')
    parts.append("</svg>")
    write_text(path, "\n".join(parts))


def write_score_svg(path: str, score_series: list[tuple[float, float]], duration_sec: float, events: list[dict]):
    width, height = 1280, 360
    left, right, top, bottom = 64, 24, 42, 48
    plot_w = width - left - right
    plot_h = height - top - bottom
    max_score = max([1.5] + [score for _, score in score_series])
    max_score = min(max_score, 10.0)

    def x_for(t):
        return left + (t / duration_sec) * plot_w if duration_sec > 0 else left

    def y_for(score):
        return top + (1.0 - clamp(score / max_score, 0.0, 1.0)) * plot_h

    points = [f"{x_for(t):.1f},{y_for(score):.1f}" for t, score in score_series]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<style>text{font-family:Segoe UI,Arial,sans-serif;font-size:14px;fill:#172033}.grid{stroke:#d8dee9;stroke-width:1}.score{fill:none;stroke:#7c3aed;stroke-width:1.4}.limit{stroke:#dc2626;stroke-width:1.3}.event{stroke:#111827;stroke-width:1.5;stroke-dasharray:4 4}</style>",
        f'<text x="{left}" y="26">瞬态爆音评分曲线（超过红线为候选）</text>',
    ]
    for frac in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = top + frac * plot_h
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.1f}" x2="{width-right}" y2="{y:.1f}"/>')
    threshold_y = y_for(1.0)
    parts.append(f'<line class="limit" x1="{left}" y1="{threshold_y:.1f}" x2="{width-right}" y2="{threshold_y:.1f}"/>')
    if points:
        parts.append(f'<polyline class="score" points="{" ".join(points)}"/>')
    for event in events:
        x = x_for(event["time_sec"])
        parts.append(f'<line class="event" x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height-bottom}"/>')
    parts.append(f'<text x="{left}" y="{height-10}">纵轴=相对鲁棒阈值的瞬态强度，虚线=候选点</text>')
    parts.append("</svg>")
    write_text(path, "\n".join(parts))


def write_text(path: str, text: str):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def write_csv(path: str, rows: list[dict], fields: list[str]):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field) for field in fields})


def round_event(event: dict) -> dict:
    return {
        "time_sec": round(event["time_sec"], 6),
        "duration_ms": round(event["duration_ms"], 4),
        "peak_delta": round(event["peak_delta"], 6),
        "peak_abs": round(event["peak_abs"], 6),
        "score": round(event["score"], 3),
        "severe": bool(event["severe"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", required=True)
    parser.add_argument("--recorded", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--points", type=int, default=2400)
    parser.add_argument("--pop-mad", type=float, default=12.0)
    parser.add_argument("--min-pop-delta", type=float, default=0.035)
    parser.add_argument("--severe-score", type=float, default=1.8)
    parser.add_argument("--max-pop-events", type=int, default=0)
    parser.add_argument("--max-severe-pop-events", type=int, default=0)
    parser.add_argument("--exclude-pulse-ms", type=float, default=300.0)
    parser.add_argument("--edge-exclude-ms", type=float, default=600.0)
    parser.add_argument("--merge-gap-ms", type=float, default=3.0)
    parser.add_argument("--max-pop-duration-ms", type=float, default=22.0)
    parser.add_argument("--score-hop-ms", type=float, default=5.0)
    parser.add_argument("--threshold-stride", type=int, default=8)
    parser.add_argument("--periodic-confidence-threshold", type=float, default=0.72)
    parser.add_argument("--periodic-cv-for-zero-confidence", type=float, default=0.25)
    parser.add_argument("--min-period-ms", type=float, default=20.0)
    parser.add_argument("--max-period-ms", type=float, default=5000.0)
    parser.add_argument("--detail-window-ms", type=float, default=80.0)
    parser.add_argument("--spectrum-fft-size", type=int, default=8192)
    parser.add_argument("--spectrum-windows", type=int, default=24)
    parser.add_argument("--spectrum-max-hz", type=float, default=12000.0)
    parser.add_argument("--spectrum-points", type=int, default=900)
    parser.add_argument("--spectrum-high-band-hz", type=float, default=4000.0)
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    reference = read_pcm16_wav(args.reference)
    recorded = read_pcm16_wav(args.recorded)
    align = align_by_pulses(reference, recorded)
    pop = detect_pop_events(recorded["samples"], align, align["reference_pulses_sec"], args)
    rows = downsample_waveforms(reference, recorded, align, args.points, pop["score_series"])
    spectrum = compute_average_spectrum(reference, recorded, align, align["reference_pulses_sec"], args)
    spectrum_rows = downsample_spectrum_rows(spectrum["rows"], args.spectrum_points)

    waveform_csv = os.path.join(args.out_dir, "waveform-downsample.csv")
    pop_csv = os.path.join(args.out_dir, "pop-events.csv")
    spectrum_csv = os.path.join(args.out_dir, "spectrum-data.csv")
    overview_svg = os.path.join(args.out_dir, "waveform-overview.svg")
    detail_svg = os.path.join(args.out_dir, "waveform-detail.svg")
    score_svg = os.path.join(args.out_dir, "pop-score.svg")
    spectrum_svg = os.path.join(args.out_dir, "spectrum-comparison.svg")
    analysis_json = os.path.join(args.out_dir, "waveform-analysis.json")

    write_csv(
        waveform_csv,
        rows,
        ["t_start", "t_end", "ref_min", "ref_max", "recorded_min", "recorded_max", "pop_score_max"],
    )
    rounded_events = [round_event(event) for event in pop["events"]]
    write_csv(pop_csv, rounded_events, ["time_sec", "duration_ms", "peak_delta", "peak_abs", "score", "severe"])
    write_csv(
        spectrum_csv,
        [
            {
                "freq_hz": round(row["freq_hz"], 3),
                "reference_db": round(row["reference_db"], 4),
                "recorded_db": round(row["recorded_db"], 4),
                "delta_db": round(row["delta_db"], 4),
            }
            for row in spectrum_rows
        ],
        ["freq_hz", "reference_db", "recorded_db", "delta_db"],
    )
    write_waveform_svg(overview_svg, "输入/输出全局波形包络", rows, align["duration_sec"], rounded_events)
    center_sec = rounded_events[0]["time_sec"] if rounded_events else min(1.0, align["duration_sec"] / 2.0)
    write_detail_svg(detail_svg, reference, recorded, align, center_sec, args.detail_window_ms)
    write_score_svg(score_svg, pop["score_series"], align["duration_sec"], rounded_events)
    write_spectrum_svg(spectrum_svg, spectrum_rows, spectrum)

    failures = []
    if pop["event_count"] > args.max_pop_events:
        failures.append(f"疑似爆音候选数量 {pop['event_count']}，阈值 <= {args.max_pop_events}")
    if pop["severe_event_count"] > args.max_severe_pop_events:
        failures.append(f"严重爆音候选数量 {pop['severe_event_count']}，阈值 <= {args.max_severe_pop_events}")
    if pop["periodic"]["detected"]:
        failures.append(
            "检测到疑似周期性爆音，置信度 "
            f"{pop['periodic']['confidence']:.3f}，平均间隔 "
            f"{pop['periodic']['mean_interval_ms']:.2f} ms"
        )

    analysis = {
        "generated_at": _dt.datetime.now().astimezone().isoformat(),
        "pass": not failures,
        "failures": failures,
        "reference_wav": os.path.abspath(args.reference),
        "recorded_wav": os.path.abspath(args.recorded),
        "sample_rate": align["sample_rate"],
        "analyzed_samples": align["count"],
        "analyzed_duration_sec": round(align["duration_sec"], 6),
        "alignment": {
            "offset_sec": round(align["offset_sec"], 6),
            "offset_samples": align["offset_samples"],
            "reference_start": align["reference_start"],
            "recorded_start": align["recorded_start"],
            "reference_pulses_sec": [round(value, 6) for value in align["reference_pulses_sec"]],
            "recorded_pulses_sec": [round(value, 6) for value in align["recorded_pulses_sec"]],
        },
        "pop_detection": {
            "pass": pop["pass"],
            "event_count": pop["event_count"],
            "severe_event_count": pop["severe_event_count"],
            "max_score": round(pop["max_score"], 3),
            "threshold": {
                "median_delta": round(pop["threshold"]["median_delta"], 8),
                "mad_delta": round(pop["threshold"]["mad_delta"], 8),
                "threshold_delta": round(pop["threshold"]["threshold_delta"], 8),
                "sampled_deltas": pop["threshold"]["sampled_deltas"],
            },
            "periodic": {
                "detected": pop["periodic"]["detected"],
                "confidence": round(pop["periodic"]["confidence"], 3),
                "mean_interval_ms": round(pop["periodic"]["mean_interval_ms"], 3)
                if pop["periodic"]["mean_interval_ms"] is not None
                else None,
                "interval_cv": round(pop["periodic"]["interval_cv"], 5)
                if pop["periodic"]["interval_cv"] is not None
                else None,
            },
            "events": rounded_events,
            "thresholds": pop["thresholds"],
        },
        "spectrum": {
            "fft_size": spectrum["fft_size"],
            "windows": spectrum["windows"],
            "max_hz": round(spectrum["max_hz"], 3),
            "bin_hz": round(spectrum["bin_hz"], 6),
            "delta_rms_db": round(spectrum["delta_rms_db"], 3),
            "high_band_start_hz": round(spectrum["high_band_start_hz"], 3),
            "high_band_delta_avg_db": round(spectrum["high_band_delta_avg_db"], 3),
        },
        "plots": {
            "waveform_overview_svg": os.path.abspath(overview_svg),
            "waveform_detail_svg": os.path.abspath(detail_svg),
            "pop_score_svg": os.path.abspath(score_svg),
            "spectrum_comparison_svg": os.path.abspath(spectrum_svg),
        },
        "data": {
            "waveform_downsample_csv": os.path.abspath(waveform_csv),
            "pop_events_csv": os.path.abspath(pop_csv),
            "spectrum_csv": os.path.abspath(spectrum_csv),
        },
    }
    write_text(analysis_json, json.dumps(analysis, ensure_ascii=True, indent=2))
    print(analysis_json)
    return 0 if analysis["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
