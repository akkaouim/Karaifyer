"""Pipeline steps in execution order. Each step module documents its contract (inputs, outputs)."""
from karaoke.runner import Step
from karaoke.steps.beats import BEATS
from karaoke.steps.check import CHECK
from karaoke.steps.ingest import INGEST
from karaoke.steps.lyrics import LYRICS
from karaoke.steps.package import PACKAGE
from karaoke.steps.separate import SEPARATE
from karaoke.steps.video import VIDEO
from karaoke.steps.vocals_split import VOCALS_SPLIT

STEPS: list[Step] = [INGEST, SEPARATE, BEATS, VOCALS_SPLIT, PACKAGE, LYRICS, CHECK, VIDEO]
