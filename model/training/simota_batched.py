"""simota_batched.py — YOLOX's SimOTA label assignment for a whole batch at once.

YOLOX's `YOLOXHead.get_losses` (third_party/YOLOX/yolox/models/yolo_head.py) assigns labels one
image at a time and picks anchors one GT at a time, with a host sync at almost every step (the per-GT
topk with a tensor k, `.max() > 1`, `.item()`, boolean-mask indexing). Measured on MPS: 401 host
syncs per training step (about 16 % of the step on MPS). `get_losses` below is a
drop-in replacement with the same assignment and ~4 host syncs per step; it then runs YOLOX's loss
math unchanged. `train.py` installs it on every run.

What is batched and what is not:
  - Batched: the center prior, candidate packing and gathers, the per-GT top-k, the multi-match rule,
    targets. Batched tensors are padded to a few shapes (SHAPE_STEP_*), because MPS builds a graph per shape.
  - Per image, sync-free: the cost matrix and dynamic k (`image_cost`). On the CPU the last bit of
    a sigmoid, log or sum depends on the tensor's shape (vector body vs scalar tail, reduction
    order). A padded [B, G, C] cost differed from the reference by 1.9e-6 and flipped a tie
    So the cost is computed with the reference's ops on the reference's shapes.

Why the result is identical, not just close:
  - Candidates are the anchors YOLOX keeps (the center prior), in the same ascending anchor order.
    The center prior uses only +, -, *, min and >, which are exact in any shape.
  - The cost, the IoUs and dynamic k are the reference's own numbers (above).
  - Per GT, the dynamic_k cheapest anchors form a unique set unless the k-th and (k+1)-th costs tie.
    On a tie the reference's pick is torch.topk's tie rule, and on the CPU that rule changes with k
    and row length. A tied row is therefore re-picked with the reference's exact call,
    torch.topk(cost_row, k, largest=False) on the unpadded row.
  - An anchor that several GTs pick goes to the GT with the lowest cost. torch.min(dim) returns the
    first minimum on both devices, as in the reference.
Out of scope: YOLOX's out-of-memory retry on the CPU. It only catches messages that contain
"CUDA out of memory. ", so on MPS it never runs and an OOM raises. Here any error raises too.
"""
from __future__ import annotations
from typing import NamedTuple

import torch
import torch.nn.functional as F

# YOLOX's SimOTA constants, copied from yolo_head.py (YOLOX @6ddff48, md5
# ea71df70b927b5271fd7383aed464c57). They are the reference's values, not new choices.
CENTER_RADIUS = 1.5     # get_geometry_constraint: center_radius
CANDIDATE_K = 10        # simota_matching: n_candidate_k = min(10, candidates)
IOU_COST_WEIGHT = 3.0   # get_assignments: cost = cls + 3.0 * iou_loss + 1e6 * ~geometry
GEOMETRY_COST = 1e6     # get_assignments: float(1e6)
IOU_EPS = 1e-8          # get_assignments: -torch.log(pair_wise_ious + 1e-8)
REG_WEIGHT = 5.0        # get_losses: reg_weight
# RECEIPT SHAPE_STEP_G=8, SHAPE_STEP_C=128 (MEASURED, EXP-003 Log 13:46Z): MPS builds and caches one graph
# per new tensor shape. With the exact batch maxima (real batches: G up to 23, C up to 431), the batched
# [B, G, C] ops meet a new shape almost every step. Rounding up to these steps limits them to G in
# {8, 16, 24, 32} and C in {128, ..., 512} for every real batch measured. Measured on MPS, first call
# per batch, 16 fresh batches, 2 runs each: 0.239 / 0.245 s with the rounding, 0.250 / 0.251 s without,
# and ~40 MB less RSS growth. Small, but the cache stays bounded over a 50-epoch run. Padded rows and
# columns are masked (invalid GT, +inf cost), so the result does not change (tests/simota_batched_test.py).
SHAPE_STEP_G = 8
SHAPE_STEP_C = 128


class Targets(NamedTuple):
    """What YOLOX's per-image loop concatenates, plus what the equivalence test compares."""
    cls_targets: torch.Tensor   # [num_fg, K]
    reg_targets: torch.Tensor   # [num_fg, 4]
    l1_targets: torch.Tensor    # [num_fg, 4], or None without use_l1
    obj_targets: torch.Tensor   # [B * A, 1]
    fg_masks: torch.Tensor      # [B * A] bool
    matched_gt: torch.Tensor    # [num_fg] GT index within its image
    num_fg: float
    num_gts: float
    tied_rows: int              # GT rows re-picked with the reference's topk call


