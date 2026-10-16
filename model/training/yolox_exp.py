"""YOLOX-S Exp for the SentryScreen student.

Dataset: COCO layout. YOLOX's COCODataset wants <data_dir>/annotations/<json> +
<data_dir>/<name>/<file_name>; train.py symlinks `annotations/{train,valid}.json` →
`../{train,valid}/_annotations.coco.json`. Category ids 1..18 are classes.CLASSES order
(cat 0 is an optional empty supercategory) → model class index = cat_id − 1 =
classes.CLASS_ID. The Core ML export labels follow the same order
(`export_yolox_coreml.py --labels-from-classes`).

Recipe anchor (taken from NudeNet 640m's own train_args: YOLOv8m COCO-pretrained, imgsz
640, epochs 50, batch 36): input 640 fixed (no
multiscale: the daemon's input is fixed at 640, Detector.swift), max_epoch = --epochs,
warmup 1 epoch at ≤5 epochs else YOLOX's 5, no_aug for the last 15% of epochs (YOLOX default is
15 of 300 = 5%; on a 50-epoch run that is 2–3 epochs — ASSUMED 15% ≈ 7 to give the
non-mosaic distribution time to settle), mosaic + mixup on (YOLOX defaults; the mosaic
quarter-scale tiling is the mechanism NudeNet's Ultralytics recipe also relies on for small
objects), lr = YOLOX basic_lr_per_img × batch.

Geometry contract: the daemon STRETCHES the 1280×720 capture to 640×640 (Vision .scaleFill,
Detector.swift) — objects appear 0.5625× narrower than in a letterboxed view. YOLOX
letterboxes (114-grey pad). `StretchTransform` replaces the pad with a plain stretch to
640×640 and, with p=SQUEEZE_P, additionally crops a central band of height 640·s
(s ∈ [SQUEEZE_MIN, 1]) and stretches it back — exactly what a 16:9 frame looks like after
.scaleFill when s = 0.5625. Boxes follow (cxcywh in pixels). Score a model with the same
stretch so the numbers describe the app's geometry.
"""
from __future__ import annotations
import os, random, sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classes import CLASSES  # noqa: E402

SQUEEZE_P = 0.5       # ASSUMED: half the batch sees 16:9-style anisotropic geometry
SQUEEZE_MIN = 0.5625  # RECEIPT: 720/1280 — the daemon's capture aspect after .scaleFill


def stretch_preproc(img, input_size):
    """Plain stretch to (h, w) — no letterbox. Returns CHW float32 and per-axis scale
    [rx, ry, rx, ry] so cxcywh pixel boxes scale by elementwise multiply."""
    import cv2
    h, w = img.shape[:2]
    out = cv2.resize(img, (input_size[1], input_size[0]), interpolation=cv2.INTER_LINEAR)
    out = np.ascontiguousarray(out.transpose(2, 0, 1), dtype=np.float32)
    return out, np.array([input_size[1] / w, input_size[0] / h] * 2, dtype=np.float64)


def squeeze_band(img_chw, boxes_cxcywh, s):
    """Crop the central horizontal band of height H·s and stretch it back to H (16:9 → square
    geometry). boxes: cxcywh pixels; boxes whose centre leaves the band are dropped."""
    import cv2
    c, H, W = img_chw.shape
    bh = max(32, int(round(H * s)))
    y0 = (H - bh) // 2
    band = img_chw[:, y0:y0 + bh, :].transpose(1, 2, 0)
    out = cv2.resize(band, (W, H), interpolation=cv2.INTER_LINEAR)
    out = np.ascontiguousarray(out.transpose(2, 0, 1), dtype=np.float32)
    if len(boxes_cxcywh) == 0:
        return out, boxes_cxcywh, np.zeros(0, dtype=bool)
    b = boxes_cxcywh.copy()
    b[:, 1] = (b[:, 1] - y0) * (H / bh)
    b[:, 3] = b[:, 3] * (H / bh)
    keep = (b[:, 1] > 0) & (b[:, 1] < H)
    # clip to the canvas
    y1 = np.clip(b[:, 1] - b[:, 3] / 2, 0, H); y2 = np.clip(b[:, 1] + b[:, 3] / 2, 0, H)
    b[:, 1] = (y1 + y2) / 2; b[:, 3] = y2 - y1
    return out, b, keep


