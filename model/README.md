# SentryScreen detector: model card

The app's detector is one Core ML file:
`weights/yolox_50ep_v8_ep50_fp16.mlpackage` (3 files, 18,307,879 bytes). Its identity
(file hashes, measured with 0644/0755 modes) is in `packaging/release-model.manifest`,
and `packaging/build-pkg.sh` checks it on every package build.

## What it is

- **Architecture:** YOLOX-S (Megvii, Apache-2.0), CSPDarknet backbone, 640×640 input,
  trained from YOLOX's COCO-pretrained `yolox_s.pth`.
- **Precision:** fp16 weights, Core ML ML Program with an embedded NonMaximumSuppression
  stage. Runs on the Neural Engine when available (about 10 ms per frame on an M1), and
  on the CPU otherwise.
- **Training run:** 50 epochs, batch 36, input 640, epoch 50 checkpoint (`v8`).

## Input and output contract

`daemon/Sources/SentryScreen/Detector.swift` loads the package through Vision
(`VNCoreMLModel`, `VNRecognizedObjectObservation`):

- **Input:** `image`, 640×640 BGR. Vision stretches the captured frame to the square
  (`.scaleFill`, no letterbox); training uses the same stretch.
- **Optional inputs:** `iouThreshold` (default 0.45), `confidenceThreshold` (default 0.25).
- **Outputs:** `confidence` [N, 32] and `coordinates` [N, 4] (normalized center x,
  center y, width, height), with string class labels. The class axis holds the 18 labels
  below, then 14 `_pad_<i>` columns that always score 0 (padding for Core ML's NMS stage).

Any model that keeps this contract and these label strings can replace it: pass
`--model <path>.mlpackage` to a development run, or set `model` in `config.json`.

## Labels

18 classes, the NudeNet v3 label set. The app acts on the first eight; the rest are
context classes that teach the detector what not to confuse with them.

| # | Label | App action |
|---|---|---|
| 1 | FEMALE_BREAST_EXPOSED | cover |
| 2 | FEMALE_GENITALIA_EXPOSED | cover |
| 3 | MALE_GENITALIA_EXPOSED | cover |
| 4 | BUTTOCKS_EXPOSED | cover |
| 5 | ANUS_EXPOSED | cover |
| 6 | FEMALE_BREAST_COVERED | cover (stricter threshold) |
| 7 | FEMALE_GENITALIA_COVERED | cover (stricter threshold) |
| 8 | BUTTOCKS_COVERED | cover (stricter threshold) |
| 9–18 | FACE_FEMALE, FACE_MALE, FEET_EXPOSED, FEET_COVERED, ARMPITS_EXPOSED, ARMPITS_COVERED, BELLY_EXPOSED, BELLY_COVERED, MALE_BREAST_EXPOSED, ANUS_COVERED | none |

Per-class thresholds and size floors are app settings, not part of the model
(`TuningPolicy.swift`, README "Tuning tools").

## How it was trained

1. Photos were pseudo-labeled by a teacher, NudeNet v3.4's 640m detector (AGPL-3.0),
   keeping detections at or above 0.5 (0.6 for the covered classes).
2. Each labeled photo was pasted into drawn macOS screen templates (browsers, Finder,
   Preview, Quick Look, Photos, Messages, Slack, QuickTime, YouTube; light and dark) with
   its boxes transformed exactly, so the detector learns content at screen scale.
3. YOLOX-S was trained on the composites with mosaic and mixup, then a final 15% of
   epochs without them, using the same stretch geometry the app applies.

**The training dataset is not published,** and neither are the sources it was
collected from. The training and export code is in `training/`.

## License

The weights are licensed under **AGPL-3.0** (root `LICENSE`). They were trained with
pseudo-labels from NudeNet (AGPL-3.0). The YOLOX code and COCO base weights are
Apache-2.0 (`packaging/THIRD-PARTY.txt`). NudeNet weights are not included here.

## Known limitations

- **Misses happen.** The app is a filter, not a guarantee. Small, partly visible,
  unusual, stylized, drawn or AI-generated content can go undetected, and content can
  show for a fraction of a second before a cover appears.
- **False positives happen,** most often on skin-heavy but harmless images (swimwear,
  sports, babies, close-ups). A false positive costs one cover that clears on its own.
- Labels come from another model, so the student inherits its teacher's blind spots.
- It detects nudity only: not violence, gore or text.
- Protected (DRM) video is captured as black frames and is not analyzed.

## Retrain or export

Requirements: an Apple Silicon Mac (MPS) or plenty of CPU time, Python 3.12, and your
own images.

```bash
cd model/training
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
git clone https://github.com/Megvii-BaseDetection/YOLOX third_party/YOLOX
git -C third_party/YOLOX checkout 6ddff4824372906469a7fae2dc3206c7aa4bbaee
# COCO base weights (sha256 f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30):
curl -A "" -L -o yolox_s.pth https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_s.pth

# 1. Pseudo-label (optional teacher; NudeNet is AGPL-3.0 and downloaded by you)
.venv/bin/pip install nudenet==3.4.2
.venv/bin/python pseudo_label.py --images data/train --teacher 640m.onnx
.venv/bin/python pseudo_label.py --images data/valid --teacher 640m.onnx

# 2. Composite into screen templates (--negatives: images with nothing to label)
.venv/bin/python compose.py --coco data/train/_annotations.coco.json --images data/train \
    --negatives data/negatives --out dataset/train
.venv/bin/python compose.py --coco data/valid/_annotations.coco.json --images data/valid \
    --out dataset/valid

# 3. Train (the shipped recipe)
.venv/bin/python train.py --yolox-repo third_party/YOLOX --pretrain yolox_s.pth \
    --dataset dataset --epochs 50 --out runs/my_run
# Quick check of the whole chain first: --epochs 2 --batch 8 --subset 48 (seconds on an M-series GPU)

# 4. Export to Core ML
.venv/bin/python export_yolox_coreml.py --yolox-repo third_party/YOLOX --exp yolox_s \
    --ckpt runs/my_run/last.pth --labels-from-classes --fp16 --out my_model_fp16
.venv/bin/python export_yolox_coreml.py --bench my_model_fp16.mlpackage   # latency
```

Already-labeled data works too: any COCO file whose category names are the 18 labels
above can go straight to `compose.py`, or into `dataset/train/` for `train.py`
(category id = row number in the table).

To package a retrained model, point `SENTRY_MODEL_PATH` at it (and optionally set
`SENTRY_MODEL_FILE` to its installed name); `packaging/build-pkg.sh` then writes a
fresh identity manifest for it instead of checking the committed one.

`compose.py --preview /tmp/templates` renders every template with a drawn stand-in, so
you can inspect the templates without any real content.
