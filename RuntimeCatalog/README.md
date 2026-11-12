<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Runtime catalog releases

`runtime-catalog.json` is the independently published dependency catalog for clients that implement `macgacha-runtime-v1`. One app update is needed to add this capability. Later compatible Wine/graphics bundle or helper revisions can be published without another DMG. Libraries linked into MacGacha and new launch/ABI compatibility profiles still require an application release.

## Publish a compatible dependency update

1. Build and test the component through its existing reproducible workflow. Publish its binary and required corresponding source/license assets first.
2. Add a new component identity and, where needed, a new bundle identity to this catalog. Never change a descriptor or binding under an existing ID. Preserve historical entries. Wine and graphics are selected together as a bundle.
3. Bind new bundles to an existing compiled compatibility profile only after validating the ABI and launch behavior. Bind optional helpers to supported profiles. The catalog cannot add executable commands or launch recipes. Changes outside the compiled contract need a new app/profile contract.
4. Update the relevant recommendation and increment `revision`. Run `python3 -I scripts/test-runtime-catalog.py` and `python3 -I scripts/check-runtime-catalog.py RuntimeCatalog/runtime-catalog.json --previous <previous-catalog.json> --verify-assets`.
5. Merge the reviewed catalog PR after CI. The Runtime catalog workflow waits for green main CI, validates immutable history and checks every new archive's size and SHA-256 (consent-required Apple payloads use GitHub’s stored-asset digest without downloading the binary), publishes an immutable `runtime-catalog-v1-r<revision>` snapshot, then promotes the `runtime-catalog-v1` channel asset. These releases are never marked Latest. A failed promotion can be retried manually on main. The retry uses the highest published immutable snapshot if the channel asset is missing, accepts an identical revision only for recovery, and rejects older revisions. Incomplete snapshot uploads can be completed without overwriting existing historical bytes.

The HTTPS channel asset is `https://github.com/deruta74/MacGacha/releases/download/runtime-catalog-v1/runtime-catalog.json`. Repository maintainers control this trust boundary. Clients accept at most 1 MiB and bound metadata requests to 20 seconds. They retain validated local metadata and reject revision regression, modified historical identities, unsupported profiles and incompatible selections. A failing/offline refresh does not replace the working catalog or selected versions.

## Activation and rollback

Automatic dependency updates are enabled by default and use the global serialized launch preferences. Only installed unpinned backend/helper selections follow new recommendations. Each update installs beside the working version, verifies the receipt and waits for every game, launch, recovery, game operation and foreground runtime reservation before activation. Failure or cancellation keeps the previous selection and retries at the next catalog check. Downloads, extraction and assembly use an isolated contained staging store. Play continues on the active version. Short publication exclusions recheck immutable source receipts and imported lineage, then move the prepared trees into the active store.

Unaccepted Apple terms use the existing Set Up flow only while automatic updates are enabled. An incompatible pinned helper prevents a bundle switch. Wine-only changes preserve an imported GPTK framework after normal signature verification. A change of D3DMetal version is offered instead, with declines persisted per graphics version. The offer remains reachable after declining.

Replacement records in contained `RuntimeCatalog/automatic-updates.json` retain the previous versions across restarts. A normal, verified session end after at least two minutes of confirmed running on the new bundle/helper qualifies cleanup, including verified ends detected after the launcher was closed. Failed launches and recovery-only ends do not qualify. Cleanup uses normal runtime removal exclusions and keeps selected, pinned, session-held, unrelated manually installed or otherwise referenced versions and shared components. Disabling updates preserves pending cleanup. Pinning a family cancels its cleanup.

Returning a pinned bundle or helper to Automatic retains its installed previous version as a replacement when the new active version differs and is the recommendation. This applies both to Use for an installed recommendation and to Set Up followed by activation. The replacement record is written only after successful durable activation and a fresh receipt scan, while the catalog mutation reservation is still held. Failed or cancelled activation creates no record. Unpinning the same version creates no record. The previous version remains installed until the next qualifying session on the new version, under the existing cleanup exclusions. Pinning again cancels this pending cleanup.

Dependencies allows selecting and pinning installed earlier versions. Refresh never cancels a pin. Explicit removal of an idle selected version keeps its selection and pin so Set Up can reinstall that exact version. Session/recovery pins remain protected. Existing Apple consent, FPS acknowledgment and opt-in Surround settings remain in force.

To withdraw a bad recommendation, publish a higher catalog revision recommending an earlier retained version. Do not overwrite historical component identities, erase the bad revision's history or reduce the catalog revision. Unpinned users with automatic updates enabled can follow the replacement recommendation. Pinned users retain their explicit choice.

## Catalog authentication

The app verifies a detached Ed25519 signature over the exact downloaded JSON bytes.
The channel and immutable revision releases include `runtime-catalog.json.sig`.
`RUNTIME_CATALOG_PUBLIC_ED_KEYS` embeds an ordered comma-separated list of accepted
base64 public keys. The release workflow rejects missing or placeholder keys.
The catalog signing step alone receives `RUNTIME_CATALOG_ED_PRIVATE_KEY` and
requires its public key to appear in that list. The private key is a base64-encoded 32-byte Ed25519 seed. Rotation adds the new key before
removing the old one. Cached signed bytes are verified again on startup. Unsigned
0.2.x caches retain only selections already trusted by the compiled baseline.
A fresh 0.2.x client that never cached r2 rejects r3 and remains on r1.

Debug local catalogs require the same detached signature beside the JSON file.
Orphaned staging stores are reclaimed only after acquiring their stage lock.
Uncertain publication keeps its staging tree for recovery instead of deleting it.

`sign-runtime-catalog.swift` creates the sidecar and `verify-runtime-catalog.swift`
verifies existing immutable signatures on retry. Signature bytes need not be
identical across valid signing invocations. `check-runtime-catalog-keys.py`
validates the embedded key list before release preparation.
