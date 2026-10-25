# Live Lyrics Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Swift renderer draws the lyrics video, with the new « Grille + paroles » layout (default) or the current
« Accords sur les paroles », on an animated neon background. It is used live in the Lecteur (with transposed chords),
for export, and by the pipeline's video step through a `karaifyer-render` tool.

**Architecture:**
- **The scene.** The pipeline keeps computing display states with its tested timeline code. It writes them, with
  beats, bars, key, title, artist and layout, to `sortie/<dossier>/video.json`.
- **The renderer.** KaraifyerCore gets:
  - `VideoScene` (decoding);
  - `VideoClock` (grid paging, beat position, animation values, all pure functions of `t`);
  - `ChordText.transpose`;
  - `KaraokeRenderer.draw(scene, t, ctx, size, options)` (Core Graphics + Core Text);
  - `VideoExporter` (AVAssetWriter).
- **The tool.** A new executable target `karaifyer-render` turns a scene into an MP4. `build-app.sh` puts it in the
  app bundle, and the app sets `KARAOKE_RENDERER` and `KARAOKE_VIDEO_LAYOUT` for the pipeline.
- **The Lecteur** replaces its AVPlayer with a live view on the display link.

**Tech Stack:**
- **Python 3.11 + pytest:** `uv --directory karaoke run pytest -q`.
- **Swift 6 / SwiftPM** (Command Line Tools only; Swift Testing:
  `swift test --package-path karaifyer -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`).
- **Frameworks:** Core Graphics, Core Text, AVFoundation.

**Spec:** `docs/superpowers/specs/2026-10-25-live-video-design.md`

## Global Constraints

- **Frame:** 1920×1080, 25 fps, H.264 yuv420p.
- **Fonts:** Arial Bold (`Arial-BoldMT`), Arial (`ArialMT`), Arial Unicode (`ArialUnicodeMS`) for ♪ ●.
- **Colours:**
  - background `#0b0b14`;
  - bricks `#1b1b26` / mortar `#101018`;
  - frame cyan `#3ee6ff`;
  - title pink `#ff4fd8`;
  - sung text yellow `#ffd600`;
  - text white;
  - secondary grey `#969696`;
  - chord light blue `#78c8ff`;
  - current bar yellow;
  - countdown red `#ff5050`.
- **Geometry, « Grille + paroles »:**
  - **Frame:** rectangle inset 60 px, corner radius 18, line 6 px plus glow.
  - **Title:** centred on the top edge, 64 pt bold, with the frame line interrupted 30 px either side.
  - **Grid:** 2 rows × 4 cells, x 140…1780, row 1 y 170…330, row 2 y 350…510.
    - Chords: 64 pt bold, at their beat's x inside the cell.
    - Beat cursor: a 10 px pill under the active beat of the current bar, row 1.
    - Row 2 is dimmed to 55 %.
  - **Lyrics:**
    - current line 88 pt bold, centred, wrapped at 1680 px, from y 610;
    - next line 60 pt grey from y 860;
    - countdown 140 pt red centred at y 560.
- **Geometry, « Accords sur les paroles »:** today's `render.py` positions inside the same frame (chords over
  syllables, the 4-bar row during instrumentals, the preview).
- **Motion, deterministic in `t`:**
  - title brightness `0.85 + 0.15·sin(2πt/4)`;
  - flicker: in each 7 s window, at the offset `hash(window) mod 6 s`, brightness drops to 0.35 for 0.12 s;
  - frame glow `0.55 + 0.45·exp(−Δ/0.25)` after a beat (Δ seconds since the beat), with a ×1.6 amplitude on beat 1.
- **Layouts:** `"grille"` (default) | `"paroles"`; env `KARAOKE_VIDEO_LAYOUT`; UserDefaults keys `videoLayout`
  (Karaoké tab) and `playerVideoLayout` (Lecteur).
- **Renderer path:** env `KARAOKE_RENDERER`, else `karaifyer/.build/release/karaifyer-render` if built. If neither
  exists, the step uses the Python renderer with the « paroles » layout and logs « rendu vidéo : moteur Python (sans
  animation) ».
- **The video step:** `version` "9". Its key adds `layout` and `renderer` ("swift" | "python").
- **Unchanged:** SysRec is never touched.

## Review Focus

