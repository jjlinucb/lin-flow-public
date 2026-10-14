#!/usr/bin/env python3
"""Measure how much noise it takes to break Lin Flow.

Canto, Wispr's model, is sold on holding up in a loud cafe. Before chasing that, we need to
know where Lin Flow actually stands, so this mixes a known-good clip with noise at a range of
signal-to-noise ratios, runs every installed model over each one, and prints word error rate
against a reference. Any change to the audio front-end - Apple's voice processing, a denoiser,
a different model - gets measured against the same curve rather than argued about.

Two noise types, both standard proxies:
  babble  several shifted copies of the speech summed together. This is what NOISEX-92 calls
          babble and it is the closest cheap stand-in for a cafe: speech-shaped, non-stationary,
          and the hardest case for a recognizer because it looks like the thing it is listening
          for.
  pink    1/f noise. Stationary and much easier; it is here as the control, so a drop on babble
          can be told apart from a drop on "any noise at all".

SNR is computed over the whole clip rather than over voiced frames only, so these numbers are
comparable with each other but not with a paper's.

    python3 scripts/noisebench.py --models parakeet-tdt-0.6b-v3-q8_0 large-v3-turbo-q5_0
"""

import argparse, array, math, os, pathlib, random, re, shlex, subprocess, sys, wave

REFERENCE = ("This is a test of the Lin Flow local dictation spike, testing 123, "
             "running on Apple Silicon, with the Parakeet speech model.")


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2, "expected 16-bit PCM"
        assert w.getnchannels() == 1, "expected mono"
        rate = w.getframerate()
        pcm = array.array("h", w.readframes(w.getnframes()))
    return [s / 32768.0 for s in pcm], rate


def write_wav(path, samples, rate):
    clipped = array.array("h", (max(-32768, min(32767, int(s * 32767))) for s in samples))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(clipped.tobytes())


def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / max(1, len(xs)))


def babble(speech, voices=6, seed=7):
    """Several copies of the speech at random offsets, summed. Speech-shaped and non-stationary,
    which is the part that makes a cafe hard."""
    rng = random.Random(seed)
    n = len(speech)
    out = [0.0] * n
    for _ in range(voices):
        off = rng.randrange(n)
        for i in range(n):
            out[i] += speech[(i + off) % n]
    return out


def pink(n, seed=7):
    """Voss-McCartney: cheap 1/f without an FFT."""
    rng = random.Random(seed)
    rows = 16
    values = [rng.uniform(-1, 1) for _ in range(rows)]
    total = sum(values)
    out = []
    for i in range(1, n + 1):
        # each row updates at half the rate of the one above it
        for r in range(rows):
            if i % (1 << r) == 0:
                total -= values[r]
                values[r] = rng.uniform(-1, 1)
                total += values[r]
                break
        out.append(total / rows)
    return out


def wind(n, rate, seed=7):
    """Wind at a microphone is turbulence, not hiss: nearly all of its energy is below a few
    hundred Hz, and it arrives in gusts rather than steadily. So this is brown noise (a leaky
    random walk, 1/f^2) shaped by a slow random envelope. That spectrum is the whole reason a
    high-pass helps here and does nothing for babble."""
    rng = random.Random(seed)
    out, x = [], 0.0
    for _ in range(n):
        x = 0.997 * x + rng.uniform(-1, 1) * 0.03      # leaky integrator -> brown
        out.append(x)
    # gusts: a few slow sine components, rectified, so the level swells and drops
    gust = []
    freqs = [(rng.uniform(0.15, 0.8), rng.uniform(0, 6.28)) for _ in range(3)]
    for i in range(n):
        t = i / rate
        env = sum(math.sin(2 * math.pi * f * t + p) for f, p in freqs) / len(freqs)
        gust.append(0.35 + 0.65 * abs(env))
    peak = max(abs(v) for v in out) or 1.0
    return [v / peak * g for v, g in zip(out, gust)]


def highpass(xs, rate, cutoff, q=0.707):
    """One RBJ-cookbook biquad, direct form I. Deliberately the plainest possible formulation:
    whatever wins here has to be reimplemented in Swift and C# and pinned to the same numbers,
    and a biquad is about fifteen lines in any language."""
    if cutoff <= 0:
        return list(xs)
    w0 = 2 * math.pi * cutoff / rate
    cos_w0, sin_w0 = math.cos(w0), math.sin(w0)
    alpha = sin_w0 / (2 * q)
    b0 = (1 + cos_w0) / 2
    b1 = -(1 + cos_w0)
    b2 = (1 + cos_w0) / 2
    a0 = 1 + alpha
    a1 = -2 * cos_w0
    a2 = 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for x in xs:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x
        y2, y1 = y1, y
        out.append(y)
    return out


