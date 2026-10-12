"""Send a MIDI CC repeatedly on the first output port whose name contains `--port` (default « IAC »),
so Live can learn it in MIDI Map mode. Exit 2 with a hint if no such port exists."""
import argparse
import sys
import time

import mido


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="IAC")
    p.add_argument("--cc", type=int, default=119)
    p.add_argument("--value", type=int, default=127)
    p.add_argument("--channel", type=int, default=1)
    p.add_argument("--seconds", type=float, default=20.0)
    a = p.parse_args()
    ports = [n for n in mido.get_output_names() if a.port.lower() in n.lower()]
    if not ports:
        print(f"Aucun port MIDI « {a.port} ». Activer le pilote IAC dans Configuration audio et MIDI "
              f"(Fenêtre → Studio MIDI → Pilote IAC → « Le périphérique est en ligne »). "
              f"Ports vus : {mido.get_output_names()}", file=sys.stderr)
        sys.exit(2)
    msg = mido.Message("control_change", channel=a.channel - 1, control=a.cc, value=a.value)
    with mido.open_output(ports[0]) as out:
        print(f"Envoi de CC {a.cc}={a.value} (canal {a.channel}) sur « {ports[0]} » pendant {a.seconds:.0f} s…")
        end = time.monotonic() + a.seconds
        while time.monotonic() < end:
            out.send(msg)
            time.sleep(0.5)


if __name__ == "__main__":
    main()