1. **A song with no chords, or no bars** (chord detection failed): the grid area shows « ♪ », and nothing crashes.
   Covered by `gridWithoutBars` (Task 2) and `test_scene_without_bars` (Task 1).
2. **`t` before the count-in, past the end, inside the last partial row, or a 1-bar song:** paging must not index out
   of range. Covered by `pagingEdges` (Task 2).
3. **The live view at a high frame rate** must not allocate per frame: no re-wrapping of text unchanged since the
   last state. Covered by caching wrapped lines per state id (Task 3) and a 60-frame timing test (`drawsFast`,
   Task 3).
4. **Export at a tempo other than 1.0:** the video must match the stretched audio exactly (frame `k` drawn at song
   time `k/25·rate`). Covered by `exportDurationFollowsRate` (Task 4).
5. **A machine without the renderer** (command line only): the pipeline falls back without error. Covered by
   `test_video_falls_back_without_renderer` (Task 1).

---

### Task 1: Pipeline — scene JSON, layout, renderer call with fallback

**Files:**
- Modify: `karaoke/src/karaoke/steps/video.py`
- Test: `karaoke/tests/test_video.py`

**Interfaces:**
- Produces: `sortie/<dossier>/video.json` with this structure:

```json
{"version": 1, "layout": "grille", "titre": "...", "artiste": "...", "key": "Ab major",
 "pad_s": 4.78, "total_s": 201.7, "beats": [0.42, ...],
 "bars": [{"start": 4.80, "beats": 4, "chords": [[0, "Fm"], [2, "Cm"]]}],
 "states": [{"start": 0.0, "end": 4.3, "kind": "titre", "current": "...", "next": "...", "countdown": null,
             "lit": 0, "chords": [[3, "Am"]], "chart": ["Am F"], "chart_pos": 0, "next_chords": []}]}
```

- Bar times and beats are in show time. A bar's `beats` count is taken from the beat grid.
- The step functions are `scene(...) -> dict`, `renderer() -> Path | None` and `layout() -> str`.

- [ ] **Step 1: Failing tests** (append to `test_video.py`; reuse that file's existing fixtures/fakes for the video
  step inputs)

```python
def test_scene_json_written_and_swift_renderer_called(cfg, monkeypatch, tmp_path):
    import json
    from karaoke.steps import video as V
    fake = tmp_path / "karaifyer-render"
    fake.write_text("#!/bin/sh\ntouch \"$2\"\n"); fake.chmod(0o755)
    monkeypatch.setenv("KARAOKE_RENDERER", str(fake))
    monkeypatch.setenv("KARAOKE_VIDEO_LAYOUT", "grille")
    ws, up = video_inputs(cfg)                      # helper: the same upstream dict the existing tests build
    V.VIDEO.run(ws, up)
    sc = json.loads((ws.out / "video.json").read_text())
    assert sc["layout"] == "grille" and sc["states"] and sc["beats"][0] >= up["package"]["pad_s"] - 1
    assert all(set(b) == {"start", "beats", "chords"} for b in sc["bars"])
    assert (ws.out / "paroles.mp4").exists()
    assert V.VIDEO.version == "9" and "|grille|swift" in V.VIDEO.key(ws)


def test_video_falls_back_without_renderer(cfg, monkeypatch):
    from karaoke.steps import video as V
    monkeypatch.setenv("KARAOKE_RENDERER", "/nonexistent")
    monkeypatch.setattr(V, "DEFAULT_RENDERER", __import__("pathlib").Path("/nonexistent"))
    called = []
    monkeypatch.setattr(V, "render_video", lambda states, out, work: (called.append(1), out.write_bytes(b"x")))
    ws, up = video_inputs(cfg)
    V.VIDEO.run(ws, up)
    assert called and "moteur Python" in (ws.work / "journal.log").read_text() and "|python" in V.VIDEO.key(ws)


def test_scene_without_bars(cfg, monkeypatch, tmp_path):
    import json
    from karaoke.steps import video as V
    monkeypatch.setattr(V, "render_video", lambda states, out, work: out.write_bytes(b"x"))
    monkeypatch.setenv("KARAOKE_RENDERER", "/nonexistent")
    monkeypatch.setattr(V, "DEFAULT_RENDERER", __import__("pathlib").Path("/nonexistent"))
    ws, up = video_inputs(cfg)
    up["chords"] = {"bars": [], "changes": []}
    V.VIDEO.run(ws, up)
    assert json.loads((ws.out / "video.json").read_text())["bars"] == []
```

