import json
import pytest
from karaoke import verification as V
from karaoke.manifest import COLUMNS, ManifestError, read_manifest, set_field, write_manifest
from test_manifest import song


def test_verifie_column_round_trips_and_is_editable(cfg):
    write_manifest(cfg.manifest, [song(id="050")])
    assert "verifie" in COLUMNS and read_manifest(cfg.manifest)[0].verifie == ""
    set_field(cfg.manifest, "050", "verifie", "2026-10-27")
    assert read_manifest(cfg.manifest)[0].verifie == "2026-10-27"
    set_field(cfg.manifest, "050", "verifie", "")
    assert read_manifest(cfg.manifest)[0].verifie == ""


def test_verifie_must_be_a_date(cfg):
    write_manifest(cfg.manifest, [song(id="050")])
    with pytest.raises(ManifestError):
        set_field(cfg.manifest, "050", "verifie", "oui")


def test_outputs_changed_only_when_a_watched_step_ran_with_a_different_result():
    before = {"lyrics": "L", "chords": "C", "video": "V", "package": "P"}
    skipped = {n: {"status": "saute", "output_hash": h} for n, h in before.items()}
    assert not V.outputs_changed(before, skipped)
    same = {**skipped, "video": {"status": "fait", "output_hash": "V"}}           # re-ran, identical result
    assert not V.outputs_changed(before, same)
    new = {**skipped, "chords": {"status": "fait", "output_hash": "C2"}}
    assert V.outputs_changed(before, new)
    first = {**skipped, "video": {"status": "fait", "output_hash": "V"}}
    assert V.outputs_changed({**before, "video": None}, first)                     # never had one: it's new
    other = {**skipped, "set": {"status": "fait", "output_hash": "S2"}}            # a set rebuild isn't what was checked
    assert not V.outputs_changed(before, other)


def test_traiter_clears_verifie_when_outputs_change(cfg, monkeypatch, tmp_path):
    from typer.testing import CliRunner
    from karaoke import cli
    a = tmp_path / "a.flac"; a.write_bytes(b"x")
    write_manifest(cfg.manifest, [song(id="050", fichier=a, verifie="2026-10-27"), song(id="051", fichier=a, verifie="2026-10-27")])
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    def fake_run(ws, steps, **kw):
        h = "NEW" if ws.song.id == "050" else "SAME"
        return {"video": {"status": "fait", "output_hash": h, "result": {}, "error": "", "seconds": 0}}
    monkeypatch.setattr(cli, "run_song", fake_run)
    for sid in ("050", "051"):
        from karaoke.workspace import Workspace
        Workspace(cfg, next(s for s in read_manifest(cfg.manifest) if s.id == sid)).write_marker(
            "video", {"key": "k", "result": {}, "output_hash": "SAME"})
    r = CliRunner().invoke(cli.app, ["traiter"])
    assert r.exit_code == 0, r.output
    by = {s.id: s for s in read_manifest(cfg.manifest)}
    assert by["050"].verifie == "" and by["051"].verifie == "2026-10-27"


def test_etat_reports_manual_corrections_with_dates(cfg, tmp_path):
    from karaoke.state import song_state
    from karaoke.steps import STEPS
    s = song(id="050", fichier=tmp_path / "a.flac")
    write_manifest(cfg.manifest, [s])
    for d in (cfg.paroles, cfg.accords, cfg.mesures):
        d.mkdir(parents=True, exist_ok=True)
    assert song_state(cfg, s, STEPS)["corrections"] == {"paroles": None, "accords": None, "mesures": None}
    (cfg.paroles / "050.lrc").write_text("[00:01.00]x")
    (cfg.mesures / "050.json").write_text("{}")
    c = song_state(cfg, s, STEPS)["corrections"]
    assert c["paroles"] and c["mesures"] and c["accords"] is None
    assert len(c["paroles"]) == 10 and c["paroles"][4] == "-"            # YYYY-MM-DD
