#!/bin/bash
# Runs the pinned static-web-server image (the file IMAGE) in Docker, as the Pod will run it: a non-root user, a read-only root file system, no capabilities, memory 32 MiB, CPU 0.1.
# It checks what is served and what must never be served, the headers, the memory under load and under big files, and the shutdown. Nothing is built: the image is upstream's.
#
#   tests/run.sh        # a few minutes; ends with "ALL OK"
#
# Needs Docker, python3, curl and ab (apache2-utils). It uses no secrets: the "secret" file below is made up for the run.
#
# What is NOT checked here: gVisor (the file system calls are slower there), Kubernetes (the probes, the rolling update, NetworkPolicy), TLS and HTTP/2 (Cloudflare and Caddy do them; Caddy ends TLS on the host and Envoy Gateway passes plain HTTP on to the Pod).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$(tr -d '[:space:]' < "$here/IMAGE")"
run="kbswsi$$"
work="${HOME}/.${run}"; rm -rf "$work"; mkdir -p "$work/public/sub" "$work/public/.hidden" "$work/public/emptydir" "$work/public/assets"; chmod 755 "$work"
cleanup() { docker rm -f "${run}" >/dev/null 2>&1; rm -rf "$work"; }
trap '[ -n "${KEEP:-}" ] || cleanup' EXIT
fail=0
check() {
  local out; out="$(eval "$2" 2>&1)"; local rc=$?
  if [ $rc = 0 ]; then echo "ok:   $1"; else echo "FAIL: $1"; fail=1; [ -n "${DEBUG:-}" ] && echo "      -> $(printf %s "$out" | head -20 | cut -c1-300)"; fi
}
note() { echo "note: $1"; }
step() { echo; echo "== $1"; }

# --- the site, and a file that is outside of it ----------------------------------------------------------------------------------------------------------------------
site="$work/public"
echo '<html>INDEX</html>' > "$site/index.html"
echo 'SUB-INDEX' > "$site/sub/index.html"
echo 'a{color:red}' > "$site/assets/app.css"
echo 'console.log(1)' > "$site/assets/app.abc123.js"
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$site/assets/logo.svg"
printf '\0asm\1\0\0\0' > "$site/assets/m.wasm"
echo '{"a":1}' > "$site/assets/data.json"
echo 'file with a space' > "$site/sp ace.txt"
echo 'DOTENV=made-up-dotenv-secret' > "$site/.env"
echo 'HIDDEN-FILE' > "$site/.hidden/x.txt"
echo 'OUTSIDE-SECRET-OF-THE-RUN' > "$work/secret.txt"; chmod 644 "$work/secret.txt"
ln -s /secret.txt "$site/link.txt"                               # a link to a file outside of the site (the container has it at /secret.txt)
head -c 100000000 /dev/zero | tr '\0' 'x' > "$site/big.bin"      # 100 MB
head -c 2000000 /dev/urandom > "$site/assets/bundle.js"          # 2 MB
chmod -R a+rX "$work"

