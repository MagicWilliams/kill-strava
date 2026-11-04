#!/usr/bin/env python3
"""Render header and search art at App Store sizes, flatten alpha, and check against the spec.

usage: render_header.py [RAW_DIR]   (RAW_DIR adds the search asset, which uses a real capture)
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "out" / "header"

# name, width, height, type size, bar scale. Bars scale down on 21:9, where height is scarce.
SIZES = [
    ("tempo-header-3840x1646", 3840, 1646, "7vw", 1.0),
    ("tempo-universal-5244x2950", 5244, 2950, "8vw", 1.2),
]


def render(name, w, h, type_size, scale, url=None):
    url = url or f"file://{HERE}/header.html?type={type_size}&scale={scale}"
    with tempfile.TemporaryDirectory() as profile:
        raw = Path(profile) / "raw.png"
        subprocess.run(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             f"--user-data-dir={profile}", f"--window-size={w},{h}",
             "--force-device-scale-factor=1", "--virtual-time-budget=4000",
             "--allow-file-access-from-files",
             f"--screenshot={raw}", url],
            check=True, capture_output=True, timeout=120,
        )
        image = Image.open(raw).convert("RGB")
    assert image.size == (w, h), f"{name}: rendered {image.size}"
    path = OUT / f"{name}.png"
    image.save(path, optimize=True)
    check = Image.open(path)
    print(f"{path.name}: {check.size[0]}x{check.size[1]} mode={check.mode} "
          f"{os.path.getsize(path) / 1e6:.1f} MB")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        render(*size)
    # The search asset shows the real Progress card, so it needs the raw capture.
    if len(sys.argv) > 1:
        capture = Path(sys.argv[1]).resolve() / "progress.png"
        render("tempo-search-3840x2560", 3840, 2560, None, None,
               f"file://{HERE}/search.html?img=file://{capture}")
