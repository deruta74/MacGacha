# Wish history v4.2 sources

Verified 2026-11-15. Tests use synthetic records and fake HTTP only. No real
cached links or authenticated live requests are used for verification.

## Published schema

`uigf-v4.2.schema.json` is the JSON Schema on
https://uigf.org/en/standards/uigf.html, preserved structurally with normalized
JSON indentation. Its v4.1 addition admits Star Rail collaboration types 21/22.
The v4.2 addition defines `hk4e_ugc` for Miliastra Wonderland.

The same schema is distributed by the official verifier at
https://github.com/UIGF-org/UIGF-SchemaVerify/blob/3f87dbfa4ae690b56237f867c13d4fcb0c4c4ac2/src/source/uigf-4.2-schema.json.
The published `hk4e_ugc` array places account `properties` and `required` beside
`type: array`, without `items`. The fixture is not silently corrected. Tests
validate the whole document against it and additionally validate each UGC
account against those published account properties, including string lengths,
numeric patterns, timestamps and all six operation types.

## Current API clients

All links below are pinned to Starward
`df8ae07b5ad4c9c6cb70d288488ce8073ce01478`.

- Ordinary Genshin: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/Genshin/GenshinGachaClient.cs
- Miliastra Wonderland: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/Genshin/GenshinBeyondGachaClient.cs
- Miliastra fields and integer/string handling: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/Genshin/GenshinBeyondGachaItem.cs
- Star Rail: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/StarRail/StarRailGachaClient.cs
- ZZZ: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/ZZZ/ZZZGachaClient.cs
- Query parameter names: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/GachaLogQuery.cs
- Hosts and cached page routes: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/GachaLogClient.cs
- UIGF section mapping: https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward/Features/Gacha/UIGF/UIGF4File.cs

| Game | Global / CN HTTPS hosts | Path | Selectors | Size |
| --- | --- | --- | --- | --- |
| Genshin | public-operation-hk4e-sg.hoyoverse.com / public-operation-hk4e.mihoyo.com | /gacha_info/api/getGachaLog | gacha_type 100, 200, 301, 302, 400, 500 | 20 |
| Miliastra Wonderland | same Genshin hosts | /gacha_info/api/getBeyondGachaLog | gacha_type 1000, 2000 | 5 |
| Star Rail | public-operation-hkrpg-sg.hoyoverse.com / public-operation-hkrpg.mihoyo.com | /common/hkrpg_gacha_record/api/getGachaLog | gacha_type 1, 2, 11, 12 | 20 |
| Star Rail collaboration | same Star Rail hosts | /common/hkrpg_gacha_record/api/getLdGachaLog | gacha_type 21, 22 | 20 |
| ZZZ | public-operation-nap-sg.hoyoverse.com / public-operation-nap.mihoyo.com | /common/gacha_record/api/getGachaLog | real_gacha_type 1, 2, 3, 5, 102, 103 | 20 |

Miliastra selector 1000 covers standard Odes, selector 2000 covers event Odes.
The returned `op_gacha_type` values are 1000, 2000, 20011, 20012, 20021 and
20022. They are not six independent HTTP selectors. Its cached page uses
`/genshin/event/e20250716gacha/index.html` on `gs.hoyoverse.com` or
`/hk4e/event/e20250716gacha/index.html` on `webstatic.mihoyo.com`.
Both ordinary and Beyond cached API URLs are accepted, and outbound routes
are rebuilt from the selected edition rather than fetched from the cache.

All APIs use page starting at 1 and the last string record ID as `end_id`.
Language parameters are short API codes except zh-cn/zh-tw, while UIGF account
language uses locale codes. Requests are paced at 300 ms with bounded bodies,
deadlines and cancellation. Miliastra UID and timezone must match ordinary
wishes, but its independent ID namespace is never deduplicated against them.

The ordinary Genshin character selector 400 is retained for completeness and
is deduplicated against 301. Source:
https://github.com/asphyxiaxx/gacha-records-export/blob/7076d41f5d7bbabf88a488f52fd667ed88507d32/src/main/extractors/genshin.js.

The complete-history Star Rail prefix replaced the truncated older route:
https://github.com/Scighost/Starward/commit/6be7fdcf7f266308e59e68960d97755a65f8333d.
Old cached Star Rail API paths remain accepted, but are never used outbound.

Genshin v2/v3 history page extraction is also documented by the synthetic
example at https://gist.github.com/noxiousninja/2b0eb04c521d7e937f44db38f83733bf.

## ZZZ schema discrepancy

The published v4.2 schema still enumerates only 1/2/3/5 for nap record types,
while current clients recognize re-run types 102/103. The exporter queries
all six pools and never treats a known current type as unsupported.
Returned 102/103 records are preserved verbatim to honor the raw-record and
complete-history contract. They are not relabeled as 2/3, and no record is
discarded. This is an explicit published-schema exception, not full enum
conformance. Synthetic tests prove those exports fail exactly the published
enum, then pass every other constraint using a test-only overlay that adds the
two omitted members. The committed schema fixture remains unchanged. Strict
conformance for those two record types requires an upstream schema correction
or an explicit decision to change their representation.

## Chromium cache link freshness

Verified 2026-11-16 against Chromium revision 3d6abaa84a0acd9640e9d11d1803f92c644faf1e.

- Index, EntryStore and RankingsNode layout: https://github.com/chromium/chromium/blob/3d6abaa84a0acd9640e9d11d1803f92c644faf1e/net/disk_cache/blockfile/disk_format.h
- Block headers and allocation bitmap: https://github.com/chromium/chromium/blob/3d6abaa84a0acd9640e9d11d1803f92c644faf1e/net/disk_cache/blockfile/disk_format_base.h
- Typed block addresses: https://github.com/chromium/chromium/blob/3d6abaa84a0acd9640e9d11d1803f92c644faf1e/net/disk_cache/blockfile/addr.h
- Block reuse: https://github.com/chromium/chromium/blob/3d6abaa84a0acd9640e9d11d1803f92c644faf1e/net/disk_cache/blockfile/block_files.cc
- Entry creation, key storage and last-used semantics: https://github.com/chromium/chromium/blob/3d6abaa84a0acd9640e9d11d1803f92c644faf1e/net/disk_cache/blockfile/entry_impl.cc

Freed blocks are reused, so a key's offset cannot establish freshness. The
reader follows only reachable index entries with normal state and allocated,
correctly typed blocks. It validates key bounds and the rankings back-pointer,
then compares entry creation time across every inspected version, using
last-used time only for a creation-time tie. Reaccessing an old URL does not
renew its credential, so last-used time cannot override a later creation time.
Indistinguishable timestamps with different credentials fail safely rather
than selecting by byte order. No naked data_2 scan or undocumented authkey
timestamp heuristic is used as a fallback.

Metadata and keys are bounded range reads through contained pinned descriptors.
Synthetic fixtures place a fresh key at a lower data_2 offset than an expired
one, leave unindexed freed bytes intact, exercise evicted entries, ties,
cycles, typed-address corruption, allocation errors and symlink escapes, and
prove a large sparse block file does not cause a whole-file read. No real cache
contents are committed. Read-only local header checks confirmed blockfile v2.1
indexes and the expected 36/256/1024/4096-byte block sizes in the required local
Genshin and Star Rail caches. Only aggregate/header metadata was reported.