class StretchTransform:
    """TrainTransform with stretch instead of letterbox + the 16:9 squeeze. Mirrors
    yolox.data.TrainTransform.__call__ (hsv, flip, min-side>1 filter, max_labels pad)."""

    def __init__(self, max_labels=50, flip_prob=0.5, hsv_prob=1.0,
                 squeeze_p=SQUEEZE_P, squeeze_min=SQUEEZE_MIN):
        self.max_labels, self.flip_prob, self.hsv_prob = max_labels, flip_prob, hsv_prob
        self.squeeze_p, self.squeeze_min = squeeze_p, squeeze_min

    def __call__(self, image, targets, input_dim):
        from yolox.data.data_augment import augment_hsv, _mirror
        from yolox.utils import xyxy2cxcywh
        boxes = targets[:, :4].copy()
        labels = targets[:, 4].copy()
        if len(boxes) == 0:
            image, _ = stretch_preproc(image, input_dim)
            return image, np.zeros((self.max_labels, 5), dtype=np.float32)
        if random.random() < self.hsv_prob:
            augment_hsv(image)
        image_t, boxes = _mirror(image, boxes, self.flip_prob)
        image_t, r = stretch_preproc(image_t, input_dim)
        boxes = xyxy2cxcywh(boxes) * r
        if random.random() < self.squeeze_p:
            s = random.uniform(self.squeeze_min, 1.0)
            image_t, boxes, keep = squeeze_band(image_t, boxes, s)
            boxes, labels = boxes[keep], labels[keep]
        mask = np.minimum(boxes[:, 2], boxes[:, 3]) > 1
        boxes, labels = boxes[mask], labels[mask]
        targets_t = np.hstack((np.expand_dims(labels, 1), boxes)) if len(boxes) else np.zeros((0, 5))
        padded = np.zeros((self.max_labels, 5))
        padded[range(len(targets_t))[: self.max_labels]] = targets_t[: self.max_labels]
        return image_t, np.ascontiguousarray(padded, dtype=np.float32)


def apply_mps_patches():
    """yolox @6ddff48 with torch 2.13: the head builds its anchor grids with
    `tensor.type('torch.mps.FloatTensor')` (legacy type strings — `xin[0].type()`), which torch
    rejects on MPS ("invalid type"); `bboxes_iou` and `IOUloss.forward` do the same. Same math, device/dtype taken
    from the tensor instead. Exact: only the cast changes. CUDA/CPU behaviour is unchanged."""
    import torch
    from yolox.models import yolo_head as yh
    from yolox.utils import boxes as yb, meshgrid

    def get_output_and_grid(self, output, k, stride, dtype):
        grid = self.grids[k]
        batch_size = output.shape[0]
        n_ch = 5 + self.num_classes
        hsize, wsize = output.shape[-2:]
        if grid.shape[2:4] != output.shape[2:4]:
            yv, xv = meshgrid([torch.arange(hsize), torch.arange(wsize)])
            grid = torch.stack((xv, yv), 2).view(1, 1, hsize, wsize, 2).to(output.device, output.dtype)
            self.grids[k] = grid
        output = output.view(batch_size, 1, n_ch, hsize, wsize)
        output = output.permute(0, 1, 3, 4, 2).reshape(batch_size, hsize * wsize, -1)
        grid = grid.view(1, -1, 2)
        output[..., :2] = (output[..., :2] + grid) * stride
        output[..., 2:4] = torch.exp(output[..., 2:4]) * stride
        return output, grid

    def decode_outputs(self, outputs, dtype):
        grids, strides = [], []
        for (hsize, wsize), stride in zip(self.hw, self.strides):
            yv, xv = meshgrid([torch.arange(hsize), torch.arange(wsize)])
            grid = torch.stack((xv, yv), 2).view(1, -1, 2)
            grids.append(grid)
            strides.append(torch.full((*grid.shape[:2], 1), stride))
        grids = torch.cat(grids, dim=1).to(outputs.device, outputs.dtype)
        strides = torch.cat(strides, dim=1).to(outputs.device, outputs.dtype)
        return torch.cat([(outputs[..., 0:2] + grids) * strides,
                          torch.exp(outputs[..., 2:4]) * strides, outputs[..., 4:]], dim=-1)

    def bboxes_iou(bboxes_a, bboxes_b, xyxy=True):
        if bboxes_a.shape[1] != 4 or bboxes_b.shape[1] != 4:
            raise IndexError
        if xyxy:
            tl = torch.max(bboxes_a[:, None, :2], bboxes_b[:, :2])
            br = torch.min(bboxes_a[:, None, 2:], bboxes_b[:, 2:])
            area_a = torch.prod(bboxes_a[:, 2:] - bboxes_a[:, :2], 1)
            area_b = torch.prod(bboxes_b[:, 2:] - bboxes_b[:, :2], 1)
        else:
            tl = torch.max((bboxes_a[:, None, :2] - bboxes_a[:, None, 2:] / 2),
                           (bboxes_b[:, :2] - bboxes_b[:, 2:] / 2))
            br = torch.min((bboxes_a[:, None, :2] + bboxes_a[:, None, 2:] / 2),
                           (bboxes_b[:, :2] + bboxes_b[:, 2:] / 2))
            area_a = torch.prod(bboxes_a[:, 2:], 1)
            area_b = torch.prod(bboxes_b[:, 2:], 1)
        en = (tl < br).to(tl.dtype).prod(dim=2)
        area_i = torch.prod(br - tl, 2) * en
        return area_i / (area_a[:, None] + area_b - area_i)

    def iou_forward(self, pred, target):  # yolox/models/losses.py IOUloss.forward, cast fixed
        assert pred.shape[0] == target.shape[0]
        pred = pred.view(-1, 4); target = target.view(-1, 4)
        tl = torch.max((pred[:, :2] - pred[:, 2:] / 2), (target[:, :2] - target[:, 2:] / 2))
        br = torch.min((pred[:, :2] + pred[:, 2:] / 2), (target[:, :2] + target[:, 2:] / 2))
        area_p = torch.prod(pred[:, 2:], 1); area_g = torch.prod(target[:, 2:], 1)
        en = (tl < br).to(tl.dtype).prod(dim=1)
        area_i = torch.prod(br - tl, 1) * en
        area_u = area_p + area_g - area_i
        iou = area_i / (area_u + 1e-16)
        if self.loss_type == "iou":
            loss = 1 - iou ** 2
        elif self.loss_type == "giou":
            c_tl = torch.min((pred[:, :2] - pred[:, 2:] / 2), (target[:, :2] - target[:, 2:] / 2))
            c_br = torch.max((pred[:, :2] + pred[:, 2:] / 2), (target[:, :2] + target[:, 2:] / 2))
            area_c = torch.prod(c_br - c_tl, 1)
            giou = iou - (area_c - area_u) / area_c.clamp(1e-16)
            loss = 1 - giou.clamp(min=-1.0, max=1.0)
        if self.reduction == "mean":
            loss = loss.mean()
        elif self.reduction == "sum":
            loss = loss.sum()
        return loss

    from yolox.models import losses as yl
    yl.IOUloss.forward = iou_forward
    yh.YOLOXHead.get_output_and_grid = get_output_and_grid
    yh.YOLOXHead.decode_outputs = decode_outputs
    yh.bboxes_iou = bboxes_iou
    yb.bboxes_iou = bboxes_iou


