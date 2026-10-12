"""Arrangement clips and locators, built from Michel's reference snippets (Live 12.4.6).

Arrangement time is in beats at the template's 120 BPM: beats = seconds × 2. Clips are
unwarped, so their loop fields are in seconds (as Live writes them).
"""
from __future__ import annotations
import os
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import soundfile as sf

from karaoke.ableton.als import snippet

BEATS_PER_SECOND = 2.0      # template tempo 120 BPM
DEFAULT_EVENT_TIME = "-63072000"   # Live's "default value" envelope point


def _num(x: float) -> str:
    x = float(x)
    return str(int(x)) if x == int(x) else repr(x)


def _set(el: ET.Element, path: str, value) -> None:
    el.find(path).set("Value", value if isinstance(value, str) else _num(value))


@dataclass(frozen=True)
class MediaInfo:
    path: Path
    rel_path: str      # relative to the set's folder (Live's RelativePath)
    frames: int        # samples at 44.1 kHz (Live's DefaultDuration)
    seconds: float
    size: int
    mtime: int


def media_info(path: Path, set_dir: Path) -> MediaInfo:
    st = path.stat()
    if path.suffix.lower() == ".mp4":
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                              "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True, check=True)
        seconds = float(out.stdout.strip())
        frames = int(seconds * 44100)
    else:
        info = sf.info(str(path))
        frames, seconds = info.frames, info.frames / info.samplerate
    return MediaInfo(path, os.path.relpath(path, set_dir), frames, seconds, st.st_size, int(st.st_mtime))


def _media_clip(kind: str, info: MediaInfo, start_s: float, name: str, color: int | None) -> ET.Element:
    c = snippet(kind)
    start = start_s * BEATS_PER_SECOND
    c.set("Time", _num(start))
    _set(c, "CurrentStart", start)
    _set(c, "CurrentEnd", start + info.seconds * BEATS_PER_SECOND)
    _set(c, "Loop/LoopEnd", info.seconds)
    _set(c, "Loop/HiddenLoopEnd", info.seconds)
    # as written by Live 12.4.6: beats for audio clips, seconds for the video clip
    _set(c, "Loop/OutMarker", info.seconds * BEATS_PER_SECOND if kind == "audioclip" else info.seconds)
    _set(c, "Name", name)
    if color is not None:
        _set(c, "Color", str(color))
    _set(c, "ScrollerTimePreserver/RightTime", info.seconds)
    fr = c.find("SampleRef/FileRef")
    _set(fr, "RelativePath", info.rel_path)
    _set(fr, "Path", str(info.path))
    _set(fr, "OriginalFileSize", str(info.size))
    _set(fr, "OriginalCrc", "0")      # Live's private checksum; validated in Live (plan Task 7)
    _set(c, "SampleRef/LastModDate", str(info.mtime))
    _set(c, "SampleRef/DefaultDuration", str(info.frames))
    _set(c, "SampleRef/DefaultSampleRate", "44100")
    return c


def audio_clip(info: MediaInfo, start_s: float, name: str, color: int) -> ET.Element:
    return _media_clip("audioclip", info, start_s, name, color)


def video_clip(info: MediaInfo, start_s: float, name: str) -> ET.Element:
    return _media_clip("videoclip", info, start_s, name, None)


def midi_clip(start_s: float, length_s: float, values: dict[str, int], target_ids: dict[int, str],
              fader_cc: dict[str, list[int]]) -> ET.Element:
    """A MIDI clip whose CC envelopes hold each part's fader value for the whole clip."""
    c = snippet("midiclip")
    start, length = start_s * BEATS_PER_SECOND, length_s * BEATS_PER_SECOND
    c.set("Time", _num(start))
    _set(c, "CurrentStart", start)
    _set(c, "CurrentEnd", start + length)
    for p in ("Loop/LoopEnd", "Loop/HiddenLoopEnd", "Loop/OutMarker"):
        _set(c, p, length)
    envs = c.find("Envelopes/Envelopes")
    template = envs.find("ClipEnvelope")
    for e in list(envs):
        envs.remove(e)
    n = 0
    for part, value in values.items():
        for cc in fader_cc[part]:
            e = ET.fromstring(ET.tostring(template))
            e.set("Id", str(n))
            e.find("EnvelopeTarget/PointeeId").set("Value", target_ids[cc])
            events = e.find("Automation/Events")
            for ev in list(events):
                events.remove(ev)
            ET.SubElement(events, "FloatEvent", Id="0", Time=DEFAULT_EVENT_TIME, Value=str(value))
            ET.SubElement(events, "FloatEvent", Id="1", Time="0", Value=str(value))
            envs.append(e)
            n += 1
    return c


def locator(time_s: float, name: str, id_: int) -> ET.Element:
    loc = snippet("locator")
    loc.set("Id", str(id_))
    _set(loc, "Time", time_s * BEATS_PER_SECOND)
    _set(loc, "Name", name)
    return loc
