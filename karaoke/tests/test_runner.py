from karaoke.runner import Step, StepRetry, inspect_song, run_song
from karaoke.workspace import Workspace
from test_manifest import song


def make_steps(calls, state):
    def mk(name, deps=(), fail=None, version="1", output=None, artifacts=None):
        def run(ws, upstream):
            calls.append(name)
            if fail == "boom":
                raise RuntimeError("boom")
            if fail == "retry":
                raise StepRetry("réseau")
            if output is not None:
                return output(ws)
            return {"name": name, "up": sorted(upstream)}
        return Step(name=name, deps=deps, key=lambda ws, n=name: state.get(n, "v1"), run=run,
                    version=version, artifacts=artifacts or (lambda ws: []))
    return mk


def test_runs_then_skips(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",)), mk("c", ("b",))]
    ws = Workspace(cfg, song())
    r1 = run_song(ws, steps)
    assert calls == ["a", "b", "c"] and r1["c"]["result"]["up"] == ["b"]
    r2 = run_song(ws, steps)
    assert calls == ["a", "b", "c"] and {v["status"] for v in r2.values()} == {"saute"}


def test_key_change_reruns_downstream_only(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("ingest"), mk("separate", ("ingest",)), mk("package", ("separate",))]
    ws = Workspace(cfg, song())
    run_song(ws, steps)
    calls.clear()
    state["package"] = "retirer=bass"          # e.g. retirer column edited
    run_song(ws, steps)
    assert calls == ["package"]


def test_failure_blocks_dependants_not_siblings(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",), fail="boom"), mk("c", ("b",)), mk("d", ("a",))]
    r = run_song(Workspace(cfg, song()), steps)
    assert r["b"]["status"] == "echec" and "boom" in r["b"]["error"]
    assert r["c"]["status"] == "bloque" and r["d"]["status"] == "fait"


def test_retry_status_and_no_marker(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    ws = Workspace(cfg, song())
    r = run_song(ws, [mk("lyrics", fail="retry")])
    assert r["lyrics"]["status"] == "a_reessayer" and ws.read_marker("lyrics") is None


def test_force_and_only(cfg):
    calls, state = [], {}
    mk = make_steps(calls, state)
    steps = [mk("a"), mk("b", ("a",)), mk("c", ("b",))]
    ws = Workspace(cfg, song())
    run_song(ws, steps)
    calls.clear()
    run_song(ws, steps, force={"b"})
    assert calls == ["b", "c"]
    calls.clear()
    run_song(ws, steps, only={"c"}, force={"c"})
    assert calls == ["c"]


def test_updated_step_with_same_output_does_not_ripple(cfg):
    # Modularity: changing a step's code (version bump) reruns that step only,
    # unless its output actually changes.
    calls, state = [], {}
    ws = Workspace(cfg, song())
    run_song(ws, [make_steps(calls, state)("a", output=lambda ws: {"x": 1}),
                  make_steps(calls, state)("b", ("a",))])
    calls.clear()
    run_song(ws, [make_steps(calls, state)("a", version="2", output=lambda ws: {"x": 1}),
                  make_steps(calls, state)("b", ("a",))])
    assert calls == ["a"]
    calls.clear()
    run_song(ws, [make_steps(calls, state)("a", version="3", output=lambda ws: {"x": 2}),
                  make_steps(calls, state)("b", ("a",))])
    assert calls == ["a", "b"]


def test_declared_artifact_change_reruns_downstream(cfg):
    calls, state = [], {}
    ws = Workspace(cfg, song())
    f = ws.work / "stem.wav"
    def writer(content):
        def out(ws):
            f.write_bytes(content)
            return {"ok": True}
        return out
    def steps(content, version):
        mk = make_steps(calls, state)
        return [mk("a", output=writer(content), version=version, artifacts=lambda ws: [f]), mk("b", ("a",))]
    run_song(ws, steps(b"one", "1"))
    calls.clear()
    run_song(ws, steps(b"one", "2"))          # same bytes: b untouched
    assert calls == ["a"]
    calls.clear()
    run_song(ws, steps(b"two", "3"))          # same result dict, different file: b reruns
    assert calls == ["a", "b"]


def test_marker_does_not_collide_with_step_artifacts(cfg):
    # The beats tool writes travail/<id>/beats.json; the runner's marker must live elsewhere.
    ws = Workspace(cfg, song())
    def run(ws, up):
        (ws.work / "beats.json").write_text('{"beats": [1, 2]}')
        return {"n": 2}
    run_song(ws, [Step("beats", (), lambda ws: "", run)])
    assert (ws.work / "beats.json").read_text() == '{"beats": [1, 2]}'
    assert ws.read_marker("beats")["result"] == {"n": 2}


def test_skip_requires_artifacts_to_exist(cfg):
    # Review: deleting a show folder must regenerate it, not report "saute"/ok.
    calls, state = [], {}
    ws = Workspace(cfg, song())
    f = ws.work / "out.flac"
    def write(ws):
        f.write_bytes(b"x")
        return {}
    steps = lambda: [make_steps(calls, state)("package", output=write, artifacts=lambda ws: [f])]
    run_song(ws, steps())
    f.unlink()
    calls.clear()
    r = run_song(ws, steps())
    assert calls == ["package"] and r["package"]["status"] == "fait" and f.exists()


def test_interrupted_rerun_does_not_leave_a_stale_marker(cfg):
    # Review: a forced rerun that crashes mid-write must not be skipped next time.
    calls, state = [], {}
    ws = Workspace(cfg, song())
    run_song(ws, [make_steps(calls, state)("separate")])
    run_song(ws, [make_steps(calls, state)("separate", fail="boom")], force={"separate"})
    calls.clear()
    r = run_song(ws, [make_steps(calls, state)("separate")])
    assert calls == ["separate"] and r["separate"]["status"] == "fait"


def test_second_run_on_the_same_song_is_refused_while_one_is_active(cfg):
    # review #3: an orphaned traiter (app quit) and a new one must not write the same files
    import fcntl
    from karaoke.runner import Step, run_song
    from karaoke.workspace import Workspace
    from test_manifest import song
    ws = Workspace(cfg, song())
    ws.work.mkdir(parents=True, exist_ok=True)
    ran = []
    a = Step(name="a", deps=(), key=lambda ws: "k", run=lambda ws, up: ran.append(1) or {})
    with open(ws.work / ".lock", "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        res = run_song(ws, [a])
    assert ran == [] and res["a"]["status"] == "a_reessayer" and "déjà en cours" in res["a"]["error"]
    assert run_song(ws, [a])["a"]["status"] == "fait"          # lock released → runs


def test_a_result_to_retry_later_is_kept_but_reruns_next_time(cfg):
    calls, state, flag = [], {}, {"on": True}
    mk = make_steps(calls, state)
    steps = [mk("lyrics", output=lambda ws: {"x": 1, **({"a_retenter": True} if flag["on"] else {})}),
             mk("video", ("lyrics",))]
    ws = Workspace(cfg, song())
    r = run_song(ws, steps)
    assert r["lyrics"]["status"] == "fait" and r["video"]["status"] == "fait"
    assert inspect_song(ws, steps)["lyrics"] == "perime"
    calls.clear()
    run_song(ws, steps)                       # still to retry, same output: the video is not redone
    assert calls == ["lyrics"]
    flag["on"] = False
    calls.clear()
    run_song(ws, steps)                       # the site is back: a new result, then up to date
    assert calls == ["lyrics", "video"] and inspect_song(ws, steps) == {"lyrics": "a_jour", "video": "a_jour"}
