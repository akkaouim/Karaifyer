"""Run the heavy ML tools, each isolated in its own uv project under karaoke/tools/."""
from __future__ import annotations
import os
import subprocess
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2] / "tools"


class ToolError(RuntimeError):
    def __init__(self, tool: str, code: int, stderr: str):
        super().__init__(f"{tool} failed (exit {code}): {stderr[-800:]}")
        self.tool, self.code, self.stderr = tool, code, stderr


def run_tool(tool: str, args: list[str], env: dict | None = None,
             timeout: float | None = None) -> subprocess.CompletedProcess:
    project = TOOLS_DIR / tool
    full_env = {**os.environ, "PYTORCH_ENABLE_MPS_FALLBACK": "1", **(env or {})}
    full_env.pop("VIRTUAL_ENV", None)   # don't let the main env leak into the tool's
    proc = subprocess.run(["uv", "run", "--project", str(project), *args],
                          cwd=project, env=full_env, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise ToolError(tool, proc.returncode, proc.stderr)
    return proc
