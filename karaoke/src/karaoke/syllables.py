"""Pure helpers for syllable-level lyrics: hyphenation (pyphen) and word/syllable timing.

Michel's tolerance is ±0.5 s per word, so syllable starts are spread over each word's duration in
proportion to their letters rather than taken from (often missing) letter-level alignment.
"""
from __future__ import annotations
import re

import pyphen

_DICTS: dict[str, pyphen.Pyphen] = {}
_LANG = {"fr": "fr_FR", "en": "en_US"}
_CORE = re.compile(r"^(\W*)(.*?)(\W*)$", re.UNICODE)


def _dic(lang: str) -> pyphen.Pyphen:
    code = _LANG.get(lang, lang)
    if code not in _DICTS:
        _DICTS[code] = pyphen.Pyphen(lang=code)
    return _DICTS[code]


def syllabify(word: str, lang: str) -> list[str]:
    """Syllables of one written word; leading/trailing punctuation stays attached."""
    lead, core, trail = _CORE.match(word).groups()
    if not core:
        return [word]
    parts, prev = [], 0
    for pos in _dic(lang).positions(core):
        parts.append(core[prev:pos])
        prev = pos
    parts.append(core[prev:])
    parts = [p for p in parts if p]
    parts[0] = lead + parts[0]
    parts[-1] = parts[-1] + trail
    return parts


def word_syllables(text: str, start: float, end: float, lang: str) -> list[dict]:
    syl = syllabify(text, lang)
    weights = [max(1, sum(c.isalnum() for c in s)) for s in syl]
    total, acc, out = sum(weights), 0, []
    for s, w in zip(syl, weights):
        out.append({"text": s, "start": round(start + (end - start) * acc / total, 3)})
        acc += w
    return out


def timed_words(line_text: str, aligned: list[dict], line_start: float, line_end: float, lang: str) -> list[dict]:
    """Words of a line with start/end and syllables. `aligned` = [{w, s, e}] from WhisperX
    (None times allowed); missing times are interpolated between their neighbours."""
    tokens = line_text.split()
    n = len(tokens)
    s = [aligned[i].get("s") if i < len(aligned) else None for i in range(n)]
    e = [aligned[i].get("e") if i < len(aligned) else None for i in range(n)]
    i = 0
    while i < n:
        if s[i] is not None:
            i += 1
            continue
        j = i
        while j < n and s[j] is None:
            j += 1
        k = j - i
        a = (e[i - 1] if e[i - 1] is not None else s[i - 1]) if i > 0 else line_start
        b = s[j] if j < n else line_end
        for m in range(k):
            frac = (m + 1) / (k + 1) if i > 0 else m / k
            s[i + m] = a + (b - a) * frac
        i = j
    words = []
    for idx, tok in enumerate(tokens):
        nxt = s[idx + 1] if idx + 1 < n else line_end
        end = e[idx] if e[idx] is not None else nxt
        end = max(end, s[idx] + 0.05)
        words.append({"text": tok, "start": round(s[idx], 3), "end": round(end, 3),
                      "syllables": word_syllables(tok, s[idx], end, lang)})
    return words
