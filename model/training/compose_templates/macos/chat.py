"""Messages.app and Slack. Image attachments render at their real on-screen sizes:
Messages ≈ 45-60% of the thread width, Slack previews ≤ 360 px wide (MEASURED)."""
from __future__ import annotations
from PIL import ImageDraw

from . import theme as T
from .chrome import icon, paste_fit, text, text_w, window, search_field

NAMES = ["Alex", "Jordan", "Sam", "Priya", "Chris", "Maya", "Taylor", "Noor", "Dev", "Robin"]
LINES = ["Sounds good, see you at 7", "Can you send the other one?", "haha yes", "On my way",
         "Look at this one", "That's the spot from last summer", "ok!!", "Which do you like better?",
         "Just got home", "Sending now", "lol", "Did you see this?"]
AVATAR_COLORS = [(255, 149, 0), (88, 86, 214), (52, 199, 89), (255, 45, 85), (90, 200, 250), (175, 82, 222)]


def messages(canvas, th, rng, rect, im, distractors):
    x0, y0, x1, y1 = rect
    body = window(canvas, th, rect, bar_h=T.TOOLBAR_H)
    d = ImageDraw.Draw(canvas)
    sbw = 280
    sb = (body[0], body[1], body[0] + sbw, body[3])
    d.rectangle(sb, fill=th.sidebar)
    d.line([sb[2], y0, sb[2], y1], fill=th.sep)
    search_field(d, th, (sb[0] + 86, y0 + 13, sb[2] - 12, y0 + 39))   # right of the traffic lights
    sel = rng.randrange(3)
    for i in range(min(9, (y1 - body[1]) // 66)):
        ry = body[1] + 8 + i * 66
        if i == sel:
            d.rounded_rectangle([sb[0] + 8, ry, sb[2] - 8, ry + 60], 8, fill=th.accent)
        col = AVATAR_COLORS[i % len(AVATAR_COLORS)]
        d.ellipse([sb[0] + 20, ry + 12, sb[0] + 56, ry + 48], fill=col)
        fg = (255, 255, 255) if i == sel else th.text
        fg2 = (230, 230, 240) if i == sel else th.text2
        text(d, (sb[0] + 68, ry + 12), NAMES[(i * 3 + rng.randint(0, 2)) % len(NAMES)], 13, "Semibold", fg)
        text(d, (sb[2] - 20, ry + 13), rng.choice(["9:41 AM", "Yesterday", "Mon", "Sun"]), 11, "Regular", fg2, anchor="ra")
        text(d, (sb[0] + 68, ry + 32), rng.choice(LINES)[:30], 12, "Regular", fg2)
    # thread header
    tx0, tx1 = sb[2] + 1, body[2]
    text(d, ((tx0 + tx1) // 2, y0 + T.TOOLBAR_H // 2 - 6), "To: " + rng.choice(NAMES), 13, "Semibold", th.text, anchor="mm")
    text(d, ((tx0 + tx1) // 2, y0 + T.TOOLBAR_H // 2 + 10), "iMessage", 10, "Regular", th.text2, anchor="mm")
    d.rectangle([tx0, body[1], tx1, body[3]], fill=th.page_bg if th is T.LIGHT else th.window_bg)
    # composer
    cy = body[3] - 44
    d.rounded_rectangle([tx0 + 44, cy, tx1 - 16, cy + 30], 15, fill=th.field, outline=th.sep)
    text(d, (tx0 + 60, cy + 15), "iMessage", 13, "Regular", th.text2, anchor="lm")
    d.ellipse([tx0 + 12, cy + 2, tx0 + 38, cy + 28], fill=th.sidebar_sel)
    # bubbles bottom-up: image bubble sits somewhere in the last few messages
    y = cy - 16
    n_after = rng.randint(0, 3)
    tw = tx1 - tx0
    def bubble(y, sent, t):
        bw = text_w(t, 14) + 28
        bx1 = tx1 - 16 if sent else tx0 + 16 + bw
        d.rounded_rectangle([bx1 - bw, y - 34, bx1, y], 17, fill=th.accent if sent else th.bubble_in)
        text(d, (bx1 - bw + 14, y - 17), t, 14, "Regular", (255, 255, 255) if sent else th.text, anchor="lm")
        return y - 40
    for _ in range(n_after):
        y = bubble(y, rng.random() < .5, rng.choice(LINES))
    sent = rng.random() < 0.5
    iw = round(tw * rng.uniform(0.45, 0.6))
    ih = min(round(iw * im.height / im.width), body[3] - body[1] - 120)
    iw = round(ih * im.width / im.height)
    ix = tx1 - 16 - iw if sent else tx0 + 16
    irect = (ix, y - ih, ix + iw, y)
    s, px, py, vis = paste_fit(canvas, im, irect, cover=True, mask_radius=17)
    y = irect[1] - 8
    while y > body[1] + 60:
        y = bubble(y, rng.random() < .5, rng.choice(LINES))
    return s, px, py, vis, []


def slack(canvas, th, rng, rect, im, distractors):
    x0, y0, x1, y1 = rect
    aub = (74, 21, 75)
    body = window(canvas, th, rect, bar_h=38, bar_color=(53, 13, 54))
    d = ImageDraw.Draw(canvas)
    sw = min(560, (x1 - x0) // 2)
    d.rounded_rectangle([(x0 + x1) // 2 - sw // 2, y0 + 7, (x0 + x1) // 2 + sw // 2, y0 + 31], 6, fill=(96, 44, 97))
    text(d, ((x0 + x1) // 2, y0 + 19), "Search " + rng.choice(["Acme", "Studio", "Team"]), 12, "Regular", (220, 200, 220), anchor="mm")
    rail = (body[0], body[1], body[0] + 64, body[3])
    d.rectangle(rail, fill=(53, 13, 54))
    for i, g in enumerate(["home", "clock", "at", "more_h"]):
        if g == "at":
            text(d, (rail[0] + 32, rail[1] + 30 + i * 52), "@", 18, "Regular", (230, 210, 230), anchor="mm")
        else:
            icon(d, g, rail[0] + 32, rail[1] + 30 + i * 52, (230, 210, 230), k=8)
    sb = (rail[2], body[1], rail[2] + 220, body[3])
    d.rectangle(sb, fill=aub)
    text(d, (sb[0] + 16, sb[1] + 18), rng.choice(["Acme", "Studio", "Team"]) + " ▾", 15, "Bold", (255, 255, 255))
    yy = sb[1] + 56
    text(d, (sb[0] + 16, yy), "Channels", 13, "Regular", (200, 180, 200)); yy += 26
    chans = ["general", "random", "design", "photos", "dev", "watercooler", "announcements"]
    sel = rng.randrange(4)
    for i, c in enumerate(chans):
        if i == sel:
            d.rectangle([sb[0], yy - 4, sb[2], yy + 18], fill=(18, 100, 163))
        text(d, (sb[0] + 20, yy), "# " + c, 14, "Regular", (255, 255, 255) if i == sel else (200, 180, 200)); yy += 26
    yy += 12
    text(d, (sb[0] + 16, yy), "Direct messages", 13, "Regular", (200, 180, 200)); yy += 26
    for n in NAMES[:5]:
        if yy > sb[3] - 20:
            break
        d.ellipse([sb[0] + 20, yy + 3, sb[0] + 32, yy + 15], fill=(60, 200, 100))
        text(d, (sb[0] + 40, yy), n, 14, "Regular", (200, 180, 200)); yy += 26
    # main pane
    mx0, mx1 = sb[2] + 1, body[2]
    d.rectangle([mx0, body[1], mx1, body[3]], fill=th.page_bg if th is T.LIGHT else (26, 29, 33))
    fg, fg2 = (29, 28, 29) if th is T.LIGHT else (209, 210, 211), (97, 96, 97) if th is T.LIGHT else (171, 171, 173)
    text(d, (mx0 + 20, body[1] + 14), "# " + chans[sel], 16, "Bold", fg)
    d.line([mx0, body[1] + 48, mx1, body[1] + 48], fill=th.sep)
    # composer
    d.rounded_rectangle([mx0 + 20, body[3] - 70, mx1 - 20, body[3] - 20], 8, fill=th.field, outline=th.sep)
    text(d, (mx0 + 36, body[3] - 45), f"Message #{chans[sel]}", 14, "Regular", fg2, anchor="lm")
    # messages, top-down; image message somewhere in the middle
    y = body[1] + 64
    img_at = rng.randint(0, 2)
    i = 0
    result = None
    while y < body[3] - 90:
        col = AVATAR_COLORS[i % len(AVATAR_COLORS)]
        d.rounded_rectangle([mx0 + 20, y, mx0 + 56, y + 36], 6, fill=col)
        text(d, (mx0 + 68, y), rng.choice(NAMES), 15, "Bold", fg)
        text(d, (mx0 + 68 + 60, y + 2), f"{rng.randint(1,12)}:{rng.randint(0,59):02d} {rng.choice(['AM','PM'])}", 11, "Regular", fg2)
        text(d, (mx0 + 68, y + 20), rng.choice(LINES), 15, "Regular", fg)
        y += 44
        if i == img_at and result is None:
            iw = min(360, mx1 - mx0 - 120)                       # MEASURED Slack preview cap
            ih = min(round(iw * im.height / im.width), body[3] - 100 - y)
            iw = round(ih * im.width / im.height)                 # keep aspect (never crop)
            irect = (mx0 + 68, y, mx0 + 68 + iw, y + ih)
            if irect[3] > body[3] - 74 or irect[2] > mx1 - 20:   # loud, never clipped
                raise RuntimeError(f"slack: attachment {irect} exceeds pane (composer top "
                                   f"{body[3] - 74}, right edge {mx1 - 20}); window {rect}")
            s, px, py, vis = paste_fit(canvas, im, irect, cover=True, mask_radius=8)
            result = (s, px, py, vis)
            y += ih + 12
        i += 1
    if result is None:
        raise RuntimeError("slack: image message not placed")
    return (*result, [])


messages.app, messages.min_size = "Messages", (760, 500)
# DERIVED: 64 rail + 220 sidebar + 480 pane (360 px preview cap + 120 margins) = 764;
# 780 keeps a 4 px divider + ≥380 px neighbour tile inside the 1280 Split View canvas.
slack.app, slack.min_size = "Slack", (780, 560)
