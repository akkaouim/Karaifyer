"""Read/write Ableton .als files (gzip XML) and find the template's parts."""
from __future__ import annotations
import gzip
import importlib.resources
import xml.etree.ElementTree as ET
from pathlib import Path

# pipeline key -> track name in Michel's template (tracks are looked up by name)
TRACKS = {"accompagnement": "Accompagnement", "clic": "Clic", "guide_voix": "Guide Voix",
          "guitare": "Guitare", "basse": "Basse", "piano": "Piano", "batterie": "Batterie",
          "back_vocals": "Back Vocals", "video": "Vidéo", "faders": "XR18 faders"}


def load_als(path: Path) -> ET.ElementTree:
    return ET.ElementTree(ET.fromstring(gzip.open(path).read()))


def save_als(tree: ET.ElementTree, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = ET.tostring(tree.getroot(), encoding="unicode")
    with gzip.open(path, "wb") as f:
        f.write(('<?xml version="1.0" encoding="UTF-8"?>\n' + body).encode("utf-8"))


def track(liveset: ET.Element, name: str) -> ET.Element:
    tracks = list(liveset.find("Tracks"))
    for t in tracks:
        if t.find("Name/EffectiveName").get("Value") == name:
            return t
    found = [t.find("Name/EffectiveName").get("Value") for t in tracks]
    raise KeyError(f"piste « {name} » absente du gabarit (pistes : {', '.join(found)})")


def arranger_events(track_el: ET.Element) -> ET.Element:
    """The Arrangement clip list of an audio or MIDI track."""
    seq = track_el.find("DeviceChain/MainSequencer")
    holder = seq.find("Sample") if track_el.tag == "AudioTrack" else seq.find("ClipTimeable")
    return holder.find("ArrangerAutomation/Events")


def snippet(name: str) -> ET.Element:
    """A fresh copy of an element captured from Michel's reference set."""
    text = importlib.resources.files("karaoke.ableton").joinpath(f"snippets/{name}.xml").read_text(encoding="utf-8")
    return ET.fromstring(text)


def controller_target_id(midi_track: ET.Element, cc: int) -> str:
    """PointeeId of MIDI CC `cc` on a MIDI track (Live stores CC n at ControllerTargets.{n+2})."""
    return midi_track.find(f".//MidiControllers/ControllerTargets.{cc + 2}").get("Id")
