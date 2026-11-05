<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Runtime catalog releases

`runtime-catalog.json` is the independently published dependency catalog for clients that implement `macgacha-runtime-v1`. One app update is needed to add this capability. Later compatible Wine/graphics bundle or helper revisions can be published without another DMG. Libraries linked into MacGacha and new launch/ABI compatibility profiles still require an application release.

## Publish a compatible dependency update

1. Build and test the component through its existing reproducible workflow. Publish its binary and required corresponding source/license assets first.
2. Add a new component identity and, where needed, a new bundle identity to this catalog. Never change a descriptor or binding under an existing ID. Preserve historical entries. Wine and graphics are selected together as a bundle.
3. Bind new bundles to an existing compiled compatibility profile only after validating the ABI and launch behavior. Bind optional helpers to supported profiles. The catalog cannot add executable commands or launch recipes. Changes outside the compiled contract need a new app/profile contract.
4. Update the relevant recommendation and increment `revision`. Run `python3 -I scripts/test-runtime-catalog.py` and `python3 -I scripts/check-runtime-catalog.py RuntimeCatalog/runtime-catalog.json --previous <previous-catalog.json> --verify-assets`.
5. Merge the reviewed catalog PR after CI. The Runtime catalog workflow waits for green main CI, validates immutable history and checks every new archive's size and SHA-256, publishes an immutable `runtime-catalog-v1-r<revision>` snapshot, then promotes the `runtime-catalog-v1` channel asset. These releases are never marked Latest. A failed promotion can be retried manually on main. The retry uses the highest published immutable snapshot if the channel asset is missing, accepts an identical revision only for recovery, and rejects older revisions. Incomplete snapshot uploads can be completed without overwriting existing historical bytes.

The HTTPS channel asset is `https://github.com/deruta74/MacGacha/releases/download/runtime-catalog-v1/runtime-catalog.json`. Repository maintainers control this trust boundary. Clients accept at most 1 MiB and bound metadata requests to 20 seconds. They retain validated local metadata and reject revision regression, modified historical identities, unsupported profiles and incompatible selections. A failing/offline refresh does not replace the working catalog or selected versions.

## Activation and rollback

Checking metadata does not install or activate anything. Set Up installs the selected target beside existing versions. Only verified successful installation permits activation. A failed download, declined consent or cancelled setup leaves the prior version selected. Previous versions remain until explicitly removed.

Runtimes allows selecting an installed earlier bundle/helper and keeping that selection pinned. The selected version and versions held by running or recoverable sessions cannot be removed. Returning to the recommended version is explicit; refreshing the catalog never cancels a rollback. Existing Apple consent, FPS acknowledgment and opt-in Surround settings remain in force.

To withdraw a bad recommendation, publish a higher catalog revision recommending an earlier retained version. Do not overwrite historical component identities, erase the bad revision's history or reduce the catalog revision. Existing users retain their current choice until they explicitly change it.
