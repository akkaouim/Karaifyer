# Phase 0: results (2026-10-12)

Full pipeline (manifest → show folders → risk report) run on 4 test tracks chosen by Michel, recorded with SysRec. Run at `nice 19` while a SysRec batch was recording on the same Mac.

| id | Track | Case tested | Lyrics | Sync | Tempo | Click drift |
|---|---|---|---|---|---|---|
| 005 | Danser, Loïc Nottet | steady tempo | LRCLIB synced | **100 %** | 100.0 BPM, **0.4 %** (stable) | **16 ms** |
| 011 | Speed, Zazie | drifting tempo | LRCLIB plain + WhisperX alignment | 100 % | 111.1 BPM, 53 % (slow intro, then faster): flagged | 15 ms |
| 012 | Le petit bal perdu, Bourvil (1961) | old recording | LRCLIB synced | 97 % | 142.9 BPM, 4.5 %: genuine 143 ↔ 147.5 BPM verse/chorus push, flagged | 32 ms |
| 041 | La chanson des blés d'or, Fabienne Thibeault | no lyrics | none (as expected): flagged « sans paroles » | n/a | rubato, beat tracking unreliable: flagged | 38 ms |

Every folder holds the 9 FLACs (accompaniment, click, guide vocal, 6 stems) with **identical sample counts**, plus `paroles.lrc`, `paroles.mp4` (1920x1080, no audio, within 0.015 s of the audio length), `temps.csv` and `rapport.json`.

## Go / no-go criteria

| Criterion (spec) | Result | Status |
|---|---|---|
| Separation usable by ear, no annoying doubling with the live parts | for Michel to judge: `sortie/*/accompagnement.flac` (here without guitar, bass, piano) | **to listen** |
| Click drift ≤ 30 ms on the steady-tempo track | 16 ms (Danser) | ✅ |
| ≥ 90 % of lyric lines in sync | 100 % / 100 % / 97 % on the 3 tracks that have lyrics | ✅ |
| Generated `.als` opens in Ableton and outputs to the right XR18 channels | deferred to the Ableton plan (Live not installed yet) | pending |
| Full-screen video on the projector, in Ableton | deferred to the Ableton plan | pending |
| Compute time extrapolated to 120 tracks < two nights | 250 s for 847 s of audio (ratio 0.30), so **≈ 2.4 h for 8 h of audio** | ✅ |

Per track (cold): separation 29–32 s, beats 4–5 s, package 4 s, lyrics 0.2–3 s (LRCLIB) or 26 s (WhisperX alignment), video 13–16 s. Disk: about 0.2 GB of deliverables and 0.5 GB of work files per track, so about 85 GB for 120 tracks on Hypermnesia.

## Spec assumptions

- **Machine:** M1 Pro / 16 GB is enough; MPS works for Demucs and Beat This!. ✅
- **60 GB free:** not on the internal disk (14 GB); the workspace is on Hypermnesia (1.5 TB free). Tool envs and models use about 2.5 GB internally. ✅ with the external drive
- **French lyrics coverage:** 3 of the 4 French titles were on LRCLIB (2 synced, 1 plain). The « no lyrics » track needs Michel's text in `paroles/041.txt`.
- **Input files:** SysRec's FLACs match Spotify's duration exactly (the duration check passes trivially).

## Problems found by running on real data, and fixed

1. LRCLIB returned HTTP 503 for every track on the first run → the client now retries with backoff (2/5/10 s); the status is « à réessayer », not « échec ».
2. « Loïc » came decomposed from Spotify's metadata (NFD), so LRCLIB found nothing → all text is normalised to NFC.
3. The LRCLIB search took the first hit within 3 s, which was plain-only while synced hits existed → synced hits are preferred.
4. The tempo-stability measure read Beat This!'s 20 ms frame jitter as variation (Danser 1.6 %) → now measured over 16-beat spans (0.4 %).
5. The runner's marker file for step `beats` overwrote the beats tool's `beats.json` → markers moved to `travail/<id>/etapes/`.
6. WhisperX put the first line at 0 s (the intro absorbed the first word) → alignment starts at the first vocal activity.

## Notes for the full run

- Click drift is measured against drum onsets. On tracks with weak or rubato percussion (041) the number is unreliable: the tempo flag already sends them to manual review.
- `retirer` was `guitar;bass;piano` for all four. Set it per track in the manifest. Rerunning only redoes `package` and `video` for that track.
