import subprocess
import pytest
from karaoke import tools
from karaoke.tools import ToolError, run_tool, tool_timeout


def test_timeout_becomes_tool_error(monkeypatch):
    # Review: a hung Demucs/WhisperX process must fail that song, not stall the overnight batch.
    def hang(proc, timeout, **kw):
        raise subprocess.TimeoutExpired(cmd="demucs", timeout=timeout)
    monkeypatch.setattr(tools, "communicate_active", hang)
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


class FakeProc:
    """communicate() keeps timing out `ticks` times, then returns; records kill()."""
    def __init__(self, ticks):
        import subprocess
        self.ticks, self.killed, self.returncode, self.sp = ticks, False, None, subprocess
    def communicate(self, timeout=None):
        if self.killed:
            self.returncode = -9
            return "", "killed"
        if self.ticks > 0:
            self.ticks -= 1
            raise self.sp.TimeoutExpired("x", timeout)
        self.returncode = 0
        return "out", ""
    def kill(self):
        self.killed = True


def test_paused_time_does_not_count_toward_the_timeout():
    # review #1: a SIGSTOP pause of minutes must not make the tool time out on resume
    from karaoke.tools import communicate_active
    times = iter([0, 1, 2, 3 + 3600, 4 + 3600, 5 + 3600, 6 + 3600])   # one tick spans an hour-long pause
    p = FakeProc(ticks=6)
    out, err = communicate_active(p, timeout=10, clock=lambda: next(times))
    assert out == "out" and not p.killed


def test_a_real_hang_still_times_out():
    import subprocess
    import pytest
    from karaoke.tools import communicate_active
    t = iter(range(100))
    p = FakeProc(ticks=99)
    with pytest.raises(subprocess.TimeoutExpired):
        communicate_active(p, timeout=5, clock=lambda: next(t))
    assert p.killed
