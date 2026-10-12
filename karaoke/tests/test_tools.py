import subprocess
import pytest
from karaoke import tools
from karaoke.tools import ToolError, run_tool, tool_timeout


def test_timeout_becomes_tool_error(monkeypatch):
    # Review: a hung Demucs/WhisperX process must fail that song, not stall the overnight batch.
    def hang(*a, **kw):
        raise subprocess.TimeoutExpired(cmd="demucs", timeout=kw.get("timeout"))
    monkeypatch.setattr(tools.subprocess, "run", hang)
    with pytest.raises(ToolError, match="timeout"):
        run_tool("separate", ["demucs"], timeout=5)


def test_timeouts_scale_with_song_length():
    assert tool_timeout("separate", 200.0) > tool_timeout("separate", 100.0) >= 300
    assert tool_timeout("align", 240.0) >= 300 and tool_timeout("beats", 240.0) >= 120


def test_steps_pass_a_timeout(cfg, monkeypatch):
    from karaoke.steps import separate as sep
    from karaoke.workspace import Workspace
    from test_manifest import song
    seen = {}
    def fake(tool, args, **kw):
        seen.update(kw, tool=tool)
        raise ToolError(tool, 1, "stop")
    monkeypatch.setattr(sep, "run_tool", fake)
    with pytest.raises(ToolError):
        sep.SEPARATE.run(Workspace(cfg, song()), {"ingest": {"duration_s": 200.0}})
    assert seen["timeout"] == tool_timeout(seen["tool"], 200.0)   # first call: the RoFormer ("vocals")
