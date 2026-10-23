import hashlib, io, json, sys, tarfile
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import chords_fetch as F


def tarball(files: dict) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, data in files.items():
            info = tarfile.TarInfo(f"repo-abc/{name}")
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def test_lab_to_segments():
    assert F.lab_to_segments("0.0 1.5 C:maj\n1.5\t3.0\tA:min7\n\n") == [[0.0, 1.5, "C:maj"], [1.5, 3.0, "A:min7"]]


def test_fetch_installs_patches_and_reuses(tmp_path, monkeypatch):
    model = b"weights"
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": hashlib.sha256(model).hexdigest(),
           "patches": [("code.py", "np.int(", "int("), ("cfg.py", "yaml.load(f)", "yaml.safe_load(f)")]}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    calls = []
    def dl(url):
        calls.append(url)
        return tarball({"m.pt": model, "code.py": b"x = np.int(3)\n", "cfg.py": b"c = yaml.load(f)\n"})
    d = F.ensure("fake", download=dl, log=lambda *a: None)
    assert d == tmp_path / "fake-abc1234" and (d / ".ready").exists()
    assert (d / "code.py").read_text() == "x = int(3)\n" and (d / "cfg.py").read_text() == "c = yaml.safe_load(f)\n"
    assert calls == ["https://codeload.github.com/x/y/tar.gz/abc1234def"]
    F.ensure("fake", download=dl, log=lambda *a: None)
    assert len(calls) == 1                                      # installed once


def test_fetch_rejects_bad_checksum_and_retries(tmp_path, monkeypatch):
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": "0" * 64, "patches": []}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    with pytest.raises(RuntimeError, match="somme de contrôle"):
        F.ensure("fake", download=lambda u: tarball({"m.pt": b"corrupt"}), log=lambda *a: None)
    assert not (tmp_path / "fake-abc1234").exists() and not list(tmp_path.glob("*.tmp"))


def test_fetch_fails_clearly_when_a_patch_no_longer_applies(tmp_path, monkeypatch):
    model = b"w"
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": hashlib.sha256(model).hexdigest(),
           "patches": [("code.py", "np.int(", "int(")]}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    with pytest.raises(RuntimeError, match="code.py"):
        F.ensure("fake", download=lambda u: tarball({"m.pt": model, "code.py": b"nothing here\n"}), log=lambda *a: None)


def test_write_result(tmp_path):
    F.write_result(tmp_path / "o.json", [[0.0, 1.0, "C:maj"]])
    assert json.loads((tmp_path / "o.json").read_text()) == {"segments": [[0.0, 1.0, "C:maj"]], "key": None}


def test_download_failure_is_a_clear_french_error(tmp_path, monkeypatch):
    src = {"repo": "x/y", "commit": "abc1234def", "model": "m.pt", "sha256": "0" * 64, "patches": []}
    monkeypatch.setitem(F.SOURCES, "fake", src)
    monkeypatch.setenv("KARAOKE_CHORDS_CACHE", str(tmp_path))
    def boom(url):
        raise OSError("network is unreachable")
    with pytest.raises(RuntimeError, match="installation impossible"):
        F.ensure("fake", download=boom, log=lambda *a: None)
    with pytest.raises(RuntimeError, match="installation impossible"):
        F.ensure("fake", download=lambda u: b"not a tarball", log=lambda *a: None)
    assert list(tmp_path.iterdir()) == []
