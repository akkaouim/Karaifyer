"""Step `separate` — three-stage stem separation.

Inputs:  travail/<id>/input.wav.
Outputs: travail/<id>/stems/vocals.wav            vocals from a Mel-Band RoFormer (cleaner than Demucs)
         stems/{drums,bass,guitar,piano,other}.wav from Demucs htdemucs_6s run on the RoFormer instrumental
         stems/residu_voix.wav                    Demucs's leftover "vocals" from the instrumental (unused)
         result {stems, vocals_model, device}.
"""
from __future__ import annotations
import os
import shutil

from karaoke.manifest import STEMS
from karaoke.runner import Step
from karaoke.steps.vocals_split import MODEL_DIR, OVERLAP
from karaoke.tools import pick_stem, run_tool, tool_timeout
from karaoke.workspace import Workspace

VOCALS_MODEL = "vocals_mel_band_roformer.ckpt"   # vocals score 12.6 (Demucs ≈ 9)
DEMUCS_STEMS = [s for s in STEMS if s != "vocals"]


def _run(ws: Workspace, upstream: dict) -> dict:
    device = os.environ.get("KARAOKE_DEVICE", "mps")
    duration = upstream["ingest"]["duration_s"]
    tmp = ws.work / "separation_tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    (tmp / "roformer").mkdir(parents=True)
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    run_tool("vocals", ["audio-separator", str(ws.work / "input.wav"), "--model_filename", VOCALS_MODEL,
                        "--model_file_dir", str(MODEL_DIR), "--mdxc_overlap", OVERLAP,
                        "--output_dir", str(tmp / "roformer"), "--output_format", "WAV"],
             timeout=tool_timeout("vocals", duration))
    outs = sorted((tmp / "roformer").glob("*.wav"))
    vocals, instrumental = pick_stem(outs, "vocals"), pick_stem(outs, "other")
    run_tool("separate", ["demucs", "-n", "htdemucs_6s", "-d", device, "--float32", "-o", str(tmp / "demucs"),
                          "--filename", "{stem}.{ext}", str(instrumental)],
             timeout=tool_timeout("separate", duration))
    ws.stems.mkdir(parents=True, exist_ok=True)
    shutil.move(str(vocals), ws.stems / "vocals.wav")
    for stem in DEMUCS_STEMS:
        shutil.move(str(tmp / "demucs" / "htdemucs_6s" / f"{stem}.wav"), ws.stems / f"{stem}.wav")
    shutil.move(str(tmp / "demucs" / "htdemucs_6s" / "vocals.wav"), ws.stems / "residu_voix.wav")
    shutil.rmtree(tmp, ignore_errors=True)
    return {"stems": list(STEMS), "vocals_model": VOCALS_MODEL, "device": device}


SEPARATE = Step(name="separate", deps=("ingest",), key=lambda ws: f"{VOCALS_MODEL}+htdemucs_6s", run=_run,
                artifacts=lambda ws: [ws.stems / f"{s}.wav" for s in STEMS],
                version="2")   # 2: RoFormer vocals, Demucs on the instrumental
