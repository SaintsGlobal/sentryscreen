"""Photos.app (grid + single-photo view) and QuickTime Player."""
from __future__ import annotations
from PIL import Image, ImageDraw

from . import theme as T
from .chrome import icon, paste_fit, pick_base_cell, text, window, sidebar, search_field

PHOTOS_GROUPS = [("Photos", ["Library", "Memories", "Favorites", "Recents"]),
                 ("Albums", ["Trip", "Selfies", "Screenshots", "Imports"])]
PHOTOS_COLORS = [(0, 122, 255), (255, 149, 0), (255, 59, 48), (0, 122, 255),
                 (0, 122, 255), (0, 122, 255), (0, 122, 255), (0, 122, 255)]


def _photos_frame(canvas, th, rng, rect):
    x0, y0, x1, y1 = rect
    body = window(canvas, th, rect, bar_h=T.TOOLBAR_H)
    d = ImageDraw.Draw(canvas)
    sb = sidebar(d, th, body, PHOTOS_GROUPS, selected=rng.randint(0, 3), icon_colors=PHOTOS_COLORS)
    ty = y0 + T.TOOLBAR_H // 2
    seg = ["Years", "Months", "Days", "All Photos"]
    sw = 300
    search_w = 168 if x1 - sb > 720 else 110
    search_field(d, th, (x1 - 12 - search_w, ty - 14, x1 - 12, ty + 14))
    icon(d, "share", x1 - 12 - search_w - 24, ty, th.text2)
    right = x1 - 12 - search_w - 48
    sx = min((sb + x1) // 2 - sw // 2, right - sw)
    if sx > sb + 16:                                          # dropped, not overlapped, when narrow
        d.rounded_rectangle([sx, ty - 13, sx + sw, ty + 13], 7, fill=th.sidebar, outline=th.sep)
        d.rounded_rectangle([sx + 3 + 3 * 74, ty - 11, sx + sw - 3, ty + 11], 5, fill=th.field)
        for i, s in enumerate(seg):
            text(d, (sx + 37 + i * 74, ty), s, 12, "Semibold" if i == 3 else "Regular", th.text, anchor="mm")
    return (sb + 1, body[1], body[2], body[3])


def photos_grid(canvas, th, rng, rect, im, distractors):
    """All Photos: square thumbnails, 4-7 columns (MEASURED zoom range), 2 px gaps."""
    c = _photos_frame(canvas, th, rng, rect)
    x0, y0, x1, y1 = c
    d = ImageDraw.Draw(canvas)
    d.rectangle(c, fill=th.page_bg)
    cols = rng.choice([3, 4, 4, 5, 6])
    g = 2
    size = (x1 - x0 - g * (cols - 1)) // cols
    rows = (y1 - y0) // (size + g) + 1
    cells = [(x0 + cc * (size + g), y0 + r * (size + g)) for r in range(rows) for cc in range(cols)]
    base_i = pick_base_cell(rng, cells, size, y1)
    result = None
    for i, (cx, cy) in enumerate(cells):
        cell = (cx, cy, cx + size, min(cy + size, y1))
        if cell[3] <= cell[1]:
            continue
        if i == base_i:
            s, px, py, vis = paste_fit(canvas, im, cell, cover=True)
            result = (s, px, py, vis)
        elif distractors:                                    # real grids have no holes
            paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), cell, cover=True)
        else:
            d.rectangle(cell, fill=th.row_alt)
    return (*result, [])


def photos_detail(canvas, th, rng, rect, im, distractors):
    """Single photo opened from the grid: dark content area, image fitted, thin scrubber."""
    c = _photos_frame(canvas, th, rng, rect)
    x0, y0, x1, y1 = c
    d = ImageDraw.Draw(canvas)
    d.rectangle(c, fill=(28, 28, 30) if th is T.DARK else (255, 255, 255))
    scrub = 56
    s, x, y, vis = paste_fit(canvas, im, (x0 + 8, y0 + 8, x1 - 8, y1 - scrub - 8), align="center")
    d.rectangle([x0, y1 - scrub, x1, y1], fill=th.window_bg)
    n_cells = (x1 - x0) // 44
    sel = rng.randrange(max(1, n_cells))
    for i in range(n_cells):
        tx = x0 + 8 + i * 44
        cell = (tx, y1 - scrub + 10, tx + 36, y1 - 10)
        if i == sel:
            d.rectangle([tx - 2, cell[1] - 2, tx + 38, cell[3] + 2], outline=th.accent, width=2)
        if distractors:                     # selected cell too: never an unlabeled copy of the base
            paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), cell, cover=True)
        else:
            d.rectangle(cell, fill=th.row_alt)
    return s, x, y, vis, []


def quicktime(canvas, th, rng, rect, im, distractors):
    """QuickTime Player: title bar over black; floating control pill (occluder) sometimes."""
    x0, y0, x1, y1 = rect
    body = window(canvas, T.DARK, rect, title=rng.choice(["clip.mov", "IMG_%04d.MOV" % rng.randint(1, 9999),
                                                          "Screen Recording.mov"]), body=(0, 0, 0))
    s, x, y, vis = paste_fit(canvas, im, body, align="center")
    occ = []
    if rng.random() < 0.6:
        pw, ph = min(520, x1 - x0 - 80), 52
        pr = ((x0 + x1) // 2 - pw // 2, y1 - 24 - ph, (x0 + x1) // 2 + pw // 2, y1 - 24)
        d = ImageDraw.Draw(canvas)
        d.rounded_rectangle(pr, 12, fill=(60, 60, 64), outline=(90, 90, 94))
        icon(d, "play", pr[0] + 40, pr[1] + 26, (240, 240, 240), k=6)
        d.rectangle([pr[0] + 110, pr[1] + 24, pr[2] - 40, pr[1] + 28], fill=(110, 110, 114))
        d.rectangle([pr[0] + 110, pr[1] + 24, pr[0] + 110 + rng.uniform(.1, .9) * (pw - 150), pr[1] + 28],
                    fill=(230, 230, 230))
        text(d, (pr[0] + 74, pr[1] + 26), f"{rng.randint(0,3)}:{rng.randint(0,59):02d}", 11, "Regular", (220, 220, 220), anchor="mm")
        occ.append(pr)
    return s, x, y, vis, occ


for fn, app, ms in [(photos_grid, "Photos", (820, 520)), (photos_detail, "Photos", (820, 520)),
                    (quicktime, "QuickTime Player", (480, 360))]:
    fn.app, fn.min_size = app, ms
