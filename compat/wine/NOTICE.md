# MacGacha Wine build candidate

Wine 11.20 fork: https://github.com/dbc-hbin/wine-yaagl-d3dmetal
Commit: a05983676741c558ac46937a29a93e02b38de8c7.
Wine remains LGPL-2.1-or-later; see the bundled COPYING.LIB and upstream
NOTICES.md. MacGacha's opt-in Dock icon patch lives in compat/dock-icon,
with its corresponding source and notice. MacGacha build orchestration and
wrapper are GPL-3.0-only, with the project NOTICE additional term.

This candidate includes prebuilt open-source dependency libraries selected
from the exact donor archive recorded in inputs.lock.json. Those libraries
were not rebuilt by this script. GStreamer and its plugins have individual
licenses; their upstream notices and source obligations must be satisfied
before public distribution. The source-inputs directory contains Wine
source and the MacGacha changes, not a complete source bundle for every
prebuilt dependency. This is a local qualification artifact, not a public
release authorization or claim of complete dependency-source delivery.

The separate dependency-sources.lock.json retains upstream Cerbero recipes
and selected GStreamer/FFmpeg/zlib sources for source-delivery preparation.
This partial set is not proof of correspondence to every donor binary.
The receipt-bound audit and remaining work are described in DEPENDENCIES.md.

Apple D3DMetal, Metal shader converter, graphics overlays and sidecars are
not included. DXMT/D3DMetal are separate compatibility inputs. crypt32 and
Surround remain separately qualified overlays. No installed runtime,
helper hard link or game prefix is modified by this builder.
