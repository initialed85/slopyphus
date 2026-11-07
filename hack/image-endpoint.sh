#!/usr/bin/env bash
# hack/image-endpoint.sh - build the forked ttyd in a throwaway container and prove the image route reads
# pictures and nothing else.
#
# The route exists because tmux keeps no copy of an inline image: a pane that has drawn one holds cells, and every
# repaint (copy-mode, a resize, a pane menu, a reattach) erases the picture. Serving the bytes the pane's relay
# saved is what lets a browser redraw them from a text marker in the grid. That makes the route a file read with a
# name attached, and a name attached to a file read is the part worth testing: this asks for a saved picture, a
# right-shaped name whose bytes are not a picture, a right-shaped name that is not there, several wrong shapes, the
# percent-encoded ways a path escape normally arrives, and a symlink planted in the picture directory.
#
# It builds in a container because the fork compiles against Ubuntu's libwebsockets in the image build and this pod
# has no compiler. The container is the builder stage from Dockerfile, so what compiles here is what CI compiles.
# The source arrives on the container's stdin as a tar (this pod's filesystem is not visible to the Docker daemon on
# bee-2), which is also why the test script below is handed over as an argument rather than on stdin.
#
# Run: hack/image-endpoint.sh        (needs docker; DOCKER_HOST as usual)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=${TTYD_BUILD_IMAGE:-ubuntu:26.04}

