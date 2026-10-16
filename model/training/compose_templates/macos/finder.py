"""Finder (gallery + icon views), Quick Look panel over Finder, and Preview.app."""
from __future__ import annotations
from PIL import Image, ImageDraw

from . import theme as T
from . import chrome
from .chrome import (icon, paste_fit, pick_base_cell, text, window, sidebar, folder_icon,
                     search_field, toolbar_button)

SIDEBAR_GROUPS = [("Favorites", ["AirDrop", "Recents", "Applications", "Desktop", "Documents",
                                 "Downloads", "Pictures"]),
                  ("iCloud", ["iCloud Drive", "Shared"]),
                  ("Locations", ["Macintosh HD", "Network"])]
SIDEBAR_COLORS = [(0, 122, 255), (0, 122, 255), (0, 122, 255), (0, 122, 255), (0, 122, 255),
                  (0, 122, 255), (0, 122, 255), (110, 180, 255), (110, 180, 255), (140, 140, 146), (140, 140, 146)]
FOLDERS = ["Screenshots", "Camera Roll", "2024", "Exports", "Raw", "Edited", "Trip", "Misc",
           "Favorites", "Archive", "Wallpapers", "Scans"]
IMG_NAMES = ["IMG_{:04d}.jpg", "DSC{:05d}.JPG", "photo-{:04d}.png", "{:04d}.jpeg", "Screenshot {:04d}.png"]


def _finder_frame(canvas, th, rng, rect, title="Pictures"):
    """Window + toolbar (back/fwd, view segmented control, search) + sidebar. Returns content rect."""
    x0, y0, x1, y1 = rect
    body = window(canvas, th, rect, bar_h=T.TOOLBAR_H)
    d = ImageDraw.Draw(canvas)
    ty = y0 + T.TOOLBAR_H // 2
    sb = sidebar(d, th, body, SIDEBAR_GROUPS, selected=rng.randint(3, 6), icon_colors=SIDEBAR_COLORS)
    text(d, (sb + 68, ty), title, 15, "Bold", th.text, anchor="lm")
    text(d, (sb + 20, ty), "‹", 18, "Regular", th.text2, anchor="mm")
    text(d, (sb + 44, ty), "›", 18, "Regular", th.text2, anchor="mm")
    # right-to-left layout with a minimum gap: items that don't fit are dropped, never overlapped
    sw = 188 if x1 - sb > 700 else 120
    search_field(d, th, (x1 - 12 - sw, ty - 14, x1 - 12, ty + 14))
    right = x1 - 12 - sw - 16
    gx = sb + 260
    if gx + 150 > right:                       # narrow window: drop, never overlap
        return (sb + 1, body[1], body[2], body[3])
    d.rounded_rectangle([gx, ty - 14, gx + 150, ty + 14], 6, fill=th.field, outline=th.sep)
    d.rounded_rectangle([gx + 1, ty - 13, gx + 37, ty + 13], 5, fill=th.sidebar_sel)
    for i, g in enumerate(["grid", "list", "columns", "gallery"]):
        icon(d, g, gx + 19 + i * 37, ty, th.text if i == 0 else th.text2)
    bx = gx + 170
    for g in ["group", "share", "tag"]:
        if bx + 28 > right:
            break
        toolbar_button(d, th, bx, ty - 14, g); bx += 36
    return (sb + 1, body[1], body[2], body[3])


