#!/usr/bin/env python3
"""Export a YOLOX checkpoint (from train.py) to the Core ML package the app loads.

The app reads the model through Vision (`VNCoreMLModel`, `.scaleFill`,
`VNRecognizedObjectObservation`), so the package needs an image input and an
embedded NonMaximumSuppression stage with outputs `confidence` [N,C] and
`coordinates` [N,4] (normalized xywh) and string class labels. Pipeline:
  1. detector  ML Program: BGR image (0-255, no mean/std) -> head decode ->
               `raw_coordinates` [A,4] + `raw_confidence` [A,C]
  2. nms       Core ML NonMaximumSuppression (IOU_DEFAULT / CONF_DEFAULT)
  3. pipeline  image in; `confidence` / `coordinates` out.
Vision stretches the frame to the declared square (.scaleFill), which is the
geometry yolox_exp.py trains with.

The shipped model was exported with:
    python export_yolox_coreml.py --yolox-repo third_party/YOLOX --exp yolox_s \
        --ckpt runs/<run>/last.pth --labels-from-classes --fp16 --out <name>_fp16

Time a package on this Mac with `--bench <package>.mlpackage`.
"""
from __future__ import annotations
import argparse, json, sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classes import NUDENET_LABELS, CLASSES  # noqa: E402  the 18 strings (a set; orders below)

# NudeNet's index order, used only for the 80-class COCO plumbing check. The app matches
# labels by string; trained students use classes.CLASSES (--labels-from-classes).
NUDENET_ORDER = [
    "FEMALE_GENITALIA_COVERED", "FACE_FEMALE", "BUTTOCKS_EXPOSED", "FEMALE_BREAST_EXPOSED",
    "FEMALE_GENITALIA_EXPOSED", "MALE_BREAST_EXPOSED", "ANUS_EXPOSED", "FEET_EXPOSED",
    "BELLY_COVERED", "FEET_COVERED", "ARMPITS_COVERED", "ARMPITS_EXPOSED", "FACE_MALE",
    "BELLY_EXPOSED", "MALE_GENITALIA_EXPOSED", "ANUS_COVERED", "FEMALE_BREAST_COVERED",
    "BUTTOCKS_COVERED"]
assert set(NUDENET_ORDER) == NUDENET_LABELS and len(NUDENET_ORDER) == 18

RES = 640            # default input square; a train.py checkpoint carries its own (--input-size)
                     # and --res overrides both. Vision stretches the capture to the declared square.
IOU_DEFAULT = 0.45   # common YOLO export defaults
CONF_DEFAULT = 0.25  # = main.swift Options.conf floor; Policy thresholds sit above it
CONF_PAD = 32        # class-axis padding for the NMS join, receipt in Decoded.forward


class Decoded(torch.nn.Module):
    """YOLOX eval forward (decode_in_inference=True) → normalized cxcywh + obj·cls scores."""

    def __init__(self, net, res: int):
        super().__init__()
        self.net, self.res = net, float(res)

    def forward(self, image):
        out = self.net(image)                    # [1, A, 5+C], boxes in pixels, obj/cls sigmoided
        # CoreML NonMaximumSuppression takes rank-2 [A,4] / [A,C] (a leading batch dim is
        # read as the class axis: "Dimension 1 of input confidence (8400) is not consistent
        # with the number of classes" — MEASURED 2026-08-27), so the batch dim is squeezed.
        boxes = (out[..., 0:4] / self.res)[0]    # [A, 4] cx, cy, w, h normalized to the input square
        conf = (out[..., 4:5] * out[..., 5:])[0] # [A, C] objectness × class prob
        # CONFIDENCE FIRST, coordinates second — the order 640m.mlpackage (Ultralytics) uses.
        # MEASURED 2026-08-27 (parity_yolox.py, 89 eval images): with (boxes, conf) order the
        # pipeline's NMS paired every confidence row with the box of a DIFFERENT anchor
        # (row i -> ~1.78 i) although detector-alone and NMS-alone were both exact — the
        # pipeline glue binds the ML Program's outputs to the NMS by POSITION, not name.
        # PAD the class axis to CONF_PAD columns (zeros). MEASURED 2026-08-27 (parity_yolox.py):
        # with 18 classes the pipeline's NMS read the confidence matrix with a row stride of
        # 32 floats, not 18 (row i of the NMS = true row 32i/18: anchors 351->624, 4200->7467),
        # i.e. the runtime hands the mlprogram output over with rows padded to a 128-byte
        # boundary and NonMaximumSuppression assumes a contiguous [A,C]. 640m never hit it:
        # 80 classes x 4 B = 320 B, already a multiple of 64. Detector-alone and NMS-alone were
        # exact; only the joined pipeline misaligned. 32 x 4 B = 128 B. The pad columns get
        # dummy labels and a 0 score, so they can never win top-1 in Vision.
        if conf.shape[1] < CONF_PAD:
            conf = torch.cat([conf, torch.zeros(conf.shape[0], CONF_PAD - conf.shape[1])], dim=1)
        return conf, boxes


