# 0.2.7 preparation — not a release approval

## Qualified local candidate

Wine `11.20-macgacha1-preview4`, SHA-256:
`c3b9d33653c6585fed36edf819e6239cae5a385f87fd4f0e2d093c848f15ec7e`.

Two independent source SDK/Wine builds followed by deterministic finalization produced identical archives. All 4147 runtime inventory entries matched. Twenty pinned source packages supply the SDK and build tools. TLS trust anchors, fonts, wineboot, Windows execution and actual synthetic H.264/MP4 decoding passed isolated probes.

Local Global Genshin 7.2 and ZZZ 3.3 reached startup/login screens with DXMT and D3DMetal. Genshin D3DMetal initially stopped at the terms dialog without accepting it automatically. The owner subsequently reported one hour of stable Genshin gameplay with D3DMetal, FPS Unlock 120 and working Surround on 2026-11-11. This is user-reported gameplay/audio evidence, distinct from automated probes. ZZZ/DXMT Game Mode was On on repeat without code changes. The earlier Off observation has no proven root cause.

Private screenshots, logs, account data and local machine inventories must not be committed.

## Remaining before release

- Complete and review the Dependencies design separately. The source-Wine build changes do not modify that UI.
- Integrate the candidate into supported launcher runtime profiles and catalog bindings. Diagnostic app overrides used for local tests are not shipped integration.
- Verify automatic Wine selection and advanced compatible-version selection, existing installations, failed-update preservation and explicit rollback against the final integrated build. Retain historical IDs and bytes.
- Complete a long ZZZ session and qualify any additional advertised editions/backends. CN and Star Rail are not qualified by this matrix.
- Review the exact distributable source closure and per-component notices. Keep Apple graphics separate. Optional feature differences remain documented in SOURCE-NOTICE.md.
- Complete the 0.2.7 user-facing release notes after the final scope lands. The current file is explicitly a draft.
- Rebuild and check the final app after the design/integration changes, then prepare signed update metadata using the established release process.

Pushing this branch does not publish a runtime, modify the live catalog, merge a PR or release 0.2.7.

## Packaging check — 2026-11-11

The retained preview4 runtime and source-delivery archives passed SHA-256 and archive-member validation. Their unpacked runtime/source inventories matched the saved receipts. Packaged Wine probes were rerun successfully with original SDKs denied.

The complete local test script passed using a SwiftPM scratch directory and Xcode derived data outside Documents. An initial run inside the existing Documents `.build` failed code signing because of Finder metadata. Package tests, app tests, string checks and the Release build passed on the clean path. No Swift source compiler warnings were emitted. Xcode emitted AppIntents metadata and dependency-scan warnings.

A local 0.2.7 DMG was built and verified, including strict app code-signature verification, embedded framework loading and `hdiutil verify`. It is a preparation artifact with the current UI/runtime catalog, not the final release. Rebuild after Dependencies design and runtime integration.
