"""Resumable per-song step runner.

Each step declares its dependencies, a `key` (its own parameters), a `version` (bump when its
code changes) and the `artifacts` (files) it produces. A step reruns when its key, version, or
the OUTPUT of a dependency changes. Downstream steps depend on what upstream steps produce,
not on how: updating one step whose output stays identical never ripples down the chain.
"""
from __future__ import annotations
import hashlib
import json
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from karaoke.workspace import Workspace


class StepRetry(Exception):
    """Transient failure (e.g. network): retry on the next run."""


def _no_artifacts(ws: Workspace) -> list[Path]:
    return []


@dataclass(frozen=True)
class Step:
    name: str
    deps: tuple[str, ...]
    key: Callable[[Workspace], str]
    run: Callable[[Workspace, dict], dict]
    version: str = "1"
    artifacts: Callable[[Workspace], list[Path]] = field(default=_no_artifacts)
    always: bool = False


def _file_digest(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def output_hash(result: dict, artifacts: list[Path]) -> str:
    h = hashlib.sha1(json.dumps(result, sort_keys=True, ensure_ascii=False, default=str).encode())
    for p in sorted(artifacts, key=str):
        h.update(p.name.encode())
        h.update(_file_digest(p).encode() if p.exists() else b"missing")
    return h.hexdigest()


def _entry(status: str, seconds: float = 0.0, result: dict | None = None, error: str = "",
           out_hash: str = "") -> dict:
    return {"status": status, "seconds": seconds, "result": result or {}, "error": error,
            "output_hash": out_hash}


def run_song(ws: Workspace, steps: list[Step], force: set[str] = frozenset(),
             only: set[str] | None = None) -> dict[str, dict]:
    out: dict[str, dict] = {}
    forced = set(force)
    for step in steps:
        t0 = time.monotonic()
        bad = [d for d in step.deps if out.get(d, {}).get("status") not in ("fait", "saute")]
        if bad:
            out[step.name] = _entry("bloque", error=f"dépend de : {', '.join(bad)}")
            continue
        key = hashlib.sha1("|".join([step.name, step.version, step.key(ws),
                                     *(out[d]["output_hash"] for d in step.deps)]).encode()).hexdigest()
        if any(d in forced for d in step.deps):
            forced.add(step.name)
        marker = ws.read_marker(step.name)
        up_to_date = marker is not None and marker.get("key") == key
        selected = only is None or step.name in only
        if not step.always and (not selected or (up_to_date and step.name not in forced)):
            if up_to_date:
                out[step.name] = _entry("saute", result=marker["result"], out_hash=marker["output_hash"])
            else:
                out[step.name] = _entry("bloque", error="étape non sélectionnée et pas à jour")
            continue
        upstream = {d: out[d]["result"] for d in step.deps}
        try:
            ws.log(f"début {step.name}")
            result = step.run(ws, upstream)
            secs = time.monotonic() - t0
            oh = output_hash(result, step.artifacts(ws))
            ws.write_marker(step.name, {"key": key, "result": result, "output_hash": oh, "seconds": secs})
            out[step.name] = _entry("fait", secs, result, out_hash=oh)
            ws.log(f"fin {step.name} ({secs:.1f} s)")
        except StepRetry as e:
            out[step.name] = _entry("a_reessayer", time.monotonic() - t0, error=str(e))
            ws.log(f"à réessayer {step.name}: {e}")
        except Exception as e:  # one song's failure must never stop the batch
            out[step.name] = _entry("echec", time.monotonic() - t0, error=f"{type(e).__name__}: {e}")
            ws.log(f"échec {step.name}: {traceback.format_exc()}")
    return out
