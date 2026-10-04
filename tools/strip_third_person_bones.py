#!/usr/bin/env python3
"""Takes the bones the 3rd-person skeleton doesn't have out of the 3rd-person wheel poses.

Animations/xbase_anim/x{Spell,Weapon}WheelPose.kf started as copies of the 1st-person poses, made
on a skeleton with more finger joints and the toes. OpenMW warns about every bone a kf keys that the
skeleton lacks ("addAnimSource: can't find bone ..."), so those bones' tracks are dropped: their
name, controller and keyframe data. The bones that remain keep their keys as they are. Safe to
rerun, e.g. after copying freshly exported poses over.

The skeleton is vanilla meshes/xbase_anim.nif, read from Morrowind.bsa or from a copy extracted
from it. Reading and writing the kf goes through ReAnimation's nifkf.py, found next to this mod as
in make_pose_variants.py.

Usage: strip_third_person_bones.py <Morrowind.bsa or xbase_anim.nif> [--reanimation DIR]
"""

import argparse
import glob
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.normpath(os.path.join(HERE, '..'))
POSE_DIR = os.path.join(MOD, 'Animations', 'xbase_anim')
POSES = ['xSpellWheelPose.kf', 'xWeaponWheelPose.kf']
SKELETON = 'meshes\\xbase_anim.nif'


def find_reanimation():
    for path in glob.glob(os.path.join(MOD, '..', '*', 'Sources', 'Tools', 'FBACompat', 'nifkf.py')):
        return os.path.normpath(os.path.join(os.path.dirname(path), '..', '..', '..'))
    return None


def read_from_bsa(path, name):
    """A file's bytes from a Morrowind (TES3) BSA, by its path in there, case-insensitively."""
    with open(path, 'rb') as f:
        version, hash_offset, count = struct.unpack('<3I', f.read(12))
        if version != 0x100:
            sys.exit(f'{path} is not a Morrowind BSA')
        table = f.read(hash_offset)  # sizes and offsets, name offsets, names
        records = struct.unpack_from(f'<{2 * count}I', table, 0)
        name_offsets = struct.unpack_from(f'<{count}I', table, 8 * count)
        names = 12 * count
        for i in range(count):
            p = names + name_offsets[i]
            if table[p:table.index(b'\0', p)].decode('latin1').lower() == name.lower():
                size, offset = records[2 * i], records[2 * i + 1]
                f.seek(12 + hash_offset + 8 * count + offset)
                return f.read(size)
    sys.exit(f'{name} is not in {path}')


def node_names(data):
    """The names of a NetImmerse 4.0.0.2 file's NiNodes, lower case."""
    if not data.startswith(b'NetImmerse File Format, Version 4.0.0.2'):
        sys.exit('the skeleton is not a Morrowind NIF')
    names = set()
    for m in re.finditer(rb'NiNode', data):
        start = m.start() - 4
        if start < 0 or struct.unpack_from('<I', data, start)[0] != len(m.group()):
            continue
        n = struct.unpack_from('<I', data, m.end())[0]
        names.add(data[m.end() + 4:m.end() + 4 + n].decode('latin1').lower())
    return names


def chain(kf, first):
    out = []
    while first >= 0:
        out.append(first)
        first = kf.blocks[first][1]['next']
    return out


def strip(kf, keep):
    """Drops the tracks of the bones not in `keep` and relinks both chains around them. Returns the
    names dropped."""
    helper = kf.blocks[0][1]
    extras = chain(kf, helper['extra'])
    ctrls = chain(kf, helper['ctrl'])
    # Names and controllers pair up in order, as in KF._index.
    names = [e for e in extras if kf.blocks[e][0] == 'NiStringExtraData']
    if len(names) != len(ctrls):
        sys.exit('bone names and controllers don\'t pair up')
    drop, dropped = set(), []
    for e, c in zip(names, ctrls):
        name = kf.blocks[e][1]['value']
        if name.lower() not in keep:
            dropped.append(name)
            drop.update((e, c))
            if kf.blocks[c][1]['data'] >= 0:
                drop.add(kf.blocks[c][1]['data'])
    if not drop:
        return dropped

    def relink(old, field):
        kept = [b for b in old if b not in drop]
        helper[field] = kept[0] if kept else -1
        for b, after in zip(kept, kept[1:] + [-1]):
            kf.blocks[b][1]['next'] = after

    relink(extras, 'extra')
    relink(ctrls, 'ctrl')

    remap, blocks = {}, []
    for i, block in enumerate(kf.blocks):
        if i not in drop:
            remap[i] = len(blocks)
            blocks.append(block)
    for t, p in blocks:
        if not isinstance(p, dict):  # keyframe data, which refers to nothing
            continue
        for field in ('extra', 'ctrl', 'next', 'data', 'target'):
            if field in p and p[field] >= 0:
                if p[field] in drop:
                    sys.exit(f'a {t} that stays refers to a dropped block')
                p[field] = remap[p[field]]
    kf.blocks = blocks
    kf._index()
    return dropped


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('skeleton', help='Morrowind.bsa, or xbase_anim.nif extracted from it')
    parser.add_argument('--reanimation', default=find_reanimation())
    args = parser.parse_args()
    if not args.reanimation:
        sys.exit('ReAnimation not found next to this mod, pass --reanimation')
    sys.path.insert(0, os.path.join(args.reanimation, 'Sources', 'Tools', 'FBACompat'))
    from nifkf import KF

    if args.skeleton.lower().endswith('.bsa'):
        skeleton = read_from_bsa(args.skeleton, SKELETON)
    else:
        skeleton = open(args.skeleton, 'rb').read()
    keep = node_names(skeleton)
    if 'bip01' not in keep:
        sys.exit('no Bip01 in the skeleton, is it the right file?')

    for pose in POSES:
        path = os.path.join(POSE_DIR, pose)
        kf = KF.load(path)
        dropped = strip(kf, keep)
        if dropped:
            kf.save(path)
        print(f'{pose}: {len(kf.bone_data) + len(kf.dataless)} bones kept, '
              f'{len(dropped)} dropped{": " + ", ".join(dropped) if dropped else ""}')


if __name__ == '__main__':
    main()
