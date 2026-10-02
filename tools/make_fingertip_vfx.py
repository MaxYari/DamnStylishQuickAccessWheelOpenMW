#!/usr/bin/env python3
"""Builds meshes/MaxYari/quick access wheel/fingertip.nif from vanilla meshes/e/hand01.nif.

hand01.nif is VFX_Hands, the glow the engine puts on each hand while casting
(CharacterController, attached to "Bip01 L/R Hand" with the spell's last
effect's particle texture). The wheel shows a smaller one on each fingertip, so
this copy:
  - scales the root node down to SCALE, which shrinks how far and fast the
    particles spread (the emitter works in its node's frame);
  - scales the particles' size by SIZE_SCALE in each particle controller: these
    are world-space particles, which OpenMW draws in world units whatever the
    node's scale;
  - scales each controller's birth rate by BIRTH_SCALE, as five fingertips each
    get one;
  - zeroes the translation of every other node, which in the original sets the
    particles about 7 units into the palm, so they sit on the bone instead.

Usage: make_fingertip_vfx.py <path to vanilla hand01.nif>
(extract it from Morrowind.bsa, e.g. with OpenMW's bsatool:
 bsatool extract Morrowind.bsa "meshes\\e\\hand01.nif" <dir>)
"""

import os
import re
import struct
import sys

SCALE = 0.3
SIZE_SCALE = 0.3
BIRTH_SCALE = 0.4
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "meshes", "MaxYari", "quick access wheel", "fingertip.nif")

NODE_TYPES = (b"NiNode", b"NiBSParticleNode", b"NiBSAnimationNode")


def node_transform_offset(data, block):
    """Offset of the translation in a NetImmerse 4.0.0.2 NiAVObject that starts at `block`
    (its type name's length). The scale follows the translation and the 3x3 rotation."""
    p = block + 4 + struct.unpack_from("<I", data, block)[0]  # type name
    p += 4 + struct.unpack_from("<I", data, p)[0]  # NiObjectNET name
    p += 8  # extra data and controller links
    p += 2  # flags
    return p


def controller_offsets(data, block):
    """Offsets of the initial size and the birth rate in a 4.0.0.2 NiParticleSystemController."""
    p = block + 4 + struct.unpack_from("<I", data, block)[0]  # type name
    p += 4 + 2 + 4 * 4 + 4  # NiTimeController: next, flags, frequency/phase/start/stop, target
    p += 6 * 4 + 3 * 4 + 4 * 4  # speed..planar angle variation, initial normal, initial colour
    size = p
    p += 4 + 2 * 4  # initial size, emit start and stop time
    p += 1  # reset particle system
    return size, p


def scale_float(data, offset, factor):
    struct.pack_into("<f", data, offset, struct.unpack_from("<f", data, offset)[0] * factor)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data = bytearray(open(sys.argv[1], "rb").read())
    if not data.startswith(b"NetImmerse File Format, Version 4.0.0.2"):
        sys.exit("not a Morrowind NIF")

    blocks, controllers = [], []
    for m in re.finditer(rb"Ni[A-Za-z]+", bytes(data)):
        start = m.start() - 4
        if start < 0 or struct.unpack_from("<I", data, start)[0] != len(m.group()):
            continue
        if m.group() in NODE_TYPES:
            blocks.append(start)
        elif m.group() == b"NiParticleSystemController":
            controllers.append(start)
    if not blocks:
        sys.exit("no nodes found")

    root, others = blocks[0], blocks[1:]
    translation = node_transform_offset(data, root)
    struct.pack_into("<f", data, translation + 12 + 36, SCALE)
    for block in others:
        struct.pack_into("<3f", data, node_transform_offset(data, block), 0.0, 0.0, 0.0)
    for block in controllers:
        size, birth_rate = controller_offsets(data, block)
        scale_float(data, size, SIZE_SCALE)
        scale_float(data, birth_rate, BIRTH_SCALE)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {os.path.relpath(OUT, os.path.join(HERE, '..'))}: root scale {SCALE}, "
          f"{len(others)} node offsets zeroed, {len(controllers)} particle controllers scaled")


if __name__ == "__main__":
    main()