If `test_video.py` has no `video_inputs` helper, write one there from its existing video-step test's setup: the
package/beats/lyrics/check/chords upstream and a workspace. Moving existing setup into a helper is not a deviation.

- [ ] **Step 2: Run to verify they fail.** `uv --directory karaoke run pytest -q tests/test_video.py`. Expected:
  FAIL (no `video.json`, version "8").

- [ ] **Step 3: Implement** in `steps/video.py`:

```python
import json, os, subprocess
from pathlib import Path
DEFAULT_RENDERER = Path(__file__).resolve().parents[4] / "karaifyer" / ".build" / "release" / "karaifyer-render"


def layout() -> str:
    v = os.environ.get("KARAOKE_VIDEO_LAYOUT", "grille")
    return v if v in ("grille", "paroles") else "grille"


def renderer() -> Path | None:
    for p in (os.environ.get("KARAOKE_RENDERER"), str(DEFAULT_RENDERER)):
        if p and Path(p).is_file() and os.access(p, os.X_OK):
            return Path(p)
    return None


def scene(ws, states, beats, chords: dict, pad: float, total: float) -> dict:
    bars, starts = [], [b["start"] + pad for b in chords.get("bars", [])]
    for k, b in enumerate(chords.get("bars", [])):
        s = starts[k]
        e = starts[k + 1] if k + 1 < len(starts) else total
        bars.append({"start": round(s, 3), "beats": max(1, sum(1 for t in beats if s - 1e-3 <= t < e - 1e-3)),
                     "chords": [[i, c] for i, c in b["chords"]]})
    st = [{"start": round(x.start, 3), "end": round(x.end, 3), "kind": x.kind, "current": x.current, "next": x.next,
           "countdown": x.countdown, "lit": x.lit, "chords": [list(c) for c in x.chords], "chart": list(x.chart),
           "chart_pos": x.chart_pos, "next_chords": [list(c) for c in x.next_chords]} for x in states]
    return {"version": 1, "layout": layout(), "titre": ws.song.titre, "artiste": ws.song.artiste,
            "key": chords.get("key"), "pad_s": pad, "total_s": total, "beats": [round(b, 3) for b in beats],
            "bars": bars, "states": st}
```

In `_run`, after `states = with_chart(states, bars, 4)`:

```python
    sc = scene(ws, states, beats, chords, pad, total)
    (ws.out / "video.json").write_text(json.dumps(sc, ensure_ascii=False), encoding="utf-8")
    r = renderer()
    if r:
        subprocess.run([str(r), str(ws.out / "video.json"), str(ws.out / "paroles.mp4")], check=True)
    else:
        ws.log("rendu vidéo : moteur Python (sans animation)")
        render_video(states, ws.out / "paroles.mp4", ws.work / "frames")
```

- The key becomes
  `lambda ws: f"{ws.song.titre}|{ws.song.artiste}|{layout()}|{'swift' if renderer() else 'python'}"`, with
  `version="9"` (comment: « 9: scène video.json, rendu Swift (grille + paroles, néon) »).
- Add `ws.out / "video.json"` to `artifacts`.
- Update the existing test that pins version "8".

- [ ] **Step 4: Run the whole Python suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaoke/src/karaoke/steps/video.py karaoke/tests/test_video.py
git commit -m "karaoke: video step writes the scene (video.json) and calls karaifyer-render, Python fallback"
```

---

### Task 2: KaraifyerCore — scene model, clock, transposition

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/VideoScene.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/VideoSceneTests.swift`

**Interfaces:**
- Produces:
  - `VideoScene: Decodable` (fields as the JSON; `VideoScene.State`, `VideoScene.Bar`; `layout: String`);
  - `VideoScene.load(url:) throws -> VideoScene`;
  - `VideoClock.state(_ s: VideoScene, at t: Double) -> VideoScene.State?` (binary search);
  - `VideoClock.grid(_ s: VideoScene, at t: Double) -> Grid?`, where `Grid { rows: [[Int]]` (bar indices, ≤ 2 rows
    of ≤ 4); `activeBar: Int?`; `activeBeat: Int?` }; nil when there are no bars;
  - `VideoClock.titleBrightness(t:) -> Double`;
  - `VideoClock.frameGlow(t:, beats:, downbeats: Set<Int>) -> Double`;
  - `ChordText.transpose(_ symbol: String, by n: Int, flats: Bool) -> String`;
  - `ChordText.prefersFlats(key: String?, shift: Int) -> Bool`.

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import KaraifyerCore

