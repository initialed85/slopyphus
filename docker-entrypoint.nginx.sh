#!/bin/sh
# Entrypoint for the slopyphus UI/front container (Dockerfile.nginx).
#
# Composes one desktop of agents out of two things only: the templates in $TEMPLATE_DIR and the
# environment. Nothing is hardcoded here, so a single front image can present any number of agents in
# any arrangement.
#
# COLUMNS / ROWS
#   Comma separated "name=url" pairs. The name is what the UI calls the agent; it becomes the iframe's
#   path (/name/), the nginx location that proxies it, and the label in the corner of the pane.
#   The url is the upstream that location proxies to. It may be written at several levels of detail:
#     coder-1                                  -> http://coder-1:7681, upstream path /coder-1
#     coder-1=coder-1:7681                     -> the same, spelled out
#     coder-1=http://other-host:7681           -> a slopyphus agent under a different name
#     alice=https://agent.dev.initialed85.cc/coder-1
#                                            -> any origin; the path is the upstream base path
#     google=https://www.google.com            -> any origin served at its own root
#   Rules: no scheme means a slopyphus agent container (port $AGENT_PORT, and ttyd's base path is the
#   agent's name, which is the first label of the host: coordinator.slopyphus.svc.cluster.local is still
#   an agent called coordinator); a scheme means an arbitrary origin served at whatever path it names
#   (its own root if none).
#   An upstream whose port is $AGENT_PORT is treated as a slopyphus agent either way, so
#   "http://coder-1:7681" and "coder-1" mean the same thing.
#
# LAYOUT
#   columns_left | columns_right  columns are equal, full-height strips on the named side; rows are
#                                 equal, half-width bands filling the other half
#   rows_top | rows_bottom        rows are equal, full-width bands on the named side; columns are
#                                 equal, half-height strips filling the other half
#
# Other environment
#   AGENT_PORT   slopyphus/ttyd port, assumed when a bare host is given        (default 7681)
#   PAGE_TITLE   the browser tab title                                         (default slopyphus)
#   RESOLVER     DNS server for per-request upstream resolution; auto-detected from
#                /etc/resolv.conf, or set to off to resolve every upstream when nginx starts
#   SVC_SUFFIX   appended to bare hosts when looking them up, for Kubernetes: nginx does not expand
#                search domains, so "coordinator" needs SVC_SUFFIX=<namespace>.svc.cluster.local to
#                become a name CoreDNS will answer (default empty)
#   TEMPLATE_DIR / CONF_OUT / HTML_OUT   where the templates are and where they are rendered to
#
# Rendering is deliberately done at container start rather than at build time: the point is to compose
# a desktop from a Deployment's environment without rebuilding an image per desktop. The output is
# plain nginx.conf / index.html, so a crashed container is debuggable by reading two files.
#
# Written for /bin/sh as busybox ash (nginx:alpine has no bash): no arrays, no [[ ]], no $''.

set -eu

PROG=${0##*/}
# Field separator for the intermediate agent table. Not a tab: `read` treats IFS whitespace specially
# and collapses runs of it, so a tab separated table silently loses an empty field (an upstream with
# no path, a host with no port). 0x1f cannot appear in a name or a URL.
US=$(printf '\037')

die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

TEMPLATE_DIR=${TEMPLATE_DIR:-/usr/share/slopyphus}
CONF_OUT=${CONF_OUT:-/etc/nginx/conf.d/default.conf}
HTML_OUT=${HTML_OUT:-/usr/share/nginx/html/index.html}
AGENT_PORT=${AGENT_PORT:-7681}
LAYOUT=${LAYOUT:-columns_left}
PAGE_TITLE=${PAGE_TITLE:-slopyphus}

# See $SVC_SUFFIX's note in parse_spec: this is a Kubernetes convenience, off by default because a
# compose network resolves bare names without any help.
SVC_SUFFIX=${SVC_SUFFIX:-}
case "$SVC_SUFFIX" in
  "") ;;
  *[!A-Za-z0-9._-]*) die "SVC_SUFFIX must be letters, digits, dot or dash (got '$SVC_SUFFIX')" ;;
