# Can Whisper go faster on the M1 Pro?

**Date:** 2026-10-15, on the MacBook Pro (M1 Pro, 6 performance + 2 efficiency cores, 16 GB).
**Question:** idea 2 from Superlinear EP 13. Can Lin Flow's Whisper path (large-v3-turbo q5_0 on
Homebrew's whisper.cpp 1.9.1, Metal, flash attention, beam 5, Silero VAD) get faster without
saying different words?

**Answer: not by enough to be worth it. 1.3 s is the practical floor for this app on this chip.**
The only drop-in that is faster is the unquantized f16 model, about 15% faster. It says different
words, not better ones, and it costs a gigabyte more memory. The chip could do the clip in about
0.8 s under MLX, but that means a new runtime in the app and changes 3 to 4% of the words. Nothing
was wired in. Today's behavior is unchanged.

## How it was measured

- **Short clip:** `scripts/testdata/test.wav`, 7.6 s, `LinFlow bench`, warm runs.
- **Long file:** 3 minutes (5:00 to 8:00) of the mic track of a room meeting, cut to the
  scratchpad and deleted afterwards. Meetings are where Whisper minutes add up.
- **Accuracy oracle:** `LinFlow whisper-ab --model-b <file>` (new on this branch). It runs today's
  engine (A) and the candidate (B) one after the other on each of the same 50 takes
  `compare-engines` picks (20 longest plus a spread), with John's settings and glossary. It
  reports how often B's words differ from A's and whether B ever loses a run of 3 or more words.
  Text stays in a local `rows.jsonl`. Run against itself, A vs A gives identical text and speed
  ratios between 0.99x and 1.06x. **Anything inside ±6% is noise.**
- **Load:** three other sessions were building on the Mac (load average 10 to 40). Every
  comparison was interleaved, A then B, and the table uses ratios from those runs, not absolute
  times taken at different moments. The quiet baseline was taken first.

**Where the 1.3 s goes** (whisper-cli's own timings on test.wav): the encoder takes 1.0 s, beam
decoding 0.16 s, VAD 0.04 s. The encoder always processes a full 30 s window, padded, however
short the clip. That is the cost every candidate below goes after.

## Results

| Candidate | test.wav (7.6 s) | 3-min file | Accuracy against today, 50 takes | Setup cost | Verdict |
|---|---|---|---|---|---|
| **Today:** q5_0, Metal, 8 threads, beam 5 | **1.24 to 1.30 s** | **14.3 s** (12.6x real time) | (the oracle) | none | |
| Threads 4 / 6 / 8 | 1.25 / 1.35 / 1.32 s | not run | same model, same text | none | No effect. The work is on the GPU. |
| q8_0 (874 MB) | inconclusive under load | 1.07x (takes over 28 s) | 1.07x overall, inside noise. 24/50 identical, 2.2% of words differ, 4 takes drop 3+ words: 2 are formatting, 1 loses a 10-word clause | 874 MB download, +300 MB RAM | No. Not faster beyond noise, and not cleaner. |
| f16 (1.6 GB) | **1.07 to 1.12 s** (1.15x) | 13.0 to 14.7 s (1.07x) | **1.13x** overall, 1.17x on takes under 10 s. 26/50 identical, 1.8% of words differ, 1 take drops a run | 1.6 GB download, +1 GB RAM, load 2.6 s instead of 0.3 s | Only real drop-in gain, but the words are different, not better. See below. |
| Core ML encoder on the Neural Engine | encode **2.3 to 3.0 s** vs Metal's 1.0 s | not run | not needed: slower | whisper.cpp built from source with `WHISPER_COREML`, 1.2 GB encoder, a 50 s compile on first load, 8 s to load each time | No. On the M1 Pro the GPU beats the ANE for this encoder. |
| Encoder window fitted to the clip (`audio_ctx`) | **0.59 s** (2.1x) | 16.8 s, slower, and loses 3 runs of 13 to 46 words | Fails: short takes go into repetition loops ("X, so X, so X..."), 315% of words differ, 14 of 21 short takes lose words. Slower overall because of the loops | none, one parameter | No. Whisper only works on full windows. |
| whisper.cpp 1.9.5 (Homebrew now offers it; this Mac runs 1.9.1) | encode 1.0 s, same as 1.9.1 | not run | not needed: same speed | a source build | No gain. |
| Greedy decoding (beam 1), an existing setting | 1.14 s (1.1x) | 13.2 s (1.04x) | not run | none | Too small to chase. Decoding is 0.16 s of 1.3. |
| **MLX** (mlx-whisper 0.4.3, fp16 turbo, greedy), outside benchmark | **0.82 s** (1.4x vs greedy, 1.5x vs today) | **7.1 s** (1.9x) | 17/50 identical, 3.7% of words differ, 2 long takes drop a run. Short takes: 14/21 identical, 3.3% differ, no drops | Python venv 1 GB + 1.6 GB weights. In the app: a Swift MLX Whisper port, with no beam search and no Silero VAD | This is the chip's real headroom. Not worth a new runtime today. |

### What f16 changes

f16 is the unquantized model and q5_0 approximates it, so f16 might be expected to win every
disagreement. It doesn't. Reading the 55 differing spans: about half are fillers ("um", which
cleanup removes anyway) and number or spelling formats. Of the rest, f16 is right a few times
(it keeps one whole clause q5_0 dropped, and spells one compound word correctly) and wrong a few
times (it mishears the glossary name Jev, garbles an acronym, and turns one 2-second take into
German). That is a different error pattern, not a better one. Only John listening to the audio
could tell which side is right more often, and 0.18 s on a non-default engine is not worth his
time to label.

## Why 1.3 s is the floor here

1. **The encoder is fixed.** 1.0 s of the 1.3 s is one pass over a padded 30 s window. Shrinking
   the window breaks the model (the loops above). The Neural Engine is 2 to 3 times slower than
   the GPU at it on the M1 Pro. Threads, the whisper.cpp version and q8_0 move nothing. f16 saves
   about 0.15 s.
2. **The remaining headroom needs a different runtime.** MLX also encodes the full padded
   window and still finishes the clip in 0.82 s, so its gain is faster fp16 GPU kernels. Getting that into Lin Flow means an MLX Whisper in Swift beside
   whisper.cpp, without beam search or Silero VAD, so it would need its own accuracy work, and it
   already disagrees on 3 to 4% of words.
3. **Whisper is off the hot path.** English dictation is Parakeet at 0.14 s. Whisper's 1.3 s
   applies to Khmer, Chinese and Japanese dictation and to an empty take's rescue. Meetings are
   re-transcribed after they end, at about 13x real time: each 30-minute track takes about 2.5
   minutes, less where it is silent.

## Not covered

- **Other languages.** John's saved takes are English, so the oracle never tested Khmer, Chinese
  or Japanese, which is the dictation Whisper actually does. If MLX or f16 comes back, the oracle
  needs takes in those languages first.
- **Other chips.** The Neural Engine on M3 and M4 is faster than on the M1. Core ML might
  win there. The Windows machines run on CPU and none of this applies.
- The `large-v3-turbo-q8_0` catalog note says "Marginally better". These 50 takes don't show that.

## When to revisit

- If John starts dictating Khmer or Chinese every day, MLX is the one to try: port it, then hold
  it to `whisper-ab`-style checks on takes in those languages.
- On a newer Mac, run `LinFlow bench scripts/testdata/test.wav` and the Core ML row again.
- `LinFlow whisper-ab --model-b <file>` checks any new ggml model in one command.