def make_exp(data_dir: Path, epochs: int, subset: int | None, workers: int = 4, input_size: int = 640):
    """input_size: the square the model trains at (train.py --input-size); 640 is the app's
    contract. No multiscale: the app's input is one fixed square."""
    apply_mps_patches()
    from yolox.exp import Exp as BaseExp

    class DistillExp(BaseExp):
        def __init__(self):
            super().__init__()
            self.exp_name = "yolox_s_distill"
            self.depth, self.width = 0.33, 0.50          # yolox_s (exps/default/yolox_s.py)
            self.num_classes = len(CLASSES)               # 18
            self.input_size = self.test_size = (input_size, input_size)
            self.multiscale_range = 0                     # daemon input is one fixed square
            self.data_dir = str(data_dir)
            self.train_ann, self.val_ann = "train.json", "valid.json"
            self.data_num_workers = workers
            self.max_epoch = epochs
            self.warmup_epochs = 1 if epochs <= 5 else 5
            self.no_aug_epochs = max(1, round(0.15 * epochs)) if epochs > 1 else 0
            self.eval_interval = 10 ** 6                  # COCO eval is not the receipt here
            self.print_interval = 20

        def get_dataset(self, cache=False, cache_type="ram"):
            from yolox.data import COCODataset
            ds = COCODataset(data_dir=self.data_dir, json_file=self.train_ann, name="train",
                             img_size=self.input_size, preproc=StretchTransform(max_labels=50),
                             cache=False)
            # cat 0 is the empty supercategory → drop it so index = cat_id − 1 = CLASS_ID
            ds.class_ids = [c for c in ds.class_ids if c != 0]
            assert ds.class_ids == list(range(1, len(CLASSES) + 1)), ds.class_ids
            ds.annotations = ds._load_coco_annotations()
            if subset:
                ds.ids = ds.ids[:subset]
                ds.annotations = ds.annotations[:subset]
                ds.num_imgs = len(ds.ids)   # __len__ reads num_imgs, not len(ids)
            return ds

        def get_data_loader(self, batch_size, is_distributed, no_aug=False, cache_img=None):
            from yolox.data import (MosaicDetection, YoloBatchSampler, DataLoader,
                                    InfiniteSampler, worker_init_reset_seed)
            self.dataset = MosaicDetection(
                dataset=self.get_dataset(), mosaic=not no_aug, img_size=self.input_size,
                preproc=StretchTransform(max_labels=120), degrees=self.degrees,
                translate=self.translate, mosaic_scale=self.mosaic_scale,
                mixup_scale=self.mixup_scale, shear=self.shear, enable_mixup=self.enable_mixup,
                mosaic_prob=self.mosaic_prob, mixup_prob=self.mixup_prob)
            sampler = InfiniteSampler(len(self.dataset), seed=self.seed if self.seed else 0)
            batch_sampler = YoloBatchSampler(sampler=sampler, batch_size=batch_size,
                                             drop_last=False, mosaic=not no_aug)
            return DataLoader(self.dataset, num_workers=self.data_num_workers,
                              pin_memory=False, batch_sampler=batch_sampler,
                              worker_init_fn=worker_init_reset_seed)

    return DistillExp()
