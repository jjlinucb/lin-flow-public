# Noise: what actually breaks Lin Flow, measured

Wispr Flow's Canto is sold on holding up in a loud cafe, and John asked whether Lin Flow can get
there — locally, on both Mac and Windows. Before building anything, this is where it actually
stands. Everything below is measured with `scripts/noisebench.py`, not estimated.

Run it again with:

```bash
mkdir -p /tmp/nb/bench-data && cp -R "$HOME/Library/Application Support/Lin Flow/models" /tmp/nb/bench-data/
python3 scripts/noisebench.py --corpus scripts/testdata/corpus \
  --models parakeet-tdt-0.6b-v3-q8_0 large-v3-turbo-q5_0 --noise babble --out /tmp/nb/run
```

## The headline: two of the three things we worried about cost nothing

| Noise | Result |
|---|---|
| **Pink** (stationary broadband — fans, road hum, aircraft cabin) | **0% WER cost at every SNR down to 0 dB**, both models. |
| **Wind** (brown noise in gusts, the park case) | **0% cost down to −10 dB SNR** — wind three times louder than the speech. Even allowing it to overload the input and hard-clip, the cost stayed near zero. |
| **Babble** (overlapped speech — the cafe, a loud session) | **The only thing that breaks it.** |

Wind does nothing because nearly all of its energy is below ~200 Hz, and the mel front-end
barely looks there. That also means **a high-pass filter is not worth building**: it would remove
energy that is already costing nothing.

The same logic rules out the obvious first move. RNNoise, WebRTC NS, SpeexDSP, spectral
subtraction — the whole classical family models and subtracts *stationary* noise, which is the
column where Lin Flow already scores zero. They cannot touch competing speech, because competing
speech looks exactly like the thing they are trying to preserve.

## Babble, on real human speech (`scripts/testdata/test.wav`, 22 words)

Drift from each model's own clean transcript, so a model's habitual spellings do not count
against it.

| SNR | Parakeet (the default) | Whisper turbo |
|---|---|---|
| 15 dB | 0% | 0% |
| **10 dB** | **14%** | **0%** |
| 5 dB | 19% | 14% |
| 0 dB | 57% | 41% |

**Whisper turbo is the more babble-robust of the two, and it is not the default.** It costs
1.3 s against Parakeet's 0.17 s on a 7.6 s clip.

## Decode settings do not help

Tested against babble at 10, 5 and 0 dB: `--beam 8`, `--fallback` (temperature fallback), and
`--no-vad`. **Every one produced numbers identical to the baseline**, except `--beam 8`, which
made Whisper *worse* at 0 dB (45.5% against 40.9%). There is nothing to win here; do not spend
time on it.

## Parakeet returns nothing rather than something wrong

At 0 dB babble, on clip 03 of the corpus, Parakeet produced **an empty transcript** — the timing
line printed, the text did not. Whisper degraded on the same clip instead of failing.

For a dictation app that is the worst outcome there is: John holds the key, speaks, and nothing
pastes. CLAUDE.md already records that an empty dictionary and a broken readback are
indistinguishable from the outside; the same is true here. **This is the most actionable finding
in the file** and it needs handling whatever else is done about noise.

The wrong answers it gives at that level are worth reading too, because they are the input to the
learned-corrections system: "the skills over" → "distills over", "to the cloud" → "to the class",
"pull request" → "gold request". Plausible English, confidently wrong — exactly the shape the
`everydayEnglish` guard exists to refuse.

## On the test material

Two sets, and they disagree in a way worth understanding.

- `scripts/testdata/test.wav` is **one human recording, 22 words.** Each word is ~4.5% of WER, so
  the precision is poor, but it is real speech.
- `scripts/testdata/corpus/` is **10 sentences, ~130 words, spoken by macOS `say`** with exact
  references. Pooled WER, so a short sentence cannot swing the result.

The TTS corpus is markedly *more* robust — around 2% WER at 5 dB babble where the human clip is
already at 14–19%. Synthetic speech is cleaner, more uniform and has no disfluency, so **treat
the corpus as a ceiling, not a forecast.** The honest reading is that the human number is closer
to the truth and the corpus is useful for comparing interventions against each other.