# start [docker options before the image] [-- more environment as -e options]: the container, hardened, with the limits of the Pod
start() {
  docker rm -f "${run}" >/dev/null 2>&1
  docker run -d --name "${run}" --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges --memory 32m --memory-swap 32m --cpus 0.1 -p 127.0.0.1::8080 \
    -e SERVER_PORT=8080 -e SERVER_ROOT=/public -e SERVER_COMPRESSION=false -e SERVER_DIRECTORY_LISTING=false -e SERVER_FALLBACK_PAGE=/public/index.html -e SERVER_LOG_LEVEL=error -e SERVER_HEALTH=true \
    -v "$site:/public:ro" -v "$work/secret.txt:/secret.txt:ro" "$@" "$IMAGE" >/dev/null
  port="$(docker port "${run}" 8080/tcp | head -1 | sed 's/.*://')"
  for _ in $(seq 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' -m 1 "http://127.0.0.1:$port/health")" = 200 ] && return 0; sleep 0.25; done; return 1
}
U() { echo "http://127.0.0.1:$port$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"; }
body() { curl -s -m 10 "$@"; }
hdr()  { curl -s -D - -o /dev/null -m 10 "$@" | tr -d '\r'; }
rss()  { awk '/VmRSS/{r=$2}/VmHWM/{h=$2}END{printf "%d %d", r/1024, h/1024}' "/proc/$(docker inspect -f '{{.State.Pid}}' "${run}")/status"; }   # "rss peak" in MiB
oom()  { docker inspect -f '{{.State.OOMKilled}}' "${run}"; }

step "It starts as the Pod will run it"
start; check "it answers /health (the probe)" '[ "$(body "$(U /health)")" = OK ]'
tag="$(sed 's/^[^:]*:\([0-9.]*\)@.*/\1/' "$here/IMAGE")"
check "it is the version in IMAGE ($tag)" '[ "$(docker run --rm "$IMAGE" --version | awk "/Version:/{print \$2}")" = "$tag" ]'
check "it runs as user 10001, on a read-only root file system, with no capabilities, memory 32 MiB" '[ "$(docker inspect -f "{{.Config.User}}" '"$run"')" = 10001:10001 ] && [ "$(docker inspect -f "{{.HostConfig.ReadonlyRootfs}}" '"$run"')" = true ] && [ "$(docker inspect -f "{{.HostConfig.CapDrop}}" '"$run"')" = "[ALL]" ] && [ "$(docker inspect -f "{{.HostConfig.Memory}}" '"$run"')" = 33554432 ]'
check "it is small at rest: RSS under 16 MiB (the request)" 'set -- $(rss); [ "$1" -lt 16 ]'
check "with a CPU limit it runs few threads (2 here, on $(nproc) cores)" '[ "$(awk "/Threads/{print \$2}" /proc/$(docker inspect -f "{{.State.Pid}}" '"$run"')/status)" -le 4 ]'

step "What is served"
check "/ is index.html, a directory gives its index.html" '[ "$(body "$(U /)")" = "<html>INDEX</html>" ] && [ "$(body "$(U /sub/)")" = SUB-INDEX ]'
check "content types: css, js, svg, wasm, json" 'for t in "assets/app.css text/css" "assets/app.abc123.js javascript" "assets/logo.svg image/svg+xml" "assets/m.wasm application/wasm" "assets/data.json application/json"; do set -- $t; hdr "$(U /$1)" | grep -i "^content-type:" | grep -qi "$2" || { echo "$1"; exit 1; }; done'
check "a name with a space (%20) is served" '[ "$(body "$(U "/sp%20ace.txt")")" = "file with a space" ]'
check "a range request gets 206 and only the bytes asked for" '[ "$(code -H "Range: bytes=0-4" "$(U /index.html)")" = 206 ] && [ "$(body -H "Range: bytes=0-4" "$(U /index.html)")" = "<html" ]'
lm="$(hdr "$(U /assets/app.css)" | awk -F": " 'tolower($1)=="last-modified"{print $2}')"
check "a file that has not changed gets 304 (If-Modified-Since)" '[ "$(code -H "If-Modified-Since: $lm" "$(U /assets/app.css)")" = 304 ]'
check "HEAD works" '[ "$(code -I "$(U /assets/app.css)")" = 200 ]'
check "only reading is allowed: POST, PUT, DELETE, PATCH get 405" 'for m in POST PUT DELETE PATCH; do [ "$(code -X $m "$(U /assets/app.css)")" = 405 ] || { echo $m; exit 1; }; done'

step "A single-page app: an unknown route gives index.html"
check "an unknown route (GET) is index.html with 200" '[ "$(code "$(U /some/route)")" = 200 ] && [ "$(body "$(U /some/route)")" = "<html>INDEX</html>" ]'
note "KNOWN: a missing file with an extension (/missing.js) also gets index.html with 200, so a client that loads a chunk that is gone (after a deploy) receives HTML, not a 404. HEAD of an unknown route is 404 while GET is 200 (use GET for probes)."
check "(that note) /missing.js is index.html with 200; HEAD of /some/route is 404" '[ "$(body "$(U /missing.js)")" = "<html>INDEX</html>" ] && [ "$(code -I "$(U /some/route)")" = 404 ]'

step "What must never be served"
check "a file outside of the site is never served: .., encoded .., doubly encoded, //, a backslash" 'for p in "/../secret.txt" "/%2e%2e/secret.txt" "/..%2fsecret.txt" "//secret.txt" "/%252e%252e/secret.txt" "/..\\secret.txt" "/assets/../../secret.txt" "/./../secret.txt"; do curl -s --path-as-is -m 10 "$(U "$p")" | grep -q OUTSIDE-SECRET && { echo "$p"; exit 1; }; done; exit 0'
check "hidden files (.env, .hidden/x.txt) are not served" '! body "$(U /.env)" | grep -q made-up-dotenv-secret && ! body "$(U /.hidden/x.txt)" | grep -q HIDDEN-FILE'
check "a symbolic link to a file outside of the site is not followed" '! body "$(U /link.txt)" | grep -q OUTSIDE-SECRET'
check "a directory without an index gives no listing" '! body "$(U /emptydir/)" | grep -qi "index of\|<table\|\.hidden"'
check "no compression is made (a gzip request gets no content-encoding)" '! hdr -H "Accept-Encoding: gzip, br" "$(U /assets/bundle.js)" | grep -qi "^content-encoding:"'
check "the server does not say what it is or which version (no Server header)" '! hdr "$(U /)" | grep -qi "^server:"'
check "no HSTS and no other security header is added here (Caddy, Envoy and Cloudflare do that)" '! hdr "$(U /)" | grep -qi "^strict-transport-security:"'
note "KNOWN: SERVER_SECURITY_HEADERS=true adds Strict-Transport-Security with includeSubDomains and preload for 2 years: do not set it (a customer's own domain would be pinned to HTTPS for all its subdomains)."
start -e SERVER_SECURITY_HEADERS=true >/dev/null
check "(that note) with SERVER_SECURITY_HEADERS=true the HSTS header is there" 'hdr "$(U /)" | grep -i "^strict-transport-security:" | grep -qi "includeSubDomains; preload"'

step "Cache-Control"
start >/dev/null
note "KNOWN: by default HTML gets max-age=86400 (one day) and the other files max-age=31536000 (one year). The files are replaced at each deploy: a browser or Cloudflare keeps the old index.html for up to a day. Set SERVER_CACHE_CONTROL_HEADERS=false and let Envoy/Cloudflare decide, or use hashed names for assets and no-cache for HTML."
check "(that note) index.html: one day, a hashed asset: one year" 'hdr "$(U /index.html)" | grep -qi "cache-control: max-age=86400" && hdr "$(U /assets/app.abc123.js)" | grep -qi "cache-control: max-age=31536000"'
start -e SERVER_CACHE_CONTROL_HEADERS=false >/dev/null
check "with SERVER_CACHE_CONTROL_HEADERS=false no Cache-Control is added" '! hdr "$(U /index.html)" | grep -qi "^cache-control:" && ! hdr "$(U /assets/app.css)" | grep -qi "^cache-control:"'
start >/dev/null

step "Memory and CPU with the limits of the Pod (memory 32 MiB, CPU 0.1)"
for t in "index.html|/index.html|20000" "a small file|/assets/app.css|20000"; do
  IFS='|' read lbl path n <<< "$t"; about="$(ab -q -n "$n" -c 100 "$(U "$path")" 2>&1)"
  check "100 concurrent requests, $n times, for $lbl: none fail" 'echo "$about" | grep -q "Failed requests:\s*0" && ! echo "$about" | grep -q "Non-2xx"'
done
check "after that: peak RSS under 24 MiB (limit 32), not killed" 'set -- $(rss); [ "$2" -lt 24 ] && [ "$(oom)" = false ]'
about="$(ab -q -n 300 -c 20 "$(U /assets/bundle.js)" 2>&1)"
check "the 2 MB bundle, 300 times, 20 at once: none fail, the bytes are all there" 'echo "$about" | grep -q "Failed requests:\s*0" && [ "$(echo "$about" | awk "/Total transferred/{print \$3}")" -ge 600000000 ]'
echo "      100 MB files, 10 at once, memory limit 32 MiB:"
for i in $(seq 1 10); do ( curl -s -o /dev/null -w '%{size_download}\n' -m 120 "$(U /big.bin)" > "$work/dl$i" ) & done; wait
check "ten downloads of a 100 MB file at once: every one has all 100,000,000 bytes, and the container is not killed (it streams, it does not hold the file)" '[ "$(cat $work/dl* | grep -c "^100000000$")" = 10 ] && [ "$(oom)" = false ]'
check "after that: peak RSS still under 24 MiB" 'set -- $(rss); [ "$2" -lt 24 ]'
echo "      peak RSS $(set -- $(rss); echo "$2") MiB"

step "Shutdown and restart"
note "KNOWN: after SIGTERM the default grace period is about 5 s; a download that is not finished by then is cut. Set SERVER_GRACE_PERIOD (up to 255 s) together with terminationGracePeriodSeconds, so that a rolling update does not cut downloads."
start >/dev/null; ( curl -s -o "$work/cut.out" --limit-rate 15M -m 60 "$(U /big.bin)" ) & sleep 1
t0=$(date +%s); docker stop -t 30 "${run}" >/dev/null; t1=$(date +%s); wait
check "(that note) with the default grace period: exit code 0 after about 5 s, and the download that was running is cut (fewer than 100,000,000 bytes)" '[ "$(docker inspect -f "{{.State.ExitCode}}" '"$run"')" = 0 ] && [ $((t1 - t0)) -le 8 ] && [ "$(wc -c < "$work/cut.out")" -lt 100000000 ]'
start -e SERVER_GRACE_PERIOD=15 >/dev/null; ( curl -s -o "$work/slow.out" --limit-rate 15M -m 60 "$(U /big.bin)" ) & sleep 1
t0=$(date +%s); docker stop -t 30 "${run}" >/dev/null; t1=$(date +%s); wait
check "with SERVER_GRACE_PERIOD=15: exit code 0, and the download that was running finished (all 100,000,000 bytes)" '[ "$(docker inspect -f "{{.State.ExitCode}}" '"$run"')" = 0 ] && [ "$(wc -c < "$work/slow.out")" = 100000000 ]'
check "it waited for it and stopped by itself, within the grace period (about 15 s: $((t1 - t0)) s)" '[ $((t1 - t0)) -ge 5 ] && [ $((t1 - t0)) -le 20 ]'
docker start "${run}" >/dev/null; port="$(docker port "${run}" 8080/tcp | head -1 | sed 's/.*://')"
check "and it serves again after a restart" 'for _ in $(seq 40); do [ "$(body "$(U /health)")" = OK ] && exit 0; sleep 0.25; done; exit 1'

echo
[ "$fail" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
