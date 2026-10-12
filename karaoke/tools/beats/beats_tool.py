"""Beat This! wrapper: wav -> {"beats": [...], "downbeats": [...]} (seconds)."""
import argparse
import json

from beat_this.inference import File2Beats


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("out")
    p.add_argument("--device", default="mps")
    a = p.parse_args()
    f2b = File2Beats(checkpoint_path="final0", device=a.device, dbn=False)
    beats, downbeats = f2b(a.wav)
    with open(a.out, "w") as f:
        json.dump({"beats": [float(b) for b in beats], "downbeats": [float(d) for d in downbeats]}, f)


if __name__ == "__main__":
    main()
