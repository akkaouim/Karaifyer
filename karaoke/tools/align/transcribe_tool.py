"""Transcribe a (lead) vocal stem when no lyrics exist anywhere: a draft Michel proofreads.

job.json: {"audio": path, "language": "fr"|"en"}
out.json: {"words": [{"w": word, "s": start, "e": end}, ...]}  (whole song, word-timed)
Whisper large-v3 (faster-whisper, int8 on CPU) for the text, then WhisperX alignment for word times.
"""
import json
import sys

import whisperx

MODEL = "large-v3"


def cached_first(load):
    """Load from the local cache without asking the Hub (works offline); download only if not cached."""
    try:
        return load(True)
    except Exception:
        return load(False)


def main(job_path: str, out_path: str) -> None:
    job = json.load(open(job_path))
    audio = whisperx.load_audio(job["audio"])
    asr = cached_first(lambda only: whisperx.load_model(MODEL, device="cpu", compute_type="int8",
                                                        language=job["language"], local_files_only=only))
    result = asr.transcribe(audio, batch_size=8, language=job["language"])
    align_model, meta = cached_first(lambda only: whisperx.load_align_model(
        language_code=job["language"], device="cpu", model_cache_only=only))
    aligned = whisperx.align(result["segments"], align_model, meta, audio, "cpu", return_char_alignments=False)
    words = [{"w": w.get("word", "").strip(), "s": w.get("start"), "e": w.get("end")}
             for w in aligned.get("word_segments", []) if w.get("word", "").strip()]
    json.dump({"words": words}, open(out_path, "w"), ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
