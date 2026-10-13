import pytest
from karaoke.manifest import ManifestError, read_manifest, set_field, write_manifest
from test_manifest import song


def test_set_field_updates_one_cell(cfg):
    write_manifest(cfg.manifest, [song(id="005"), song(id="006")])
    s = set_field(cfg.manifest, "005", "retirer", "guitar;other")
    assert s.retirer == ("guitar", "other")
    rows = read_manifest(cfg.manifest)
    assert rows[0].retirer == ("guitar", "other") and rows[1].retirer == ("guitar",)
    assert set_field(cfg.manifest, "006", "partie", "Dessert").partie == "Dessert"


def test_invalid_values_are_refused_and_file_untouched(cfg):
    write_manifest(cfg.manifest, [song(id="005")])
    before = cfg.manifest.read_bytes()
    for champ, valeur in [("retirer", "flute"), ("decompte_mesures", "deux"), ("id", "999"), ("couleur", "x")]:
        with pytest.raises(ManifestError):
            set_field(cfg.manifest, "005", champ, valeur)
    with pytest.raises(ManifestError, match="introuvable"):
        set_field(cfg.manifest, "404", "partie", "x")
    assert cfg.manifest.read_bytes() == before


def test_modifier_cli_error_exit(cfg, monkeypatch):
    from typer.testing import CliRunner
    from karaoke import cli
    monkeypatch.setenv("KARAOKE_HOME", str(cfg.home))
    write_manifest(cfg.manifest, [song(id="005")])
    ok = CliRunner().invoke(cli.app, ["modifier", "--id", "005", "--champ", "langue", "--valeur", "en"])
    assert ok.exit_code == 0 and '"langue": "en"' in ok.output
    bad = CliRunner().invoke(cli.app, ["modifier", "--id", "005", "--champ", "retirer", "--valeur", "flute"])
    assert bad.exit_code == 1 and "flute" in bad.output
