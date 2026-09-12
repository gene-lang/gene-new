#!/usr/bin/env python3
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE.parent / "tools"))
from build_aot import build

build(HERE, "gene_sdl2", ["sdl", "font"], ["native/graphics.c", "native/events.c"], ["-lm"])
