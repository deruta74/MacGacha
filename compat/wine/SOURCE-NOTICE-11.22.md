# MacGacha source-built Wine 11.22 candidate

Base: official Wine `wine-11.22`, commit
`9f8c4ae4d35c7ff4153267aba9618c026f5f5583`.
The WineHQ source archive and detached release signature are recorded in
`source-runtime-11.22.lock.json`. Wine remains LGPL-2.1-or-later.
See COPYING.LIB, AUTHORS and NOTICES.md in the runtime.

The compatibility delta carries the paired MSync client/server, ARM64 server
support for x86 clients, D3DMetal bridge, FSR bridges, cursor handling and
resource lifetime corrections from the exact Wine 11.20 fork input retained
in the lock. Its complete original archive accompanies the candidate sources.
The macOS driver reconciles those changes with Wine 11.22 IOSurface rendering.
Protocol tables are regenerated from the Wine 11.22 protocol plus the retained
extensions. The independent opt-in Dock icon patch is also applied.
MR 11824 is already upstream. No crypt32 correction is applied.

Only the three named build/staging scripts are copied from the fork archive.
Runtime source changes enter through the checksum-pinned compatibility delta.
The original inputs, complete delta, build scripts and receipts accompany the
candidate under source-inputs. This is a new build and requires qualification.

Dependencies and tools are built from the pinned source-build.lock.json inputs.
Their configuration and source-delivery limits remain documented in
SOURCE-NOTICE.md. Runtime dependency notices remain under share/licenses and
lib/GStreamer.framework/Versions/1.0/share/licenses.

Apple graphics and sidecars are excluded. DXMT and consented D3DMetal are
separate inputs. The Wine 11.20 Surround module is not qualified for this ABI
and must not be loaded into Wine 11.22. A separate rebuild is required.
MacGacha build orchestration and wrapper are GPL-3.0-only with the project
NOTICE term. This local candidate does not authorize publication.