esac

# Upstream names are resolved per request (see $DYNAMIC below), which needs a DNS server nginx can
# ask. The cluster's own DNS is already in /etc/resolv.conf: 127.0.0.11 on a compose network, the
# cluster DNS at 10.43.0.10 in the dev cluster. Override RESOLVER to point somewhere else.
RESOLVER=${RESOLVER:-}
if [ -z "$RESOLVER" ]; then
  RESOLVER=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)
fi
case "$RESOLVER" in off | none | static) RESOLVER= ;; esac

# The name of the variable a dynamic proxy_pass is built from. It has to be a variable for nginx to
# defer resolution, so the "variable" is literally where the upstream goes.
# shellcheck disable=SC2016  # deliberate: $slopyphus_upstream is nginx's variable, not this shell's
UPSTREAM_VAR='$slopyphus_upstream'
if [ -n "$RESOLVER" ]; then DYNAMIC=1; else DYNAMIC=0; fi

# COLUMNS is also a general-purpose shell variable; read it once into names that cannot move under us.
COLUMNS_SPEC=${COLUMNS_SPEC:-}
ROWS_SPEC=${ROWS_SPEC:-}
if [ -z "$COLUMNS_SPEC" ]; then COLUMNS_SPEC=${COLUMNS:-}; fi
if [ -z "$ROWS_SPEC" ]; then ROWS_SPEC=${ROWS:-}; fi

tmp=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmp"' INT TERM EXIT

trim() {
  printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_name() {
  case ${1:-} in
    "") die "agent name is empty" ;;
    . | ..) die "agent name '$1' would collide with a filesystem path in a URL" ;;
    healthz) die "agent name 'healthz' is reserved by the front's own probe route" ;;
    *[!A-Za-z0-9._-]*) die "invalid agent name '$1': use letters, digits, dot, dash or underscore" ;;
  esac
}

