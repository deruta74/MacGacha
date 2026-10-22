# Download throughput benchmark

Opt-in; no CI timing assertions or external network. A synthetic 8.59 GB plan
has 6,396 objects and 3,657 files (mostly one or two chunks). The loopback server
uses real TCP/HTTP/1.1, persistent connections, and independent socket workers.
The engine uses real contained filesystem writes, hashing and durability.

```sh
swift run -c release --package-path Packages/LauncherKit ThroughputBenchmark 8 20 8 urlsession 8 100 system
```

Arguments: approximate GiB, request latency in milliseconds, assembly limit,
`urlsession` or `memory`, session count, inter-fragment delay in microseconds,
and disk probe (`system`, `important`, or `fixed`). Both engine and session
connection limits use `SpaceBudget.defaultMaxConcurrentObjects`.

- `system` is the real uncached kernel free-block probe used by production.
- `important` reproduces the former fresh-URL Foundation important-usage query,
  including its expensive CacheDelete/volume enumeration. It deliberately does
  not reuse a URL's resource-value cache, which can return stale capacity.
- `fixed` isolates I/O from capacity queries. The earlier memory-client/fixed-
  probe benchmark omitted the real serialized bottleneck.
- Fragment delay 100 sends paced 16 KiB pieces to stress callbacks; 0 sends
  bodies at socket speed. Initial request latency remains 20 ms in either case.

Release measurements on this Mac, with no competing tests, on 2026-10-22:

| Real URLSession + filesystem | MB/s | Wall seconds | Capacity-query seconds | Peak RSS MiB |
| --- | ---: | ---: | ---: | ---: |
| Former query, 1 session, paced | 218.9 | 39.238 | 26.477 | 148.5 |
| Kernel query, 8 sessions, paced | 661.9 | 12.978 | 0.061 | 123.8 |
| Kernel query, 8 sessions, socket-speed bodies | 756.1 | 11.362 | See run output | 238.5 |

Sharding alone with the former probe measured 214.7 MB/s; it did not remove
that allocation-gate bottleneck. Paced runs with the kernel query measured
roughly 662–700 MB/s with either one or eight sessions. Session sharding removes
the single delegate-queue / HTTP/2-pool constraint; real CDN and TLS behavior
still need a new live measurement.

The timed run prints its PID and samples Mach user/system CPU per thread,
average CPU relative to one core, and peak 100 ms CPU. It also reports native
data-callback counts/work by thread and overlapping hash/assembly/sync work.
An optional separate `/usr/bin/sample <PID> 3 5 -file /tmp/throughput.sample.txt`
should start after the `transport=...` line, not during synthetic plan creation.
Before, samples show `checkCapacity -> resourceValues ->
CacheDeleteCopyAvailableSpaceForVolume` while the allocation gate blocks
writers; afterward, that path disappears and workers hash/assemble concurrently.
Do not use a sampling run's throughput as the uninstrumented comparison.