def _focus_unshuffle(self, x):
    """Focus (4 strided slices + concat) as pixel_unshuffle + channel gather — exact, but the
    compute plan puts pixel_unshuffle/gather on the CPU (MEASURED 2026-08-27, no gain);
    kept behind --focus-unshuffle for the record. The slices themselves run on the ANE."""
    import torch.nn.functional as F
    c = x.shape[1]
    y = F.pixel_unshuffle(x, 2)              # channel = ch*4 + (dy*2 + dx)
    idx = [ch * 4 + dy * 2 + dx for (dy, dx) in ((0, 0), (1, 0), (0, 1), (1, 1)) for ch in range(c)]
    y = y[:, idx]
    return self.conv(y)


def _spp_cascade(self, x):
    """SPPBottleneck with max-pool k=5/9/13 rewritten as cascaded 5×5 pools (SPPF identity:
    mp5∘mp5 == mp9, mp5∘mp5∘mp5 == mp13 for stride-1 same-padded max pooling — exact,
    asserted at export). Why: CoreML places k=9/13 max_pool on the CPU (compute plan,
    MEASURED 2026-08-27), splitting the ANE graph twice mid-network."""
    import torch
    x = self.conv1(x)
    p5 = self.m[0](x)          # k=5
    p9 = self.m[0](p5)
    p13 = self.m[0](p9)
    x = torch.cat([x, p5, p9, p13], dim=1)
    return self.conv2(x)


def checkpoint_input_size(ckpt: Path) -> int:
    """The square a train.py run trained at (--input-size, frozen in ck['args']); RES for
    any checkpoint that was not written by train.py."""
    ck = torch.load(ckpt, map_location="cpu", weights_only=True)
    return int(ck.get("args", {}).get("input_size", RES)) if isinstance(ck, dict) else RES


def build_net(repo: Path, exp_name: str, ckpt: Path | None, num_classes: int, focus_unshuffle: bool,
              spp_cascade: bool = True):
    sys.path.insert(0, str(repo))
    from yolox.exp import get_exp
    from yolox.models.network_blocks import Focus, SPPBottleneck
    exp = get_exp(exp_name=exp_name)
    exp.num_classes = num_classes
    model = exp.get_model()
    if ckpt is not None:   # --random-init: latency-only export, weights do not affect timing
        sd = torch.load(ckpt, map_location="cpu", weights_only=True)
        model.load_state_dict(sd["model"] if "model" in sd else sd)
    model.eval()
    model.head.decode_in_inference = True
    if spp_cascade:
        for m in model.modules():
            if isinstance(m, SPPBottleneck):
                assert [k.kernel_size for k in m.m] == [5, 9, 13], [k.kernel_size for k in m.m]
                x = torch.rand(1, m.conv1.conv.in_channels, 20, 20)
                with torch.no_grad():
                    ref = m(x)
                    m.forward = _spp_cascade.__get__(m, SPPBottleneck)
                    assert torch.allclose(ref, m(x), atol=1e-5), "SPP cascade is not exact"
    if focus_unshuffle:
        x = torch.rand(1, 3, 64, 64)
        for m in model.modules():
            if isinstance(m, Focus):
                with torch.no_grad():
                    ref = m(x)
                    m.forward = _focus_unshuffle.__get__(m, Focus)
                    assert torch.allclose(ref, m(x), atol=1e-6), "Focus rewrite is not exact"
    return model


