#!/usr/bin/env python3
"""Pseudo-label a directory of images with a teacher detector and write COCO json.

The shipped student was trained on labels produced this way, with NudeNet v3.4's 640m
detector as the teacher. NudeNet is AGPL-3.0 and is not included: install it with
`pip install nudenet==3.4.2` and, for the 640m model, download `640m.onnx` from the
NudeNet v3.4 release yourself. Without --teacher, NudeNet's bundled 320n model is used.

A detection is kept when its score reaches the class floor in classes.CONF_FLOOR.
Images with no kept detection stay in the file as background examples.

    python pseudo_label.py --images data/train [--teacher 640m.onnx]
    # writes data/train/_annotations.coco.json
"""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classes import CLASSES, floor_of  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def categories():
    """COCO categories: id = classes.CLASSES index + 1 (yolox_exp.py relies on this)."""
    return [{"id": i + 1, "name": c, "supercategory": "nudity"} for i, c in enumerate(CLASSES)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", type=Path, required=True)
    ap.add_argument("--teacher", type=Path, help="NudeNet .onnx (for example 640m.onnx); default: bundled 320n")
    ap.add_argument("--resolution", type=int, default=None, help="teacher input size; default 640 with --teacher")
    ap.add_argument("--out", type=Path, help="default: <images>/_annotations.coco.json")
    args = ap.parse_args()

    from nudenet import NudeDetector
    from PIL import Image
    if args.teacher:
        det = NudeDetector(model_path=str(args.teacher), inference_resolution=args.resolution or 640)
    else:
        det = NudeDetector()
    cat_id = {c: i + 1 for i, c in enumerate(CLASSES)}

    paths = sorted(p for p in args.images.iterdir() if p.suffix.lower() in IMAGE_EXTS)
    images, annotations = [], []
    for n, p in enumerate(paths, 1):
        with Image.open(p) as im:
            w, h = im.size
        images.append({"id": n, "file_name": p.name, "width": w, "height": h})
        for d in det.detect(str(p)):
            cls, score = d["class"], float(d["score"])
            if cls not in cat_id or score < floor_of(cls):
                continue
            x, y, bw, bh = (float(v) for v in d["box"])
            annotations.append({"id": len(annotations) + 1, "image_id": n, "category_id": cat_id[cls],
                                "bbox": [x, y, bw, bh], "area": bw * bh, "iscrowd": 0, "score": score})
        if n % 500 == 0:
            print(f"pseudo_label: {n}/{len(paths)} images, {len(annotations)} boxes", flush=True)
    out = args.out or args.images / "_annotations.coco.json"
    out.write_text(json.dumps({"images": images, "annotations": annotations, "categories": categories()}))
    print(json.dumps({"images": len(images), "boxes": len(annotations), "out": str(out)}))


if __name__ == "__main__":
    main()
