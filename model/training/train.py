#!/usr/bin/env python3
"""Train the YOLOX-S student on a COCO dataset (Apple Silicon MPS, or CPU).

YOLOX's own Trainer assumes CUDA, so this loop reuses YOLOX's Exp pieces (model, optimizer,
LR schedule, mosaic dataloader, EMA) and owns device placement, checkpoints and resume.

Dataset layout (compose.py output, one directory per split):
    <dataset>/train/_annotations.coco.json + images
    <dataset>/valid/_annotations.coco.json + images   (optional)

The shipped model's recipe (v8): 50 epochs, batch 36, 4 workers, input 640, COCO-pretrained
yolox_s.pth, lr scale 1.0:
    python train.py --yolox-repo third_party/YOLOX --pretrain yolox_s.pth \
        --dataset dataset --epochs 50 --out runs/my_run

Outputs in --out: last.pth (EMA weights under "model", plus the state to resume), ep<N>.pth
copies with --keep-every, and train.log. Export with export_yolox_coreml.py --ckpt last.pth.
Resume an interrupted run with --resume (same --out).

Fine-tune from trained weights with a fresh schedule: --pretrain <run>/last.pth --lr-scale 0.1-0.3
on a dataset that still contains the original training data.
"""
from __future__ import annotations
import argparse, math, os, shutil, sys, time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))


def log(path: Path, msg: str):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(path, "a") as f:
        f.write(line + "\n")


def save(torch, path: Path, obj):
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(obj, tmp)
    os.replace(tmp, path)


def link_annotations(ds_dir: Path):
    """YOLOX's COCODataset reads <data_dir>/annotations/<split>.json."""
    ann = ds_dir / "annotations"
    ann.mkdir(exist_ok=True)
    for split in ("train", "valid"):
        link, src = ann / f"{split}.json", ds_dir / split / "_annotations.coco.json"
        if src.exists() and not link.exists():
            link.symlink_to(Path("..") / split / "_annotations.coco.json")