def finder_gallery(canvas, th, rng, rect, im, distractors):
    """Gallery view: large preview on top, filmstrip below, metadata strip on the right."""
    c = _finder_frame(canvas, th, rng, rect, rng.choice(["Pictures", "Downloads", "Camera Roll"]))
    x0, y0, x1, y1 = c
    d = ImageDraw.Draw(canvas)
    d.rectangle(c, fill=th.page_bg)
    strip_h = 96
    meta_w = 220 if x1 - x0 > 800 and rng.random() < 0.6 else 0
    pv = (x0 + 24, y0 + 16, x1 - 24 - meta_w, y1 - strip_h - 24)
    s, x, y, vis = paste_fit(canvas, im, pv, align="center")
    if meta_w:
        d.line([x1 - meta_w, y0, x1 - meta_w, y1 - strip_h], fill=th.sep)
        text(d, (x1 - meta_w + 16, y0 + 24), rng.choice(IMG_NAMES).format(rng.randint(1, 9999)), 13, "Semibold", th.text)
        text(d, (x1 - meta_w + 16, y0 + 44), f"JPEG image · {rng.uniform(.4, 6):.1f} MB", 11, "Regular", th.text2)
        y2 = y0 + 84
        for k, v in [("Created", "Today, 9:41"), ("Modified", "Today, 9:42"), ("Dimensions", f"{im.width}×{im.height}"),
                     ("Color space", "RGB"), ("Tags", "—")]:
            text(d, (x1 - meta_w + 16, y2), k, 11, "Regular", th.text2)
            text(d, (x1 - 16, y2), v, 11, "Regular", th.text, anchor="ra"); y2 += 20
    # filmstrip
    sy = y1 - strip_h
    d.rectangle([x0, sy, x1, y1], fill=th.window_bg)
    d.line([x0, sy, x1, sy], fill=th.sep)
    n = (x1 - x0 - 24) // 84
    sel = rng.randrange(min(n, 6))
    for i in range(n):
        tx = x0 + 12 + i * 84
        cell = (tx + 8, sy + 16, tx + 72, sy + 80)
        if i == sel:
            d.rounded_rectangle([tx + 2, sy + 10, tx + 78, sy + 86], 6, outline=th.accent, width=2)
        if distractors and (i == sel or rng.random() < 0.6):   # never an unlabeled copy of the base
            paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), cell, cover=True)
        else:
            folder_icon(d, tx + 10, sy + 18, 60)
    return s, x, y, vis, []


