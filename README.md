# Static web server image

KoedoDB serves the static front end of a project (the build output of React, Vue, Svelte, ...) with [static-web-server](https://github.com/static-web-server/static-web-server) (SWS) **as upstream publishes it**. Nothing is built or patched here: this directory pins the image, says how KoedoDB runs it, and tests what KoedoDB relies on.

This is not an official static-web-server repository, and KoedoDB is not affiliated with its authors.

## The image

The file `IMAGE` holds the image, by tag and by digest of the multi-architecture index:

```
joseluisq/static-web-server:2.44.0@sha256:2c1a7c3e0feaea5859307403b74e1c575f3ec1499094fc077344173d11abaae2
```

This is the default (scratch) variant: 12 MB, a single static binary, no operating system packages to patch. The `-debian` variant uses about 4 MiB less memory but is 135 MB; that is not a reason to choose it.

To update it, change the tag and the digest together (`docker buildx imagetools inspect joseluisq/static-web-server:<tag>`), then run `tests/run.sh`. Read the [release notes](https://github.com/static-web-server/static-web-server/releases) and the [security advisories](https://github.com/static-web-server/static-web-server/security-advisories) first.

## How it is run

```sh
docker run --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --memory 32m --cpus 0.1 \
  -e SERVER_PORT=8080 -e SERVER_ROOT=/public -e SERVER_FALLBACK_PAGE=/public/index.html \
  -e SERVER_COMPRESSION=false -e SERVER_DIRECTORY_LISTING=false -e SERVER_LOG_LEVEL=error \
  -e SERVER_HEALTH=true -e SERVER_GRACE_PERIOD=15 -e SERVER_CACHE_CONTROL_HEADERS=false \
  -v ./site:/public:ro <IMAGE>
```

In KoedoDB the site is baked into the image of the Pod (or mounted read-only). TLS is ended in front, by Caddy on the host; Envoy Gateway passes plain HTTP/1.1 on to the Pod. SWS itself needs no TLS, no HTTP/2, and no compression (Cloudflare and Caddy do those).

The Pod's resources: **memory request 16 MiB, limit 32 MiB; CPU request 10m, limit 100m.**

## Settings

| Variable | Value | Note |
|---|---|---|
| `SERVER_PORT` | `8080` | |
| `SERVER_ROOT` | `/public` | |
| `SERVER_FALLBACK_PAGE` | `/public/index.html` | For a single-page app: an unknown route gets `index.html` (see "Things to know"). |
| `SERVER_COMPRESSION` | `false` | Done in front. |
| `SERVER_DIRECTORY_LISTING` | `false` | A directory with no index gives no listing. |
| `SERVER_LOG_LEVEL` | `error` | |
| `SERVER_HEALTH` | `true` | `GET /health` answers `OK`: use it for the probes. |
| `SERVER_GRACE_PERIOD` | `15` | **Set it**, with `terminationGracePeriodSeconds` (see below). |
| `SERVER_CACHE_CONTROL_HEADERS` | `false` | See below. |
| `SERVER_SECURITY_HEADERS` | **not set** | See below. |

## Things to know

- **Always give the Pod a CPU limit.** With one, SWS runs 2 threads; without it, it runs as many as the node has cores, and uses more memory.
- **Nothing outside of the site is served.** `..`, `%2e%2e`, `..%2f`, `//`, a doubly encoded `%252e%252e`, a backslash, and a symbolic link to a file outside of the site all end at the fallback page, never at the file. **Hidden files (`.env`, `.hidden/x.txt`) are not served** either. No `Server` header is sent. Only GET, HEAD and OPTIONS work; POST, PUT, DELETE and PATCH get 405.
- **Do not set `SERVER_SECURITY_HEADERS=true`.** It adds `Strict-Transport-Security` with `includeSubDomains; preload` for two years. On a customer's own domain that pins the whole domain and all of its subdomains to HTTPS in the browsers that have visited it. Let Caddy or Envoy set the headers that are wanted.
- **Cache-Control: decide it.** By default HTML gets `max-age=86400` (one day) and every other file `max-age=31536000` (one year). The files are replaced at each deploy, so a browser or Cloudflare keeps the old `index.html` for up to a day. With `SERVER_CACHE_CONTROL_HEADERS=false` no header is added, and Envoy or Cloudflare decide. Another way is hashed file names for assets and `no-cache` for HTML.
- **A single-page app: every unknown path is `index.html` with 200**, also a missing file with an extension (`/missing.js`). A browser that loads a chunk that a deploy has removed gets HTML, not a 404. `HEAD` of an unknown path is 404 while `GET` is 200: use `GET` for probes (`/health` is fine).
- **Shutdown: set the grace period.** After SIGTERM the default grace period is about 5 seconds, and a download that is not finished by then is cut (a 100 MB download at 15 MB/s was cut at 98 MB). With `SERVER_GRACE_PERIOD=15` SWS stops taking new connections, waits for the running ones, and exits with code 0. Make `terminationGracePeriodSeconds` longer than it (the maximum is 255 s).
- **A Rust server still has security advisories.** Rust removes memory-safety bugs; the advisories of SWS (7, checked 2026-10-06) are logic bugs of a file server: symbolic-link and pre-compressed-file path traversal, path traversal in markdown negotiation, stored XSS in directory listings, and three in Basic authentication. The four published on 2026-08-03 are fixed in 2.44.0, the version in `IMAGE`. The settings above keep the features they are in (directory listing, Basic authentication, pre-compressed files, markdown, metrics) off, and the tests look at path traversal, hidden files and links on every run. Read `gh api repos/static-web-server/static-web-server/security-advisories` before an update, and watch it.
- **Big files are streamed, not held in memory.** Ten downloads of a 100 MB file at once, under a 32 MiB limit, all finished; the peak RSS was 12 MiB.
- Range requests (206) and `If-Modified-Since` (304) work. SWS sends no `ETag`.

## What the tests check

`tests/run.sh` builds a test site (a 100 MB file, a 2 MB bundle, hidden files, a symbolic link out of the site, a file outside of it), starts the image as described above with the limits of the Pod, and checks:

- it starts hardened, is the version in `IMAGE`, and is small at rest (RSS under 16 MiB);
- what is served: indexes, content types (css, js, svg, wasm, json), a name with a space, ranges, 304, HEAD, the methods that get 405;
- the single-page fallback, and the things listed above as known;
- what must never be served: the traversal variants, hidden files, the symbolic link, a directory listing, compression, the `Server` header, HSTS;
- the Cache-Control defaults and how to turn them off;
- memory and CPU with the Pod's limits: 100 concurrent requests, 20,000 times, for two files; the 2 MB bundle; ten 100 MB downloads at once; the peak RSS stays under 24 MiB and nothing is killed;
- shutdown: with the default grace period a running download is cut; with `SERVER_GRACE_PERIOD=15` it finishes; a restart serves again.

It needs Docker, Python 3, curl and `ab` (apache2-utils), and uses no secrets: the "secret" file is made up for the run. A workflow runs it on every push and pull request (and by hand).

## Measured

On a laptop, Docker, memory 32 MiB, CPU 0.1, a 12 MB site: idle RSS 10 MiB (scratch) and 6 MiB (Debian); peak RSS after 100 concurrent requests 13 MiB and 8 MiB; about 1,100 requests per second for a small HTML file (p99 190 ms) and about 33 per second for a 2 MB file (CPU 0.1 is the limit; Cloudflare's cache is in front in production). These are one laptop's numbers, not a benchmark.

## Not checked

gVisor (file system calls are several times slower there, and a static server makes many), Kubernetes (the probes, the rolling update, NetworkPolicy), TLS and HTTP/2, a very large site (hundreds of MB: the page cache counts in the cgroup but can be reclaimed), and long loads (the load above lasts tens of seconds).

## License

Copyright (c) 2026 RadarWorks LLC. The files in this repository (`IMAGE`, the tests and this documentation) are licensed under the [MIT License](LICENSE). static-web-server itself is MIT OR Apache-2.0 ([static-web-server/static-web-server](https://github.com/static-web-server/static-web-server)); the image is upstream's.
