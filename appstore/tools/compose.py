#!/usr/bin/env python3
"""Compose captioned App Store screenshots from raw simulator captures.

usage: compose.py RAW_DIR

Writes appstore/out/screenshots/{6.9,6.1}/ and checks each file against Apple's spec. The 6.1"
set comes from the same captures: its width is 91% of the 6.9" width and nearly the same shape,
and Apple accepts a consistent UI scaled down from the larger display.
"""
import os
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "out" / "screenshots"
SIZES = {"6.9": (1320, 2868), "6.1": (1206, 2622)}

# Upload order. The first three are the ones that can show in search results. Captions are short
# phrases that add to the screen rather than describe it, and every claim is visible in the app.
SHOTS = [
    ("01-on-track", "progress", "Know if you're<br><em>on track.</em>", 0),
    ("02-today", "today", "Know what to run<br><em>today.</em>", 0),
    ("03-coach", "coach", "A coach that<br><em>knows your runs.</em>", 0),
    ("04-run-detail", "detail1", "Every run,<br><em>in detail.</em>", 0),
    ("05-analysis", "detail2", "Pace, heart rate,<br><em>every split.</em>", 0.115),
    ("06-plan", "plan", "A plan built from<br><em>your real running.</em>", 0),
    ("07-history", "history1", "Years of running,<br><em>on one screen.</em>", 0),
    ("08-record", "live", "Record your runs<br><em>right here.</em>", 0),
]


def render(name, raw, caption, crop, size, raw_dir):
    w, h = size
    with Image.open(raw_dir / f"{raw}.png") as capture:
        ratio = capture.height / capture.width
    query = urllib.parse.urlencode({
        "cap": caption, "img": f"file://{raw_dir}/{raw}.png", "crop": crop, "ratio": ratio,
    })
    with tempfile.TemporaryDirectory() as profile:
        out = Path(profile) / "raw.png"
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--allow-file-access-from-files", f"--user-data-dir={profile}",
             f"--window-size={w},{h}", "--force-device-scale-factor=1",
             "--virtual-time-budget=4000", f"--screenshot={out}", f"file://{HERE}/frame.html?{query}"],
            check=True, capture_output=True, timeout=120,
        )
        image = Image.open(out).convert("RGB")   # Apple rejects alpha
    assert image.size == size, f"{name}: rendered {image.size}"
    folder = OUT / ("6.9" if w == 1320 else "6.1")
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{name}.png"
    image.save(path, optimize=True)
    with Image.open(path) as check:
        assert check.mode == "RGB" and check.size == size
    print(f"{folder.name}/{path.name}: {w}x{h} {os.path.getsize(path) / 1e6:.1f} MB")


if __name__ == "__main__":
    raw_dir = Path(sys.argv[1]).resolve()
    for name, raw, caption, crop in SHOTS:
        for size in SIZES.values():
            render(name, raw, caption, crop, size, raw_dir)
