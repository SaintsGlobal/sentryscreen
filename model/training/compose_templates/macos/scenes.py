"""Scenes wrap an app window: plain desktop, Stage Manager (left tile strip), or Split View."""
from __future__ import annotations
from PIL import ImageDraw

from . import theme as T
from . import chrome
from .chrome import (Placement, desktop, window_rect, shadow, app_icon, DOCK_APPS,
                     lines, folder_icon, notification, sheet, background_window, cursor)


def _render_app(app, canvas, th, rng, rect, im, distractors, area=None):
    app.area = area          # only quicklook reads it: where its floating panel may sit
    s, x, y, vis, occ = app(canvas, th, rng, rect, im, distractors)
    return s, x, y, vis, list(occ)


def desktop_scene(app, rng, im, th, distractors, size):
    canvas, work = desktop(rng, th, size, app.app)
    rect = window_rect(rng, work, *app.min_size)
    s, x, y, vis, occ = _render_app(app, canvas, th, rng, rect, im, distractors)
    return Placement(canvas, s, x, y, vis, occ, "desktop"), rect, work


def stage_manager_scene(app, rng, im, th, distractors, size):
    """Stage Manager: 4-5 recent-app tiles down the left (MEASURED strip ≈ 150 px, tiles
    ≈ 128 px wide with the app icon at the bottom-right), active window offset right."""
    canvas, work = desktop(rng, th, size, app.app)
    d = ImageDraw.Draw(canvas)
    strip_w = 150
    ty = work[1] + 24
    for i in range(rng.randint(3, 5)):
        tw, tht = 128, rng.randint(72, 96)
        tr = (12, ty, 12 + tw, ty + tht)
        shadow(canvas, tr, 6, blur=8, dy=4, alpha=80)
        d.rounded_rectangle(tr, 6, fill=th.window_bg, outline=th.border)
        d.rectangle([tr[0] + 1, tr[1] + 1, tr[2] - 1, tr[1] + 8], fill=th.titlebar)
        lines(d, tr[0] + 8, tr[1] + 14, tw - 16, 3, 0, rng, th.text2, 7, gap=3)
        name, col, glyph = DOCK_APPS[(i * 3 + 1) % len(DOCK_APPS)]
        app_icon(d, tr[2] - 22, tr[3] - 22, 32, name, col, glyph)
        ty += tht + 28
    inner = (strip_w + 16, work[1] + 12, work[2] - 24, work[3] - 12)
    rect = window_rect(rng, inner, *app.min_size, zoomed_p=0.35)
    s, x, y, vis, occ = _render_app(app, canvas, th, rng, rect, im, distractors, area=inner)
    return Placement(canvas, s, x, y, vis, occ, "stage_manager"), rect, inner


def split_view_scene(app, rng, im, th, distractors, size):
    """Full-screen Split View: two windows fill the display (menu bar hidden), 8 px black
    divider (MEASURED). The app takes the wider or narrower side at random."""
    W, H = size
    canvas = T.wallpaper(rng, size, th).point(lambda v: v // 4)   # dimmed backdrop behind the gap
    # the app tile is at least app.min_size wide (MEASURED: Split View lets a window claim
    # up to ~70% of the display); the other tile keeps ≥ 380 px. Never squash below min.
    min_w = app.min_size[0] + 8
    if min_w > W - 380:
        raise RuntimeError(f"split_view: {app.app} min width {min_w} leaves <380 px for the "
                           f"other tile on a {W}-wide canvas")
    app_w = rng.randint(max(min_w, round(W * 0.45)), min(W - 380, round(W * 0.7)))
    if rng.random() < 0.5:
        app_side, other = (0, 0, app_w - 4, H), (app_w + 4, 0, W, H)
    else:
        app_side, other = (W - app_w + 4, 0, W, H), (0, 0, W - app_w - 4, H)
    # windows in Split View have no rounded corners or shadow: paint flat
    d = ImageDraw.Draw(canvas)
    d.rectangle(other, fill=th.window_bg)
    d.rectangle([other[0], 0, other[2], T.TOOLBAR_H], fill=th.titlebar)
    lines(d, other[0] + 32, T.TOOLBAR_H + 24, other[2] - other[0] - 64, rng.randint(8, 16), 0, rng, th.text2, 14)
    for i in range(3):
        folder_icon(d, other[0] + 40 + i * 100, other[3] - 140, 64)
    chrome.FLAT = True                   # Split View tiles: no shadow, square corners
    try:
        s, x, y, vis, occ = _render_app(app, canvas, th, rng, app_side, im, distractors, area=app_side)
    finally:
        chrome.FLAT = False
    return Placement(canvas, s, x, y, vis, occ, "split_view"), app_side, (0, 0, W, H)


SCENES = [("desktop", desktop_scene, 0.75), ("stage_manager", stage_manager_scene, 0.15),
          ("split_view", split_view_scene, 0.10)]      # ASSUMED shares; see POOL receipt


def render(app, rng, im, th, distractors, size, occluder_p=0.3, scene=None):
    """Pick a scene (or force `scene` — tests), render the app in it, then maybe draw an
    occluder on top. ASSUMED: 30% of screens have something in front (notification /
    sheet / other window)."""
    name, fn, _ = rng.choices(SCENES, weights=[w for _, _, w in SCENES])[0]
    if scene:
        name, fn, _ = next(s for s in SCENES if s[0] == scene)
    pl, rect, work = fn(app, rng, im, th, distractors, size)
    if rng.random() < occluder_p:
        kind = rng.choices(["notification", "sheet", "window"], weights=[.4, .25, .35])[0]
        if kind == "notification":
            pl.occluders.append(notification(pl.canvas, th, rng))
        elif kind == "sheet":
            pl.occluders.append(sheet(pl.canvas, th, rng, rect, app.app,
                                      bar_h=38 if app.app == "Slack" else 40 if app.app == "Google Chrome" else None))
        elif name != "split_view":
            pl.occluders.append(background_window(pl.canvas, th, rng, rect, work))
    if rng.random() < 0.5:
        cursor(pl.canvas, rng, work)
    return pl