def finder_icons(canvas, th, rng, rect, im, distractors):
    """Icon view at a large icon size (MEASURED slider range 16-512; ASSUMED 160-256 here so
    the labeled thumbnail is still a detectable size)."""
    c = _finder_frame(canvas, th, rng, rect, rng.choice(["Pictures", "Downloads", "Desktop"]))
    x0, y0, x1, y1 = c
    d = ImageDraw.Draw(canvas)
    d.rectangle(c, fill=th.page_bg)
    size = rng.choice([160, 192, 224, 256])
    gx, gy = size + 40, size + 44
    cols = max(1, (x1 - x0 - 20) // gx)
    rows = max(1, (y1 - y0 - 20) // gy + 1)
    cells = [(x0 + 20 + cc * gx, y0 + 16 + r * gy) for r in range(rows) for cc in range(cols)]
    base_i = pick_base_cell(rng, cells, size + 16, y1)
    result = None
    for i, (cx, cy) in enumerate(cells):
        cell = (cx, cy, cx + size, min(cy + size, y1))
        if cell[3] - cell[1] < size // 3:
            continue
        name = rng.choice(IMG_NAMES).format(rng.randint(1, 9999))
        if i == base_i:
            s, px, py, vis = paste_fit(canvas, im, cell, align="center")
            d.rounded_rectangle([cx - 6, cy - 6, cx + size + 6, min(cy + size, y1) + 6], 6,
                                outline=th.sidebar_sel, width=3)
            result = (s, px, py, vis)
        elif cy + size <= y1 and rng.random() < 0.5:           # folders never cross the edge
            folder_icon(d, cx + size * .1, cy + size * .1, size * .8)
            name = rng.choice(FOLDERS)
        elif distractors:
            paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), cell, align="center")
        else:
            d.rectangle(cell, fill=th.row_alt)
        if cy + size + 16 < y1:
            text(d, (cx + size // 2, cy + size + 8), name, 12, "Regular", th.text, anchor="ma")
    if result is None:  # cannot happen (base_i is always a full cell) — fail loudly if it does
        raise RuntimeError("finder_icons: base cell not placed")
    return (*result, [])


def quicklook(canvas, th, rng, rect, im, distractors):
    """Quick Look panel (space bar in Finder) centered over an inactive Finder window.
    MEASURED: panel is a dark-translucent rounded 10 window with a 28 px title bar showing
    the file name and an 'Open with Preview' button; image fills the panel."""
    c = _finder_frame(canvas, th, rng, rect)
    x0, y0, x1, y1 = c
    d = ImageDraw.Draw(canvas)
    d.rectangle(c, fill=th.page_bg)
    size = 96
    cols = max(1, (x1 - x0 - 20) // (size + 40))
    for i in range((y1 - y0) // (size + 44) * cols):
        cx, cy = x0 + 20 + (i % cols) * (size + 40), y0 + 16 + (i // cols) * (size + 44)
        if cy + size > y1:
            break
        if distractors and rng.random() < 0.4:
            paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), (cx, cy, cx + size, cy + size), align="center")
        else:
            folder_icon(d, cx + 8, cy + 8, size - 16)
    # panel: 55-90% of the scene's usable width, centered in it (the whole work area on a
    # plain desktop; the app's own tile in Split View / Stage Manager)
    ax0, ay0, ax1, ay1 = quicklook.area if quicklook.area else (0, T.MENU_BAR_H, canvas.width,
                                                               canvas.height - T.DOCK_H - T.DOCK_GAP)
    aw, ah = ax1 - ax0, ay1 - ay0 - 24
    aspect = im.width / im.height
    pw = round(aw * rng.uniform(0.55, 0.9))
    ph = round(pw / aspect) + T.TITLE_H
    if ph > ah:
        ph = ah; pw = round((ph - T.TITLE_H) * aspect)
    px0, py0 = ax0 + (aw - pw) // 2, ay0 + 12 + (ah - ph) // 2
    panel = (px0, py0, px0 + pw, py0 + ph)
    dark = T.DARK
    flat = chrome.FLAT
    chrome.FLAT = False          # a floating panel keeps its shadow/corners even over a Split View tile
    try:
        body = window(canvas, dark, panel, title=rng.choice(IMG_NAMES).format(rng.randint(1, 9999)),
                      bar_h=T.TITLE_H, body=(30, 30, 32))
    finally:
        chrome.FLAT = flat
    d.rounded_rectangle([panel[2] - 150, py0 + 4, panel[2] - 12, py0 + 24], 5, fill=(70, 70, 74))
    text(d, (panel[2] - 81, py0 + 14), "Open with Preview", 11, "Regular", dark.text, anchor="mm")
    s, x, y, vis = paste_fit(canvas, im, body, align="center")
    return s, x, y, vis, []


def preview(canvas, th, rng, rect, im, distractors):
    """Preview.app: toolbar 52 with the file name, optional thumbnail sidebar, image on grey."""
    x0, y0, x1, y1 = rect
    body = window(canvas, th, rect, bar_h=T.TOOLBAR_H)
    d = ImageDraw.Draw(canvas)
    ty = y0 + T.TOOLBAR_H // 2
    icon(d, "sidebar", x0 + 88, ty, th.text2)
    name = rng.choice(IMG_NAMES).format(rng.randint(1, 9999))
    text(d, ((x0 + x1) // 2, ty), name, 13, "Semibold", th.text, anchor="mm")
    for i, g in enumerate(["zoom_out", "zoom_in", "pen", "share", "search"]):
        toolbar_button(d, th, x1 - 210 + i * 40, ty - 14, g)
    d.line([x0, body[1] - 1, x1, body[1] - 1], fill=th.sep)
    d.rectangle(body, fill=th.content_bg)
    cx0 = body[0]
    if rng.random() < 0.3:                                    # thumbnail sidebar
        d.rectangle([body[0], body[1], body[0] + 150, body[3]], fill=th.sidebar)
        d.line([body[0] + 150, body[1], body[0] + 150, body[3]], fill=th.sep)
        for i in range(rng.randint(1, 4)):
            cell = (body[0] + 25, body[1] + 20 + i * 120, body[0] + 125, body[1] + 120 + i * 120)
            if cell[3] > body[3]:
                break
            if i == 0:
                d.rounded_rectangle([cell[0] - 5, cell[1] - 5, cell[2] + 5, cell[3] + 5], 4, outline=th.accent, width=2)
            if distractors:                                   # never an unlabeled copy of the base
                paste_fit(canvas, Image.open(rng.choice(distractors)).convert("RGB"), cell, align="center")
        cx0 = body[0] + 151
    s, x, y, vis = paste_fit(canvas, im, (cx0, body[1], body[2], body[3]), rng,
                             fill=(0.7, 1.0), align="center")
    return s, x, y, vis, []


quicklook.area = None   # set by scenes.render to the scene's usable rect before each call
for fn, app, ms in [(finder_gallery, "Finder", (820, 520)), (finder_icons, "Finder", (760, 500)),
                    (quicklook, "Finder", (760, 500)), (preview, "Preview", (640, 480))]:
    fn.app, fn.min_size = app, ms