def load_pretrain(torch, model, path: Path):
    sd = torch.load(path, map_location="cpu", weights_only=True)
    sd = sd["model"] if "model" in sd else sd
    own = model.state_dict()
    keep = {k: v for k, v in sd.items() if k in own and own[k].shape == v.shape}
    model.load_state_dict(keep, strict=False)
    # Only the class-prediction convs (80 COCO classes → 18) may differ.
    bad = [k for k in own if k not in keep and "cls_preds" not in k]
    if bad:
        sys.exit(f"pretrain mismatch beyond cls_preds: {bad[:5]}")
    return len(keep)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--yolox-repo", type=Path, required=True, help="YOLOX checkout (commit 6ddff48)")
    ap.add_argument("--dataset", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--epochs", type=int, default=50)
    ap.add_argument("--batch", type=int, default=36)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--input-size", type=int, default=640, help="the app's model input is 640")
    ap.add_argument("--lr-scale", type=float, default=1.0)
    ap.add_argument("--pretrain", type=Path, help="yolox_s.pth (COCO) or a trained checkpoint")
    ap.add_argument("--resume", action="store_true", help="continue from <out>/last.pth")
    ap.add_argument("--subset", type=int, default=None, help="first N training images only")
    ap.add_argument("--keep-every", type=int, default=0, help="also keep ep<N>.pth every N epochs")
    ap.add_argument("--device", default="mps", choices=["mps", "cpu"])
    args = ap.parse_args()

    sys.path.insert(0, str(args.yolox_repo.resolve()))
    import torch
    from yolox.utils import ModelEMA
    from yolox_exp import make_exp
    import simota_batched

    device = "mps" if args.device == "mps" and torch.backends.mps.is_available() else "cpu"
    args.out.mkdir(parents=True, exist_ok=True)
    log_path = args.out / "train.log"
    ckpt_path = args.out / "last.pth"
    ck = None
    if args.resume:
        if not ckpt_path.exists():
            sys.exit(f"--resume: {ckpt_path} does not exist")
        ck = torch.load(ckpt_path, map_location="cpu", weights_only=True)
        for k in ("epochs", "batch", "input_size", "lr_scale", "subset"):
            setattr(args, k, ck["args"][k])
    elif not args.pretrain:
        sys.exit("--pretrain is required for a new run (YOLOX's yolox_s.pth COCO weights)")

    link_annotations(args.dataset)
    exp = make_exp(args.dataset, args.epochs, args.subset, args.workers, args.input_size)
    simota_batched.install()   # same assignment as YOLOX, far fewer host syncs on MPS
    exp.basic_lr_per_img *= args.lr_scale
    model = exp.get_model()
    if ck:
        model.load_state_dict(ck["raw_model"])
        start_epoch = ck["epoch"]
    else:
        n = load_pretrain(torch, model, args.pretrain)
        start_epoch = 0
        log(log_path, f"pretrain {args.pretrain.name}: loaded {n} tensors")
    model.to(device).train()
    optimizer = exp.get_optimizer(args.batch)
    if ck:
        optimizer.load_state_dict(ck["optimizer"])

    tail_start = exp.max_epoch - exp.no_aug_epochs   # last epochs: mosaic/mixup off, L1 loss on
    no_aug = start_epoch >= tail_start
    loader = exp.get_data_loader(args.batch, is_distributed=False, no_aug=no_aug)
    if no_aug:
        model.head.use_l1 = True
    iters = len(loader)
    lr_sched = exp.get_lr_scheduler(exp.basic_lr_per_img * args.batch, iters)
    ema = ModelEMA(model, 0.9998)
    ema.updates = iters * start_epoch
    if ck:
        ema.ema.load_state_dict(ck["ema"])
    del ck
    log(log_path, f"device={device} images={len(exp.dataset)} batch={args.batch} iters/epoch={iters} "
                  f"epochs={exp.max_epoch} no_aug_epochs={exp.no_aug_epochs} start_epoch={start_epoch}")

    for epoch in range(start_epoch, exp.max_epoch):
        if epoch >= tail_start and not no_aug:
            no_aug = True
            loader = exp.get_data_loader(args.batch, is_distributed=False, no_aug=True)
            model.head.use_l1 = True
            log(log_path, f"epoch {epoch}: mosaic/mixup off, L1 loss on")
        # YOLOX's sampler restarts from a fixed seed on every iter(loader): reseed per epoch.
        loader.batch_sampler.sampler._seed = epoch * 100_000
        data = iter(loader)
        t0, seen = time.time(), 0
        for it in range(iters):
            inps, targets, _, _ = next(data)
            inps = inps.to(device).float()
            targets = targets.to(device).float()
            loss = model(inps, targets)["total_loss"]
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            lv = float(loss.detach().cpu())
            if not math.isfinite(lv):
                sys.exit(f"non-finite loss at epoch {epoch} iter {it}; resume from last.pth")
            optimizer.step()
            ema.update(model)
            lr = lr_sched.update_lr(epoch * iters + it + 1)
            for g in optimizer.param_groups:
                g["lr"] = lr
            seen += inps.shape[0]
            if (it + 1) % 50 == 0:
                log(log_path, f"epoch {epoch} iter {it + 1}/{iters} loss {lv:.3f} "
                              f"img/s {seen / (time.time() - t0):.1f} lr {lr:.5f}")
        save(torch, ckpt_path, {"model": ema.ema.state_dict(), "raw_model": model.state_dict(),
                                "ema": ema.ema.state_dict(), "optimizer": optimizer.state_dict(),
                                "epoch": epoch + 1, "args": vars(args) | {"yolox_repo": str(args.yolox_repo),
                                                                       "dataset": str(args.dataset),
                                                                       "out": str(args.out),
                                                                       "pretrain": str(args.pretrain)},
                                "num_classes": exp.num_classes})
        log(log_path, f"epoch {epoch} done in {time.time() - t0:.0f}s; saved {ckpt_path.name}")
        if args.keep_every and (epoch + 1) % args.keep_every == 0:
            shutil.copyfile(ckpt_path, args.out / f"ep{epoch + 1}.pth")
    log(log_path, "done")


if __name__ == "__main__":
    main()
