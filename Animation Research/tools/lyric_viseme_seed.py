#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re

VOWEL_MAP = {
    'a': 'aa_wide',
    'e': 'eh_mid',
    'i': 'ee_tight',
    'o': 'oh_round',
    'u': 'oo_pucker',
    'y': 'ee_tight',
}


def tokenize(text: str) -> list[str]:
    return [token for token in re.findall(r"[A-Za-z']+", text.lower()) if token]


def dominant_vowel(word: str) -> str:
    for ch in word:
        if ch in VOWEL_MAP:
            return VOWEL_MAP[ch]
    if word[:1] in {'m', 'b', 'p'}:
        return 'mbp'
    return 'rest'


def build_events(text: str, fps: int, frames_per_token: int) -> list[dict]:
    events = [{'frame': 0, 'shape': 'rest'}]
    frame = 0
    for token in tokenize(text):
        frame += max(1, frames_per_token)
        events.append({'frame': frame, 'shape': dominant_vowel(token), 'lyric': token})
    return events


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('text')
    parser.add_argument('--character-id', default='character')
    parser.add_argument('--mouth-profile-id', default='mouth-profile')
    parser.add_argument('--mode', choices=['speech', 'singing'], default='singing')
    parser.add_argument('--fps', type=int, default=24)
    parser.add_argument('--frames-per-token', type=int, default=6)
    args = parser.parse_args()
    payload = {
        'schemaVersion': 1,
        'characterId': args.character_id,
        'mouthProfileId': args.mouth_profile_id,
        'mode': args.mode,
        'sourceText': args.text,
        'events': build_events(args.text, args.fps, args.frames_per_token),
    }
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
