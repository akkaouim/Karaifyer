"""Pipeline steps in execution order. Each step module documents its contract (inputs, outputs)."""
from karaoke.runner import Step
from karaoke.steps.beats import BEATS
from karaoke.steps.ingest import INGEST
from karaoke.steps.lyrics import LYRICS
from karaoke.steps.package import PACKAGE
from karaoke.steps.separate import SEPARATE

STEPS: list[Step] = [INGEST, SEPARATE, BEATS, PACKAGE, LYRICS]