struct VideoSceneTests {
    func scene(bars n: Int) -> VideoScene {
        let bars = (0..<n).map { VideoScene.Bar(start: 4.0 + Double($0) * 2, beats: 4, chords: [ChordAt(beat: 0, label: "C")]) }
        let beats = (0..<(n * 4 + 8)).map { Double($0) * 0.5 }
        return VideoScene(version: 1, layout: "grille", titre: "T", artiste: "A", key: "C major", padS: 4, totalS: 4 + Double(n) * 2,
                          beats: beats, bars: bars, states: [VideoScene.State(start: 0, end: 100, kind: "ligne", current: "la", next: "",
                          countdown: nil, lit: 0, chords: [], chart: [], chartPos: nil, nextChords: [])])
    }

    @Test func pagingKeepsTheActiveRowOnTop() {
        let s = scene(bars: 10)
        #expect(VideoClock.grid(s, at: 4.1)!.rows == [[0, 1, 2, 3], [4, 5, 6, 7]])
        let g = VideoClock.grid(s, at: 12.6)!                        // bar 4 (starts 12.0), beat 2
        #expect(g.rows == [[4, 5, 6, 7], [8, 9]] && g.activeBar == 4 && g.activeBeat == 1)
    }

    @Test func pagingEdges() {
        let s = scene(bars: 10)
        #expect(VideoClock.grid(s, at: 1.0)!.activeBar == nil)          // count-in: first 8 bars, none active
        #expect(VideoClock.grid(s, at: 999)!.rows.first == [8, 9])       // past the end: last row
        #expect(VideoClock.grid(scene(bars: 1), at: 4.5)!.rows == [[0]])
    }

    @Test func gridWithoutBars() {
        #expect(VideoClock.grid(scene(bars: 0), at: 5) == nil)
    }

