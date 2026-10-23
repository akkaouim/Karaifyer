"""ace_tool.py in.wav out.json — consonance-ACE (Poltronieri et al. 2025), decomposed root/bass/notes."""
import subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from chords_fetch import ensure, lab_to_segments, write_result

src, out = sys.argv[1], sys.argv[2]
try:
    repo = ensure("ace", log=lambda m: print(m, file=sys.stderr))
except RuntimeError as e:          # no network, corrupt download…: the step retries next run
    print(e, file=sys.stderr)
    sys.exit(75)
with tempfile.TemporaryDirectory() as d:
    lab = Path(d) / "out.lab"
    subprocess.run([sys.executable, "-m", "ACE.inference", "--audio", str(Path(src).resolve()), "--out", str(lab),
                    "--chord-min-duration", "0.5"], cwd=repo, check=True)
    write_result(out, lab_to_segments(lab.read_text()))
