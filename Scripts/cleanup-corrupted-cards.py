#!/usr/bin/env python3
"""Clean corrupted LLM placeholder notes from .ows bracket markup and regenerated script-cards.json."""

import json
import re
import os
import sys
from pathlib import Path

PROJECT_DIR = "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera"
SONGS_DIR = os.path.join(PROJECT_DIR, "Songs")
METADATA_DIR = os.path.join(PROJECT_DIR, "Metadata")

CORRUPTION_PATTERNS = [
    "Pull place references",
    "Essential elements",
    "Set anchors:",
]

def is_corrupted_notes(notes_value):
    """Check if a notes value looks like LLM placeholder text."""
    for pattern in CORRUPTION_PATTERNS:
        if pattern in notes_value:
            return True
    return False

def clean_camera_markup(match):
    """Remove corrupted notes parameter from camera bracket markup."""
    full = match.group(0)
    inner = match.group(1)
    
    # Split on | to find parameters
    if '|' not in inner:
        # No params section, just [camera: primary]
        return full
    
    tag_part, *param_parts = inner.split('|', 1)
    if len(param_parts) == 0:
        return full
    
    params_str = param_parts[0]
    params = params_str.split('|')
    
    cleaned_params = []
    for param in params:
        param = param.strip()
        # Check if this is a notes=... parameter with corrupted content
        if param.startswith('notes='):
            notes_val = param[6:].strip().strip('"')
            if is_corrupted_notes(notes_val):
                continue  # Skip this corrupted parameter
        cleaned_params.append(param)
    
    if not cleaned_params:
        return f"[{tag_part}]"
    
    return f"[{tag_part} | {' | '.join(cleaned_params)}]"


def clean_lyrics_text(text):
    """Clean corrupted notes from all camera brackets in lyrics text."""
    # Match [camera: ...] brackets - everything between [ and ]
    # Use a non-greedy approach that handles nested quotes properly
    pattern = re.compile(r'\[camera:\s*(.*?)\]', re.DOTALL)
    
    result = []
    last_end = 0
    
    for m in pattern.finditer(text):
        # Add text before this match
        result.append(text[last_end:m.start()])
        
        # Get the inner content between [camera: and ]
        inner = m.group(1).rstrip().rstrip(']')
        
        # Check if this has corrupted notes
        if not is_corrupted_notes(inner):
            result.append(m.group(0))
        else:
            # Clean it
            cleaned = re.sub(r'notes=.*?(?:\||$)', '', inner)
            cleaned = cleaned.rstrip().rstrip('|').strip()
            if cleaned:
                result.append(f'[camera: {cleaned}]')
            else:
                result.append(f'[camera: hold]')
        
        last_end = m.end()
    
    result.append(text[last_end:])
    return ''.join(result)


def process_ows_file(filepath):
    """Read an .ows file, clean its lyrics, and write back if changed."""
    try:
        with open(filepath, 'r') as f:
            data = json.load(f)
    except Exception as e:
        print(f"  ERROR reading {filepath}: {e}")
        return 0
    
    changed = False
    cleaned_count = 0
    
    # Process the versions array
    versions = data.get('versions', [])
    for version in versions:
        lyrics = version.get('lyrics', '')
        if not lyrics:
            continue
        
        cleaned_lyrics = clean_lyrics_text(lyrics)
        if cleaned_lyrics != lyrics:
            version['lyrics'] = cleaned_lyrics
            changed = True
            cleaned_count += 1
    
    if changed:
        # Backup original
        backup_path = filepath + '.corrupted-backup'
        if not os.path.exists(backup_path):
            os.rename(filepath, backup_path)
        
        with open(filepath, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"  Cleaned {cleaned_count} version(s) in {os.path.basename(filepath)}")
        return cleaned_count
    
    return 0


def main():
    print("=== Cleaning Corrupted OWS Files ===")
    total_cleaned = 0
    files_cleaned = 0
    
    ows_files = sorted(Path(SONGS_DIR).glob("*.ows"))
    for ows_file in ows_files:
        count = process_ows_file(str(ows_file))
        if count > 0:
            files_cleaned += 1
            total_cleaned += count
    
    print(f"\nCleaned {total_cleaned} versions across {files_cleaned} files.")
    
    # Regenerate script-cards.json
    script_cards_path = os.path.join(METADATA_DIR, "script-cards.json")
    if os.path.exists(script_cards_path):
        backup_path = script_cards_path + '.corrupted-backup'
        if not os.path.exists(backup_path):
            os.rename(script_cards_path, backup_path)
            print(f"\nRemoved corrupted script-cards.json (backed up).")
            print("It will be regenerated from clean bracket markup on next app open.")
    
    print("\n=== Cleanup Complete ===")
    print("The app will regenerate script-cards.json from the cleaned .ows files.")
    print("Backup copies of corrupted files saved with .corrupted-backup extension.")


if __name__ == "__main__":
    main()