INNER=$(cat <<'EOS'
set -u
mkdir -p /src/ttyd /work/.slopyphus/images
tar -xC /src/ttyd
export DEBIAN_FRONTEND=noninteractive
apt update -qq >/dev/null 2>&1
apt install -y -qq --no-install-recommends build-essential cmake libwebsockets-dev libjson-c-dev libuv1-dev \
  zlib1g-dev curl >/dev/null 2>&1
cd /src/ttyd
cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
if ! cmake --build build --parallel "$(nproc)" > /tmp/build.log 2>&1; then
  echo "the fork does not build:"
  grep -E "error|Error" /tmp/build.log | head -20
  exit 1
fi
echo "built: $(build/ttyd --version 2>&1 | head -1)"

# A real PNG, the smallest one worth having. The names are the shape the relay writes: ten lowercase hex digits,
# which in the relay is a prefix of the content hash.
printf 'iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFUlEQVR42mNk+M9Qz0BBQURMBQBEIAAGrYHeAAAAAElFTkSuQmCC' |
  base64 -d > /work/.slopyphus/images/abcdef1234.png
printf 'not an image, but a name of the right shape\n' > /work/.slopyphus/images/9999999999.png
printf 'secret\n' > /work/.slopyphus/secret
ln -s /etc/passwd /work/.slopyphus/images/feedface00.png

cd /work
/src/ttyd/build/ttyd --writable -w /work -p 7681 --image-dir .slopyphus/images true > /tmp/ttyd.log 2>&1 &
ttyd=$!
sleep 2
echo "the server's own startup output:"
sed 's/^/  /' /tmp/ttyd.log

fails=0
if grep -q "served images: .slopyphus/images" /tmp/ttyd.log; then
  echo "  ok   a server says which directory it reads pictures from"
else
  fails=$((fails + 1)); echo "  FAIL the startup log does not name the image directory"
fi

# ask <want status pattern> <path> <header substring that must appear, or "-"> <header substring that must not, or "-">
ask() {
  local want=$1 path=$2 need=$3 forbid=$4 status got ok got_note code hit
  : > /tmp/body  # curl only creates the output file once a response starts; a refused connection must not leave
  # the previous case's bytes behind to be mistaken for this one's
  curl -sS -o /tmp/body -D /tmp/headers "http://127.0.0.1:7681$path" 2>/tmp/curl.err
  [ -s /tmp/curl.err ] && got_note="curl: $(cat /tmp/curl.err)"
  cp /tmp/body /tmp/last-body  # so a later case cannot be mistaken for this one's bytes
  tr -d '\r' < /tmp/headers > /tmp/h
  status=$(head -1 /tmp/h | awk '{print $2}')
  got_note=""
  [ -s /tmp/curl.err ] && got_note="curl: $(cat /tmp/curl.err)"
  # A connection closed before any response is also a refusal to serve, and worth naming rather than leaving as an
  # empty field in the report.
  [ -n "$status" ] || status=noresponse
  got="status $status${got_note:+ $got_note}"
  ok=ok
  # Several cases below can be refused by this handler, by libwebsockets' own URI parsing, or by the connection
  # being closed before a response starts. All of them are fine as long as nothing is served, so a want is a list
  # of acceptable codes rather than one code.
  hit=no
  for code in $want; do
    [ "$code" = "$status" ] && hit=yes && break
  done
  [ "$hit" = yes ] || ok=FAIL
  if [ "$need" != "-" ] && ! grep -qiF "$need" /tmp/h; then ok=FAIL; got="$got, missing '$need'"; fi
  if [ "$forbid" != "-" ] && grep -qiF "$forbid" /tmp/h; then ok=FAIL; got="$got, has '$forbid'"; fi
  [ "$ok" = ok ] || fails=$((fails + 1))
  printf '  %-4s %-48s %s  %s\n' "$ok" "$path" "$got" \
    "$(grep -iE '^(content-type|cache-control):' /tmp/h | paste -sd ' ' -)"
}

IMMUTABLE="cache-control: public, max-age=31536000, immutable"
PNG=/work/.slopyphus/images/abcdef1234.png

echo "a picture that is there"
ask 200 /images/abcdef1234.png "$IMMUTABLE" -
ask 200 /images/abcdef1234.png "content-type: image/png" -
ask 200 /images/9999999999.png "content-type: image/png" -  # the type follows the name; the bytes are never sniffed
ask 200 /images/abcdef1234.png "content-length: $(stat -c %s "$PNG")" -  # the declared length is the file's own
# The bytes served have to be the bytes on disk: a picture redrawn from a cache is only the same picture if the
# file it came from is byte for byte what was sent.
if cmp /tmp/last-body "$PNG"; then
  echo "  ok   the bytes served are the bytes on disk"
else
  fails=$((fails + 1)); echo "  FAIL the bytes served are not the file"
fi

echo "a name that is not a picture this relay would have written"
ask 404 /images/0000000000.png - -                          # right shape, not there
ask 404 /images/abcdef123.png - -                           # nine hex digits
ask 404 /images/zzzzzzzzzz.png - -                          # not hex
ask 404 /images/a.png - -                                   # not a content hash prefix
ask 404 /images/abcdef1234.txt - -                          # an extension the relay does not write
ask 404 /images/abcdef1234.png.png - -                      # two extensions
ask 404 /images/abcdef1234.PNG - -                          # upper case is not what the relay writes
ask 404 '/images/abcdef1234.png/' - -                       # a trailing slash is not a name
ask 404 '/images/abcdef1234.png/extra' - -                  # a name with something after it
ask 404 '/images/abcdef1234/' - -                           # a directory-looking tail
ask "404 400" '/images/' - -                                # the route itself
ask "404 400" '/slopyphus/images/abcdef1234.png' - -        # this server has no such base path

echo "someone trying to read elsewhere in the pane's directory, or outside it"
ask 404 '/images/abcdef1234.png/../.slopyphus/secret' - "content-type: text/plain"
ask "404 400" '/images/..%2F..%2Fetc%2Fpasswd' - -          # a traversal, percent encoded
ask "404 400" '/images/%2e%2e%2f%2e%2e%2fetc%2Fpasswd' - -  # and dot encoded
ask "404 400 noresponse" '/images/abcdef1234.png%00' - -    # a NUL where a byte of the extension should be
ask "404 400" '/images/abcdef1234%2E%2E' - -                # dots where an extension should be
ask 404 '/images/feedface00.png' - -                        # a symlink into /etc: the name is the whole contract
ask "404 400" '/.slopyphus/secret' - -                      # only uploads and pictures are ever served from here
ask "404 400" '/index.html' - -                             # the page itself is served at /, not at a file name

kill "$ttyd" 2>/dev/null || true
echo
if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "every check passed"
EOS
)

tar -c --exclude .git -C "$REPO/vendor/ttyd" . | docker run --rm -i "$IMAGE" bash -c "$INNER"
