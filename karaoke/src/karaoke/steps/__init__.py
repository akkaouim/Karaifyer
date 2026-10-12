"""Pipeline steps in execution order. Each step module documents its contract (inputs, outputs)."""
from karaoke.runner import Step
from karaoke.steps.ingest import INGEST

STEPS: list[Step] = [INGEST]