def mix(speech, noise, snr_db, allow_clipping=False):
    """Scale the noise to the requested SNR and combine.

    By default the peak is normalised back under full scale, which measures the noise on its
    own. With allow_clipping the sum is hard-limited at full scale instead, which is what a
    real microphone preamp does when a gust hits it - and for wind that distinction is the
    whole story, because wind that does not overload the input turns out to cost nothing at
    all. Returns the signal and the fraction of samples that clipped."""
    s, nz = rms(speech), rms(noise)
    if nz == 0:
        return list(speech), 0.0
    gain = (s / nz) / (10 ** (snr_db / 20.0))
    out = [a + gain * b for a, b in zip(speech, noise)]
    peak = max(abs(x) for x in out) or 1.0
    if not allow_clipping:
        return ([x / peak * 0.95 for x in out] if peak > 0.95 else out), 0.0
    clipped = sum(1 for x in out if abs(x) >= 1.0)
    return [max(-1.0, min(1.0, x)) for x in out], clipped / max(1, len(out))


def normalise(text):
    text = text.lower().replace("-", " ")
    return re.sub(r"[^a-z0-9 ]", "", text).split()


def wer(ref, hyp):
    """Levenshtein over words. Returns (rate, edits, reference length)."""
    r, h = normalise(ref), normalise(hyp)
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] != h[j - 1]))
        prev = cur
    return prev[len(h)] / max(1, len(r)), prev[len(h)], len(r)


