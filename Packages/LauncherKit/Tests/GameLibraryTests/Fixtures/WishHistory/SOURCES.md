# Wish history schema fixture

`uigf-v4.0.schema.json` is the JSON Schema published by UIGF-org at
https://uigf.org/en/standards/uigf-legacy-v4.0.html, retrieved 2026-11-15.
It is preserved structurally, with JSON indentation normalized. It is a public
standard fixture, not captured game data. Tests generate synthetic responses.

Endpoint and paging evidence was inspected in the maintained exporter:
https://github.com/asphyxiaxx/gacha-records-export/tree/7076d41f5d7bbabf88a488f52fd667ed88507d32/src/main/extractors

- Genshin `genshin.js`: Global `public-operation-hk4e-sg.hoyoverse.com`,
  CN `public-operation-hk4e.mihoyo.com`, `/gacha_info/api/getGachaLog`,
  `gacha_type` 100/200/301/302/400/500.
- Star Rail `starrail.js`: Global `public-operation-hkrpg-sg.hoyoverse.com`,
  CN `public-operation-hkrpg.mihoyo.com`, `/common/hkrpg_gacha_record/api/getGachaLog`,
  `gacha_type` 1/2/11/12, plus 21/22 on `getLdGachaLog`.
- ZZZ `zzz.js`: Global `public-operation-nap-sg.hoyoverse.com`,
  CN `public-operation-nap.mihoyo.com`, `/common/gacha_record/api/getGachaLog`,
  `real_gacha_type` 1/2/3/5/102/103.
- All: `size=20`, `page` starting at 1, subsequent `end_id` from the last string
  record ID, API `lang` short codes except zh-cn/zh-tw. Export language uses UIGF
  locale codes. No live authenticated requests were performed.

The v4.0 schema excludes Star Rail 21/22 and ZZZ 102/103. Export must fail
explicitly on incompatible nonempty records rather than omit them or label
nonconforming bytes as v4.0. Current standard:
https://uigf.org/en/standards/uigf.html (v4.2 on the retrieval date).

Star Rail now uses `/common/hkrpg_gacha_record/api/` for both ordinary and
collaboration records. The earlier `/common/gacha_record/` route can truncate
available history. Primary change evidence:
https://github.com/Scighost/Starward/commit/6be7fdcf7f266308e59e68960d97755a65f8333d
and https://github.com/Scighost/Starward/issues/1900.
Cached old API paths remain accepted, but requests use the current path.

Official cached history webpage prefixes and current API paths are also listed
in the maintained client at
https://github.com/Scighost/Starward/blob/df8ae07b5ad4c9c6cb70d288488ce8073ce01478/src/Starward.Core/Gacha/GachaLogClient.cs.
The edition-specific `gs.hoyoverse.com` or `webstatic.mihoyo.com` page link is
parsed locally and never fetched. Only rebuilt allowlisted gacha API requests
receive its credentials. Global and CN webpage URLs are tested synthetically.

Current v4.2 still does not enumerate ZZZ 102/103 as output gacha types. Those
are also API request selectors. The exporter preserves returned gacha_type
rather than assuming selector and response type are interchangeable.

Genshin's v3 history page route is independently documented in the synthetic
example and extraction source at
https://gist.github.com/noxiousninja/2b0eb04c521d7e937f44db38f83733bf.
Both v2 and v3 page routes are covered without real credentials.
