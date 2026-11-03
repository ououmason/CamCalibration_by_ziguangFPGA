import fs from 'node:fs';

const small = process.argv.includes('--small');
const W = small ? 32 : 1920;
const H = small ? 24 : 1080;
const dir = small ? 'sim/vectors_small' : 'rom';
const output = small ? 'sim/rgb_expected_small.hex' : 'sim/rgb_expected_full.hex';
const readHex = file => fs.readFileSync(file, 'utf8').trim().split(/\s+/);
const source = Uint8Array.from(readHex(`${dir}/source.hex`), x => parseInt(x, 16));
const green = small ? Uint8Array.from(source, x => x ^ 0x5a) : null;
const blue = small ? Uint8Array.from(source, x => 255 - x) : null;
const map = readHex(`${dir}/map.hex`).map(x => [
    BigInt(`0x${x.slice(6)}`), BigInt(`0x${x.slice(0, 6)}`)
]);
const gx = [];
const gy = [];
for (let x = 0; x < W; x += 16) gx.push(x);
for (let y = 0; y < H; y += 16) gy.push(y);
if (gx.at(-1) !== W - 1) gx.push(W - 1);
if (gy.at(-1) !== H - 1) gy.push(H - 1);
if (map.length !== gx.length * gy.length || source.length !== W * H)
    throw Error('ROM and source dimensions do not match');

const result = Buffer.alloc(W * H);
const resultG = small ? Buffer.alloc(W * H) : null;
const resultB = small ? Buffer.alloc(W * H) : null;
const interpolate = (src, x0, y0, fx, fy) => {
    const a = src[y0 * W + x0];
    const b = src[y0 * W + x0 + 1];
    const c = src[(y0 + 1) * W + x0];
    const d = src[(y0 + 1) * W + x0 + 1];
    const sum = a * (4096 - fx) * (4096 - fy) + b * fx * (4096 - fy) +
                c * (4096 - fx) * fy + d * fx * fy + 8388608;
    return Math.min(255, Math.floor(sum / 16777216));
};
for (let y = 0; y < H; y++) {
    const iy = Math.floor(y / 16);
    const by = iy * 16;
    const ty = BigInt(Math.floor(((y - by) * 65536 + Math.floor((gy[iy + 1] - by) / 2)) / (gy[iy + 1] - by)));
    for (let x = 0; x < W; x++) {
        const ix = Math.floor(x / 16);
        const bx = ix * 16;
        const tx = BigInt(Math.floor(((x - bx) * 65536 + Math.floor((gx[ix + 1] - bx) / 2)) / (gx[ix + 1] - bx)));
        const i = iy * gx.length + ix;
        const corners = [map[i], map[i + 1], map[i + gx.length], map[i + gx.length + 1]];
        const weights = [
            (65536n - tx) * (65536n - ty), tx * (65536n - ty),
            (65536n - tx) * ty, tx * ty
        ];
        const u = Number((corners.reduce((v, p, k) => v + p[0] * weights[k], 0n) + 2147483648n) >> 32n);
        const v = Number((corners.reduce((v, p, k) => v + p[1] * weights[k], 0n) + 2147483648n) >> 32n);
        const x0 = u >> 12;
        const y0 = v >> 12;
        const fx = u & 4095;
        const fy = v & 4095;
        if (x0 + 1 >= W || y0 + 1 >= H) throw Error(`ROM coordinate out of range at ${x},${y}`);
        result[y * W + x] = interpolate(source, x0, y0, fx, fy);
        if (small) {
            resultG[y * W + x] = interpolate(green, x0, y0, fx, fy);
            resultB[y * W + x] = interpolate(blue, x0, y0, fx, fy);
        }
    }
}
fs.writeFileSync(output, Array.from(result, x => x.toString(16).padStart(2, '0')).join('\n') + '\n');
if (small) {
    fs.writeFileSync('sim/rgb_expected_small_g.hex', Array.from(resultG, x => x.toString(16).padStart(2, '0')).join('\n') + '\n');
    fs.writeFileSync('sim/rgb_expected_small_b.hex', Array.from(resultB, x => x.toString(16).padStart(2, '0')).join('\n') + '\n');
}
console.log(`Wrote ${output} from the current coordinate ROM`);
