"""« Vérifié » (set by Michel in the Karaoké tab) holds only while what he checked is still there: a re-analysis
that produces different lyrics, chords, mix or video clears it. A re-analysis that redoes nothing — or redoes a step
with the same result — keeps it."""

WATCHED = ("lyrics", "chords", "package", "video")


def outputs_changed(before: dict[str, str | None], res: dict[str, dict]) -> bool:
    """`before`: each watched step's output hash before the run (None: never produced)."""
    return any((res.get(n) or {}).get("status") == "fait" and res[n].get("output_hash") != before.get(n)
               for n in WATCHED)
