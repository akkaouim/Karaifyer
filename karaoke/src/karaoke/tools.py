"""Run the heavy ML tools, each isolated in its own uv project under karaoke/tools/."""
from __future__ import annotations
import os
import subprocess
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2] / "tools"

# Timeout = base + factor × song duration. Measured in phase 0 (M1 Pro): separate ≈ 0.15×,
# align ≈ 0.12×, beats ≈ 0.02× real time; these leave ~10× headroom for a cold model load.
_TIMEOUTS = {"separate": (300.0, 3.0), "beats": (120.0, 1.0), "align": (300.0, 3.0),
             "vocals": (600.0, 4.0)}   # RoFormer / karaoke ≈ 0.78× real time (spike), model load included   # vocals split ≈ 0.76× real time (spike), model load included


def tool_timeout(tool: str, duration_s: float) -> float:
    base, factor = _TIMEOUTS[tool]
    return base + factor * max(0.0, duration_s)


class ToolError(RuntimeError):
    def __init__(self, tool: str, code: int, stderr: str):
        super().__init__(f"{tool} failed (exit {code}): {stderr[-800:]}")
        self.tool, self.code, self.stderr = tool, code, stderr


def run_tool(tool: str, args: list[str], env: dict | None = None,
             timeout: float | None = None) -> subprocess.CompletedProcess:
    project = TOOLS_DIR / tool
    full_env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1", **(env or {})}
    full_env.pop("VIRTUAL_ENV", None)   # don't let the main env leak into the tool's
    try:
        proc = subprocess.run(["uv", "run", "--project", str(project), *args],
                              cwd=project, env=full_env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise ToolError(tool, -1, f"timeout after {e.timeout:.0f} s") from e
    if proc.returncode != 0:
        raise ToolError(tool, proc.returncode, proc.stderr)
    return proc


def pick_stem(files: list[Path], label: str) -> Path:
    """The audio-separator output whose name carries `(label)`, case-insensitively
    (the RoFormer writes `(vocals)`, the karaoke model `(Vocals)`)."""
    tag = f"({label.lower()})"
    found = [f for f in files if tag in f.name.lower()]
    if len(found) != 1:
        raise ValueError(f"sortie « {label} » introuvable parmi {[f.name for f in files]}")
    return found[0]