    @Test func animationIsDeterministicAndPeaksOnBeatOne() {
        #expect(VideoClock.titleBrightness(t: 12.34) == VideoClock.titleBrightness(t: 12.34))
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0]
        let down = VideoClock.frameGlow(t: 2.01, beats: beats, downbeats: [4])
        let other = VideoClock.frameGlow(t: 1.51, beats: beats, downbeats: [4])
        #expect(down > other && other > VideoClock.frameGlow(t: 1.95, beats: beats, downbeats: [4]))
    }

    @Test func chordTransposition() {
        #expect(ChordText.transpose("Em", by: 1, flats: true) == "Fm")
        #expect(ChordText.transpose("D/F#", by: 1, flats: true) == "Eb/G")
        #expect(ChordText.transpose("Asus4", by: 2, flats: false) == "Bsus4")
        #expect(ChordText.transpose("N.C.", by: 3, flats: false) == "N.C.")
        #expect(ChordText.prefersFlats(key: "C major", shift: -2) == true)    // Bb major
        #expect(ChordText.prefersFlats(key: "C major", shift: 2) == false)    // D major
    }

    @Test func decodesTheSceneJSON() throws {
        let json = #"{"version":1,"layout":"grille","titre":"T","artiste":"A","key":null,"pad_s":4.8,"total_s":10,"beats":[0.4],"bars":[{"start":4.8,"beats":4,"chords":[[0,"Fm"]]}],"states":[{"start":0,"end":4,"kind":"titre","current":"T","next":"","countdown":null,"lit":0,"chords":[[3,"Am"]],"chart":["Am"],"chart_pos":0,"next_chords":[]}]}"#
        let s = try JSONDecoder.snake.decode(VideoScene.self, from: Data(json.utf8))
        #expect(s.padS == 4.8 && s.bars[0].chords[0].label == "Fm" && s.states[0].chords[0].label == "Am" && s.states[0].chartPos == 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'VideoScene'`.

- [ ] **Step 3: Implement** `VideoScene.swift`:
  - The `Codable` structs mirror the JSON. `chords` and `next_chords` are `[ChordAt]`: an `[offset, label]` pair
    decodes as `ChordAt(beat: offset, label:)`, already Codable as `[Int, String]`.
  - Add `extension JSONDecoder { static var snake: JSONDecoder }` (`convertFromSnakeCase`).
  - **`VideoClock.state`:** binary search on `start`.
  - **`VideoClock.grid`:**
    - `b` = the last bar with `start <= t`, or nil before the first.
    - `row0` = `(b ?? 0) / 4 * 4`, clamped so the last row stays on top past the end.
    - `rows` = `[row0..<row0+4, row0+4..<row0+8]`, clipped to the bar count, with empty rows dropped.
    - `activeBeat` = the number of beats with `bar.start <= beat <= t`, minus 1, clamped to `bar.beats - 1`.
  - **`titleBrightness`:** `0.85 + 0.15 * sin(2π t / 4)`, times the flicker factor.
    - The flicker uses window `w = Int(t / 7)` and offset `o = Double(hash32(w) % 6000) / 1000`, where `hash32` is a
      fixed integer hash (`w &* 2654435761`).
    - Inside `[w·7 + o, w·7 + o + 0.12)`, multiply by 0.35/0.85.
  - **`frameGlow`:** find the last beat index `i` with `beats[i] <= t`, and `Δ = t − beats[i]`. The amplitude is 1.6
    when `downbeats.contains(i)`, else 1. Return `min(1, 0.55 + 0.45 · amp · exp(−Δ / 0.25))`.
  - **Downbeats:** passed in as the beat indices of bar starts. Add `VideoScene.downbeatIndices` (the nearest beat to
    each bar start).
  - **`ChordText.transpose`:**
    - parse `^([A-G][#b]?)([^/]*)(?:/([A-G][#b]?))?$`;
    - shift the root and bass pitch classes, spelled from the sharp table `C C# D D# E F F# G G# A A# B` or the flat
      table `C Db D Eb E F Gb G Ab A Bb B`;
    - leave `N.C.` or anything unparsable unchanged.
  - **`ChordText.prefersFlats`:** the key's major tonic (minor → +3), plus the shift, falls in `{1, 3, 5, 6, 8, 10}`.

- [ ] **Step 4: Run the Swift suite.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/VideoScene.swift karaifyer/Tests/KaraifyerCoreTests/VideoSceneTests.swift
git commit -m "karaifyer: video scene model, grid paging, deterministic animation, chord transposition"
```

---

### Task 3: KaraifyerCore — `KaraokeRenderer` (both layouts, neon background)

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/KaraokeRenderer.swift`
- Test: `karaifyer/Tests/KaraifyerCoreTests/KaraokeRendererTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces:
  - `KaraokeRenderer` (final class, owns caches);
  - `init(scene:)`;
  - `func draw(at t: Double, in ctx: CGContext, size: CGSize, layout: String, transpose: Int)`;
  - `static func bitmap(width:height:) -> CGContext` (BGRA, premultiplied).

- [ ] **Step 1: Failing tests**

```swift
import CoreGraphics
import Foundation
import Testing
@testable import KaraifyerCore

struct KaraokeRendererTests {
    func scene() -> VideoScene {
        let bars = (0..<8).map { VideoScene.Bar(start: 4 + Double($0) * 2, beats: 4, chords: [ChordAt(beat: 0, label: "Am"), ChordAt(beat: 2, label: "F")]) }
        return VideoScene(version: 1, layout: "grille", titre: "Tout le bonheur du monde", artiste: "Sinsémilia", key: "C major",
                          padS: 4, totalS: 20, beats: (0..<40).map { Double($0) * 0.5 }, bars: bars,
                          states: [VideoScene.State(start: 0, end: 20, kind: "ligne", current: "On vous souhaite tout le bonheur du monde",
                                                    next: "Et que quelqu'un vous tende la main", countdown: nil, lit: 12,
                                                    chords: [ChordAt(beat: 0, label: "Am")], chart: [], chartPos: nil, nextChords: [])])
    }

    func lit(_ ctx: CGContext, _ rect: CGRect) -> Int {          // pixels clearly brighter than the background
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self), w = ctx.width
        var n = 0
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 4) {
            let p = (y * w + x) * 4; if Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2]) > 300 { n += 1 } } }
        return n
    }

    @Test func drawsTitleGridAndLyrics() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 6.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0)
        // CG origin is bottom-left: top band = high y
        #expect(lit(ctx, CGRect(x: 600, y: 1000, width: 720, height: 70)) > 50)      // neon title
        #expect(lit(ctx, CGRect(x: 140, y: 750, width: 1640, height: 160)) > 50)     // grid row 1
        #expect(lit(ctx, CGRect(x: 140, y: 330, width: 1640, height: 140)) > 50)     // current lyric line
    }

    @Test func oldLayoutAlsoDraws() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        r.draw(at: 6.2, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "paroles", transpose: -2)
        #expect(lit(ctx, CGRect(x: 140, y: 450, width: 1640, height: 300)) > 50)
    }

    @Test func drawsFast() {
        let r = KaraokeRenderer(scene: scene()), ctx = KaraokeRenderer.bitmap(width: 1920, height: 1080)
        let t0 = Date()
        for k in 0..<60 { r.draw(at: 6 + Double(k) / 60, in: ctx, size: CGSize(width: 1920, height: 1080), layout: "grille", transpose: 0) }
        #expect(Date().timeIntervalSince(t0) / 60 < 0.030)          // well under a 25 fps frame, even in debug
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'KaraokeRenderer'`.

- [ ] **Step 3: Implement**, following the Global Constraints geometry. Work in a flipped coordinate space, scaled to
  `size / (1920, 1080)`: `ctx.translateBy(0, h); ctx.scaleBy(sx, -sy)`, and draw text with a text matrix that undoes
  the flip.
  - **Background:**
    - a cached `CGImage` of the brick wall: rows 46 px tall, bricks 120 px wide, offset by half a brick every other
      row, mortar 3 px, slight random tint from a fixed seed so it's stable;
    - the frame: a rounded rect stroked cyan with a shadow blur of `30·glow` and alpha `glow`, where `glow` comes from
      `VideoClock.frameGlow`;
    - the title: « Titre — Artiste » 64 pt bold pink, alpha from `titleBrightness`, shadow blur 25. The frame line is
      cut behind it (stroke the top edge as two segments).
  - **« Grille + paroles »:**
    - **Grid:** from `VideoClock.grid`.
      - Each cell is a rounded rect (alpha 0.08, current bar yellow alpha 0.18).
      - Chords are transposed by `ChordText.transpose(…, flats: prefersFlats(key, transpose))`, drawn at
        `x = cell.minX + 24 + beat / bar.beats · (cell.width − 48)`, white on row 1 and grey on row 2.
      - The beat cursor is a yellow pill 10 px tall under the active beat x.
      - With no bars, draw « ♪ » in grey centred in the grid area.
    - **Lyrics:**
      - the current state's `current`, wrapped at 1680 px; the first `lit` characters yellow, the rest white;
      - `next` grey 60 pt;
      - `countdown` big red when set;
      - for `kind == "titre"` before any line, `next` only;
      - for `kind == "fin"`, nothing in the lyrics area.
  - **« Accords sur les paroles »:** port `render.py`'s `_frame`:
    - chords above syllables (transposed) for « ligne »;
    - the 4-bar `chart` row for « instrumental » / « titre » / « fin »;
    - the preview with dimmed chords;
    - the countdown;
    - all inside the same background.
  - **Caches:**
    - the wrapped lines and Core Text `CTLine`s per `(state index, layout, transpose)`, so a frame where only `t`
      moves re-uses them;
    - the brick image;
    - the fonts.
- [ ] **Step 4: Run the Swift suite.** Expected: all pass, including `drawsFast`. If `drawsFast` misses in debug,
  profile the caches. Don't relax the bound without a ledger ruling.
- [ ] **Step 5: Commit**

```bash
git add karaifyer/Sources/KaraifyerCore/KaraokeRenderer.swift karaifyer/Tests/KaraifyerCoreTests/KaraokeRendererTests.swift
git commit -m "karaifyer: KaraokeRenderer — neon background, bar grid + lyrics layout, chords-over-lyrics layout"
```

---

### Task 4: Export — `VideoExporter`, the `karaifyer-render` tool, app wiring

**Files:**
- Create: `karaifyer/Sources/KaraifyerCore/VideoExporter.swift`
- Create: `karaifyer/Sources/karaifyer-render/main.swift`
- Modify: `karaifyer/Package.swift` (executable target `karaifyer-render`, depends on KaraifyerCore)
- Modify: `karaifyer/build-app.sh` (build and copy `karaifyer-render` into `Karaifyer.app/Contents/MacOS/`)
- Modify: `karaifyer/Sources/Karaifyer/Pipeline.swift` (`env`: `KARAOKE_RENDERER` = the bundled tool if present;
  `KARAOKE_VIDEO_LAYOUT` = UserDefaults `videoLayout` or "grille")
- Test: `karaifyer/Tests/KaraifyerCoreTests/VideoExporterTests.swift`

**Interfaces:**
- Produces:
  - `VideoExporter.export(scene:, to url:, layout:, transpose:, rate: Double = 1, fps: Int = 25, progress: (Double) -> Bool) throws`;
  - `karaifyer-render <scene.json> <out.mp4> [--layout grille|paroles]`, where the layout defaults to the scene's.

- [ ] **Step 1: Failing tests**

```swift
import AVFoundation
import Foundation
import Testing
@testable import KaraifyerCore

struct VideoExporterTests {
    func scene(total: Double) -> VideoScene {
        VideoScene(version: 1, layout: "grille", titre: "T", artiste: "A", key: nil, padS: 1, totalS: total,
                   beats: (0..<12).map { Double($0) * 0.5 }, bars: [VideoScene.Bar(start: 1, beats: 4, chords: [ChordAt(beat: 0, label: "C")])],
                   states: [VideoScene.State(start: 0, end: total, kind: "ligne", current: "la la", next: "", countdown: nil, lit: 2,
                                             chords: [], chart: [], chartPos: nil, nextChords: [])])
    }

    func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    @Test func exportsTheSceneDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).mp4")
        try VideoExporter.export(scene: scene(total: 3), to: url, layout: "grille", transpose: 0) { _ in true }
        #expect(abs(try await duration(url) - 3) < 0.05)
    }

    @Test func exportDurationFollowsRate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).mp4")
        try VideoExporter.export(scene: scene(total: 3), to: url, layout: "grille", transpose: 0, rate: 1.5) { _ in true }
        #expect(abs(try await duration(url) - 2) < 0.05)              // 3 s of song at ×1.5
    }
}
```

- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'VideoExporter'`.

