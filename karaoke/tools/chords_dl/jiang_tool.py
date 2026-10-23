"""jiang_tool.py in.wav out.json — Jiang et al. 2019 large-vocabulary chords (submission dictionary)."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
try:
    repo = ensure("jiang", log=lambda m: print(m, file=sys.stderr))
except RuntimeError as e:          # no network, corrupt download…: the step retries next run
    print(e, file=sys.stderr)
    sys.exit(75)
with tempfile.TemporaryDirectory() as d:
    lab = Path(d) / "out.lab"
    subprocess.run([sys.executable, "chord_recognition.py", str(Path(src).resolve()), str(lab)], cwd=repo, check=True)
    write_result(out, lab_to_segments(lab.read_text()))
