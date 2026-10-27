import hashlib
import os
from pathlib import Path
from karaoke.runner import inspect_song
from karaoke.steps import STEPS
from karaoke.steps import ingest
from karaoke.workspace import Workspace
from test_manifest import song


def legacy_full_key(path: Path, duree) -> str:
    st = path.stat()
    k = f"{path}|{st.st_size}|{st.st_mtime_ns}|{duree}"
    return hashlib.sha1("|".join(["ingest", ingest.INGEST.version, k]).encode()).hexdigest()


def test_key_does_not_contain_the_path(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    assert str(f) not in ingest._key(ws) and ingest._key(ws).startswith("10|")


def test_legacy_marker_is_adopted_so_ingest_stays_up_to_date(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    (ws.work / "input.wav").write_bytes(b"w")
    ws.write_marker("ingest", {"key": legacy_full_key(f, ws.song.duree_ref_s), "result": {}, "output_hash": "h"})
    assert inspect_song(ws, STEPS)["ingest"] == "perime"
    assert ingest.adopt_legacy_marker(ws) is True
    assert inspect_song(ws, STEPS)["ingest"] == "a_jour"
    assert ingest.adopt_legacy_marker(ws) is False            # already adopted: no-op


def test_marker_of_a_moved_file_is_adopted_with_its_old_path(cfg, tmp_path):
    old = tmp_path / "05 - Danser.flac"; old.write_bytes(b"x" * 10)
    ws0 = Workspace(cfg, song(fichier=old))
    (ws0.work / "input.wav").write_bytes(b"w")
    ws0.write_marker("ingest", {"key": legacy_full_key(old, ws0.song.duree_ref_s), "result": {}, "output_hash": "h"})
    new = tmp_path / "Danser.flac"; os.rename(old, new)          # rename keeps size and mtime
    ws = Workspace(cfg, song(fichier=new))
    assert ingest.adopt_legacy_marker(ws, old_path=old) is True
    assert inspect_song(ws, STEPS)["ingest"] == "a_jour"


def test_changed_file_is_not_adopted(cfg, tmp_path):
    f = tmp_path / "a.flac"; f.write_bytes(b"x" * 10)
    ws = Workspace(cfg, song(fichier=f))
    ws.write_marker("ingest", {"key": "something-else", "result": {}, "output_hash": "h"})
    assert ingest.adopt_legacy_marker(ws) is False