- [ ] **Step 3: Implement.**
  - **`VideoExporter`:**
    - `AVAssetWriter(.mp4)`, an H.264 input of 1920×1080 at 8 Mbps;
    - an `AVAssetWriterInputPixelBufferAdaptor` (32BGRA);
    - frames `k = 0..<Int(ceil(totalS / rate · fps))`;
    - each frame is drawn by `KaraokeRenderer` at `t = k / fps · rate` into the pixel buffer's `CGContext`;
    - presentation time `CMTime(k, fps)`;
    - `progress(k / n)` returning false cancels: the writer is cancelled, the file deleted and `CancellationError`
      thrown.
  - **`main.swift`:** load the scene, export with `progress` printing a percentage every 10 %, exit 1 with the error
    on stderr.
  - **`build-app.sh`:** `swift build -c release --product karaifyer-render`, then copy it next to the app binary.
  - **`Pipeline.env`:**
    - `KARAOKE_RENDERER` = `Bundle.main.bundlePath + "/Contents/MacOS/karaifyer-render"` if it's executable;
    - `KARAOKE_VIDEO_LAYOUT` from UserDefaults.
- [ ] **Step 4: Run the Swift suite. Then a real render:** `swift build -c release --product karaifyer-render` and
  `KARAOKE_RENDERER=<that binary> uv --directory karaoke run karaoke traiter --ids 042 --forcer video`. Expected:
  `video:fait`, and `paroles.mp4` lasts `total_s` (check with `ffprobe`, ±0.05 s). Look at frame 30 s with
  `ffmpeg -ss 30 -frames:v 1` and read the PNG.
