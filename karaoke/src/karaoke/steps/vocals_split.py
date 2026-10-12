"""Step `vocals_split` — lead vs backing vocals (karaoke Mel-Band RoFormer via audio-separator).

Inputs:  travail/<id>/stems/vocals.wav (Demucs).
Outputs: stems/lead.wav (lead singer), stems/backing.wav (backing vocals); result {model, lead_rms_db,
         backing_rms_db}. On the vocal stem the model's « Vocals » output is the lead and its
         « Instrumental » output the remainder, i.e. the backing vocals.
"""
from __future__ import annotations
import shutil
from pathlib import Path

import numpy as np

from karaoke import audio
from karaoke.runner import Step
from karaoke.tools import run_tool, tool_timeout
from karaoke.workspace import Workspace

MODEL = "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"
OVERLAP = "2"      # spike: 2 min 29 s per 3:17 song vs 5 min 26 s at the default 8
MODEL_DIR = Path.home() / ".cache" / "audio-separator-models"   # downloaded once (881 MB)


def pick_outputs(files: list[Path]) -> tuple[Path, Path]:
    lead = [f for f in files if "(Vocals)" in f.name]
    backing = [f for f in files if "(Instrumental)" in f.name]
    if len(lead) != 1 or len(backing) != 1:
        raise ValueError(f"sorties inattendues de audio-separator : {[f.name for f in files]}")
    return lead[0], backing[0]


def _rms_db(path: Path) -> float:
    x, _ = audio.read(path)
    return float(20 * np.log10(np.sqrt((x.astype(np.float64) ** 2).mean()) + 1e-12))


def _run(ws: Workspace, upstream: dict) -> dict:
    tmp = ws.work / "vocals_tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    run_tool("vocals", ["audio-separator", str(ws.stems / "vocals.wav"), "--model_filename", MODEL,
                        "--model_file_dir", str(MODEL_DIR), "--mdxc_overlap", OVERLAP,
                        "--output_dir", str(tmp), "--output_format", "WAV"],
             timeout=tool_timeout("vocals", upstream["ingest"]["duration_s"]))
    lead, backing = pick_outputs(sorted(tmp.glob("*.wav")))
    shutil.move(str(lead), ws.stems / "lead.wav")
    shutil.move(str(backing), ws.stems / "backing.wav")
    shutil.rmtree(tmp, ignore_errors=True)
    return {"model": MODEL, "lead_rms_db": _rms_db(ws.stems / "lead.wav"),
            "backing_rms_db": _rms_db(ws.stems / "backing.wav")}


VOCALS_SPLIT = Step(name="vocals_split", deps=("ingest", "separate"), key=lambda ws: f"{MODEL}|overlap={OVERLAP}",
                    run=_run, artifacts=lambda ws: [ws.stems / "lead.wav", ws.stems / "backing.wav"])
