"""« Vérifié » (set by Michel in the Karaoké tab) holds only while what he checked is still there: a re-analysis
that produces different lyrics, chords, mix or video clears it. A re-analysis that redoes nothing — or redoes a step
with the same result — keeps it."""

WATCHED = ("lyrics", "chords", "package", "video")


def outputs_changed(before: dict[str, str | None], res: dict[str, dict]) -> bool:
    """`before`: each watched step's output hash before the run (None: never produced)."""
    return any((res.get(n) or {}).get("status") == "fait" and res[n].get("output_hash") != before.get(n)
               for n in WATCHED)


# What « Vérifié » covers: every step's version and inputs (its key: corrections, title, settings, the recording…)
# when Michel ticked it, kept in travail/<id>/verifie.json. A re-analysis whose inputs are still exactly those is
# only applying what he checked (saved corrections, then « Vérifié », then « Analyser ») and keeps it.

def _inputs(ws, steps) -> list[str]:
    return [f"{s.name}:{s.version}:{s.key(ws)}" for s in steps]


def remember(ws, steps) -> None:
    import json
    (ws.work / "verifie.json").write_text(json.dumps(_inputs(ws, steps), ensure_ascii=False), encoding="utf-8")


def forget(ws) -> None:
    (ws.work / "verifie.json").unlink(missing_ok=True)


def unchanged_since_verified(ws, steps) -> bool:
    import json
    p = ws.work / "verifie.json"
    return p.exists() and json.loads(p.read_text(encoding="utf-8")) == _inputs(ws, steps)
