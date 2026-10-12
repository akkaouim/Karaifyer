"""Behringer X Air fader law (same taper as X32) and the karaoke XR18 fader map.

XR18 MIDI (Behringer chart): MIDI channel 1, CC 0-15 = input faders 1-16, CC 16 = AuxLineIn 17-18.
"""
from __future__ import annotations
import math

# pipeline part -> XR18 fader CCs (XR18 channel n = CC n-1; the 17/18 aux pair = CC 16)
FADER_CC = {"clic": [9], "guide_voix": [10], "guitare": [11], "basse": [12], "piano": [13],
            "batterie": [14], "back_vocals": [15], "accompagnement": [16]}


def _db_from_f(f: float) -> float:
    if f <= 0:
        return -math.inf
    if f >= 0.5:
        return f * 40 - 30
    if f >= 0.25:
        return f * 80 - 50
    if f >= 0.0625:
        return f * 160 - 70
    return f * 480 - 90


def _f_from_db(db: float) -> float:
    if db == -math.inf or db <= -90:
        return 0.0
    if db >= -10:
        f = (db + 30) / 40
    elif db >= -30:
        f = (db + 50) / 80
    elif db >= -60:
        f = (db + 70) / 160
    else:
        f = (db + 90) / 480
    return min(1.0, max(0.0, f))


def xair_db(cc: int) -> float:
    return _db_from_f(cc / 127)


def xair_cc(db: float) -> int:
    return int(round(_f_from_db(db) * 127))
