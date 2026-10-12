# Phase 0 spike: ML tools on the target Mac (2026-10-12)

Machine: MacBook Pro M1 Pro, 16 GB. Test track: « Le petit bal perdu » (Bourvil), 196.9 s, recorded by SysRec at 44.1 kHz.

| Tool | Version | Device | Wall time (model already downloaded) | Result |
|---|---|---|---|---|
| Demucs `htdemucs_6s` | demucs 4.0.1, torch 2.8.0, torchaudio 2.8.0 | MPS | 44 s (26 s of which is separation) | 6 stems OK |
| Beat This! `final0` | beat-this 1.1.0 (git b95c8ab), torch 2.8 | MPS | 5 s | 468 beats, 156 downbeats, so 3 beats per bar (correct, it's a waltz), about 145 BPM |
| WhisperX alignment (`fr`, wav2vec2) | whisperx 3.8.6, torch 2.8.0 | CPU | 26 s | 39/39 lines aligned |

**Projection:** about 75 s of ML time per 3–4 minute track, so roughly **2.5 h for 120 tracks**, plus FLAC/video packaging. That's well under the 10 h target.

## Alignment accuracy (measured)

The plain lyric lines were aligned on the Demucs vocal stem and compared with LRCLIB's synced timestamps for the same recording (« Exclusive (2022 Remastered) », 197.7 s):

- median offset 0.00 s; 30/39 lines within the display window (−0.3 s … +0.1 s), 32/39 within ±0.3 s; worst +1.21 s.
- First version placed line 1 at 0.0 s (the single alignment segment started at 0, so the first word absorbed the intro). **Fix:** the segment now starts where the vocal stem first exceeds −40 dBFS (minus 0.2 s). Line 1 then lands at 8.57 s against the reference 8.95 s.

## Workarounds and findings

- **demucs 4.0.1 + torchaudio ≥ 2.9 can't save files.** Newer torchaudio needs the separate `torchcodec` package to write audio. Pinned `torch==2.8.*`, `torchaudio==2.8.*` in `tools/separate`.
- **LRCLIB returned a transient HTTP 503** once; that's handled as « à réessayer ».
- **LRCLIB `/api/get` returned 404** for this recording's album name, but `/api/search` returned 8 hits within 3 s of the duration. The first hit had only plain lyrics while others had synced lyrics. **So the search fallback must prefer synced hits**, then the closest duration (Task 8 ruling).
- Disk on the internal SSD: tool venvs 2.1 GB, torch hub cache 0.5 GB, WhisperX French model in `~/.cache/huggingface`. Free space after install: 13 GB.
