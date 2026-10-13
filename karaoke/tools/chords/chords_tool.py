"""chords_tool.py in.wav out.json — madmom DeepChroma chord segments + CNN key.

Writes {segments: [[start, end, label]], key}; labels are madmom's (`C:maj`, `A:min`, `N`).
DeepChroma was chosen in the spike: 1 s per song vs 60 s for CNN-CRF, 85–87 % agreement.
"""
import json
import sys

from madmom.audio.chroma import DeepChromaProcessor
from madmom.features.chords import DeepChromaChordRecognitionProcessor
from madmom.features.key import CNNKeyRecognitionProcessor, key_prediction_to_label

src, out = sys.argv[1], sys.argv[2]
segs = DeepChromaChordRecognitionProcessor()(DeepChromaProcessor()(src))
key = key_prediction_to_label(CNNKeyRecognitionProcessor()(src))
with open(out, "w") as f:
    json.dump({"segments": [[float(s), float(e), str(l)] for s, e, l in segs], "key": key}, f)
