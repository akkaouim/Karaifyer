"""Upstream chord-recognition code + model at a pinned commit, fetched once into ~/.cache/karaoke/chords/.

No third-party code lives in the repository: each engine's repo is downloaded as a tarball, its model file is checked
against a sha256, and the few compatibility edits it needs (2019 code vs today's numpy/PyYAML/torch) are applied —
each edit asserts its target exists, so a changed upstream fails clearly. Used by chords_dl/ and chords_ace/ wrappers.
"""
from __future__ import annotations
import hashlib, io, json, os, re, shutil, tarfile, urllib.request
from pathlib import Path

NP_ALIASES = (r"np\.int([^0-9_a-z])", r"int\1"), (r"np\.float([^0-9_a-z])", r"float\1"), (r"np\.bool([^_a-z])", r"bool\1")
SOURCES = {
    "jiang": {"repo": "music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition",
              "commit": "481f4ce703f8822b99f4037e9104ba1760e21ea3",
              "model": "cache_data/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s0.best.sdict",
              "sha256": "921b42d5d1cf9ce1c0c0e45a74d409b8066e0acec46058ef74e24ee0fb540761",
              "patches": [(f, "re", NP_ALIASES) for f in ("extractors/beat_preprocess.py", "extractors/xhmm_decoder.py",
                                                         "extractors/xhmm_ismir.py", "results_ismir2017.py")]},
    "btc": {"repo": "jayg996/BTC-ISMIR19", "commit": "2682317be668032e6e4b269ded36adaa2ad57df0",
            "model": "test/btc_model_large_voca.pt",
            "sha256": "1673d23f8f9a55ae7f9e8b80a51da616debb22675b8d8b67ea6ce0ef37b0ab51",
            "patches": [("utils/hparams.py", "yaml.load(f)", "yaml.safe_load(f)"),
                        ("test.py", "torch.load(model_file)", "torch.load(model_file, map_location='cpu', weights_only=False)"),
                        ("utils/chords.py", "re", NP_ALIASES), ("utils/transformer_modules.py", "re", NP_ALIASES)]},
    "ace": {"repo": "andreamust/consonance-ACE", "commit": "d17633aea4e68e616e735d09df97b97ae3428e71",
            "model": "ACE/checkpoints/conformer_decomposed_smooth.ckpt",
            "sha256": "6ab1a314366fefb3d09e351ae7cb7f826a9e0718e94e7ff164df844ba7bcd954", "patches": []},
}


def _cache() -> Path:
    return Path(os.environ.get("KARAOKE_CHORDS_CACHE", Path.home() / ".cache" / "karaoke" / "chords"))


def _download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def _patch(root: Path, rel: str, old, new) -> None:
    p = root / rel
    text = p.read_text(encoding="utf-8") if p.exists() else ""
    if old == "re":                                   # regex list (numpy aliases): at least one must apply
        out = text
        for pat, rep in new:
            out = re.sub(pat, rep, out)
        if out == text:
            raise RuntimeError(f"correctif introuvable dans {rel} (code amont modifié ?)")
    else:
        if old not in text:
            raise RuntimeError(f"correctif introuvable dans {rel} : « {old} » (code amont modifié ?)")
        out = text.replace(old, new)
    p.write_text(out, encoding="utf-8")


def ensure(engine: str, download=None, log=print) -> Path:
    s = SOURCES[engine]
    dest = _cache() / f"{engine}-{s['commit'][:7]}"
    if (dest / ".ready").exists():
        return dest
    log(f"installation du détecteur {engine} (une seule fois) …")
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        data = (download or _download)(f"https://codeload.github.com/{s['repo']}/tar.gz/{s['commit']}")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
            for m in t.getmembers():
                parts = Path(m.name).parts[1:]               # strip the top-level « repo-<sha> » folder
                if not parts or ".." in parts:
                    continue
                m.name = str(Path(*parts))
                t.extract(m, tmp)
        model = tmp / s["model"]
        if not model.exists() or hashlib.sha256(model.read_bytes()).hexdigest() != s["sha256"]:
            raise RuntimeError(f"détecteur {engine} : somme de contrôle du modèle incorrecte (téléchargement abîmé ?)")
        for rel, old, new in s["patches"]:
            _patch(tmp, rel, old, new)
        (tmp / ".ready").write_text(s["commit"])
        shutil.rmtree(dest, ignore_errors=True)
        tmp.rename(dest)
        return dest
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def lab_to_segments(text: str) -> list[list]:
    out = []
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 3:
            out.append([float(p[0]), float(p[1]), p[2]])
    return out


def write_result(path, segments: list, key: str | None = None) -> None:
    Path(path).write_text(json.dumps({"segments": segments, "key": key}))