# One spec ("a=x,b=y") to a US separated table of: kind US name US upstream US upstream_path US host
#
# kind is "agent" (a slopyphus/ttyd container, whose UI lives under its own base path) or "site"
# (anything else, framed through nginx so the pane stays same-origin and the keyboard relay in
# index.html keeps working).
parse_spec() {
  _spec=${1:-}
  _out=${2:-}
  : >"$_out"
  if [ -z "$_spec" ]; then
    return 0
  fi

  # Not a pipeline into the loop: a loop on the far end of a pipe runs in a subshell, where a
  # validation failure can only exit the subshell and the caller would carry on with half a table.
  printf '%s\n' "$_spec" | tr ',' '\n' >"$tmp/spec"

  while IFS= read -r _raw; do
    _raw=$(trim "$_raw")
    if [ -z "$_raw" ]; then
      continue
    fi

    case "$_raw" in
      *=*) _name=$(trim "${_raw%%=*}"); _url=$(trim "${_raw#*=}") ;;
      *) _name=$_raw; _url= ;;
    esac
    validate_name "$_name"

    # Only the scheme is matched case insensitively; a path is case sensitive and kept verbatim.
    _lower=$(printf '%s' "$_url" | tr '[:upper:]' '[:lower:]')
    case "$_lower" in
      http://*) _scheme=http; _rest=${_url#*://} ;;
      https://*) _scheme=https; _rest=${_url#*://} ;;
      *://*) die "unsupported scheme in '$_url' (http or https only)" ;;
      *) _scheme=; _rest=$_url ;;
    esac

    # Trailing slashes carry no meaning: an upstream written as host, host/ or host// all mean
    # "serve the pane at whatever the upstream's root is".
    while [ "$_rest" != "${_rest%/}" ]; do _rest=${_rest%/}; done

    case "$_rest" in
      */*) _hostport=${_rest%%/*}; _path=/${_rest#*/} ;;
      *) _hostport=$_rest; _path= ;;
    esac

    # Host without the port: the Host header and SNI name nginx must present to an arbitrary origin,
    # and the base path a slopyphus agent serves itself under.
    case "$_hostport" in
      *:*) _port=${_hostport##*:}; _host=${_hostport%:*} ;;
      *) _port=; _host=$_hostport ;;
    esac

    # The port as written is what distinguishes a slopyphus agent from an arbitrary origin: ttyd
    # listens on $AGENT_PORT and serves its UI under its own name, so anything on that port is
    # expected to behave that way whatever scheme it was written with.
    _bare=0
    if [ -z "$_scheme" ]; then
      # Bare host: a slopyphus container on a compose network, or a Kubernetes service name.
      _bare=1
      if [ -z "$_hostport" ]; then
        _hostport=$_name
        _host=$_name
      fi
      if [ -z "$_port" ]; then
        _hostport="${_hostport}:${AGENT_PORT}"
        _port=$AGENT_PORT
      fi
      _scheme=http
      _kind=agent
    elif [ "$_port" = "$AGENT_PORT" ]; then
      _kind=agent
    else
      _kind=site
    fi

    case "$_host" in
      "") die "no host in '$_url'" ;;
      # Not an exhaustive host grammar; it is enough to catch the ways a name=url value is mistyped.
      *[!A-Za-z0-9._-]*) die "invalid host '$_host' in '$_url' (letters, digits, dot or dash)" ;;
    esac
    case "$_port" in
      *[!0-9]*) die "invalid port '$_port' in '$_url'" ;;
    esac

    if [ "$_kind" = agent ] && [ -z "$_path" ]; then
      # The agent container starts ttyd with a base path of its own name, so /alice/ has to reach
      # coder-1 as /coder-1/, not as /alice/. The base path is the agent's NAME, which is the
      # Service or container name, i.e. the first label of whatever host string was written: a host
      # spelled out as coordinator.default.svc.cluster.local is still an agent called coordinator.
      # A leading slash, never a trailing one: the renderers append exactly one.
      _path="/${_host%%.*}"
    fi

    # nginx's resolver is not a libc stub resolver: it sends the name it was given and does not try the
    # `search` domains in /etc/resolv.conf. Measured in the dev cluster with a bare Service name
    # (kubernetes, kubernetes.default, then the FQDN): only the FQDN resolved (502, 502, 400). So a bare
    # Kubernetes Service name 502s every pane unless something lengthens it. SVC_SUFFIX is that
    # something, applied to the lookup only: the pane name, the agent's own base path and the host it is
    # called by all stay short, because none of them are DNS names.
    if [ "$_bare" = 1 ] && [ -n "$SVC_SUFFIX" ]; then
      case "$_host" in
        *."$SVC_SUFFIX") ;; # already spelled out; do not suffix twice
        *) _hostport="${_host}.${SVC_SUFFIX}:${_port}" ;;
      esac
    fi

    printf '%s\037%s\037%s://%s\037%s\037%s\n' "$_kind" "$_name" "$_scheme" "$_hostport" "$_path" "$_host" >>"$_out"
  done <"$tmp/spec"
}

# Names only, one per line, for the duplicate check and the startup summary.
agent_names() {
  cut -d"$US" -f2 "$@"
}