Neither set has reverb or the clatter of a real cafe. The single best improvement to this
benchmark would be a real recording of John dictating in one, with a written reference.

## The literature agrees, and rules out the obvious fix

Two independent confirmations of the measurements above, both worth knowing before anyone
reopens these questions.

**Whisper beating Parakeet in babble is a published result, at the same crossover.** The Whisper
paper's own §3.7 tests against "pub noise" — explicitly "ambient noise and indistinct chatter
typical in a crowded restaurant" — and finds the NVIDIA STT line, which Parakeet descends from,
"outperformed by Whisper under high noise (SNR < 10 dB)"
([arXiv 2212.04356](https://arxiv.org/abs/2212.04356)). The onset measured here — Parakeet from
10 dB, Whisper from 5 dB — is that crossover.

**Speech enhancement is measured to make these two models worse, specifically.** De Oliveira,
Peer & Gerkmann, [arXiv 2605.12107](https://arxiv.org/abs/2605.12107), tested Parakeet TDT and
Whisper Large v3 Turbo on EARS-WHAM (real café and bar ambience) at −2.5 to 10 dB. **Every
enhancer degraded both.** Parakeet went 5.0% → 10.2% WER under the *best* one and 26.6% under a
generative one; Whisper Turbo 5.9% → 8.6%. Meanwhile weak, clean-trained models improved by
~35% relative — which is the mechanism: enhancement artifacts are out of distribution for a
large pretrained acoustic model, so the pay-off only exists when the back-end is fragile. Ours
is not. Corroborated by [arXiv 2404.14860](https://arxiv.org/abs/2404.14860) (15.9% → 30.5%),
[arXiv 2512.17562](https://arxiv.org/abs/2512.17562) (MetricGAN+ worse in 40 of 40 configs on
Whisper and Parakeet) and the URGENT 2024 challenge, where six of 23 submitted systems scored
*below doing nothing*.

So the original conclusion stands and is now doubly supported: **do not wire up a denoiser.** It
is two to four hours of work to make things measurably worse.

**Target-speaker extraction is the one family that works on babble** — VoiceFilter-Lite reports
77.9% → 30.6% WER on speech noise at 1–10 dB — **and has no deployable local artifact.** No ONNX,
no CoreML, no GGML, no C or Rust build with weights. sherpa-onnx, which would otherwise fit, ships
no target-speaker model. This is the real ceiling and it is currently out of reach.

## Two more things tested here, both negative

**Beam size is a dead end.** whisper.cpp hard-caps it: `too many decoders requested (15), max = 8`.
The literature's recommendation (beam 15 at SNR ≤ 0) cannot be run at all, and beam 8 — the
reachable maximum — measured *worse* than the default: 45.5% against 40.9% at 0 dB babble.

**The glossary prompt helps, against the general advice.** [arXiv 2502.11572](https://arxiv.org/abs/2502.11572)
reports that `initial_prompt` raises WER, because Whisper's prompt slot expects the previous
segment's transcript rather than a word list. Measured here it does the opposite:

| | clean | babble 5 dB | babble 0 dB |
|---|---|---|---|
| glossary prompt on (the default) | 1.5% | 1.5% | **24.6%** |
| prompt off | 2.2% | 2.2% | **29.1%** |

It also fixes the thing it exists to fix — with the glossary on, "Marissa" comes back as "Marisa".
The difference from the paper is that John's glossary is *his own vocabulary*, so it is relevant
by construction, where the paper's caution is about generic lists. **Keep the prompt.** Note the
glossary used in this test was written to match the corpus, so treat the size of the gap as
optimistic and the direction as sound.

## What was built

1. **A take that produces nothing is retried on the other engine kind.** `ModelCatalog.rescueModelURL`
   picks it — a different *kind*, since a second Parakeet fails the same way — and
   `DictationController.process` runs it. Before this the app deleted the recording and returned
   in silence.
2. **The recording is kept when the engine heard nothing**, instead of being discarded, and an
   error sound plays. Silence was indistinguishable from a broken hotkey, and the audio was the
   only evidence.
3. **Windows says so.** It has no second engine to retry with, so it shows a notification instead
   and suggests moving the microphone closer.
4. **`AudioIO.snrEstimate` is logged on every dictation.** It drives no engine switch (see below).
5. **A loud room on the Mac's own mic gets a nudge (2026-10-14).** `LoudRoom` shows a toast
   suggesting AirPods after two takes in a row at a floor of 0.01 or more on the built-in mic,
   then stays quiet for two hours. AirPods never trigger it, since their floor is near 0 in any
   room. The threshold comes from 913 built-in takes: median 0.0022, 90% under 0.0036, and the
   10-14 cafe at 0.031 to 0.046. Since then `LinFlow transcribe` also retries an empty take on the
   other engine, as the app does, and a rescued take's history row names the model that wrote it.

## What was deliberately not built

**The automatic engine switch.** Parakeet is measurably worse than Whisper below about 10 dB, so
switching when it is loud is worth having. But the estimator cannot yet separate loud babble from
someone talking without pausing: a clip with its gaps removed reads 16.6 dB against
babble-at-10-dB's 13.8. Those are adjacent, and a threshold that makes every dictation eight
times slower when it misfires must not be set by intuition on ten synthetic clips — the same rule
CLAUDE.md already states for the `PasteWatcher` edit threshold. The estimate and the noise floor
are logged on every take so the threshold can be set from real recordings in real rooms. **Dictate
in the cafe a few times, then read the log.**

**A high-pass filter.** Wind costs nothing, so there is nothing for it to recover.

## The first real-world log (2026-09-21)

The log then contradicted the plan twice. The noise **floor** separates rooms far better than SNR:
a quiet home measured 0.0009 against a cafe's 0.0143, a 16x gap, while SNR moved only from 21 to
14 dB. So an engine switch, if one is ever built, should threshold on the floor. And John's two
worst transcripts came at **29 and 28 dB in a silent room**: long, disfluent takes with one
out-of-vocabulary proper noun, while the 14 dB cafe take was word for word. The real error
sources are vocabulary and long rambling takes, not the room. "Superlinear" went into the
dictionary as a result.

Since 2026-09-22 every history row keeps its SNR, floor, input device and start delay
(`HistoryEntry`), so a few more cafe takes are enough to set that threshold from the data.
`LinFlow compare-engines` covers the other half: whether long takes read better from Whisper.

On 2026-09-23 the device on each row showed that the floor belongs to the microphone as much as
the room. John's AirPods Pro read a floor of exactly 0 on 5 of 14 takes and at most 0.0007 on the
rest, below the quiet home's 0.0009, while the built-in microphone read 0.0013 to 0.0036 the same
day. The AirPods suppress noise before Lin Flow hears it, so their floor says nothing about the
room. A threshold on the floor has to be set per device, and a zero floor leaves `snrDB` empty.

## Still open

- **The biggest free win is physical.** AMI measures 52.0% WER on distant microphones against
  29.6% on a headset. Moving the mic closer beats every software option in this file, and it is a
  nudge in the UI rather than code.
- **Apple's `setVoiceProcessingEnabled`** is still untried. It engages the mic array, which should
  help, but it also applies Apple's own single-channel noise suppression and AGC — the exact class
  of processing measured above to hurt. No measurement of its effect on ASR WER exists anywhere
  that could be found. It is cheap to A/B with `noisebench.py` and a bad thing to assume; it is
  also Mac-only, so it would not be the shared-core answer John asked for.
- **Windows has no second engine.** `whisper.dll` is already sitting in `windows/native/Release`
  and is simply never copied by `package.sh`; what is missing is the P/Invoke binding and a
  `WhisperEngine.cs`. `whisper_full_params` is a large layout-sensitive struct and this is the
  known hazard on that side, so it wants doing on the Windows machine where it can be run.
