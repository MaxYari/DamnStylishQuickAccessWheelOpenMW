#!/usr/bin/env python3
"""Makes corrected copies of the 1st-person wheel poses for idles that turn the chest away.

The poses (Animations/xbase_anim.1st/xSpellWheelPose.kf, xWeaponWheelPose.kf) play on one arm each;
the chest under the arm comes from whatever idle is playing. They were made over a chest standing
about straight up, so over an idle that turns it a lot (the spear idle swings it far to the right)
the arm swings with it, out of view. With nothing drawn the chest is the plain "idle" whatever the
weapon, which the poses fit; the corrections are for the drawn weapons' idles.

Both clavicles hang off Bip01 Neck, and the 1st-person view doesn't follow the skeleton, so the fix
is the same for every arm bone below: compare the neck's transform in the object-root frame, pose
against idle (averaged over the idle's loop, Start to Loop Stop; the tail some idles have after it
only plays when they stop looping), and for idles more than THRESHOLD away re-solve the clavicle
keys to keep their pose transform on top of the idle's neck.

Idles whose chests are within SIMILAR of each other share one correction, made for the average of
their chests. Each correction is one kf, xWheelPoseFix<n>.kf, holding the spell pose's left arm and
the weapon pose's right arm (both poses share the same chest), under two groups,
spellwheelpose_fix<n> and weaponwheelpose_fix<n>; each pose masks off the other arm anyway. Which
idle takes which correction is written to scripts/MaxYari/quick access wheel/pose_fixes.lua.

Idles come from vanilla xbase_anim.1st.kf and ReAnimation's Animations/xbase_anim.1st, in the order
OpenMW loads them (the base file, then the folder sorted by name), the last file with a group being
the one that plays. Only ReAnimation's own idles get corrections (vanilla's storm idle, which it
leaves alone, sways too much in its loop for one correction to fit). Bones an idle doesn't key fall
back to the plain "idle".

Rerun after re-exporting the poses or any of ReAnimation's 1st-person idles.

Usage: make_pose_variants.py <vanilla xbase_anim.1st.kf> [--reanimation DIR] [--report]
(extract the kf from Morrowind.bsa, e.g. bsatool extract Morrowind.bsa "meshes\\xbase_anim.1st.kf" <dir>)
"""

import argparse
import copy
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.normpath(os.path.join(HERE, '..'))
POSE_DIR = os.path.join(MOD, 'Animations', 'xbase_anim.1st')
FIXES_LUA = os.path.join(MOD, 'scripts', 'MaxYari', 'quick access wheel', 'pose_fixes.lua')
SPELL_POSE, WEAPON_POSE = 'spellwheelpose', 'weaponwheelpose'
THRESHOLD = 15.0  # degrees between the pose's chest and an idle's for the idle to get a correction
SIMILAR = 10.0  # degrees within which idles share one
LOOP_SAMPLES = 20

CHAIN = ['Bip01', 'Bip01 Pelvis', 'Bip01 Spine', 'Bip01 Spine1', 'Bip01 Spine2', 'Bip01 Neck']
CLAVICLES = ['Bip01 L Clavicle', 'Bip01 R Clavicle']


def find_reanimation():
    for path in glob.glob(os.path.join(MOD, '..', '*', 'Sources', 'Tools', 'FBACompat', 'nifkf.py')):
        return os.path.normpath(os.path.join(os.path.dirname(path), '..', '..', '..'))
    return None


def group_ranges(kf):
    """{group: (start, end of its loop)} from the text keys, lower case."""
    out = {}
    for group, keys in kf.groups().items():
        times = {k: t for t, k in keys}
        if 'start' in times:
            out[group] = (times['start'], times.get('loop stop', times.get('stop', times['start'])))
    return out


