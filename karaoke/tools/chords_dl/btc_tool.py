"""btc_tool.py in.wav out.json — BTC (Park et al. 2019), large vocabulary (170 classes)."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
repo = ensure("btc", log=lambda m: print(m, file=sys.stderr))
with tempfile.TemporaryDirectory() as d:
    (Path(d) / "song.wav").symlink_to(Path(src).resolve())     # test.py reads a folder
    subprocess.run([sys.executable, "test.py", "--voca", "True", "--audio_dir", d, "--save_dir", d], cwd=repo, check=True)
    lab = Path(d) / "song.lab"
    write_result(out, lab_to_segments(lab.read_text()) if lab.exists() else [])
