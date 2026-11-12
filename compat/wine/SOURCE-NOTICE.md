# MacGacha source-built Wine candidate

Wine 11.20 fork: https://github.com/dbc-hbin/wine-yaagl-d3dmetal
Commit: a05983676741c558ac46937a29a93e02b38de8c7.
Wine remains LGPL-2.1-or-later; see COPYING.LIB, AUTHORS and NOTICES.md.
The opt-in Dock icon patch and its source are in compat/dock-icon.
MacGacha build orchestration is GPL-3.0-only with the project NOTICE term.

Dependencies are built from the source archives pinned in source-build.lock.json,
not copied from the preview3 donor. Original source archives, build driver,
configuration arguments and receipts accompany the candidate under
source-inputs/dependencies. Runtime notices are retained under share/licenses
and lib/GStreamer.framework/Versions/1.0/share/licenses.

The explicit media build enables playback, typefinding, audio/video conversion,
MP4/Matroska/AVI/WAV parsing and FFmpeg decoding. It does not reproduce the
entire upstream GStreamer distribution. FFmpeg GPL/nonfree options, encoders,
network access, external optional dependencies and x86 assembly are disabled.
FreeType optional HarfBuzz/Brotli/PNG/bzip2 support and GnuTLS optional IDN,
PKCS#11 and compression integrations are disabled in this initial candidate.
These feature choices require qualification; they are not claimed equivalent
to preview3. Other optional dependencies absent from the source lock (including
libxml2/libxslt) are not supplied by this SDK. See the pinned per-package
configuration arguments and compare Wine's generated feature configuration
when qualifying a new candidate.

Apple graphics are excluded. DXMT/D3DMetal and ABI-scoped crypt32/Surround
overlays are separate inputs. This local candidate is not a public release;
licensing/source-delivery review and runtime qualification remain separate.