# Emit nginx locations, one per agent, in the order they were declared.
#
# A request to /name/ is proxied to <upstream><upstream_path>/, i.e. the UI name is a prefix that is
# swapped for the upstream's own base path. That is what lets a pane called "alice" show an agent that
# calls itself "coder-1", and what lets "google" show a site that knows nothing about either name.
#
# Two forms, picked by $DYNAMIC:
#   proxy_pass http://host:7681/prefix/;  nginx rewrites the prefix and resolves the name at start.
#     If a name does not resolve, nginx refuses to start at all: one missing agent takes the whole
#     desktop down.
#   set $upstream http://host:7681; rewrite ...; proxy_pass $upstream;
#     A proxy_pass built from a variable is resolved at request time (via the resolver directive), so
#     the front starts whether or not the agents exist and only the absent pane answers 502. A desktop
#     that composes agents should not depend on them being there.
render_locations() {
  _tsv=${1:-}
  [ -s "$_tsv" ] || return 0

  while IFS=$US read -r _kind _name _upstream _path _host; do
    printf '  location = /%s {\n' "$_name"
    printf '    return 308 /%s/;\n' "$_name"
    printf '  }\n'
    printf '  location /%s/ {\n' "$_name"

    if [ "$DYNAMIC" = 1 ]; then
      printf '    set %s %s;\n' "$UPSTREAM_VAR" "$_upstream"
      # shellcheck disable=SC2016  # deliberate: $1 here is nginx's capture group, not this shell's
      printf '    rewrite ^/%s/(.*)$ %s/$1 break;\n' "$_name" "$_path"
      printf '    proxy_pass %s;\n' "$UPSTREAM_VAR"
    else
      printf '    proxy_pass %s%s/;\n' "$_upstream" "$_path"
    fi

    if [ "$_kind" = site ]; then
      # Framing an arbitrary origin through nginx keeps the pane same-origin, but the origin then
      # gets a request it was never designed for: it wants its own Host header, its own SNI name,
      # and it will usually refuse to be framed.
      printf '    proxy_set_header Host %s;\n' "$_host"
      # Re-emitted, not inherited. nginx replaces an inherited directive *set* wholesale as soon as a
      # nested block states one of its own, so the single Host line above silently drops the server-level
      # Upgrade/Connection pair, and a terminal framed this way stops being one: ttyd sees a plain GET on
      # its /ws path, logs it as HTTP, and never spawns a process. Measured in the front testbed with
      # COLUMNS='keys=http://<node>:<port>/keys' against a ttyd whose command wrote every byte it received
      # to a file - no file appeared, because no process started.
      printf '    proxy_set_header Upgrade $http_upgrade;\n'
      printf '    proxy_set_header Connection $connection_upgrade;\n'
      printf '    proxy_hide_header X-Frame-Options;\n'
      printf '    proxy_hide_header Content-Security-Policy;\n'
      case "$_upstream" in
        https://*)
          printf '    proxy_ssl_server_name on;\n'
          printf '    proxy_ssl_name %s;\n' "$_host"
          printf '    proxy_ssl_protocols TLSv1.2 TLSv1.3;\n'
          ;;
      esac
    fi

    printf '  }\n'
    printf '\n'
  done <"$_tsv"
}

# One cell per agent: the pane, its label, and the upstream it is wired to (for debugging in devtools).
render_group() {
  _tsv=${1:-}
  _axis=${2:-}
  [ -s "$_tsv" ] || return 0

  printf '      <div class="group group-%s">\n' "$_axis"
  while IFS=$US read -r _kind _name _upstream _path _host; do
    printf '        <div class="cell" data-agent="%s" data-upstream="%s%s">\n' "$_name" "$_upstream" "$_path"
    printf '          <span class="tag">%s</span>\n' "$_name"
    printf '          <iframe id="f-%s" src="/%s/" title="%s" frameborder="0" scrolling="no" style="overflow: hidden"></iframe>\n' \
      "$_name" "$_name" "$_name"
    printf '        </div>\n'
  done <"$_tsv"
  printf '      </div>\n'
}

# Which half of the viewport each group gets. The inner split of each half (equal strips or equal
# bands) is fixed in the template's CSS and needs no count, so a group of one or fifty both work.
render_groups() {
  case "$LAYOUT" in
    columns_left | rows_bottom)
      render_group "$tmp/columns.tsv" columns
      render_group "$tmp/rows.tsv" rows
      ;;
    columns_right | rows_top)
      render_group "$tmp/rows.tsv" rows
      render_group "$tmp/columns.tsv" columns
      ;;
  esac
}

render_grid_css() {
  if [ -s "$tmp/columns.tsv" ] && [ -s "$tmp/rows.tsv" ]; then
    case "$LAYOUT" in
      columns_left | columns_right) printf '      #wrap { grid-template-columns: 1fr 1fr; }\n' ;;
      *) printf '      #wrap { grid-template-rows: 1fr 1fr; }\n' ;;
    esac
  else
    printf '      #wrap { grid-template-columns: 1fr; }\n'
  fi
}

