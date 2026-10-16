"""The 18-class contract shared by training, export and the app.

The student is trained on all 18 NudeNet labels. The app acts on the first eight
(ACTION_CLASSES); the other ten are look-alike context classes that give the
detector explicit examples of regions often confused with the action classes.

Order is stable and load-bearing: COCO category id = index + 1, model class
index = index, and the exported Core ML labels follow the same order.
"""
ACTION_CLASSES = [
    "FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED", "MALE_GENITALIA_EXPOSED",
    "BUTTOCKS_EXPOSED", "ANUS_EXPOSED",
    "FEMALE_BREAST_COVERED", "FEMALE_GENITALIA_COVERED", "BUTTOCKS_COVERED",
]
CONTEXT_CLASSES = [
    "FACE_FEMALE", "FACE_MALE", "FEET_EXPOSED", "FEET_COVERED",
    "ARMPITS_EXPOSED", "ARMPITS_COVERED", "BELLY_EXPOSED", "BELLY_COVERED",
    "MALE_BREAST_EXPOSED", "ANUS_COVERED",
]
CLASSES = ACTION_CLASSES + CONTEXT_CLASSES
CLASS_ID = {c: i for i, c in enumerate(CLASSES)}
EXPLICIT = set(ACTION_CLASSES[:5])
COVERED_ACTION = set(ACTION_CLASSES[5:])
# Pseudo-label confidence floors: 0.5 for explicit and context classes, 0.6 for
# the covered action classes (they are the most frequent false positives).
CONF_FLOOR = {**{c: 0.5 for c in EXPLICIT}, **{c: 0.6 for c in COVERED_ACTION},
              **{c: 0.5 for c in CONTEXT_CLASSES}}
NUDENET_LABELS = set(CLASSES)
assert len(CLASSES) == 18 and len(NUDENET_LABELS) == 18


def floor_of(cls: str) -> float:
    return CONF_FLOOR[cls]
