#!/usr/bin/env python3
"""Paste labeled photos into drawn macOS screen templates; labels move with the paste.

The app sees photos inside browsers, Finder, Preview, chat apps and video players, at
screen scale. Training on those composites is what lets a small detector work on screen
captures. Templates are compose_templates/macos/ (menu bar, Dock, Finder, Safari/Chrome,
Preview, Quick Look, Photos, Messages, Slack, QuickTime, YouTube; light and dark), drawn
with PIL primitives and the system font. Nothing is rendered to a display.

Input:  a COCO json (pseudo_label.py output) and its image directory; optionally a
        directory of negative images (no labeled content) used as surrounding thumbnails.
Output: <out>/<sha256>.jpg composites and <out>/_annotations.coco.json.
Each base gets VARIANTS distinct templates. Label transform: paste at scale s offset
(dx,dy) → box (x·s+dx, y·s+dy, w·s, h·s), clipped to the visible region minus occluders;
a box with less than MIN_BOX_VISIBLE of its area visible is dropped (and counted).

    python compose.py --coco data/train/_annotations.coco.json --images data/train \
        [--negatives data/negatives] --out dataset/train
    python compose.py --preview /tmp/templates     # every template with a drawn stand-in
"""
from __future__ import annotations
import argparse, hashlib, io, json, random, sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classes import CLASSES  # noqa: E402
from compose_templates import macos  # noqa: E402
from pseudo_label import categories  # noqa: E402

CANVAS = macos.CANVAS   # (1280, 800): a retina display downscaled to ~1280 wide, like the capture
VARIANTS = 5
JPEG_QUALITY = 90
MIN_BOX_VISIBLE = 0.4   # a box less than 40% visible teaches truncation noise, not detection
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def transform_boxes(boxes, s, dx, dy, visible_rect, occluders=()):
    """Exact label transform + visibility clip. Returns (kept, dropped_count)."""
    vx0, vy0, vx1, vy1 = visible_rect
    kept, dropped = [], 0
    for b in boxes:
        x, y, w, h = b["box"]
        nx, ny, nw, nh = x * s + dx, y * s + dy, w * s, h * s
        cx0, cy0 = max(nx, vx0), max(ny, vy0)
        cx1, cy1 = min(nx + nw, vx1), min(ny + nh, vy1)
        vis = max(0, cx1 - cx0) * max(0, cy1 - cy0)
        for ox0, oy0, ox1, oy1 in occluders:
            ix0, iy0 = max(cx0, ox0), max(cy0, oy0)
            ix1, iy1 = min(cx1, ox1), min(cy1, oy1)
            vis -= max(0, ix1 - ix0) * max(0, iy1 - iy0)
        if nw * nh <= 0 or vis / (nw * nh) < MIN_BOX_VISIBLE:
            dropped += 1
            continue
        kept.append({**b, "box": [round(cx0), round(cy0), round(cx1 - cx0), round(cy1 - cy0)]})
    return kept, dropped


def synth_base(rng, w, h):
    """Drawn stand-in with two fake label boxes, for template previews without content."""
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        d.line([0, y, w, y], fill=(200 - y * 60 // h, 150 + y * 40 // h, 120))
    bx, by, bw, bh = w * 0.25, h * 0.2, w * 0.5, h * 0.6
    d.rounded_rectangle([bx, by, bx + bw, by + bh], 40, fill=(230, 190, 170), outline=(120, 60, 40), width=6)
    boxes = [{"cls": "FEMALE_BREAST_EXPOSED", "box": [bx, by, bw / 2, bh / 2]},
             {"cls": "BUTTOCKS_EXPOSED", "box": [bx + bw / 2, by + bh / 2, bw / 2, bh / 2]}]
    return im, boxes


def preview(out: Path, per_template: int):
    out.mkdir(parents=True, exist_ok=True)
    sizes = [(1200, 800), (800, 1200), (1000, 1000), (1600, 900)]
    neg, _ = synth_base(random.Random(1), 900, 600)
    negp = out / "_neg.jpg"
    neg.point(lambda v: 255 - v).save(negp)
    for name in macos.NAMES:
        for k in range(per_template):
            rng = random.Random(f"{name}{k}")
            im, boxes = synth_base(rng, *sizes[k % len(sizes)])
            pl = macos.render(name, rng, im, [negp])
            kept, _ = transform_boxes(boxes, pl.s, pl.x, pl.y, pl.visible, pl.occluders)
            d = ImageDraw.Draw(pl.canvas)
            for b in kept:
                x, y, w, h = b["box"]
                d.rectangle([x, y, x + w, y + h], outline=(255, 0, 0), width=2)
            pl.canvas.save(out / f"{name}_{k}_{pl.theme}_{pl.scene}.png")
    print(f"preview: {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--coco", type=Path, help="COCO json with the base images' labels")
    ap.add_argument("--images", type=Path, help="directory the COCO file_names are relative to")
    ap.add_argument("--negatives", type=Path, help="optional directory of images with no labeled content")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--variants", type=int, default=VARIANTS)
    ap.add_argument("--preview", type=Path, metavar="DIR", help="render every template with a drawn stand-in")
    ap.add_argument("--preview-n", type=int, default=2)
    args = ap.parse_args()
    if args.preview:
        preview(args.preview, args.preview_n)
        return
    if not (args.coco and args.images and args.out):
        ap.error("--coco, --images and --out are required")

    coco = json.loads(args.coco.read_text())
    cat_name = {c["id"]: c["name"] for c in coco["categories"]}
    boxes_by_image = {}
    for a in coco["annotations"]:
        boxes_by_image.setdefault(a["image_id"], []).append({"cls": cat_name[a["category_id"]], "box": a["bbox"]})
    distractors = sorted(p for p in (args.negatives.iterdir() if args.negatives else [])
                         if p.suffix.lower() in IMAGE_EXTS)
    cat_id = {c: i + 1 for i, c in enumerate(CLASSES)}

    args.out.mkdir(parents=True, exist_ok=True)
    images, annotations, seen = [], [], set()
    dropped_total = 0
    for img in coco["images"]:
        im = Image.open(args.images / img["file_name"]).convert("RGB")
        boxes = boxes_by_image.get(img["id"], [])
        rng = random.Random(img["file_name"])
        for name, _, _ in macos.pick(rng, args.variants):
            pl = macos.render(name, rng, im, distractors)
            kept, dropped = transform_boxes(boxes, pl.s, pl.x, pl.y, pl.visible, pl.occluders)
            dropped_total += dropped
            buf = io.BytesIO()
            pl.canvas.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
            data = buf.getvalue()
            cid = hashlib.sha256(data).hexdigest()
            if cid in seen:
                continue
            seen.add(cid)
            (args.out / f"{cid}.jpg").write_bytes(data)
            image_id = len(images) + 1
            images.append({"id": image_id, "file_name": f"{cid}.jpg", "width": CANVAS[0], "height": CANVAS[1]})
            for b in kept:
                annotations.append({"id": len(annotations) + 1, "image_id": image_id,
                                    "category_id": cat_id[b["cls"]], "bbox": b["box"],
                                    "area": b["box"][2] * b["box"][3], "iscrowd": 0})
    out_json = args.out / "_annotations.coco.json"
    out_json.write_text(json.dumps({"images": images, "annotations": annotations, "categories": categories()}))
    print(json.dumps({"bases": len(coco["images"]), "composites": len(images), "boxes": len(annotations),
                      "boxes_dropped": dropped_total, "out": str(out_json)}))


if __name__ == "__main__":
    main()
