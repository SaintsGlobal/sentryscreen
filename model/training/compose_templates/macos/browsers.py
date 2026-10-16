"""Safari (Sequoia, separate-tab layout) and Chrome windows with three page bodies:
article (one large image in flowing text), thumbnail grid, and YouTube watch page."""
from __future__ import annotations
from PIL import Image, ImageDraw

from . import theme as T

from .chrome import icon, paste_fit, pick_base_cell, text, text_w, lines, window

DOMAINS = ["photos.example.com", "gallery.example.org", "news.example.net",
           "example.com/blog/2041", "images.example.io/set/summer", "example.travel/stories"]
TABS = ["Gallery", "Inbox (3)", "Weather", "Docs", "Maps", "Search", "Untitled", "Photos"]


# ---- chrome strips ---------------------------------------------------------------
def safari_chrome(canvas, th, rng, rect):
    """Toolbar 52 + tab bar 36 (separate layout, MEASURED Safari 18). Returns page rect."""
    x0, y0, x1, y1 = rect
    body = window(canvas, th, rect, bar_h=T.TOOLBAR_H)
    d = ImageDraw.Draw(canvas)
    ty = y0 + T.TOOLBAR_H // 2
    icon(d, "sidebar", x0 + 88, ty, th.text2)
    for i, g in enumerate(["‹", "›"]):
        text(d, (x0 + 118 + i * 30, ty), g, 16, "Regular", th.text2, anchor="mm")
    uw = min(560, int((x1 - x0) * .55))
    cx = (x0 + x1) // 2
    d.rounded_rectangle([cx - uw // 2, ty - 15, cx + uw // 2, ty + 15], 8, fill=th.field,
                        outline=th.sep)
    dom = rng.choice(DOMAINS)
    text(d, (cx, ty), dom, 13, "Regular", th.text, anchor="mm")
    d.rounded_rectangle([cx - text_w(dom, 13) / 2 - 20, ty - 5, cx - text_w(dom, 13) / 2 - 12,
                         ty + 4], 2, outline=th.text2)                      # padlock
    icon(d, "share", x1 - 100, ty, th.text2)
    text(d, (x1 - 66, ty), "+", 15, "Regular", th.text2, anchor="mm")
    icon(d, "tabs", x1 - 32, ty, th.text2)
    # tab bar
    tb0 = y0 + T.TOOLBAR_H + 1
    d.rectangle([x0 + 1, tb0, x1 - 1, tb0 + 36], fill=th.titlebar)
    d.line([x0, tb0 + 36, x1, tb0 + 36], fill=th.sep)
    n = rng.randint(1, 6)
    tw = min(240, (x1 - x0 - 16) // n)
    active = rng.randrange(n)
    for i in range(n):
        tx = x0 + 8 + i * tw
        if i == active:
            d.rounded_rectangle([tx, tb0 + 4, tx + tw - 4, tb0 + 32], 6, fill=th.window_bg,
                                outline=th.sep)
        text(d, (tx + tw // 2 - 2, tb0 + 18), rng.choice(TABS) if i != active else dom.split("/")[0],
             12, "Regular", th.text if i == active else th.text2, anchor="mm")
    return (body[0], tb0 + 37, body[2], body[3])


def chrome_chrome(canvas, th, rng, rect):
    """Tab strip 40 + toolbar 40 (MEASURED Chrome 128 on macOS). Returns page rect."""
    x0, y0, x1, y1 = rect
    strip = (222, 225, 230) if th is T.LIGHT else (32, 33, 36)
    bar = (255, 255, 255) if th is T.LIGHT else (53, 54, 58)
    omni = (241, 243, 244) if th is T.LIGHT else (32, 33, 36)
    body = window(canvas, th, rect, bar_h=40, bar_color=strip)
    d = ImageDraw.Draw(canvas)
    n = rng.randint(1, 7)
    tw = min(220, (x1 - x0 - 100) // n)
    active = rng.randrange(n)
    dom = rng.choice(DOMAINS)
    for i in range(n):
        tx = x0 + 80 + i * tw
        if i == active:
            d.rounded_rectangle([tx, y0 + 8, tx + tw, y0 + 40], 8, fill=bar)
            d.rectangle([tx, y0 + 30, tx + tw, y0 + 40], fill=bar)
        d.ellipse([tx + 10, y0 + 18, tx + 24, y0 + 32], fill=th.text2)
        text(d, (tx + 32, y0 + 25), (dom.split("/")[0] if i == active else rng.choice(TABS))[:18],
             12, "Regular", th.text if i == active else th.text2, anchor="lm")
    text(d, (x0 + 80 + n * tw + 14, y0 + 24), "+", 18, "Regular", th.text2, anchor="mm")
    tb = y0 + 40
    d.rectangle([x0 + 1, tb, x1 - 1, tb + 40], fill=bar)
    for i, g in enumerate(["←", "→", "↻"]):
        text(d, (x0 + 24 + i * 30, tb + 20), g, 15, "Regular", th.text2, anchor="mm")
    d.rounded_rectangle([x0 + 110, tb + 6, x1 - 120, tb + 34], 14, fill=omni)
    text(d, (x0 + 128, tb + 20), dom, 13, "Regular", th.text, anchor="lm")
    d.ellipse([x1 - 96, tb + 8, x1 - 72, tb + 32], fill=(120, 160, 220))
    icon(d, "more", x1 - 40, tb + 20, th.text2)
    d.line([x0, tb + 40, x1, tb + 40], fill=th.sep)
    return (body[0], tb + 41, body[2], body[3])


# ---- page bodies -----------------------------------------------------------------
def page_theme(th, rng, dark_p=0.25):
    """Web pages are mostly light even in dark mode (ASSUMED 25% dark pages)."""
    dark = rng.random() < dark_p
    return ((15, 15, 15), (240, 240, 240), (170, 170, 170)) if dark else \
           ((255, 255, 255), (30, 30, 30), (110, 110, 110))


def page_article(canvas, th, rng, page, im):
    """One large image in flowing text. The page body is drawn into its own image and
    pasted into the page rect, so a scrolled-off header can never overpaint the chrome."""
    x0, y0, x1, y1 = page
    bg, fg, fg2 = page_theme(th, rng)
    pw, ph = x1 - x0, y1 - y0
    pg = Image.new("RGB", (pw, ph), bg)
    d = ImageDraw.Draw(pg)
    col_w = min(pw - 80, rng.randint(720, 1100))
    cx0 = (pw - col_w) // 2
    scroll = rng.randint(0, 120)                   # page scrolled up a little
    y = -scroll
    d.rectangle([0, y, pw, y + 56], fill=T.blend(fg, .06, bg))       # site nav
    text(d, (cx0, y + 28), rng.choice(["Gallery", "Stories", "The Daily", "Portfolio"]),
         18, "Bold", fg, anchor="lm")
    for i, m in enumerate(["Home", "Latest", "Albums", "About"]):
        text(d, (cx0 + col_w - 300 + i * 78, y + 28), m, 13, "Regular", fg2, anchor="lm")
    y += 56 + rng.randint(16, 48)
    text(d, (cx0, y), rng.choice(["Weekend in the city", "Summer set, part two",
                                  "Studio notes", "New arrivals"]), 30, "Bold", fg)
    y += 46
    y = lines(d, cx0, y, col_w, rng.randint(0, 3), 0, rng, fg2, 15)
    y += 12
    # the image: 70-100% of the column fit (MEASURED 2026-08-26: at 0.5-1.0 the median
    # base area was 0.11 of the canvas for the two heaviest-weighted templates — the
    # small-paste-scale regime the composites-vs-bases recall gap was blamed on)
    s, px, py, vis = paste_fit(pg, im, (cx0, max(y, 0), cx0 + col_w, ph), rng,
                               fill=(0.7, 1.0), align=rng.choice(["top", "top", None]))
    iy1 = py + round(im.height * s)
    if iy1 + 40 < ph:
        lines(d, cx0, iy1 + 24, col_w, min(8, (ph - iy1 - 24) // 23), 0, rng, fg2, 15)
    canvas.paste(pg, (x0, y0))
    return s, px + x0, py + y0, (vis[0] + x0, vis[1] + y0, vis[2] + x0, vis[3] + y0)


def page_thumbs(canvas, th, rng, page, im, distractors):
    """Image-results / tumblr-style grid; base is one card (2-3 columns → 300-500 px cards)."""
    x0, y0, x1, y1 = page
    bg, fg, fg2 = page_theme(th, rng)
    d = ImageDraw.Draw(canvas)
    d.rectangle(page, fill=bg)
    cols = rng.choice([2, 2, 3])
    g = 12
    cw = (x1 - x0 - 48 - g * (cols - 1)) // cols
    ch = min(round(cw * rng.uniform(0.7, 1.0)), y1 - y0 - 32)   # first row always fits
    rows = (y1 - y0 + ch) // (ch + g) + 1
    cells = [(x0 + 24 + c * (cw + g), y0 + 16 + r * (ch + g)) for r in range(rows) for c in range(cols)]
    base_i = pick_base_cell(rng, cells, ch, y1)
    result = None
    for i, (cx, cy) in enumerate(cells):
        cell = (cx, cy, cx + cw, min(cy + ch, y1))
        if cell[3] <= cell[1]:
            continue
        if i == base_i:
            s, px, py, _ = paste_fit(canvas, im, cell, cover=True)
            result = (s, px, py, cell)
        elif distractors:                                    # real grids have no holes
            dis = Image.open(rng.choice(distractors)).convert("RGB")
            paste_fit(canvas, dis, cell, cover=True)
        else:
            d.rectangle(cell, fill=T.blend(fg, .08, bg))
    return result


def page_youtube(canvas, th, rng, page, im, distractors):
    """Watch page: 16:9 player left, recommendations column right, title + lines below."""
    x0, y0, x1, y1 = page
    dark = rng.random() < 0.5
    bg = (15, 15, 15) if dark else (255, 255, 255)
    fg = (241, 241, 241) if dark else (15, 15, 15)
    fg2 = (170, 170, 170) if dark else (96, 96, 96)
    d = ImageDraw.Draw(canvas)
    d.rectangle(page, fill=bg)
    # top bar
    d.rectangle([x0, y0, x1, y0 + 56], fill=bg)
    d.rounded_rectangle([x0 + 24, y0 + 18, x0 + 52, y0 + 38], 6, fill=(255, 0, 0))
    d.polygon([(x0 + 34, y0 + 23), (x0 + 34, y0 + 33), (x0 + 44, y0 + 28)], fill=(255, 255, 255))
    text(d, (x0 + 58, y0 + 28), "YouTube", 17, "Bold", fg, anchor="lm")
    sw = min(540, (x1 - x0) // 2)
    d.rounded_rectangle([(x0 + x1) // 2 - sw // 2, y0 + 10, (x0 + x1) // 2 + sw // 2, y0 + 46], 18,
                        fill=T.blend(fg, .08, bg), outline=T.blend(fg, .2, bg))
    text(d, ((x0 + x1) // 2 - sw // 2 + 18, y0 + 28), "Search", 14, "Regular", fg2, anchor="lm")
    d.ellipse([x1 - 56, y0 + 12, x1 - 24, y0 + 44], fill=(90, 120, 200))
    # player
    pw = x1 - x0
    side_w = 400 if pw >= 1000 else 0
    px0, py0 = x0 + 24, y0 + 72
    pl_w = pw - 48 - side_w - (24 if side_w else 0)
    pl_h = round(pl_w * 9 / 16)
    if py0 + pl_h > y1 - 92:              # title + channel block below the player is 88 px
        pl_h = y1 - 92 - py0; pl_w = round(pl_h * 16 / 9)
        if pl_h < 200:
            raise RuntimeError(f"youtube: player height {pl_h} < 200 in page {page}; "
                               f"window below min_size?")
    player = (px0, py0, px0 + pl_w, py0 + pl_h)
    d.rounded_rectangle(player, 12, fill=(0, 0, 0))
    s, ix, iy, ivis = paste_fit(canvas, im, player, align="center")
    occ = []
    if rng.random() < 0.5:                                  # hover controls
        cb = (player[0], player[3] - 40, player[2], player[3])
        d.rectangle(cb, fill=(0, 0, 0))
        d.rectangle([cb[0] + 12, cb[1] + 2, cb[2] - 12, cb[1] + 5], fill=(90, 90, 90))
        d.rectangle([cb[0] + 12, cb[1] + 2, cb[0] + 12 + rng.uniform(.1, .9) * (pl_w - 24), cb[1] + 5],
                    fill=(255, 0, 0))
        icon(d, "play", cb[0] + 24, cb[1] + 22, (255, 255, 255), k=6)
        icon(d, "pause", cb[0] + 54, cb[1] + 22, (255, 255, 255), k=6)
        text(d, (cb[0] + 90, cb[1] + 22), f"{rng.randint(0,9)}:{rng.randint(0,59):02d} / {rng.randint(10,59)}:{rng.randint(0,59):02d}",
             12, "Regular", (220, 220, 220), anchor="lm")
        occ.append(cb)
    # title + channel
    ty = player[3] + 14
    text(d, (px0, ty), rng.choice(["Morning walk through the old town", "Unboxing and first look",
                                   "Weekend vlog — part 3", "Studio session (4K)"]), 18, "Semibold", fg)
    d.ellipse([px0, ty + 34, px0 + 40, ty + 74], fill=(120, 90, 160))
    text(d, (px0 + 52, ty + 40), rng.choice(["Ana Ruiz", "The Field Kit", "Sam & Co"]), 14, "Semibold", fg)
    text(d, (px0 + 52, ty + 58), f"{rng.randint(1,900)}K subscribers", 12, "Regular", fg2)
    if side_w:
        sx = x1 - 24 - side_w
        ry = py0
        while ry + 94 < y1:
            th_rect = (sx, ry, sx + 168, ry + 94)
            if distractors:
                dis = Image.open(rng.choice(distractors)).convert("RGB")
                paste_fit(canvas, dis, th_rect, cover=True)
            else:
                d.rounded_rectangle(th_rect, 8, fill=T.blend(fg, .12, bg))
            lines(d, sx + 180, ry + 4, side_w - 180, 2, 0, rng, fg, 13, gap=4)
            text(d, (sx + 180, ry + 48), f"{rng.randint(2,800)}K views · {rng.randint(1,11)} months ago",
                 12, "Regular", fg2)
            ry += 106
    return s, ix, iy, ivis, occ


# ---- templates -------------------------------------------------------------------
def _browser(kind, page_fn):
    def render(canvas, th, rng, rect, im, distractors):
        page = safari_chrome(canvas, th, rng, rect) if kind == "safari" else \
            chrome_chrome(canvas, th, rng, rect)
        if page_fn == "article":
            s, x, y, vis = page_article(canvas, th, rng, page, im); occ = []
        elif page_fn == "thumbs":
            s, x, y, vis = page_thumbs(canvas, th, rng, page, im, distractors); occ = []
        else:
            s, x, y, vis, occ = page_youtube(canvas, th, rng, page, im, distractors)
        return s, x, y, vis, occ
    render.app = "Safari" if kind == "safari" else "Google Chrome"
    render.min_size = (760, 520)
    return render


safari = _browser("safari", "article")
chrome = _browser("chrome", "article")
browser_thumbs = _browser("safari", "thumbs")
chrome_thumbs = _browser("chrome", "thumbs")
youtube = _browser("chrome", "youtube")
youtube_safari = _browser("safari", "youtube")
