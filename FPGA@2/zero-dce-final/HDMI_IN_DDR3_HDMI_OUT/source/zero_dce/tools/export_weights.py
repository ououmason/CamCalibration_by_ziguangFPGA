"""Export the author's Zero-DCE++ state_dict; no PyTorch installation required.

python source/zero_dce/tools/export_weights.py ../Epoch99.pth
Run from HDMI_IN_DDR3_HDMI_OUT. Only a whitelisted tensor unpickler is used.
The generated files are synthesis inputs, not a quality/RTL validation report.
"""
import argparse
import collections
import hashlib
import io
import json
import pickle
from pathlib import Path
import zipfile

import numpy as np

CHANNELS = [(3, 32), (32, 32), (32, 32), (32, 32),
            (64, 32), (64, 32), (64, 3)]
ACT_FRAC = 10
WEIGHT_FRAC = 12
LANES = 8


def load_state_dict(path):
    """Read only plain float32 tensor state_dicts, including CUDA-saved tensors."""
    with zipfile.ZipFile(path) as archive:
        pkl = next(n for n in archive.namelist() if n.endswith('/data.pkl'))
        prefix = pkl[:-len('data.pkl')]

        def rebuild(storage, offset, shape, stride, *unused):
            # Copy before the zip closes. Preserve torch's element strides.
            return np.ndarray(tuple(shape), dtype='<f4', buffer=storage,
                              offset=int(offset) * 4,
                              strides=tuple(int(s) * 4 for s in stride)).copy()

        class TensorReader(pickle.Unpickler):
            def find_class(self, module, name):
                if (module, name) == ('collections', 'OrderedDict'):
                    return collections.OrderedDict
                if module == 'torch._utils' and name in (
                        '_rebuild_tensor_v2', '_rebuild_tensor'):
                    return rebuild
                if (module, name) == ('torch', 'FloatStorage'):
                    return 'float32'
                raise ValueError(f'Unsupported checkpoint object {module}.{name}')

            def persistent_load(self, ident):
                kind, dtype, key, location, count = ident[:5]
                if kind != 'storage' or dtype != 'float32':
                    raise ValueError(f'Unsupported tensor storage: {ident}')
                data = archive.read(prefix + 'data/' + key)
                if len(data) != int(count) * 4:
                    raise ValueError('Invalid float32 storage length')
                return data

        return TensorReader(io.BytesIO(archive.read(pkl))).load()


def quantize(value, fractional, bits, name):
    scaled = np.rint(np.asarray(value, dtype=np.float64) * (1 << fractional))
    if not np.all(np.isfinite(scaled)):
        raise ValueError(f'{name}: non-finite parameters')
    lower, upper = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if np.any(scaled < lower) or np.any(scaled > upper):
        raise ValueError(f'{name}: cannot fit Q{fractional} in {bits} bits; '
                         'change both exporter and RTL rather than clip weights')
    return scaled.astype(np.int64)


def write_hex(path, values, bits):
    mask = (1 << bits) - 1
    digits = (bits + 3) // 4
    path.write_text(''.join(f'{int(v) & mask:0{digits}x}\n' for v in values),
                    encoding='ascii')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'weights')
    args = parser.parse_args()
    state = load_state_dict(args.checkpoint)
    args.output.mkdir(parents=True, exist_ok=True)
    dw, db, pw, pb, layers = [], [], [[] for _ in range(LANES)], [], []
    expected = set()
    for index, (cin, cout) in enumerate(CHANNELS, 1):
        tensors = {}
        for suffix, shape in [('depth_conv.weight', (cin, 1, 3, 3)),
                              ('depth_conv.bias', (cin,)),
                              ('point_conv.weight', (cout, cin, 1, 1)),
                              ('point_conv.bias', (cout,))]:
            key = f'e_conv{index}.{suffix}'
            expected.add(key)
            if key not in state or state[key].shape != shape:
                raise ValueError(f'Missing/wrong shape for {key}, expected {shape}')
            bias = suffix.endswith('bias')
            tensors[suffix] = quantize(state[key], ACT_FRAC + WEIGHT_FRAC
                                      if bias else WEIGHT_FRAC,
                                      32 if bias else 16, key)
        layers.append(dict(layer=index, cin=cin, cout=cout, dw_base=len(dw),
                           db_base=len(db), pw_base=len(pw[0]), pb_base=len(pb)))
        dw.extend(tensors['depth_conv.weight'].reshape(-1))
        db.extend(tensors['depth_conv.bias'])
        weight = tensors['point_conv.weight'].reshape(cout, cin)
        bias = tensors['point_conv.bias']
        for group in range((cout + LANES - 1) // LANES):
            # ROM lane 0 is the least significant lane of the packed bias ROM.
            packed_bias = 0
            for lane in range(LANES):
                oc = group * LANES + lane
                pw[lane].extend(weight[oc] if oc < cout else [0] * cin)
                packed_bias |= (int(bias[oc]) & 0xffffffff if oc < cout else 0) << (32 * lane)
            pb.append(packed_bias)
    if set(state) != expected:
        raise ValueError(f'Unexpected checkpoint keys: {set(state) - expected}')
    write_hex(args.output / 'dw_weight.mem', dw, 16)
    write_hex(args.output / 'dw_bias.mem', db, 32)
    for lane in range(LANES):
        write_hex(args.output / f'pw_weight_{lane}.mem', pw[lane], 16)
    write_hex(args.output / 'pw_bias.mem', pb, 256)
    write_hex(args.output / 'tanh.mem',
              np.rint(np.tanh(np.arange(513) / 64.0) * (1 << 14)), 16)
    manifest = dict(
        architecture='Official Zero-DCE++: 32 channels, 7 separable layers, 8 shared-curve iterations',
        source='https://github.com/Li-Chongyi/Zero-DCE_extension',
        license='CC BY-NC 4.0 (author checkpoint)',
        checkpoint_sha256=hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
        fractional_bits=dict(activation=ACT_FRAC, weight=WEIGHT_FRAC,
                             bias=ACT_FRAC + WEIGHT_FRAC, curve=14),
        lanes=LANES, layers=layers, parameter_count=sum(v.size for v in state.values()),
        dw_words=len(dw), db_words=len(db), pw_rows=len(pw[0]), pb_rows=len(pb),
        note='Generated initialization data. Quantization/low-resolution quality requires user validation.')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Exported {manifest["parameter_count"]} parameters to {args.output}')
    print(f'SHA256 {manifest["checkpoint_sha256"]}')


if __name__ == '__main__':
    main()