- [ ] **Step 5: Commit**

```bash
git add karaifyer/Package.swift karaifyer/build-app.sh karaifyer/Sources karaifyer/Tests
git commit -m "karaifyer: VideoExporter and the karaifyer-render tool; the app passes the renderer and layout to the pipeline"
```

---

### Task 5: Lecteur — live video, disposition, transposition, export

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/PlayerModel.swift`
- Modify: `karaifyer/Sources/Karaifyer/PlayerView.swift`
- Modify: `karaifyer/Sources/Karaifyer/PlayerExport.swift`
- Modify: `karaifyer/Sources/KaraifyerCore/ExportOptions.swift` (the video+master ffmpeg arguments take an
  already-timed video: no `setpts`)
- Test: `karaifyer/Tests/KaraifyerCoreTests/ExportOptionsTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces (UI):
  - `PlayerModel.scene: VideoScene?`, `renderer: KaraokeRenderer?`, `videoLayout` (UserDefaults
    `playerVideoLayout`, default "grille");
  - a `LiveVideoView` (NSView drawing `renderer.draw(at: model.position …)` on `displayLink`);
  - full screen uses the same view.

- [ ] **Step 1: Failing test** (ExportOptions). When given a pre-timed video, `ffmpegArgs` must not contain `setpts`
  or `scale`, and must keep `-shortest` and `+faststart`. Add the parameter `videoTimed: Bool = false`; the export
  passes true. Run it, expect FAIL, implement, expect PASS.
