"""macOS composite template pack used by compose.py.

POOL is the template pool with sampling weights; compose.py draws VARIANTS templates per
base image without replacement (weighted). The weights are an assumed usage mix: browsers
dominate, and large single-image surfaces are weighted up because small paste scales hurt
recall.
"""
from __future__ import annotations
from . import browsers, finder, media, chat, scenes, theme

POOL = [  # (name, renderer, weight)
    ("safari", browsers.safari, 0.14),
    ("chrome", browsers.chrome, 0.12),
    ("preview", finder.preview, 0.10),
    ("quicklook", finder.quicklook, 0.08),
    ("photos_detail", media.photos_detail, 0.07),
    ("youtube", browsers.youtube, 0.06),
    ("youtube_safari", browsers.youtube_safari, 0.03),
    ("messages", chat.messages, 0.08),
    ("quicktime", media.quicktime, 0.06),
    ("finder_gallery", finder.finder_gallery, 0.06),
    ("photos_grid", media.photos_grid, 0.05),
    ("browser_thumbs", browsers.browser_thumbs, 0.04),
    ("chrome_thumbs", browsers.chrome_thumbs, 0.03),
    ("slack", chat.slack, 0.04),
    ("finder_icons", finder.finder_icons, 0.04),
]
assert abs(sum(w for _, _, w in POOL) - 1.0) < 1e-9, "POOL weights must sum to 1"
NAMES = [n for n, _, _ in POOL]
DARK_P = 0.35      # ASSUMED share of dark-mode desktops
CANVAS = (1280, 800)


def pick(rng, k):
    """k distinct templates, weighted without replacement (deterministic under rng)."""
    pool, out = list(POOL), []
    for _ in range(min(k, len(pool))):
        i = rng.choices(range(len(pool)), weights=[w for _, _, w in pool])[0]
        out.append(pool.pop(i))
    return out


def render(name, rng, im, distractors, size=CANVAS, scene=None, th=None):
    """scene / th override the random picks (tests iterate template × scene × theme)."""
    fn = dict((n, f) for n, f, _ in POOL)[name]
    th = th or (theme.DARK if rng.random() < DARK_P else theme.LIGHT)
    pl = scenes.render(fn, rng, im, th, distractors, size, scene=scene)
    pl.theme = th.name
    return pl
