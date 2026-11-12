# Dependency source delivery: preview3 audit

The 2026-11-10 audit of the exact locally tested preview3 found **88 root
library entries** and **1059 framework entries**. Counts include aliases,
metadata and licenses, not 1147 distinct software packages. The archive
SHA-256 is `9a884ada52a8b35873416ee17fd836d21fbaece5d9e3ad2e4c10781d4e46b94b`.

## Evidence and limits

| Input | Established | Still missing |
| --- | --- | --- |
| Root `lib/*.dylib` | Exact donor pin and packaged hashes | Exact source versions, patches, build recipes and per-library notices |
| GStreamer framework | Packaged file hashes, bundled `share/versions.txt` and `share/licenses` | Binary-to-recipe correspondence, exact configuration and full source closure |
| Cerbero 1.28.7 | Tag resolves to commit `e0e7007e210dab3e2f3e898939e2cfe1fd02f123`; pinned recipe archive includes patches | Recipes alone are not their referenced source archives |
| GStreamer 1.28.7, FFmpeg 7.1, framework zlib 1.3.1 | Source archives match checksums in pinned Cerbero recipes | Remaining recipes, Rust/vendor sources and configuration |

Do not infer binary versions from `inputs.lock.json` development headers.
For example, the donor has `libbrotlicommon.1.2.0.dylib`, while the header
input is Brotli 1.2.1. The framework has its own zlib 1.3.1; the root
libraries include a separate `libz.1.3.2.dylib`. These are distinct inputs.

The cached MacPorts packages did not produce byte-identical comparisons
against donor root libraries. That does **not** prove different source:
relocation/signing also changes bytes. It does mean those package sources
cannot yet be represented as verified corresponding donor source.

Framework `versions.txt` includes build tools and packages not necessarily
shipped. License directories include LGPL, GPL and permissive components;
do not label the entire payload LGPL or use a directory name as proof that
a particular binary was shipped. Preserve actual license texts when
assembling a replacement runtime.

## Next implementation stage

1. Replace unproven root dependencies with builds from exact source archives
   and pinned recipes/patches. Keep separate receipts for sources, compiler
   inputs, configuration and output files. Include transitive dependencies.
2. Build the required media payload from the pinned Cerbero recipes in an
   isolated root, retaining all fetched source archives, patches, generated
   configuration and notices. Select the required plugin set explicitly;
   account for all shipped files instead of assuming all recipes are needed.
3. Assemble the Wine source deliverable with those receipts and source
   archives. Check that every shipped dependency has a documented origin,
   license and complete corresponding build input set.
4. Build a **new candidate ID**, repeat independent-build comparison and
   TLS/font/media probes, then the real-game matrix. Replacing libraries
   invalidates preview3's qualification for the new bytes.

Source delivery remains incomplete. The audit intentionally reports this;
a successful audit exit only means the inventory and retained-source checks
passed. It is not a publication gate or permission to release binaries.