def export(args):
    import coremltools as ct
    from coremltools.proto import FeatureTypes_pb2 as ft
    # a train.py student's class index is classes.CLASSES order (dataset category id − 1,
    # yolox_exp.py); the export-check COCO placeholder used NUDENET_ORDER. The daemon matches
    # on strings, so either order is a valid file drop — but it MUST match the checkpoint.
    labels = list(CLASSES) if args.labels_from_classes else list(NUDENET_ORDER)
    if args.num_classes != len(labels):
        # export CHECK on COCO weights: relabel the first 18 indices, drop the rest at NMS
        labels = labels + [f"coco_{i}" for i in range(len(labels), args.num_classes)]
        print(json.dumps({"note": "placeholder weights: first 18 class indices carry NudeNet "
                          "names; remaining classes named coco_<i>"}), flush=True)
    # padding columns (Decoded.forward CONF_PAD): dummy labels, always score 0
    labels = labels + [f"_pad_{i}" for i in range(len(labels), CONF_PAD)]
    net = build_net(args.yolox_repo, args.exp, args.ckpt, args.num_classes, args.focus_unshuffle,
                    not args.keep_spp)
    res = args.res or (checkpoint_input_size(args.ckpt) if args.ckpt else RES)
    wrapped = Decoded(net, res).eval()
    x = torch.zeros(1, 3, res, res)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, x)
        c, b = wrapped(x)
    n_anchors, n_cls = int(b.shape[0]), int(c.shape[1])

    # 1. detector — image in (BGR raw 0-255: YOLOX non-legacy preproc, no normalization)
    conv_kw = dict(
        inputs=[ct.ImageType(name="image", shape=(1, 3, res, res), color_layout=ct.colorlayout.BGR,
                             scale=1.0)],
        # outputs pinned to float32 even under fp16 compute: the NMS model type only accepts
        # FLOAT32/DOUBLE inputs (validator error on Float16, MEASURED 2026-08-27)
        outputs=[ct.TensorType(name="raw_confidence", dtype=np.float32),
                 ct.TensorType(name="raw_coordinates", dtype=np.float32)])
    if args.backend == "mlprogram":
        conv_kw.update(compute_precision=ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32,
                       minimum_deployment_target=ct.target.macOS13)
    else:
        # neuralnetwork: the Ultralytics-era construction (640m.mlpackage is built this way);
        # no compute_precision knob — fp16 is weight quantization after conversion.
        conv_kw.update(minimum_deployment_target=ct.target.macOS11)
    det = ct.convert(traced, convert_to=args.backend, **conv_kw)
    if args.backend == "neuralnetwork" and args.fp16:
        from coremltools.models.neural_network import quantization_utils
        det = quantization_utils.quantize_weights(det, nbits=16)
    det_spec = det.get_spec()

    # 2. NMS — the neural-network-era NonMaximumSuppression model type
    nms_spec = ct.proto.Model_pb2.Model()
    nms_spec.specificationVersion = det_spec.specificationVersion
    # NMS inputs must be byte-identical in type to the detector's outputs ([1,A,4]/[1,A,C]
    # float32, batch dim kept) or the pipeline validator rejects the join — copy them.
    for i in range(2):
        inp = nms_spec.description.input.add()
        inp.ParseFromString(det_spec.description.output[i].SerializeToString())
        if not inp.type.multiArrayType.shape:   # neuralnetwork outputs carry no shape; the
            # NMS validator demands one ("missing shape constraints", MEASURED 2026-08-27)
            inp.type.multiArrayType.shape.extend([n_anchors, 4 if inp.name == "raw_coordinates" else n_cls])
    for name, dim in (("confidence", n_cls), ("coordinates", 4)):
        out = nms_spec.description.output.add(); out.name = name
        # must equal the detector outputs' element type (FLOAT16 under --fp16) or CoreML's
        # validator rejects the NMS model
        out.type.multiArrayType.dataType = det_spec.description.output[0].type.multiArrayType.dataType
        rng = out.type.multiArrayType.shapeRange.sizeRanges.add(); rng.lowerBound = 0; rng.upperBound = -1
        rng = out.type.multiArrayType.shapeRange.sizeRanges.add(); rng.lowerBound = dim; rng.upperBound = dim
    nms = nms_spec.nonMaximumSuppression
    nms.confidenceInputFeatureName = "raw_confidence"
    nms.coordinatesInputFeatureName = "raw_coordinates"
    nms.confidenceOutputFeatureName = "confidence"
    nms.coordinatesOutputFeatureName = "coordinates"
    nms.iouThresholdInputFeatureName = "iouThreshold"
    nms.confidenceThresholdInputFeatureName = "confidenceThreshold"
    nms.iouThreshold = args.iou
    nms.confidenceThreshold = args.conf
    nms.pickTop.perClass = True
    nms.stringClassLabels.vector.extend(labels)
    for name in ("iouThreshold", "confidenceThreshold"):
        inp = nms_spec.description.input.add(); inp.name = name
        inp.type.doubleType.MergeFromString(b"")
    nms_model = ct.models.MLModel(nms_spec)

    # 3. pipeline
    pipe = ct.models.pipeline.Pipeline(
        input_features=[("image", ct.models.datatypes.Array(3, res, res)),
                        ("iouThreshold", ct.models.datatypes.Double()),
                        ("confidenceThreshold", ct.models.datatypes.Double())],
        output_features=["confidence", "coordinates"])
    pipe.add_model(det)
    pipe.add_model(nms_model)
    pipe.spec.description.input[0].ParseFromString(det_spec.description.input[0].SerializeToString())
    pipe.spec.description.output[0].ParseFromString(nms_spec.description.output[0].SerializeToString())
    pipe.spec.description.output[1].ParseFromString(nms_spec.description.output[1].SerializeToString())
    pipe.spec.specificationVersion = det_spec.specificationVersion
    md = pipe.spec.description.metadata
    md.userDefined["classes"] = ",".join(labels)
    md.userDefined["iou_threshold"] = str(args.iou)
    md.userDefined["confidence_threshold"] = str(args.conf)
    md.userDefined["input_layout"] = "BGR 0-255 raw (YOLOX non-legacy preproc); daemon .scaleFill stretch"
    md.userDefined["license"] = "YOLOX Apache-2.0 (Megvii); export script: this repo"
    md.shortDescription = f"YOLOX {args.exp} student, NMS embedded, {n_cls} classes"
    out = Path(args.out).with_suffix(".mlpackage")
    if args.backend == "mlprogram":
        ct.models.MLModel(pipe.spec, weights_dir=det.weights_dir).save(str(out))
    else:
        ct.models.MLModel(pipe.spec).save(str(out))
    print(json.dumps({"package": str(out), "anchors": n_anchors, "classes": n_cls,
                      "fp16": args.fp16, "res": res, "random_init": args.random_init, "labels_head": labels[:3]}), flush=True)


