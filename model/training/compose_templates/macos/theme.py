"""macOS visual tokens for the compositor templates (Sonoma/Sequoia, 1x point metrics).

Everything here is a measurement of the real UI at 1280x800 (a retina display downscaled
2x, which is what the daemon's capture geometry looks like). Colors were
sampled from macOS 14/15 screenshots; metrics are Apple's HIG point values. Where a value
is a guess it says ASSUMED.
"""
from __future__ import annotations
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageFont, ImageOps

# ---- metrics (points == px at 1x) --------------------------------------------------
MENU_BAR_H = 24          # MEASURED: non-notch Macs; notch Macs are 37 (not modeled)
TITLE_H = 28             # MEASURED: plain title bar (Preview/QuickTime/Messages)
TOOLBAR_H = 52           # MEASURED: unified toolbar windows (Finder/Safari/Photos)
WINDOW_RADIUS = 10       # MEASURED: Big Sur+ window corner radius
LIGHT_D = 12             # MEASURED: traffic-light diameter; centers at x 19/39/59, y 14
DOCK_ICON = 48           # ASSUMED: owner default dock size range is 40-64
DOCK_PAD = 6
DOCK_H = DOCK_ICON + DOCK_PAD * 2   # 60 + 8 px gap above the screen edge
DOCK_GAP = 8

SF = "/System/Library/Fonts/SFNS.ttf"           # SF Pro (system, both Macs)
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"
_FALLBACK = "/System/Library/Fonts/Supplemental/Arial.ttf"


@lru_cache(maxsize=64)
def font(size: int, weight: str = "Regular", mono: bool = False) -> ImageFont.FreeTypeFont:
    """SF Pro at `size` px with a named variable-font weight; falls back to Arial/bitmap.
    Cached: FreeType faces are expensive and the set of (size, weight) pairs is tiny."""
    for path in ((SF_MONO if mono else SF), _FALLBACK):
        if Path(path).exists():
            f = ImageFont.truetype(path, size)
            try:
                f.set_variation_by_name(weight.encode())
            except Exception:
                pass                       # non-variable fallback: weight is cosmetic
            return f
    return ImageFont.load_default()


@dataclass(frozen=True)
class Theme:
    name: str
    window_bg: tuple        # window body / toolbar background
    titlebar: tuple         # plain title bar (slightly darker than body when inactive)
    sidebar: tuple          # source-list sidebar
    sidebar_sel: tuple      # selected sidebar row
    content_bg: tuple       # document area behind an image (Preview grey)
    page_bg: tuple          # web page body
    field: tuple            # URL / search field
    border: tuple           # 1 px window outline
    sep: tuple              # hairline separators
    text: tuple
    text2: tuple            # secondary text
    menubar: tuple          # menu bar tint, blended with the wallpaper at MENU_ALPHA
    dock: tuple             # dock tint, blended at DOCK_ALPHA
    accent: tuple           # selection / progress accent (system blue)
    bubble_in: tuple        # received message bubble
    row_alt: tuple          # alternating list row


LIGHT = Theme(
    name="light",
    window_bg=(236, 236, 236), titlebar=(229, 229, 229), sidebar=(232, 232, 234),
    sidebar_sel=(214, 214, 218), content_bg=(229, 229, 229), page_bg=(255, 255, 255),
    field=(255, 255, 255), border=(190, 190, 192), sep=(214, 214, 214),
    text=(28, 28, 30), text2=(120, 120, 124), menubar=(246, 246, 246),
    dock=(240, 240, 242), accent=(0, 122, 255), bubble_in=(233, 233, 235),
    row_alt=(245, 245, 247))
DARK = Theme(
    name="dark",
    window_bg=(40, 40, 42), titlebar=(50, 50, 52), sidebar=(38, 38, 40),
    sidebar_sel=(72, 72, 76), content_bg=(30, 30, 32), page_bg=(24, 24, 26),
    field=(60, 60, 64), border=(20, 20, 22), sep=(66, 66, 70),
    text=(235, 235, 240), text2=(150, 150, 156), menubar=(36, 36, 38),
    dock=(50, 50, 54), accent=(10, 132, 255), bubble_in=(58, 58, 62),
    row_alt=(46, 46, 48))
MENU_ALPHA = 0.82        # MEASURED-ish: menu bar is a translucent material over the wallpaper
DOCK_ALPHA = 0.72

# Wallpaper gradient pairs (top-left → bottom-right). Sampled from the Sonoma/Sequoia
# dynamic wallpapers' dominant tones — no Apple assets, just two colors each.
WALLPAPERS = [
    ((42, 76, 160), (186, 84, 140)),    # Sequoia blue → magenta
    ((246, 148, 74), (78, 88, 176)),    # Sonoma sunset orange → indigo
    ((22, 34, 70), (46, 112, 150)),     # deep navy → teal
    ((214, 190, 170), (98, 118, 150)),  # sand → slate
    ((20, 20, 24), (72, 60, 96)),       # near-black → violet (dark wallpaper)
    ((88, 148, 96), (216, 210, 150)),   # green hills → straw
]


def wallpaper(rng, size, theme: Theme) -> Image.Image:
    c0, c1 = rng.choice(WALLPAPERS if theme is LIGHT else WALLPAPERS[2:])
    # diagonal gradient: 64x64 L ramp along a random diagonal, upscaled bilinear (no seams)
    n = 64
    g = Image.new("L", (n, n))
    flip_x, flip_y = rng.random() < 0.5, rng.random() < 0.5
    g.putdata([round(255 * (((n - 1 - x) if flip_x else x) + ((n - 1 - y) if flip_y else y))
                     / (2 * (n - 1))) for y in range(n) for x in range(n)])
    g = g.resize(size, Image.BILINEAR)
    return ImageOps.colorize(g, black=c0, white=c1).convert("RGB")


def blend(color, alpha, over):
    """Solid stand-in for a translucent material: color at alpha over `over`."""
    return tuple(round(c * alpha + o * (1 - alpha)) for c, o in zip(color, over))