- [ ] **Step 2: Model.**
  - On `load`, read `sortie/<dossier>/video.json` into `scene` and create `renderer`. If it's missing (song analysed
    before this change), keep the AVPlayer path as today and show the caption « Réanalyser pour la vidéo en direct ».
  - `position` already follows the engine, latency-corrected.
  - Remove the AVPlayer resync when a scene exists.
- [ ] **Step 3: View.**
  - **`LiveVideoView`** (NSViewRepresentable):
    - `draw(_:)` calls `renderer.draw(at: model.positionNow, in: NSGraphicsContext.current!.cgContext, size: bounds.size, layout: model.videoLayout, transpose: model.settings.semitones)`;
    - redraws on `displayLink(target:selector:)` (macOS 14+) while playing, and once on seek, pause or settings
      changes.
    - `positionNow` reads the engine directly (not the 10 Hz `position`), so the cursor moves smoothly.
  - Double-click opens full screen with a second `LiveVideoView`.
  - **A « Disposition » picker** in the controls row: « Grille + paroles » / « Accords sur les paroles ».
- [ ] **Step 4: Export.** In `ExportUI.run`, for `videoMaster`:
  - render the video first with `VideoExporter.export(scene:, to: tmpVideo, layout: player.videoLayout, transpose: settings.semitones, rate: player.rate)`, as the first third of the progress;
  - then the offline audio render;
  - then ffmpeg muxing with `videoTimed: true`;
  - when there's no scene, keep today's path.
- [ ] **Step 5: Build and install; Swift suite; commit**

```bash
git add karaifyer/Sources karaifyer/Tests
git commit -m "karaifyer player: live-rendered video (disposition, transposed chords, full screen) and rendered export"
```

---

### Task 6: Karaoké tab layout menu, docs, checklist, re-render

**Files:**
- Modify: `karaifyer/Sources/Karaifyer/KaraokeView.swift` (toolbar menu « Vidéo : Grille + paroles / Accords sur
  les paroles », UserDefaults `videoLayout`)
- Modify: `docs/guide/GUIDE.md`, `docs/karaoke/karaifyer-validation.md`, `karaifyer/README.md`, `karaoke/README.md`

- [ ] **Step 1: Menu.** It sits next to « Rapport ». Changing it saves the UserDefaults key, which `Pipeline.env`
  already reads. Add a help line: « appliqué aux vidéos rendues par l'analyse (paroles.mp4, sets Ableton) ».
- [ ] **Step 2: Docs.**
  - **Guide:** the new video (layout, neon, motion), the Lecteur's live video, « Disposition » and transposed chords,
    and the export.
  - **Checklist rows:**
    - Lecteur: live video in sync, full screen too; « Hauteur » transposes the chords shown; « Disposition »
      switches the layout; export keeps the layout;
    - Karaoké tab: the « Vidéo » menu changes the rendered `paroles.mp4`.
  - **READMEs:** `karaifyer-render` and the two environment variables.
- [ ] **Step 3: Real check.**
  - Build and install the app.
  - Then `KARAOKE_RENDERER=~/Applications/Karaifyer.app/Contents/MacOS/karaifyer-render uv --directory karaoke run karaoke traiter --ids 005 --forcer video`.
  - Expected: `video:fait` and a 30 s frame showing the grid and lyrics. Read the extracted PNG.
- [ ] **Step 4: Commit**

```bash
git add karaifyer docs karaoke/README.md
git commit -m "karaifyer: video layout menu in the Karaoké tab; docs"
```
