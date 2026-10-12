"""Forced alignment of known lyric lines on a vocal stem (no transcription).

job.json: {"audio": path, "language": "fr"|"en", "lines": ["...", ...]}
out.json: {"starts": [seconds|null per line], "scores": [mean word score|null per line]}
"""
import json
import sys

import whisperx


def main(job_path: str, out_path: str) -> None:
    job = json.load(open(job_path))
    audio = whisperx.load_audio(job["audio"])          # 16 kHz mono float32
    model, meta = whisperx.load_align_model(language_code=job["language"], device="cpu")
    lines = [l.strip() for l in job["lines"]]
    words_per_line = [len(l.split()) for l in lines]
    text = " ".join(l for l in lines if l)
    dur = len(audio) / 16000.0
    # Start the segment where the vocal stem first becomes audible (-40 dBFS);
    # otherwise the first word absorbs the whole intro and lands at 0 s.
    loud = (abs(audio) > 0.01).nonzero()[0]
    start = max(0.0, float(loud[0]) / 16000.0 - 0.2) if len(loud) else 0.0
    res = whisperx.align([{"start": start, "end": dur, "text": text}], model, meta, audio,
                         "cpu", return_char_alignments=False)
    words = res.get("word_segments", [])
    starts, scores, i = [], [], 0
    for n in words_per_line:
        chunk = words[i:i + n]
        i += n
        timed = [w for w in chunk if "start" in w]
        starts.append(float(timed[0]["start"]) if timed else None)
        sc = [w["score"] for w in timed if "score" in w]
        scores.append(float(sum(sc) / len(sc)) if sc else None)
    json.dump({"starts": starts, "scores": scores}, open(out_path, "w"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
