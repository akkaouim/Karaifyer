import math
import pytest
from karaoke.xair import xair_cc, xair_db, FADER_CC


def test_unity_and_off():
    assert xair_cc(0.0) == 95 and abs(xair_db(95)) < 0.1
    assert xair_cc(-math.inf) == 0 and xair_db(0) == -math.inf


def test_roundtrip_and_clamp():
    for db in (-50.0, -30.0, -10.0, -3.0, 5.0):
        assert xair_db(xair_cc(db)) == pytest.approx(db, abs=0.7)
    assert xair_cc(20.0) == 127 and xair_cc(-200.0) == 0


def test_fader_map_matches_xr18_plan():
    # XR18 channel n ↔ CC n-1 on MIDI channel 1; AuxLineIn 17-18 ↔ CC 16
    assert FADER_CC["guitare"] == [11] and FADER_CC["batterie"] == [14] and FADER_CC["back_vocals"] == [15]
    assert FADER_CC["accompagnement"] == [16]
