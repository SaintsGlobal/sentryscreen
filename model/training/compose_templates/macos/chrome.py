"""Shared macOS drawing primitives: window frame + shadow, traffic lights, menu bar, Dock,
sidebars, icons, occluders (notification / sheet / overlapping window) and the one paste
routine every template uses (returns the label-transform parameters).

Pure PIL; nothing here touches a display.
"""
from __future__ import annotations
import math
from dataclasses import dataclass, field

from PIL import Image, ImageDraw, ImageFilter

from . import theme as T
from .theme import font

Rect = tuple  # (x0, y0, x1, y1)


@dataclass
class Placement:
    """What compose.py needs to transform labels: the base was pasted at scale `s` with its
    top-left at (x, y) (may be outside `visible` for cover-fit), only `visible` shows, and
    `occluders` are rects drawn over it afterwards."""
    canvas: Image.Image
    s: float
    x: int
    y: int
    visible: Rect
    occluders: list = field(default_factory=list)
    scene: str = "desktop"
    theme: str = "light"


# ---- paste ---------------------------------------------------------------------------
def paste_fit(canvas, im, rect, rng=None, fill=(0.0, 1.0), cover=False, align=None,
              mask_radius=0):
    """Paste `im` into `rect`. contain: scale so the image fits, then multiply by a jitter
    in `fill` (fraction of the fit) and place at `align` ('center', 'top', or random).
    cover: scale so the image fills the rect and crop to it (square thumbnails).
    mask_radius: rounded corners (chat attachments). Returns (s, x, y, visible_rect) where
    visible_rect is the pasted image's on-canvas rect (the paste-scale receipt)."""
    x0, y0, x1, y1 = rect
    rw, rh = x1 - x0, y1 - y0
    if cover:
        s = max(rw / im.width, rh / im.height)
    else:
        s = min(rw / im.width, rh / im.height)
        if rng is not None:
            s *= rng.uniform(*fill)
    w, h = max(1, round(im.width * s)), max(1, round(im.height * s))
    if cover or align == "center":
        x, y = x0 + (rw - w) // 2, y0 + (rh - h) // 2
    elif align == "top":
        x, y = x0 + (rw - w) // 2, y0
    else:
        x = x0 + (rng.randint(0, max(0, rw - w)) if rng else (rw - w) // 2)
        y = y0 + (rng.randint(0, max(0, rh - h)) if rng else (rh - h) // 2)
    resized = im.resize((w, h), Image.LANCZOS)
    if x0 < 0 or y0 < 0 or x1 > canvas.width or y1 > canvas.height or x1 < x0 or y1 < y0:
        raise RuntimeError(f"paste_fit: target rect {rect} outside the {canvas.size} canvas — "
                           f"a template layout bug (labels would be silently lost)")
    vx0, vy0 = max(x, x0), max(y, y0)
    vx1, vy1 = min(x + w, x1), min(y + h, y1)
    if vx1 > vx0 and vy1 > vy0:
        crop = resized.crop((vx0 - x, vy0 - y, vx1 - x, vy1 - y))
        if mask_radius:
            m = Image.new("L", crop.size, 0)
            ImageDraw.Draw(m).rounded_rectangle([0, 0, crop.width - 1, crop.height - 1], mask_radius, fill=255)
            canvas.paste(crop, (vx0, vy0), m)
        else:
            canvas.paste(crop, (vx0, vy0))
        return s, x, y, (vx0, vy0, vx1, vy1)      # the IMAGE's visible rect, not the container
    return s, x, y, (x0, y0, x0, y0)               # nothing visible: empty rect → all boxes drop


def pick_base_cell(rng, cells, cell_h, y1, max_rows=2):
    """Index of the grid cell that gets the labeled base: a fully visible cell in the first
    `max_rows` rows (a base cut off by the page edge would just be a dropped-label
    composite). Fails loudly if the grid has no such cell."""
    ok = [i for i, (_, cy) in enumerate(cells) if cy + cell_h <= y1]
    ok = [i for i in ok if cells[i][1] <= cells[0][1] + (cell_h + 2) * (max_rows - 1) + 1]
    if not ok:
        raise RuntimeError(f"grid has no fully visible cell in the first {max_rows} rows "
                           f"(cell_h={cell_h}, page bottom={y1})")
    return rng.choice(ok)


# ---- text ----------------------------------------------------------------------------
def text(d, xy, s, size=13, weight="Regular", color=(0, 0, 0), anchor="la", mono=False):
    d.text(xy, s, font=font(size, weight, mono), fill=color, anchor=anchor)


def text_w(s, size=13, weight="Regular"):
    return font(size, weight).getlength(s)


def lines(d, x, y, w, n, th, rng, color, size=13, gap=8):
    """Paragraph stand-in: n rows of real words (not grey bars) wrapped to width w."""
    words = ("the a of and to in for with on at from by about into over after new more "
             "photo gallery latest update today share view open home news travel design "
             "recipe weekend morning light summer city street park garden window room").split()
    f = font(size)
    for i in range(n):
        line, tw = [], 0
        target = w * (rng.uniform(0.55, 0.9) if i == n - 1 else 1.0)
        while True:
            wd = rng.choice(words)
            nw = f.getlength(wd + " ")
            if tw + nw > target:
                break
            line.append(wd); tw += nw
        d.text((x, y + i * (size + gap)), " ".join(line), font=f, fill=color)
    return y + n * (size + gap)


# ---- window frame --------------------------------------------------------------------
def shadow(canvas, rect, radius=T.WINDOW_RADIUS, blur=18, dy=10, alpha=110):
    """Window drop shadow (MEASURED: Sonoma active-window shadow ≈ 20 px blur, 10 px down).
    Blurred on a rect-sized sub-layer so the cost is per-window, not per-canvas."""
    x0, y0, x1, y1 = rect
    m = blur * 3
    layer = Image.new("RGBA", (x1 - x0 + 2 * m, y1 - y0 + 2 * m), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle([m, m + dy, m + x1 - x0, m + dy + y1 - y0],
                                            radius, fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(layer, (x0 - m, y0 - m), layer)


def traffic_lights(d, x, y, active=True):
    cols = [(255, 95, 87), (254, 188, 46), (40, 200, 64)] if active else [(206, 206, 206)] * 3
    for i, c in enumerate(cols):
        cx = x + 13 + i * 20
        d.ellipse([cx, y, cx + T.LIGHT_D, y + T.LIGHT_D], fill=c,
                  outline=tuple(max(0, v - 40) for v in c))


FLAT = False   # set by the Split View scene: tiles have no shadow and square corners


def window(canvas, th: T.Theme, rect, title=None, bar_h=T.TITLE_H, active=True,
           bar_color=None, body=None):
    """Frame: shadow, rounded body, title/toolbar strip, traffic lights, hairline.
    Returns the content rect (below the bar)."""
    x0, y0, x1, y1 = rect
    r = 0 if FLAT else T.WINDOW_RADIUS
    if not FLAT:
        shadow(canvas, rect, alpha=110 if active else 70)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(rect, r, fill=body or th.window_bg, outline=th.border)
    bar = bar_color or (th.titlebar if bar_h == T.TITLE_H else th.window_bg)
    # bar with rounded top corners only: draw rounded rect then square off the bottom
    d.rounded_rectangle([x0, y0, x1, y0 + bar_h], r, fill=bar, outline=th.border)
    d.rectangle([x0 + 1, y0 + r, x1 - 1, y0 + bar_h], fill=bar)
    d.line([x0, y0 + bar_h, x1, y0 + bar_h], fill=th.sep)
    traffic_lights(d, x0, y0 + (bar_h - T.LIGHT_D) // 2, active)
    if title:
        text(d, ((x0 + x1) // 2, y0 + bar_h // 2), title, 13, "Semibold",
             th.text if active else th.text2, anchor="mm")
    return (x0 + 1, y0 + bar_h + 1, x1 - 1, y1 - 1)


# ---- menu bar + dock -----------------------------------------------------------------
APP_MENUS = {
    "Finder": ["File", "Edit", "View", "Go", "Window", "Help"],
    "Safari": ["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"],
    "Google Chrome": ["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab",
                      "Window", "Help"],
    "Preview": ["File", "Edit", "View", "Go", "Tools", "Window", "Help"],
    "Photos": ["File", "Edit", "Image", "View", "Window", "Help"],
    "Messages": ["File", "Edit", "View", "Conversations", "Window", "Help"],
    "Slack": ["File", "Edit", "View", "History", "Window", "Help"],
    "QuickTime Player": ["File", "Edit", "View", "Window", "Help"],
}


def menu_bar(canvas, th: T.Theme, rng, app: str, under=None):
    """24 px menu bar: Apple glyph, bold app name, menus; right side status items + clock.
    `under` is the wallpaper color it blends over (translucent material)."""
    d = ImageDraw.Draw(canvas)
    w = canvas.width
    bg = T.blend(th.menubar, T.MENU_ALPHA, under or (128, 128, 128))
    d.rectangle([0, 0, w, T.MENU_BAR_H], fill=bg)
    x = 14
    text(d, (x, 12), "\uf8ff", 15, "Regular", th.text, anchor="lm")   # Apple logo, U+F8FF in SF
    x += 28
    text(d, (x, 12), app, 13, "Bold", th.text, anchor="lm")
    x += text_w(app, 13, "Bold") + 20
    for m in APP_MENUS.get(app, ["File", "Edit", "View", "Window", "Help"]):
        text(d, (x, 12), m, 13, "Regular", th.text, anchor="lm")
        x += text_w(m, 13) + 20
    # right cluster: battery, wi-fi, control center, clock
    hh, mm = rng.randint(1, 12), rng.randint(0, 59)
    day = rng.choice(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    clock = f"{day} {rng.randint(1, 28)} {rng.choice(['Jan','Mar','May','Aug','Oct','Nov'])}" \
            f"  {hh}:{mm:02d} {rng.choice(['AM', 'PM'])}"
    cx = w - 12 - text_w(clock, 13)
    text(d, (cx, 12), clock, 13, "Regular", th.text, anchor="lm")
    cx -= 30
    for yy in (7, 13):                                                       # control center
        d.rounded_rectangle([cx - 9, yy, cx + 7, yy + 4], 2, outline=th.text)
        d.ellipse([cx - 8 + (0 if yy == 7 else 10), yy + 1, cx - 5 + (0 if yy == 7 else 10), yy + 3], fill=th.text)
    cx -= 26
    d.ellipse([cx - 8, 6, cx + 2, 16], outline=th.text, width=2)             # spotlight
    d.line([cx + 1, 15, cx + 5, 19], fill=th.text, width=2)
    cx -= 26
    for r in (8, 5, 2):                                                      # wi-fi arcs
        d.arc([cx - r, 12 - r, cx + r, 12 + r], 210, 330, fill=th.text)
    cx -= 34
    d.rounded_rectangle([cx - 12, 7, cx + 10, 17], 2, outline=th.text)       # battery
    d.rectangle([cx - 10, 9, cx - 10 + rng.randint(6, 18), 15], fill=th.text)
    d.rectangle([cx + 11, 10, cx + 12, 14], fill=th.text)
    return (0, T.MENU_BAR_H, w, T.MENU_BAR_H)


DOCK_APPS = [  # (name, base color, glyph) — simplified squircles, no Apple artwork
    ("Finder", (60, 150, 240), "face"), ("Launchpad", (120, 120, 130), "grid"),
    ("Safari", (40, 130, 240), "compass"), ("Messages", (60, 200, 90), "bubble"),
    ("Mail", (55, 140, 245), "env"), ("Photos", (250, 250, 250), "flower"),
    ("Music", (250, 60, 80), "note"), ("Notes", (255, 220, 90), "lines"),
    ("Terminal", (30, 30, 34), "prompt"), ("Google Chrome", (225, 228, 232), "chrome"),
    ("System Settings", (140, 140, 150), "gear"), ("Slack", (74, 21, 75), "hash"),
]


def app_icon(d, x, y, size, name, color, glyph):
    r = round(size * 0.22)
    d.rounded_rectangle([x, y, x + size, y + size], r, fill=color,
                        outline=tuple(max(0, c - 30) for c in color))
    cx, cy, k = x + size / 2, y + size / 2, size / 2
    ink = (255, 255, 255) if sum(color) < 500 else (60, 60, 70)
    if glyph == "face":
        d.rectangle([cx, y + 2, x + size - 2, y + size - 2], fill=(220, 235, 250))
        d.ellipse([cx - k * .45, cy - k * .3, cx - k * .25, cy - k * .1], fill=(30, 30, 40))
        d.ellipse([cx + k * .25, cy - k * .3, cx + k * .45, cy - k * .1], fill=(30, 30, 40))
        d.arc([cx - k * .5, cy - k * .2, cx + k * .5, cy + k * .55], 20, 160, fill=(30, 30, 40), width=2)
    elif glyph == "compass":
        d.ellipse([cx - k * .7, cy - k * .7, cx + k * .7, cy + k * .7], outline=ink, width=2)
        d.polygon([(cx + k * .45, cy - k * .45), (cx + k * .1, cy - k * .1),
                   (cx - k * .1, cy + k * .1), (cx - k * .45, cy + k * .45)], fill=(255, 70, 60))
    elif glyph == "bubble":
        d.ellipse([cx - k * .6, cy - k * .5, cx + k * .6, cy + k * .4], fill=ink)
    elif glyph == "env":
        d.rectangle([cx - k * .6, cy - k * .4, cx + k * .6, cy + k * .4], fill=ink)
        d.line([cx - k * .6, cy - k * .4, cx, cy + k * .05, cx + k * .6, cy - k * .4], fill=color, width=2)
    elif glyph == "flower":
        for i, c in enumerate([(255, 90, 90), (255, 170, 60), (255, 230, 80), (110, 210, 100),
                               (80, 170, 240), (150, 110, 230), (240, 110, 200), (255, 130, 90)]):
            a = i * math.pi / 4
            px, py = cx + math.cos(a) * k * .35, cy + math.sin(a) * k * .35
            d.ellipse([px - k * .3, py - k * .3, px + k * .3, py + k * .3], fill=c)
    elif glyph == "note":
        d.ellipse([cx - k * .5, cy + k * .1, cx - k * .1, cy + k * .5], fill=ink)
        d.line([cx - k * .12, cy + k * .3, cx - k * .12, cy - k * .5, cx + k * .4, cy - k * .65], fill=ink, width=3)
    elif glyph == "lines":
        d.rectangle([x, y, x + size, y + size * .25], fill=(255, 200, 60))
        for i in range(3):
            d.line([cx - k * .6, cy + i * k * .3 - k * .1, cx + k * .6, cy + i * k * .3 - k * .1], fill=(120, 100, 40))
    elif glyph == "prompt":
        d.text((cx - k * .6, cy - k * .55), ">_", font=font(round(size * .45), "Bold", True), fill=ink)
    elif glyph == "chrome":
        d.ellipse([cx - k * .8, cy - k * .8, cx + k * .8, cy + k * .8], fill=(255, 255, 255))
        d.ellipse([cx - k * .7, cy - k * .7, cx + k * .7, cy + k * .7], fill=(220, 60, 50))
        d.pieslice([cx - k * .7, cy - k * .7, cx + k * .7, cy + k * .7], 30, 150, fill=(60, 170, 80))
        d.pieslice([cx - k * .7, cy - k * .7, cx + k * .7, cy + k * .7], 150, 270, fill=(250, 200, 50))
        d.ellipse([cx - k * .28, cy - k * .28, cx + k * .28, cy + k * .28], fill=(60, 130, 240))
    elif glyph == "gear":
        d.ellipse([cx - k * .55, cy - k * .55, cx + k * .55, cy + k * .55], outline=ink, width=4)
    elif glyph == "hash":
        d.text((cx, cy), "#", font=font(round(size * .6), "Bold"), fill=ink, anchor="mm")
    elif glyph == "grid":
        for i in range(3):
            for j in range(3):
                d.ellipse([cx - k * .6 + i * k * .45, cy - k * .6 + j * k * .45,
                           cx - k * .35 + i * k * .45, cy - k * .35 + j * k * .45], fill=ink)


def dock(canvas, th: T.Theme, rng, running=("Finder",), under=None):
    """Bottom-center Dock: translucent pill, app icons, separator, Trash, running dots.
    Returns the dock rect (windows are placed above it, never under)."""
    d = ImageDraw.Draw(canvas)
    n = rng.randint(7, len(DOCK_APPS))
    apps = DOCK_APPS[:n]
    gap = 8
    inner = n * T.DOCK_ICON + (n - 1) * gap + 24 + T.DOCK_ICON   # + separator + trash
    w = inner + T.DOCK_PAD * 2
    x0 = (canvas.width - w) // 2
    y1 = canvas.height - T.DOCK_GAP
    y0 = y1 - T.DOCK_H
    bg = T.blend(th.dock, T.DOCK_ALPHA, under or (128, 128, 128))
    d.rounded_rectangle([x0, y0, x0 + w, y1], 16, fill=bg,
                        outline=T.blend((255, 255, 255), .3, bg) if th is T.LIGHT else th.border)
    x = x0 + T.DOCK_PAD
    for name, col, glyph in apps:
        app_icon(d, x, y0 + T.DOCK_PAD, T.DOCK_ICON, name, col, glyph)
        if name in running:
            d.ellipse([x + T.DOCK_ICON / 2 - 2, y1 - 5, x + T.DOCK_ICON / 2 + 2, y1 - 1],
                      fill=th.text2)
        x += T.DOCK_ICON + gap
    d.line([x + 4, y0 + 10, x + 4, y1 - 10], fill=th.sep)
    x += 24
    # trash: simple bin
    d.rounded_rectangle([x + 10, y0 + T.DOCK_PAD + 12, x + T.DOCK_ICON - 10, y1 - T.DOCK_PAD - 2],
                        4, fill=(200, 200, 205), outline=(150, 150, 155))
    d.rectangle([x + 7, y0 + T.DOCK_PAD + 8, x + T.DOCK_ICON - 7, y0 + T.DOCK_PAD + 12],
                fill=(170, 170, 176))
    return (x0, y0, x0 + w, y1)


# ---- desktop -------------------------------------------------------------------------
def desktop(rng, th: T.Theme, size, app: str):
    """Wallpaper + menu bar + Dock. Returns (canvas, work_rect) where work_rect is the
    area a window may occupy (below the menu bar, above the Dock)."""
    canvas = T.wallpaper(rng, size, th)
    px = canvas.getpixel((size[0] // 2, 12))
    menu_bar(canvas, th, rng, app, under=px)
    dock(canvas, th, rng, running=("Finder", app), under=canvas.getpixel((size[0] // 2, size[1] - 30)))
    return canvas, (0, T.MENU_BAR_H, size[0], size[1] - T.DOCK_H - T.DOCK_GAP)


def window_rect(rng, work, min_w=720, min_h=480, zoomed_p=0.2):
    """Random window rect inside the work area. Windows in the wild are mostly large:
    ASSUMED 20% fill the work area (green-light zoom), the rest 60-100% of it."""
    wx0, wy0, wx1, wy1 = work
    ww, wh = wx1 - wx0, wy1 - wy0
    if rng.random() < zoomed_p:
        return (wx0, wy0, wx1, wy1)
    w = rng.randint(max(min_w, int(ww * .6)), ww)
    h = rng.randint(max(min_h, int(wh * .6)), wh)
    x = wx0 + rng.randint(0, ww - w)
    y = wy0 + rng.randint(0, wh - h)
    return (x, y, x + w, y + h)


# ---- sidebars / list widgets ---------------------------------------------------------
def sidebar(d, th: T.Theme, rect, groups, selected=0, icon_colors=None, width=200):
    """Finder/Photos-style source list. groups: [(header, [items])]. Returns x of its edge."""
    x0, y0, x1, y1 = rect
    sx1 = x0 + width
    d.rectangle([x0, y0, sx1, y1], fill=th.sidebar)
    d.line([sx1, y0, sx1, y1], fill=th.sep)
    y = y0 + 12
    i = 0
    for header, items in groups:
        text(d, (x0 + 18, y), header, 11, "Semibold", th.text2)
        y += 20
        for it in items:
            if i == selected:
                d.rounded_rectangle([x0 + 8, y - 3, sx1 - 8, y + 19], 5, fill=th.sidebar_sel)
            col = (icon_colors or [th.accent])[i % len(icon_colors or [1])]
            d.rounded_rectangle([x0 + 18, y + 3, x0 + 30, y + 13], 2, fill=col)
            text(d, (x0 + 38, y + 1), it, 13, "Regular", th.text)
            y += 24; i += 1
        y += 12
    return sx1


def folder_icon(d, x, y, size):
    b = (98, 178, 240); dark = (74, 150, 220)
    d.rounded_rectangle([x, y + size * .18, x + size, y + size * .82], size * .08, fill=b)
    d.rounded_rectangle([x, y + size * .12, x + size * .42, y + size * .3], size * .06, fill=dark)
    d.rectangle([x, y + size * .28, x + size, y + size * .36], fill=dark)


def search_field(d, th, rect, placeholder="Search"):
    d.rounded_rectangle(rect, 6, fill=th.field, outline=th.sep)
    x0, y0, x1, y1 = rect
    cy = (y0 + y1) // 2
    d.ellipse([x0 + 8, cy - 5, x0 + 16, cy + 3], outline=th.text2, width=2)
    d.line([x0 + 15, cy + 2, x0 + 19, cy + 6], fill=th.text2, width=2)
    text(d, (x0 + 26, cy), placeholder, 12, "Regular", th.text2, anchor="lm")


def icon(d, name, cx, cy, color, k=7):
    """Toolbar glyphs as primitives (SF Pro has no box-drawing/emoji symbols; a Unicode
    stand-in renders as the .notdef box). k = half-size in px."""
    if name == "grid":            # icon view: 2x2 squares
        for i in (-1, 0):
            for j in (-1, 0):
                d.rectangle([cx + i * k + 1, cy + j * k + 1, cx + (i + 1) * k - 1, cy + (j + 1) * k - 1], fill=color)
    elif name == "list":          # 3 rows
        for j in (-k + 2, 0, k - 2):
            d.line([cx - k, cy + j, cx + k, cy + j], fill=color, width=2)
    elif name == "columns":       # 3 vertical bars
        for i in (-k + 2, 0, k - 2):
            d.line([cx + i, cy - k, cx + i, cy + k], fill=color, width=2)
    elif name == "gallery":       # big rect over a row of small ones
        d.rectangle([cx - k, cy - k, cx + k, cy + 1], outline=color)
        for i in range(3):
            d.rectangle([cx - k + i * 5, cy + 3, cx - k + i * 5 + 3, cy + k], fill=color)
    elif name == "sidebar":       # rect with a divided left pane
        d.rounded_rectangle([cx - k, cy - k + 1, cx + k, cy + k - 1], 2, outline=color, width=2)
        d.line([cx - k + 5, cy - k + 1, cx - k + 5, cy + k - 1], fill=color, width=2)
    elif name == "group":         # circle-in-box (group by)
        d.rectangle([cx - k, cy - k, cx + k, cy + k], outline=color, width=2)
        d.ellipse([cx - 3, cy - 3, cx + 3, cy + 3], fill=color)
    elif name == "share":         # box with an up arrow
        d.rectangle([cx - k + 2, cy - 2, cx + k - 2, cy + k], outline=color, width=2)
        d.line([cx, cy - k, cx, cy + 2], fill=color, width=2)
        d.line([cx - 3, cy - k + 3, cx, cy - k, cx + 3, cy - k + 3], fill=color, width=2)
    elif name == "tag":           # circle outline
        d.ellipse([cx - k + 1, cy - k + 1, cx + k - 1, cy + k - 1], outline=color, width=2)
    elif name == "tabs":          # two overlapping squares
        d.rectangle([cx - k, cy - k + 3, cx + k - 3, cy + k], outline=color, width=2)
        d.rectangle([cx - k + 3, cy - k, cx + k, cy + k - 3], outline=color, width=2)
    elif name == "search":        # magnifier
        d.ellipse([cx - k, cy - k, cx + 2, cy + 2], outline=color, width=2)
        d.line([cx + 1, cy + 1, cx + k, cy + k], fill=color, width=2)
    elif name == "more":          # vertical ellipsis
        for j in (-5, 0, 5):
            d.ellipse([cx - 1, cy + j - 1, cx + 1, cy + j + 1], fill=color)
    elif name == "more_h":        # horizontal ellipsis
        for i in (-5, 0, 5):
            d.ellipse([cx + i - 1, cy - 1, cx + i + 1, cy + 1], fill=color)
    elif name == "pen":           # markup pen
        d.line([cx - k, cy + k, cx + k - 2, cy - k + 2], fill=color, width=3)
        d.polygon([(cx - k, cy + k), (cx - k + 4, cy + k), (cx - k, cy + k - 4)], fill=color)
    elif name == "zoom_in" or name == "zoom_out":
        d.line([cx - k + 2, cy, cx + k - 2, cy], fill=color, width=2)
        if name == "zoom_in":
            d.line([cx, cy - k + 2, cx, cy + k - 2], fill=color, width=2)
    elif name == "home":          # house
        d.polygon([(cx, cy - k), (cx - k, cy), (cx + k, cy)], fill=color)
        d.rectangle([cx - k + 3, cy, cx + k - 3, cy + k], fill=color)
    elif name == "clock":
        d.ellipse([cx - k, cy - k, cx + k, cy + k], outline=color, width=2)
        d.line([cx, cy - 4, cx, cy, cx + 3, cy + 2], fill=color, width=2)
    elif name == "pause":
        d.rectangle([cx - 5, cy - k, cx - 2, cy + k], fill=color)
        d.rectangle([cx + 2, cy - k, cx + 5, cy + k], fill=color)
    elif name == "play":
        d.polygon([(cx - k + 2, cy - k), (cx + k, cy), (cx - k + 2, cy + k)], fill=color)


def toolbar_button(d, th, x, y, glyph, size=28):
    d.rounded_rectangle([x, y, x + size, y + size], 6, fill=th.window_bg)
    icon(d, glyph, x + size // 2, y + size // 2, th.text2)


# ---- occluders (drawn after the paste; returned so labels lose the covered area) ------
def notification(canvas, th, rng):
    """Top-right banner (MEASURED: 360x76, radius 14, 12 px from the top-right edges)."""
    w, h = 360, 76
    x1, y0 = canvas.width - 12, T.MENU_BAR_H + 12
    rect = (x1 - w, y0, x1, y0 + h)
    shadow(canvas, rect, 14, blur=10, dy=4, alpha=70)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(rect, 14, fill=T.blend(th.window_bg, .92, (128, 128, 128)), outline=th.border)
    name, col, glyph = rng.choice(DOCK_APPS[3:5] + DOCK_APPS[7:8])
    title, body = {"Messages": ("Alex", "Are we still on for tonight?"),
                   "Mail": ("Order confirmation", "Your order has shipped"),
                   "Notes": ("Reminder", "Lunch at 12:30")}[name]
    app_icon(d, rect[0] + 12, y0 + 18, 40, name, col, glyph)
    text(d, (rect[0] + 64, y0 + 16), name.upper(), 10, "Semibold", th.text2)
    text(d, (rect[0] + 64, y0 + 30), title, 13, "Semibold", th.text)
    text(d, (rect[0] + 64, y0 + 48), body, 12, "Regular", th.text2)
    return rect


def sheet(canvas, th, rng, win_rect, app="Finder", bar_h=None):
    """Alert sheet dropped from a window's title/tool bar (MEASURED: 260 wide, centered)."""
    x0, y0, x1, y1 = win_rect
    w, h = 260, 200
    cx = (x0 + x1) // 2
    bar_h = bar_h or (T.TITLE_H if app in ("QuickTime Player",) else T.TOOLBAR_H)
    rect = (cx - w // 2, y0 + bar_h, cx + w // 2, y0 + bar_h + h)
    shadow(canvas, rect, 12, blur=12, dy=6, alpha=90)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(rect, 12, fill=th.window_bg, outline=th.border)
    icon = next((a for a in DOCK_APPS if a[0] == app), DOCK_APPS[0])
    app_icon(d, cx - 28, rect[1] + 18, 56, *icon)
    title, body, ok = rng.choice([
        ("Do you want to save the changes?", "Your changes will be lost if you\ndon't save them.", "Save"),
        (f"Are you sure you want to quit {app}?", "All open windows will be closed.", "Quit"),
        ("Delete this item?", "This item will be moved to the Trash.", "Delete")])
    text(d, (cx, rect[1] + 92), title, 12, "Bold", th.text, anchor="ma")
    text(d, (cx, rect[1] + 110), body, 11, "Regular", th.text2, anchor="ma")
    bw = (w - 40) // 2
    d.rounded_rectangle([rect[0] + 16, rect[3] - 44, rect[0] + 16 + bw, rect[3] - 18], 6,
                        fill=th.field, outline=th.sep)
    text(d, (rect[0] + 16 + bw // 2, rect[3] - 31), "Cancel", 13, "Regular", th.text, anchor="mm")
    d.rounded_rectangle([rect[2] - 16 - bw, rect[3] - 44, rect[2] - 16, rect[3] - 18], 6, fill=th.accent)
    text(d, (rect[2] - 16 - bw // 2, rect[3] - 31), ok, 13, "Semibold", (255, 255, 255), anchor="mm")
    return rect


def background_window(canvas, th, rng, avoid_rect, work):
    """Second window in FRONT of the main one from a random side (it is the active one,
    so it gets lit traffic lights and a full shadow)."""
    wx0, wy0, wx1, wy1 = work
    w, h = rng.randint(360, 620), rng.randint(280, 520)
    side = rng.choice(["right", "bottom", "left"])
    if side == "right":
        x = min(wx1 - w, avoid_rect[2] - rng.randint(w // 3, w // 2)); y = rng.randint(wy0, max(wy0, wy1 - h))
    elif side == "left":
        x = max(wx0, avoid_rect[0] - w + rng.randint(w // 3, w // 2)); y = rng.randint(wy0, max(wy0, wy1 - h))
    else:
        x = rng.randint(wx0, max(wx0, wx1 - w)); y = min(wy1 - h, avoid_rect[3] - rng.randint(h // 3, h // 2))
    rect = (x, y, x + w, y + h)
    content = window(canvas, th, rect, title=rng.choice(["Notes", "Untitled", "Reminders", "Calendar"]),
                     active=True)
    d = ImageDraw.Draw(canvas)
    lines(d, content[0] + 24, content[1] + 20, w - 48, rng.randint(4, 10), 0, rng, th.text2, 13)
    return rect


def cursor(canvas, rng, work):
    """Arrow pointer (tiny; not treated as an occluder)."""
    x, y = rng.randint(work[0], work[2] - 20), rng.randint(work[1], work[3] - 24)
    d = ImageDraw.Draw(canvas)
    pts = [(x, y), (x, y + 17), (x + 4, y + 13), (x + 7, y + 19), (x + 10, y + 18), (x + 7, y + 12), (x + 12, y + 12)]
    d.polygon(pts, fill=(0, 0, 0), outline=(255, 255, 255))