def transcribe(cli, wav, model, env, extra=()):
    """The CLI prints the transcript on stdout and its timing line on stderr.

    An empty transcript is treated as a broken run, not as a score of zero. The first wind
    measurement read 100% WER on every case including the clean one, which looked like a
    catastrophic result and was in fact LINFLOW_DATA_DIR pointing at a folder with no models
    in it: the CLI said "model not found" and the harness scored the silence."""
    p = subprocess.run([cli, "transcribe", str(wav), "--raw", "--model", model, *extra],
                       capture_output=True, text=True, env=env, timeout=300)
    # A CLI that rejected its arguments prints usage and exits non-zero. Without this check the
    # harness scored a line of usage text as the transcript and reported a confident 100% WER.
    if p.returncode != 0:
        raise RuntimeError(f"{model}: exit {p.returncode}: "
                           f"{(p.stderr or p.stdout).strip().splitlines()[0] if (p.stderr or p.stdout).strip() else 'no output'}")
    out = [l for l in p.stdout.splitlines() if l.strip() and not l.startswith("[lin-flow")]
    if not out:
        raise RuntimeError(f"no transcript for {model}: "
                           f"{(p.stdout + p.stderr).strip().splitlines()[-1] if (p.stdout + p.stderr).strip() else 'no output'}")
    return out[-1].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", default="scripts/testdata/test.wav")
    ap.add_argument("--reference", default=REFERENCE)
    ap.add_argument("--corpus", default=None,
                    help="A folder of NN.wav next to NN.txt. Word error rate is pooled over the "
                         "whole set - total edits over total reference words - rather than "
                         "averaged per clip, so a short sentence cannot swing the result.")
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--snr", nargs="+", type=float, default=[30, 20, 15, 10, 5, 0])
    ap.add_argument("--cli", default=".build/debug/LinFlow")
    ap.add_argument("--out", default=None, help="where to leave the generated wavs")
    ap.add_argument("--noise", nargs="+", default=["babble", "pink", "wind"])
    ap.add_argument("--highpass", type=float, default=0,
                    help="Hz. Applied to the mixed signal, where the app would apply it.")
    # One string, split here: with nargs="*" argparse swallows anything starting with a dash
    # as an option of its own, so --cli-args --beam 8 silently passed nothing through.
    ap.add_argument("--cli-args", default="",
                    help='Extra flags for `LinFlow transcribe`, as one string: '
                         '--cli-args "--beam 8 --fallback". This is how decode settings get A/B-d.')
    ap.add_argument("--allow-clipping", action="store_true",
                    help="Hard-limit at full scale instead of normalising, the way a mic preamp "
                         "overloads on a gust.")
    ap.add_argument("--prefilter", action="store_true",
                    help="Apply the high-pass BEFORE clipping, i.e. in front of the preamp, "
                         "which is what a windscreen or an analog filter does. Software can only "
                         "filter after the ADC, so this is the unreachable best case.")
    args = ap.parse_args()

    if args.corpus:
        folder = pathlib.Path(args.corpus)
        items = [(w, (w.with_suffix(".txt")).read_text().strip())
                 for w in sorted(folder.glob("*.wav")) if w.with_suffix(".txt").exists()]
        if not items:
            sys.exit(f"no NN.wav/NN.txt pairs in {folder}")
    else:
        items = [(pathlib.Path(args.clip), args.reference)]

    out_dir = pathlib.Path(args.out or (os.environ.get("TMPDIR", "/tmp") + "/linflow-noisebench"))
    out_dir.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    # Never read John's live dictionary, history or notes: a benchmark whose result depends on
    # what he dictated yesterday is not a benchmark. This is a fixed folder rather than one per
    # run, so the models are copied once and every output directory can share them.
    data = pathlib.Path(env.get("LINFLOW_DATA_DIR") or (out_dir.parent / "bench-data"))
    env["LINFLOW_DATA_DIR"] = str(data)
    if not (data / "models").is_dir():
        sys.exit(f"no models in {data}/models - copy them there first:\n"
                 f'  mkdir -p "{data}" && cp -R "$HOME/Library/Application Support/Lin Flow/models" "{data}/"')

    extra = shlex.split(args.cli_args)
    hp = f"  highpass {args.highpass:.0f} Hz" if args.highpass else "  no filtering"
    hp += f"  cli {args.cli_args}" if extra else ""
    total_words = sum(len(normalise(r)) for _, r in items)
    print(f"{len(items)} clip(s), {total_words} reference words{hp}")
    print("Pooled WER, and drift from each model's own clean output on the same clips.\n")
    print(f"{'case':<16}" + "".join(f"{m[:24]:>26}" for m in args.models))
    print(f"{'':<16}" + "".join(f"{'wer    drift':>26}" for _ in args.models))
    print("-" * (16 + 26 * len(args.models)))

    # Noise is generated per clip, since it has to be the same length as the speech.
    def noise_for(kind, speech, rate):
        return {"babble": lambda: babble(speech),
                "pink": lambda: pink(len(speech)),
                "wind": lambda: wind(len(speech), rate)}[kind]()

    cases = [("clean", None)] + [(f"{k}@{int(v)}dB", (k, v)) for k in args.noise for v in args.snr]
    clean_hyp = {}          # (model, clip index) -> transcript on the clean version

    for name, spec in cases:
        cells = []
        for m in args.models:
            edits = words = drift_edits = drift_words = 0
            failed = None
            for idx, (clip_path, reference) in enumerate(items):
                speech, rate = read_wav(clip_path)
                if spec is None:
                    signal = list(speech)
                else:
                    nz = noise_for(spec[0], speech, rate)
                    if args.prefilter and args.highpass:
                        nz = highpass(nz, rate, args.highpass)
                    signal, _ = mix(speech, nz, spec[1], args.allow_clipping)
                    if args.highpass and not args.prefilter:
                        signal = highpass(signal, rate, args.highpass)
                wav = out_dir / f"{name.replace('@','_')}-{idx:02d}.wav"
                write_wav(wav, signal, rate)
                try:
                    hyp = transcribe(args.cli, wav, m, env, extra)
                except Exception as e:
                    failed = e
                    break
                if name == "clean":
                    clean_hyp[(m, idx)] = hyp
                _, e1, n1 = wer(reference, hyp)
                edits += e1; words += n1
                _, e2, n2 = wer(clean_hyp.get((m, idx), reference), hyp)
                drift_edits += e2; drift_words += n2
            if failed is not None:
                cells.append(f"{'ERROR':>26}")
                print(f"\n  {m}: {failed}", file=sys.stderr)
            else:
                cells.append(f"{edits/max(1,words)*100:>17.1f} %"
                             f"{drift_edits/max(1,drift_words)*100:>6.1f} %")
        print(f"{name:<16}" + "".join(cells))

    print(f"\nwavs in {out_dir}")


if __name__ == "__main__":
    sys.exit(main())
