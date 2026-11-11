# Synthetic H.264 fixture

`red-h264.mp4.b64` is base64-encoded synthetic content: two solid-red
32x32 H.264 frames in an MP4 container. It contains no game or user data.
Generated locally on 2026-11-10 using FFmpeg/libx264:

```sh
ffmpeg -f lavfi -i color=c=red:s=32x32:r=10:d=0.2 -c:v libx264 -pix_fmt yuv420p -preset ultrafast -an -movflags +faststart red.mp4
```

Generation is not part of the build. Qualification decodes the committed
bytes with the candidate's MP4 parser, H.264 parser/decoder and RGBA converter
and requires exactly two delivered video buffers plus end-of-stream.
This is a bounded smoke test, not coverage of every game codec or audio path.