class Track:
    """A kf evaluated at a time, with a fallback track for the bones it doesn't key."""

    def __init__(self, kf, start, fallback=None):
        self.kf, self.start, self.fallback = kf, start, fallback

    def local(self, bone, t=None):
        t = self.start if t is None else t
        if bone in self.kf.bone_data:
            d = self.kf.data(bone)
            rot = E.rotation(d, t)
            trans = E.translation(d, t) if d.trans['keys'] else None
            if rot is not None and trans is not None:
                return rot, trans
            if self.fallback:
                frot, ftrans = self.fallback.local(bone)
                return rot or frot, trans or ftrans
            return rot or (1.0, 0.0, 0.0, 0.0), trans or (0.0, 0.0, 0.0)
        if self.fallback:
            return self.fallback.local(bone)
        raise KeyError(bone)

    def neck(self, t=None):
        """(rotation, position) of Bip01 Neck in the object-root frame."""
        rot, pos = (1.0, 0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
        for bone in CHAIN:
            lr, lt = self.local(bone, t)
            pos = tuple(p + c for p, c in zip(pos, E.qrot(rot, lt)))
            rot = E.qmul(rot, lr)
        return rot, pos


def average(transforms):
    """Average of (rotation, position) pairs: the sign-aligned normalized quaternion sum."""
    ref = transforms[0][0]
    total = [0.0, 0.0, 0.0, 0.0]
    for rot, _ in transforms:
        sign = 1.0 if sum(a * b for a, b in zip(ref, rot)) >= 0 else -1.0
        total = [t + sign * c for t, c in zip(total, rot)]
    pos = tuple(sum(p[i] for _, p in transforms) / len(transforms) for i in range(3))
    return E.qnorm(tuple(total)), pos


def loop_neck(kf, start, stop, fallback):
    """The neck averaged over the idle's loop, and how far the loop strays from that average."""
    track = Track(kf, start, fallback)
    samples = [track.neck(start + (stop - start) * i / LOOP_SAMPLES) for i in range(LOOP_SAMPLES + 1)]
    mean = average(samples)
    wander = max(E.qangle(mean[0], s[0]) for s in samples)
    return mean, wander


def effective_idles(vanilla, folder):
    """{idle group: (kf, path, start, loop stop)}, the last loaded file with the group winning."""
    files = [vanilla] + sorted(glob.glob(os.path.join(folder, '*.kf')), key=lambda p: os.path.basename(p).lower())
    idles = {}
    for path in files:
        kf = KF.load(path)
        for group, (start, stop) in group_ranges(kf).items():
            if group.startswith('idle'):
                idles[group] = (kf, path, start, stop)
    return idles


def cluster(necks):
    """Groups idles whose chests are all within SIMILAR of each other, largest groups first."""
    groups = []
    for idle in sorted(necks):
        for group in groups:
            if all(E.qangle(necks[idle][0], necks[other][0]) <= SIMILAR for other in group):
                group.append(idle)
                break
        else:
            groups.append([idle])
    return sorted(groups, key=lambda g: (-len(g), g[0]))


def left_arm(bone):
    return bone.startswith('Bip01 L ') or bone == 'Shield Bone'


def resolve_clavicles(kf, track, neck):
    """Re-solves the clavicle keys of kf (in place) to keep their object-root transform on top of
    `neck` instead of the kf's own neck."""
    neck_rot, neck_pos = neck
    inv = E.qconj(neck_rot)
    for bone in CLAVICLES:
        d = kf.data(bone)
        if d.rot_type == 4:
            times = {k[0] for g in d.xyz for k in g['keys']}
        else:
            times = {k[0] for k in d.quat_keys}
        times = sorted(times | {k[0] for k in d.trans['keys']})
        rots, transes = [], []
        for t in times:
            own_rot, own_pos = track.neck(t)
            lr, lt = track.local(bone, t)
            world_rot = E.qmul(own_rot, lr)
            world_pos = tuple(p + c for p, c in zip(own_pos, E.qrot(own_rot, lt)))
            q = E.qnorm(E.qmul(inv, world_rot))
            if rots and sum(a * b for a, b in zip(rots[-1][1], q)) < 0:
                q = tuple(-c for c in q)
            rots.append((t, q, ()))
            transes.append((t, E.qrot(inv, tuple(w - n for w, n in zip(world_pos, neck_pos))), ()))
        d.rot_type = 1
        d.xyz = None
        d.quat_keys = rots
        d.trans = {'itype': 1, 'keys': transes}


def name_groups(kf, old, new_names):
    """Turns every key line of group `old` into the same key for each of `new_names`."""
    keys = kf.text_keys()
    for i, (t, text) in enumerate(keys):
        lines = []
        for line in text.replace('\r', '').split('\n'):
            if ':' in line and line.split(':', 1)[0].strip().lower() == old:
                rest = line.split(':', 1)[1]
                lines.extend(name + ':' + rest for name in new_names)
            else:
                lines.append(line)
        keys[i] = (t, '\r\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('vanilla_kf')
    parser.add_argument('--reanimation', default=find_reanimation())
    parser.add_argument('--report', action='store_true', help='only print the comparison')
    args = parser.parse_args()
    if not args.reanimation:
        sys.exit('ReAnimation not found next to this mod, pass --reanimation')

    sys.path.insert(0, os.path.join(args.reanimation, 'Sources', 'Tools', 'FBACompat'))
    global KF, E
    from nifkf import KF
    import kfeval as E

    idles = effective_idles(args.vanilla_kf, os.path.join(args.reanimation, 'Animations', 'xbase_anim.1st'))
    base_kf, _, base_start, _ = idles['idle']
    base = Track(base_kf, base_start)

    spell = KF.load(os.path.join(POSE_DIR, 'xSpellWheelPose.kf'))
    weapon = KF.load(os.path.join(POSE_DIR, 'xWeaponWheelPose.kf'))
    spell_start = group_ranges(spell)[SPELL_POSE][0]
    weapon_start = group_ranges(weapon)[WEAPON_POSE][0]
    pose_neck = Track(weapon, weapon_start, base).neck()
    drift = E.qangle(pose_neck[0], Track(spell, spell_start, base).neck()[0])
    if drift > 1.0:
        sys.exit(f'the two poses stand on different chests ({drift:.1f} deg apart); they no longer share corrections')

    necks = {}
    for idle, (kf, path, start, stop) in sorted(idles.items()):
        neck, wander = loop_neck(kf, start, stop, base)
        angle = E.qangle(pose_neck[0], neck[0])
        over = angle > THRESHOLD and path != args.vanilla_kf
        print(f'{idle:20s} {angle:5.1f} deg (loop +-{wander:4.1f})  {os.path.basename(path)}{"  *" if over else ""}')
        if over:
            necks[idle] = neck

    groups = cluster(necks)
    fixes = {}
    for n, members in enumerate(groups, 1):
        neck = average([necks[m] for m in members])
        spread = max(E.qangle(neck[0], necks[m][0]) for m in members)
        print(f'fix{n}: {", ".join(members)} (within {spread:.1f} deg of their average)')
        for m in members:
            fixes[m] = f'fix{n}'
    if args.report:
        return

    for old in glob.glob(os.path.join(POSE_DIR, 'x*WheelPose_*.*')) + glob.glob(os.path.join(POSE_DIR, 'xWheelPoseFix*')):
        os.remove(old)

    for n, members in enumerate(groups, 1):
        fix = f'fix{n}'
        kf = KF.load(os.path.join(POSE_DIR, 'xWeaponWheelPose.kf'))
        # The spell pose's left arm next to the weapon pose's right arm: one kf for both poses.
        for bone in spell.bone_data:
            if left_arm(bone) and bone in kf.bone_data:
                kf.blocks[kf.bone_data[bone]] = ('NiKeyframeData', copy.deepcopy(spell.data(bone)))
        resolve_clavicles(kf, Track(kf, weapon_start, base), average([necks[m] for m in members]))
        names = [f'SpellWheelPose_{fix}', f'WeaponWheelPose_{fix}']
        name_groups(kf, WEAPON_POSE, names)
        stem = f'xWheelPoseFix{n}'
        kf.save(os.path.join(POSE_DIR, stem + '.kf'))
        with open(os.path.join(POSE_DIR, stem + '.yaml'), 'w') as f:
            f.write(f'# The wheel poses with their clavicles re-solved for the chest of {", ".join(members)}\n'
                    f'# (made by tools/make_pose_variants.py). Blending in: 0.05 s of game time is 0.5 s on\n'
                    f'# screen, as the wheel slows the game to 0.1 (see xWeaponWheelPose.yaml).\n'
                    f'blending_rules:\n')
            for name in names:
                f.write(f'  - from: "*"\n    to: "{name.lower()}"\n    easing: "sineInOut"\n    duration: 0.05\n')

    with open(FIXES_LUA, 'w') as f:
        f.write('-- Generated by tools/make_pose_variants.py: the corrected wheel pose\n'
                '-- (Animations/xbase_anim.1st/xWheelPoseFix<n>.kf) for each idle that turns the chest away.\n'
                '-- Idles not listed take the plain pose.\n'
                'return {\n')
        for idle in sorted(fixes):
            f.write(f"    {idle} = '{fixes[idle]}',\n")
        f.write('}\n')
    print(f'wrote {len(groups)} corrections and {os.path.relpath(FIXES_LUA, MOD)}')


if __name__ == '__main__':
    main()