# Replace @@MARKER@@ lines with the contents of a file. Inserted text is copied literally: no shell
# quoting, no regex, so an upstream URL containing / & or \ cannot corrupt the output.
render() {
  _tpl=${1:-}
  _out=${2:-}
  [ -f "$_tpl" ] || die "missing template $_tpl"

  awk \
    -v LOCATIONS="$tmp/locations.frag" \
    -v GROUPS="$tmp/groups.frag" \
    -v GRIDCSS="$tmp/gridcss.frag" \
    -v RESOLVER="$tmp/resolver.frag" \
    -v TITLE="$PAGE_TITLE" '
    function emit(file,  line) {
      while ((getline line < file) > 0) print line
      close(file)
    }
    /@@AGENT_LOCATIONS@@/ { emit(LOCATIONS); next }
    /@@GROUPS@@/ { emit(GROUPS); next }
    /@@GRID_CSS@@/ { emit(GRIDCSS); next }
    /@@RESOLVER@@/ { emit(RESOLVER); next }
    /@@PAGE_TITLE@@/ {
      # mid-line insertion, kept literal (a title may legitimately contain & or regex characters)
      where = index($0, "@@PAGE_TITLE@@")
      printf "%s%s%s\n", substr($0, 1, where - 1), TITLE, substr($0, where + 14)
      next
    }
    { print }
  ' "$_tpl" >"$_out"
}

case "$LAYOUT" in
  columns_left | columns_right | rows_top | rows_bottom) ;;
  *) die "LAYOUT must be columns_left, columns_right, rows_top or rows_bottom (got '$LAYOUT')" ;;
esac

parse_spec "$COLUMNS_SPEC" "$tmp/columns.tsv"
parse_spec "$ROWS_SPEC" "$tmp/rows.tsv"

_duplicates=$(agent_names "$tmp/columns.tsv" "$tmp/rows.tsv" | sort | uniq -d)
if [ -n "$_duplicates" ]; then
  die "agent names appear in both COLUMNS and ROWS (or twice in one): $(printf '%s' "$_duplicates" | tr '\n' ' ')"
fi

if [ ! -s "$tmp/columns.tsv" ] && [ ! -s "$tmp/rows.tsv" ]; then
  die "no agents: set COLUMNS and/or ROWS to comma separated name=url pairs"
fi

render_locations "$tmp/columns.tsv" >"$tmp/locations.frag"
render_locations "$tmp/rows.tsv" >>"$tmp/locations.frag"
render_groups >"$tmp/groups.frag"
render_grid_css >"$tmp/gridcss.frag"

if [ "$DYNAMIC" = 1 ]; then
  printf '  resolver %s valid=10s ipv6=off;\n' "$RESOLVER" >"$tmp/resolver.frag"
else
  {
    printf '  # Upstream names are resolved when nginx starts (no resolver configured): an agent\n'
    printf '  # whose name does not resolve stops the whole front from coming up. Set RESOLVER=<ip>\n'
    printf '  # for per-request resolution, or RESOLVER=off to make this mode deliberate.\n'
  } >"$tmp/resolver.frag"
fi

render "$TEMPLATE_DIR/nginx.conf.template" "$CONF_OUT"
render "$TEMPLATE_DIR/index.html.template" "$HTML_OUT"

printf '%s: layout=%s\n' "$PROG" "$LAYOUT"
printf '  columns: %s\n' "$(agent_names "$tmp/columns.tsv" | tr '\n' ' ')"
printf '  rows:    %s\n' "$(agent_names "$tmp/rows.tsv" | tr '\n' ' ')"
if [ "$DYNAMIC" = 1 ]; then
  printf '  upstreams resolved per request via %s\n' "$RESOLVER"
else
  printf '  upstreams resolved at start (no resolver found)\n'
fi

# An overridden command line is how a check (CI, or a human) validates the rendered config instead of
# serving it: docker run --entrypoint /docker-entrypoint.nginx.sh <image> nginx -t
if [ "$#" -gt 0 ]; then exec "$@"; fi
exec nginx -g 'daemon off;'