BENCH_WARMUP = 5     # the first predicts after load are 3-10x slower while Core ML specializes the plan


def bench(pkg: Path, runs: int, units: str):
    """Latency on this Mac: p50/p90 over `runs` predicts after warmup, on random pixels
    (latency does not depend on content here)."""
    import coremltools as ct, statistics, time
    from PIL import Image
    cu = {"cpu": ct.ComputeUnit.CPU_ONLY, "gpu": ct.ComputeUnit.CPU_AND_GPU,
          "ane": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL}[units]
    t0 = time.perf_counter()
    ml = ct.models.MLModel(str(pkg), compute_units=cu)
    load_s = time.perf_counter() - t0
    spec = ml.get_spec()
    img = spec.description.input[0].type.imageType   # the size the package declares (--res)
    rng = np.random.default_rng(0)
    im = Image.fromarray(rng.integers(0, 256, (img.height, img.width, 3), dtype=np.uint8))
    names = {i.name for i in spec.description.input}
    x = {"image": im}
    if "confidenceThreshold" in names:
        x["confidenceThreshold"] = CONF_DEFAULT
    if "iouThreshold" in names:
        x["iouThreshold"] = IOU_DEFAULT
    warm = []
    for _ in range(BENCH_WARMUP):
        t = time.perf_counter()
        ml.predict(x)
        warm.append(round((time.perf_counter() - t) * 1000, 1))
    ts = []
    for _ in range(runs):
        t = time.perf_counter()
        ml.predict(x)
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    r = {"package": pkg.name, "input": f"{img.width}x{img.height}", "compute_units": units,
         "runs": runs, "load_s": round(load_s, 2),
         "p50_ms": round(statistics.median(ts), 1), "p90_ms": round(ts[int(0.9 * runs) - 1], 1),
         "p95_ms": round(ts[int(0.95 * runs) - 1], 1),
         "min_ms": round(ts[0], 1), "warmup_ms": warm}
    print(json.dumps(r), flush=True)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--yolox-repo", type=Path)
    ap.add_argument("--exp", default="yolox_s")
    ap.add_argument("--ckpt", type=Path)
    ap.add_argument("--out")
    ap.add_argument("--bench", type=Path, help=".mlpackage to time on this Mac")
    ap.add_argument("--runs", type=int, default=50)
    ap.add_argument("--units", default="all", choices=["cpu", "gpu", "ane", "all"])
    ap.add_argument("--num-classes", type=int, default=len(NUDENET_ORDER))
    ap.add_argument("--fp16", action="store_true")
    ap.add_argument("--res", type=int, default=None,
                    help="square input size; default = the checkpoint's own --input-size, else 640")
    ap.add_argument("--random-init", action="store_true",
                    help="skip --ckpt (latency-only export; never ship)")
    ap.add_argument("--labels-from-classes", action="store_true",
                    help="label order = classes.CLASSES (train.py students); default NUDENET_ORDER")
    ap.add_argument("--focus-unshuffle", action="store_true",
                    help="Focus stem as pixel_unshuffle+gather (lands on CPU, no gain; off)")
    ap.add_argument("--keep-spp", action="store_true", help="keep k=9/13 max-pools (CPU-placed, slow)")
    ap.add_argument("--backend", default="mlprogram", choices=["mlprogram", "neuralnetwork"],
                    help="detector model type inside the pipeline")
    ap.add_argument("--iou", type=float, default=IOU_DEFAULT)
    ap.add_argument("--conf", type=float, default=CONF_DEFAULT)
    args = ap.parse_args()
    if args.bench:
        bench(args.bench, args.runs, args.units)
        return
    for req in ("yolox_repo", "ckpt", "out"):
        if req == "ckpt" and args.random_init:
            continue
        if getattr(args, req) is None:
            ap.error(f"--{req.replace('_', '-')} is required unless --bench")
    export(args)


if __name__ == "__main__":
    main()
