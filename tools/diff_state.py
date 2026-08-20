#!/usr/bin/env python3
"""Compare two machine-state dumps region by region.

    diff_state.py <mame_state.txt> <rtl_state.txt>

Only the regions present in both are compared, so the RTL dump can carry extra
ones (work RAM) that the MAME dumper does not write.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tp84video as tp


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    _, a = tp.load_state(sys.argv[1])
    _, b = tp.load_state(sys.argv[2])
    tag = os.path.basename(sys.argv[2])

    # Everything the video model reads is compared; there is no stack region
    # in this set, because the tp84 dumper captures video state only.
    skip = {}
    bad_total = 0
    detail = []
    for name in ('BGVIDEORAM', 'FGVIDEORAM', 'BGCOLORRAM', 'FGCOLORRAM',
                 'SPRITERAM', 'PALETTEBANK', 'SCROLLX', 'SCROLLY'):
        if name not in a or name not in b:
            continue
        x, y = a[name], b[name]
        n = min(len(x), len(y))
        ign = skip.get(name, ())
        bad = [i for i in range(n) if x[i] != y[i] and i not in ign]
        if bad:
            bad_total += len(bad)
            detail.append(f'{name}: {len(bad)}/{n}  first ' +
                          ', '.join(f'{i:03x}:{x[i]:02x}!={y[i]:02x}' for i in bad[:6]))
    if bad_total == 0:
        print(f'OK   {tag}: RAM identical to MAME')
        return 0
    print(f'FAIL {tag}: {bad_total} bytes differ')
    for d in detail:
        print('  ', d)
    return 1


if __name__ == '__main__':
    sys.exit(main())
