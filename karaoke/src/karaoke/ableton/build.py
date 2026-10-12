"""Assemble an Ableton set from Michel's template: songs in sequence (one per set in practice),
one locator each, XR18 fader defaults sent by a MIDI clip at each song start, and an automatic
stop at each song's end. The template file is only read.

Automatic stop: if the template has a MIDI track « Auto stop » (output: IAC Driver bus), a clip at
the end of each song sends CC 119 = 127; Live's Stop button is MIDI-mapped to it once
(`karaoke apprendre-stop`)."""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path

from karaoke.ableton.als import TRACKS, arranger_events, controller_target_id, load_als, save_als, track
from karaoke.ableton.clips import audio_clip, locator, media_info, midi_clip, video_clip
from karaoke.xair import FADER_CC

AUDIO_FILES = ["accompagnement", "clic", "guide_voix", "guitare", "basse", "piano", "batterie", "back_vocals"]
FADER_CLIP_S = 0.5
CLIP_COLOR = 9
AUTO_STOP_TRACK = "Auto stop"
AUTO_STOP_CC = 119
AUTO_STOP_AFTER_S = 0.5


class SetError(ValueError):
    pass


@dataclass(frozen=True)
class SongEntry:
    id: str
    titre: str
    folder: Path
    faders: dict[str, int]


def _check(songs: list[SongEntry]) -> None:
    problems = []
    for s in songs:
        missing = [f"{n}.flac" for n in AUDIO_FILES if not (s.folder / f"{n}.flac").exists()]
        if not (s.folder / "paroles.mp4").exists():
            missing.append("paroles.mp4")
        if missing:
            problems.append(f"{s.id} ({s.folder.name}) : manque {', '.join(missing)}")
    if problems:
        raise SetError("Fichiers manquants, relancer « karaoke traiter » :\n" + "\n".join(problems))


def build_set(template: Path, songs: list[SongEntry], out: Path, gap_s: float = 4.0) -> dict:
    _check(songs)
    tree = load_als(template)
    ls = tree.getroot().find("LiveSet")
    # The template may have been saved with the playhead mid-arrangement: open every set at 0.
    ls.find("Transport/CurrentTime").set("Value", "0")
    events = {k: arranger_events(track(ls, name)) for k, name in TRACKS.items()}
    faders_track = track(ls, TRACKS["faders"])
    target_ids = {cc: controller_target_id(faders_track, cc) for ccs in FADER_CC.values() for cc in ccs}
    loc_list = ls.find("Locators/Locators")
    warnings = []
    try:
        stop_track = track(ls, AUTO_STOP_TRACK)
        stop_events = arranger_events(stop_track)
        stop_ids = {AUTO_STOP_CC: controller_target_id(stop_track, AUTO_STOP_CC)}
    except KeyError:
        stop_events = None
        warnings.append(f"piste MIDI « {AUTO_STOP_TRACK} » absente du gabarit : pas d'arrêt automatique")
    t, names = 0.0, []
    for i, s in enumerate(songs):
        infos = {n: media_info(s.folder / f"{n}.flac", out.parent) for n in AUDIO_FILES}
        clips = {n: audio_clip(info, t, n, CLIP_COLOR) for n, info in infos.items()}
        clips["video"] = video_clip(media_info(s.folder / "paroles.mp4", out.parent), t, "paroles")
        clips["faders"] = midi_clip(t, FADER_CLIP_S, s.faders, target_ids, FADER_CC)
        for k, clip in clips.items():
            clip.set("Id", str(i))          # clips are numbered within each track's list, as Live does
            events[k].append(clip)
        if stop_events is not None:
            stop = midi_clip(t + infos["accompagnement"].seconds + AUTO_STOP_AFTER_S, FADER_CLIP_S,
                             {"stop": 127}, stop_ids, {"stop": [AUTO_STOP_CC]})
            stop.set("Id", str(i))
            stop_events.append(stop)
        name = f"{s.id} {s.titre}"
        loc_list.append(locator(t, name, i))
        names.append(name)
        t += infos["accompagnement"].seconds + gap_s
    save_als(tree, out)
    return {"songs": len(songs), "duration_s": max(0.0, t - gap_s), "locators": names, "warnings": warnings}