def round_up(n, step, cap):
    """n rounded up to a multiple of step, at most cap (the tensor's real size)."""
    return min(-(-n // step) * step, cap)


def center_prior(gt, gt_valid, x_shifts, y_shifts, expanded_strides):
    """[B, G, A] bool: the anchor centre lies within CENTER_RADIUS strides of the GT centre.
    get_geometry_constraint with a batch dimension; min of the four deltas > 0, same ops."""
    stride = expanded_strides[0]
    x_centers = ((x_shifts[0] + 0.5) * stride).unsqueeze(0)
    y_centers = ((y_shifts[0] + 0.5) * stride).unsqueeze(0)
    center_dist = stride.unsqueeze(0) * CENTER_RADIUS
    gx, gy = gt[..., 0:1], gt[..., 1:2]
    c_l = x_centers - (gx - center_dist)
    c_r = (gx + center_dist) - x_centers
    c_t = y_centers - (gy - center_dist)
    c_b = (gy + center_dist) - y_centers
    inside = torch.minimum(torch.minimum(c_l, c_t), torch.minimum(c_r, c_b)) > 0.0
    return inside & gt_valid.unsqueeze(-1)


def image_cost(num_classes, gt, gt_classes, preds, cls, obj, geometry):
    """One image's SimOTA cost [G, C], IoUs [G, C] and dynamic k [G]: get_assignments' and
    simota_matching's math on the same shapes and memory layout. On the CPU a float op's last bit
    can depend on shape (vector body vs scalar tail, reduction order), so this part stays per image.
    It needs no host sync: every size is already a host int."""
    from yolox.models import yolo_head   # its bboxes_iou is the one yolox_exp.apply_mps_patches installs
    ious = yolo_head.bboxes_iou(gt, preds, False)
    gt_cls = F.one_hot(gt_classes.to(torch.int64), num_classes).float()
    iou_cost = -torch.log(ious + IOU_EPS)
    p = (cls.float().sigmoid_() * obj.float().sigmoid_()).sqrt()
    G, C = ious.shape
    cls_cost = F.binary_cross_entropy(p.unsqueeze(0).repeat(G, 1, 1), gt_cls.unsqueeze(1).repeat(1, C, 1),
                                      reduction="none").sum(-1)
    cost = cls_cost + IOU_COST_WEIGHT * iou_cost + float(GEOMETRY_COST) * (~geometry)
    top_ious, _ = torch.topk(ious, min(CANDIDATE_K, C), dim=1)
    dynamic_ks = torch.clamp(top_ious.sum(1).int(), min=1)
    return cost, ious, dynamic_ks


def simota(cost, dynamic_ks, gt_valid, counts):
    """simota_matching on padded [B, G, C]: invalid pairs cost +inf, padded GT rows are masked
    by gt_valid. Returns the matched GT per candidate [B, C], the fg mask [B, C] and the number
    of tied rows re-picked with the reference's call."""
    B, G, C = cost.shape
    width = min(CANDIDATE_K + 1, C)   # one past the largest k, to see a tie at the boundary
    vals, pos = torch.topk(cost, width, dim=-1, largest=False)
    rank = torch.arange(width, device=cost.device)
    chosen = (rank < dynamic_ks.unsqueeze(-1)) & gt_valid.unsqueeze(-1)
    matching = torch.zeros_like(cost, dtype=torch.uint8).scatter_(-1, pos, chosen.to(torch.uint8))

    k = dynamic_ks.long().unsqueeze(-1)
    kth = vals.gather(-1, k - 1)
    nxt = vals.gather(-1, k.clamp(max=width - 1))
    tied = ((kth == nxt) & (k < width)).squeeze(-1) & gt_valid
    tied_rows = tied.nonzero().tolist()          # host sync; almost always empty on real batches
    for b, g in tied_rows:
        _, p = torch.topk(cost[b, g, :counts[b]], k=int(dynamic_ks[b, g]), largest=False)
        matching[b, g].zero_()
        matching[b, g, p] = 1

    n_match = matching.sum(1)                                                      # [B, C]
    cost_argmin = torch.min(cost, dim=1).indices
    matched = torch.where(n_match > 1, cost_argmin, matching.argmax(1))
    return matched, n_match > 0, len(tied_rows)


@torch.no_grad()
def batched_targets(head, labels, bbox_preds, obj_preds, cls_preds, x_shifts, y_shifts,
                    expanded_strides, dtype):
    """YOLOX's per-image target loop (get_losses + get_assignments), for the whole batch.
    Host syncs: GT counts, candidate counts, the tie check, the fg list (4 per step)."""
    B, A = bbox_preds.shape[:2]
    K = head.num_classes
    dev = bbox_preds.device
    nlabel = (labels.sum(dim=2) > 0).sum(dim=1)
    num_gt = nlabel.tolist()
    G = max(num_gt)
    fg_masks = torch.zeros(B, A, dtype=torch.bool, device=dev)
    if G == 0:
        empty = bbox_preds.new_zeros((0, 4))
        return Targets(bbox_preds.new_zeros((0, K)), empty, empty if head.use_l1 else None,
                       fg_masks.reshape(-1, 1).to(dtype), fg_masks.reshape(-1),
                       torch.zeros(0, dtype=torch.long, device=dev), 0.0, 0.0, 0)

    G = round_up(G, SHAPE_STEP_G, labels.shape[1])
    gt = labels[:, :G, 1:5]
    gt_classes = labels[:, :G, 0]
    gt_valid = torch.arange(G, device=dev) < nlabel.unsqueeze(1)
    in_center = center_prior(gt, gt_valid, x_shifts, y_shifts, expanded_strides)
    anchor_filter = in_center.any(1)
    counts = anchor_filter.sum(1).tolist()
    for b in range(B):
        if num_gt[b] and not counts[b]:
            # the reference raises here too: topk(k=1) on an empty cost row
            raise RuntimeError(f"simota_batched: image {b} has {num_gt[b]} GT and no candidate anchor "
                               f"(every GT centre is more than {CENTER_RADIUS} strides from every anchor)")
    C = round_up(max(counts), SHAPE_STEP_C, A)
    # candidate anchors per image, ascending: the order the reference's boolean-mask indexing gives
    cand = torch.argsort((~anchor_filter).to(torch.uint8), dim=1, stable=True)[:, :C]
    cand_valid = torch.arange(C, device=dev) < torch.tensor(counts, device=dev).unsqueeze(1)

    # one gather per tensor for the batch; each image then reads a contiguous [c, ...] view, the same
    # layout as the reference's boolean-mask copy
    take = lambda x: x.gather(1, cand.unsqueeze(-1).expand(B, C, x.shape[-1]))   # noqa: E731
    preds_c, cls_c, obj_c = take(bbox_preds), take(cls_preds), take(obj_preds)
    geometry_c = in_center.gather(2, cand.unsqueeze(1).expand(B, G, C))
    cost = torch.full((B, G, C), float("inf"), device=dev)
    ious = torch.zeros((B, G, C), device=dev)
    dynamic_ks = torch.ones((B, G), dtype=torch.int32, device=dev)
    for b in range(B):
        g, c = num_gt[b], counts[b]
        if not g:
            continue
        cost_b, ious_b, dk_b = image_cost(K, labels[b, :g, 1:5], labels[b, :g, 0], preds_c[b, :c], cls_c[b, :c],
                                          obj_c[b, :c], geometry_c[b, :g, :c])
        cost[b, :g, :c] = cost_b
        ious[b, :g, :c] = ious_b
        dynamic_ks[b, :g] = dk_b

    matched, fg, tied_rows = simota(cost, dynamic_ks, gt_valid, counts)
    fg = fg & cand_valid
    b_idx, c_idx = fg.nonzero().unbind(1)      # (image, candidate) order = the reference's concat order
    anchor = cand[b_idx, c_idx]
    m = matched[b_idx, c_idx]
    fg_masks[b_idx, anchor] = True
    pred_ious = ious[b_idx, m, c_idx]
    cls_targets = F.one_hot(gt_classes[b_idx, m].to(torch.int64), K) * pred_ious.unsqueeze(-1)
    reg_targets = gt[b_idx, m]
    l1_targets = None
    if head.use_l1:
        l1_targets = head.get_l1_target(bbox_preds.new_zeros((len(anchor), 4)), reg_targets,
                                        expanded_strides[0][anchor], x_shifts=x_shifts[0][anchor],
                                        y_shifts=y_shifts[0][anchor])
    return Targets(cls_targets, reg_targets, l1_targets, fg_masks.reshape(-1, 1).to(dtype),
                   fg_masks.reshape(-1), m, float(len(anchor)), float(sum(num_gt)), tied_rows)


def get_losses(self, imgs, x_shifts, y_shifts, expanded_strides, labels, outputs, origin_preds, dtype):
    """Drop-in for YOLOXHead.get_losses: batched targets, then YOLOX's loss math line for line."""
    bbox_preds = outputs[:, :, :4]
    obj_preds = outputs[:, :, 4:5]
    cls_preds = outputs[:, :, 5:]
    x_shifts = torch.cat(x_shifts, 1)
    y_shifts = torch.cat(y_shifts, 1)
    expanded_strides = torch.cat(expanded_strides, 1)
    if self.use_l1:
        origin_preds = torch.cat(origin_preds, 1)
    t = batched_targets(self, labels, bbox_preds, obj_preds, cls_preds, x_shifts, y_shifts,
                        expanded_strides, dtype)

    num_fg = max(t.num_fg, 1)
    loss_iou = (self.iou_loss(bbox_preds.view(-1, 4)[t.fg_masks], t.reg_targets)).sum() / num_fg
    loss_obj = (self.bcewithlog_loss(obj_preds.view(-1, 1), t.obj_targets)).sum() / num_fg
    loss_cls = (self.bcewithlog_loss(cls_preds.view(-1, self.num_classes)[t.fg_masks], t.cls_targets)
                ).sum() / num_fg
    if self.use_l1:
        loss_l1 = (self.l1_loss(origin_preds.view(-1, 4)[t.fg_masks], t.l1_targets)).sum() / num_fg
    else:
        loss_l1 = 0.0
    loss = REG_WEIGHT * loss_iou + loss_obj + loss_cls + loss_l1
    return loss, REG_WEIGHT * loss_iou, loss_obj, loss_cls, loss_l1, num_fg / max(t.num_gts, 1)


def install():
    """Replace YOLOXHead.get_losses for this process (train_yolox.py, every run)."""
    from yolox.models.yolo_head import YOLOXHead
    YOLOXHead.get_losses = get_losses
