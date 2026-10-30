<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
Synthetic WebM fixtures only, with VP9 Profile 0 and silent Opus audio.
`vp9-tiny.webm` is the supplied 64x48, 10 fps, two-second parser fixture.
`vp9-decode.webm` is generated locally at 128x128 because this Mac's decoder refuses 64x48 session creation.
The decode test also packs a hidden keyframe and a shown keyframe into a superframe in memory.

Generation: `ffmpeg -f lavfi -i testsrc2=size=128x128:rate=10:duration=2 -f lavfi -i anullsrc=r=48000:cl=mono -t 2 -c:v libvpx-vp9 -profile:v 0 -pix_fmt yuv420p -deadline good -cpu-used 2 -b:v 120k -lag-in-frames 16 -auto-alt-ref 1 -c:a libopus vp9-decode.webm`
