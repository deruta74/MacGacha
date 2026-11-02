# Upstream-generated HDIFF13 fixtures

Synthetic data, generated on 2026-11-02. These files contain no game data.
The handwritten HDIFF13 and Zstandard fixtures remain in the test sources.

- HDiffPatch: `sisong/HDiffPatch@06961361340085ddb2a551775dc402172b8ca67c`
  ([pinned source](https://github.com/sisong/HDiffPatch/tree/06961361340085ddb2a551775dc402172b8ca67c)).
- Compressor: Zstandard **1.5.7**, used by the upstream `hdiffz` build.
- Generator: Python 3 script below, seed **20261102**.
- Committed files: `old.bin`, `plain.hdiff`, `zstd.hdiff`. The expected `new.bin`
  is deliberately omitted; regenerate it with the script.
- Expected output: **355,000 bytes**, MD5 **4e1e17e72ca60098640bce0765bc353c**.
  Both patches were round-tripped by the supplied upstream `hpatchz` build.

| File | Bytes | SHA-256 |
|---|---:|---|
| `old.bin` | 300,000 | `85809216ec97cef0d5f81874342199a375b2389eb00c1a39a200446958519166` |
| `plain.hdiff` | 86,690 | `f8e361e64eed1b348a7450e1089ddc677617b9ede1c4b2ae071ac851591e2ee9` |
| `zstd.hdiff` | 26,304 | `6ff911b4d5a9d66d44f9fe29b419c8cc22e498eb120a75c43bf29f20b339e265` |

`plain.hdiff` starts with `HDIFF13&` and an empty compressor name.
`zstd.hdiff` starts with `HDIFF13&zstd`. Its new-data section has 86,432 decoded
bytes and 26,039 encoded bytes, with three entropy-compressed Zstandard blocks
(block type 2): 9,643, 5,436 and 10,942 encoded bytes. These are real compressed
blocks, rather than the raw/RLE blocks used by the handwritten tests.

`HDiffUpstreamTests` reconstructs the output through the Swift API and checks
its exact size and MD5. Cases run with public defaults and with internal
257-byte input / 1,024-byte output buffers, so all three compressed blocks
cross decoder buffer boundaries. Verification reads in 997-byte chunks. A
truncated patch is created in the test's temporary contained filesystem by
removing the final byte of `zstd.hdiff`; it is not a fourth committed fixture.

## Exact patch commands

The supplied generation commands used `old` and `new` as the input names:

```sh
hdiffz -f old new plain.hdiff
hdiffz -f -c-zstd-21-24 old new zstd.hdiff
```

To reproduce from the script below in an empty scratch directory, save it as
`generate.py`, run `python3 generate.py`, then copy `old.bin` to `old` and
`new.bin` to `new` before running those commands. With the pinned upstream
executables on PATH, verify the generated patches with:

```sh
hpatchz -f old.bin plain.hdiff out-plain.bin
hpatchz -f old.bin zstd.hdiff out-zstd.bin
cmp new.bin out-plain.bin
cmp new.bin out-zstd.bin
```

## Complete deterministic generator

```python
import random
r=random.Random(20261102)
words=[bytes(r.choice(b'abcdefghijklmnopqrstuvwxyz') for _ in range(r.randint(3,9))) for _ in range(400)]
def text(n):
    out=bytearray()
    while len(out)<n: out+=r.choice(words)+b' '
    return bytes(out[:n])
old=text(150_000)+bytes(r.getrandbits(8) for _ in range(40_000))+text(110_000)
new=bytearray(old)
new[1000:1000]=text(5000)
new[60_000:62_000]=bytes(r.getrandbits(8) for _ in range(2000))
del new[200_000:230_000]
new+=text(80_000)
open('old.bin','wb').write(old); open('new.bin','wb').write(bytes(new))
```
