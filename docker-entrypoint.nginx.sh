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
# PANES_PER_TAB
#   How many panes one page may show before the desktop is spread over more pages. Default 6; 0 (or
#   off/none/all) puts every pane on one page, which is what this front did before tabs existed.
#   The split is by count, not by geometry: 20 panes at 6 per tab is 4 pages, and the entrypoint
#   balances them (ceil(20/6)=4 pages, ceil(20/4)=5 panes each) rather than filling pages and leaving
#   scraps, because a 6,6,6,2 desktop gives four different pane widths and 5,5,5,5 gives one.
#   Order is preserved: columns as declared, then rows as declared, cut at the page boundaries, and a
#   page keeps each pane's group - so a tab holding three columns and three rows is laid out exactly the
#   way LAYOUT says a 3+3 desktop is, and a tab holding one pane gets the whole viewport.
#   Pages are files, not a router: index.html is the first tab, tab-2.html ... tab-N.html the rest,
#   all.html every pane at once. /tab-2 redirects to /tab-2.html. A tab is a page load, which means the
#   panes on the tab you left disconnect from their terminals (tmux keeps the session; the page you arrive
#   at attaches a new client) and the keyboard broadcast and the expand chord only see the panes on the
#   page you are on.
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

# 6 is a number chosen for a laptop viewport, not derived from anything: at 800px wide, six columns is
# 133px per pane, which is about 19 terminal columns - enough to read and narrow enough to be a pane
# rather than a window. It is also the point where the 20-pane desktop this repo ships stops being 40px
# strips (measured in the front testbed: "minecraft-pinger" at 78px in a 40px pane pushed the page 42px
# wider than the viewport).
PANES_PER_TAB=${PANES_PER_TAB:-6}
case "$PANES_PER_TAB" in
  0 | off | none | all) PANES_PER_TAB=0 ;;
  *[!0-9]*) die "PANES_PER_TAB must be a pane count, or 0 for no tabs (got '$PANES_PER_TAB')" ;;
esac
case "$PANES_PER_TAB" in
  0) ;;
  1 | 2 | 3 | 4 | 5) ;; # legal, pointless next to a tab strip that costs 22px of height to show one pane
esac

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
    # The front's own pages are files in the same directory an agent's location is a prefix of, and the
    # tab pages are named by number. A pane called index, all or tab-1 would be a name that is also a
    # route, which is the kind of collision only the person deploying it would notice, and only at the
    # front, and only sometimes.
    index | index.html | all | all.html) die "agent name '$1' is a page the front renders itself" ;;
    tab-[0-9]*) die "agent name '$1' collides with the front's tab pages (/tab-N.html)" ;;
    # Not a scheme check: a pane name is used as a URL prefix, and one ending in .html would be a pane
    # that looks like a page and is served by a location instead of by the file server.
    *.html) die "agent name '$1' ends in .html, which is what the front's own pages are" ;;
    slopyphus-desktop | slopyphus-desktop.css | slopyphus-desktop.js)
      die "agent name '$1' collides with the stylesheet and script every page links"
      ;;
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

# Which half of the viewport each group gets, for one page's two tables. The inner split of each half
# (equal strips or equal bands) is in the shared stylesheet and needs no count, so a group of one or
# fifty both work.
render_groups() {
  _cols=${1:-}
  _rows=${2:-}
  case "$LAYOUT" in
    columns_left | rows_bottom)
      render_group "$_cols" columns
      render_group "$_rows" rows
      ;;
    columns_right | rows_top)
      render_group "$_rows" rows
      render_group "$_cols" columns
      ;;
  esac
}

# The per-page CSS. Two things, both of which depend on this page and on nothing else: how the viewport
# is shared between the page's two groups (a single group takes all of it), and how tall the tab strip
# is, which the shared stylesheet needs as a number because an expanded pane starts below the strip
# rather than under it. 0px on a page with no strip, so the same rule is right on both kinds of page.
render_grid_css() {
  _cols=${1:-}
  _rows=${2:-}
  _tabs=${3:-0}
  if [ "$_tabs" -gt 1 ] 2>/dev/null; then
    printf '      body { --tabs-h: 22px; }\n'
  else
    printf '      body { --tabs-h: 0px; }\n'
  fi
  if [ -s "$_cols" ] && [ -s "$_rows" ]; then
    case "$LAYOUT" in
      columns_left | columns_right) printf '      #wrap { grid-template-columns: 1fr 1fr; }\n' ;;
      *) printf '      #wrap { grid-template-rows: 1fr 1fr; }\n' ;;
    esac
  else
    printf '      #wrap { grid-template-columns: 1fr; }\n'
  fi
}

# The tab strip: a link per page and the panes that live on each one, in the link's title and in a dim
# hint on this page. Numbers rather than names because the strip shares its width with every other tab,
# and 20 panes is 4 tabs at 800px, which is not room for names. aria-current on the page you are on so
# the marked tab is a fact the browser knows rather than a class this script sets.
render_tab_nav() {
  _tabs=${1:-1}
  _self=${2:-1}
  _label=${3:-}
  shift 3
  [ "$_tabs" -gt 1 ] 2>/dev/null || return 0
  printf '    <nav id="tabs">\n'
  _k=1
  while [ "$_k" -le "$_tabs" ]; do
    _href=/
    _name="tab $_k"
    if [ "$_k" -gt 1 ]; then _href="/tab-$_k.html"; fi
    _hint=$(trim "$(agent_names "$tmp/tab-$_k.columns.tsv" "$tmp/tab-$_k.rows.tsv" | tr '\n' ' ')")
    if [ "$_k" = "$_self" ]; then
      printf '      <a href="%s" title="%s (%s)" aria-current="page">%d</a>\n' "$_href" "$_name" "$_hint" "$_k"
    else
      printf '      <a href="%s" title="%s (%s)">%d</a>\n' "$_href" "$_name" "$_hint" "$_k"
    fi
    _k=$((_k + 1))
  done
  if [ -n "$_label" ]; then
    if [ "$_self" = 0 ]; then
      printf '      <a href="/all.html" title="every pane on one page" aria-current="page">all</a>\n'
    else
      printf '      <a href="/all.html" title="every pane on one page">all</a>\n'
    fi
  fi
  _here=$(agent_names "$@" | tr '\n' ' ')
  printf '      <span class="hint">%s</span>\n' "$(trim "$_here")"
  printf '    </nav>\n'
}

# Routes the front owns for itself: the short spellings of its own pages, and no-store on the page and
# the two assets every page links. The second one is not tidiness - a pane's client is embedded in a
# binary and a rollout changes it, and a desktop page cached beside it keeps referencing the stylesheet
# and script of the rollout before, which from the browser looks exactly like a fix that did not deploy.
#
# Served, not redirected. `return 308 /tab-3.html` would build an absolute URL from $server_name and
# $server_port, which on a NodePort or any front reached on a port other than the one it listens on sends
# the browser to the wrong host - measured in the front testbed, where /tab-3 on port 38137 answered
# http://192.168.1.213/tab-3.html. try_files picks the file up from the server's own root and says nothing
# about where the front is.
render_page_locations() {
  _tabs=${1:-1}
  _k=1
  while [ "$_k" -le "$_tabs" ]; do
    if [ "$_k" = 1 ]; then
      printf '  location = /tab-1 {\n    add_header Cache-Control "no-store";\n    try_files /index.html =404;\n  }\n\n'
    else
      printf '  location = /tab-%d {\n    add_header Cache-Control "no-store";\n    try_files /tab-%d.html =404;\n  }\n\n' "$_k" "$_k"
    fi
    _k=$((_k + 1))
  done
  if [ "$_tabs" -gt 1 ] 2>/dev/null; then
    printf '  location = /all {\n    add_header Cache-Control "no-store";\n    try_files /all.html =404;\n  }\n\n'
  fi
  printf '  location ~ ^/(index|all|tab-[0-9]+)\\.html$ {\n    add_header Cache-Control "no-store";\n  }\n\n'
  printf '  location = /slopyphus-desktop.css {\n    add_header Cache-Control "no-store";\n  }\n\n'
  printf '  location = /slopyphus-desktop.js {\n    add_header Cache-Control "no-store";\n  }\n\n'
}

# The plan: every pane of the desktop in one ordered table, tagged with the group it was declared in,
# which is what lets a page rebuild its own two tables and hand them to the renderers unchanged. Columns
# first, then rows, each in the order declared - the same order the single-page desktop laid panes out in,
# so a desktop that fits on one page renders identically with tabs switched on.
build_plan() {
  : >"$tmp/plan.tsv"
  tag_table columns "$tmp/columns.tsv" >>"$tmp/plan.tsv"
  tag_table rows "$tmp/rows.tsv" >>"$tmp/plan.tsv"
}

tag_table() {
  _group=$1
  _in=$2
  [ -s "$_in" ] || return 0
  awk -v g="$_group" 'NF { print g "\037" $0 }' "$_in"
}

# Cut the plan into pages of at most PANES_PER_TAB panes, balanced so the pages are as equal as the
# count allows, and write each page's two tables in the format the renderers already read. 0 panes per
# tab means no tabs: one page holding everything.
split_tabs() {
  _total=${1:-0}
  _tabs=${2:-1}
  _size=${3:-0}
  _k=1
  while [ "$_k" -le "$_tabs" ]; do
    : >"$tmp/tab-$_k.columns.tsv"
    : >"$tmp/tab-$_k.rows.tsv"
    _k=$((_k + 1))
  done
  [ "$_total" -gt 0 ] || return 0
  _i=0
  while IFS=$US read -r _group _kind _name _upstream _path _host; do
    _i=$((_i + 1))
    _k=$(( (_i - 1) / _size + 1 ))
    printf '%s\037%s\037%s\037%s\037%s\n' "$_kind" "$_name" "$_upstream" "$_path" "$_host" >>"$tmp/tab-$_k.$_group.tsv"
  done <"$tmp/plan.tsv"
}

# Replace @@MARKER@@ lines with the contents of a file. Inserted text is copied literally: no shell
# quoting, no regex, so an upstream URL containing / & or \ cannot corrupt the output. The title is the
# one mid-line substitution, because it belongs in a title element rather than on a line of its own.
render() {
  _tpl=${1:-}
  _out=${2:-}
  _title=${3:-$PAGE_TITLE}
  _nav=${4:-}
  [ -f "$_tpl" ] || die "missing template $_tpl"

  awk \
    -v LOCATIONS="$tmp/locations.frag" \
    -v GROUPS="$tmp/groups.frag" \
    -v GRIDCSS="$tmp/gridcss.frag" \
    -v NAV="$_nav" \
    -v RESOLVER="$tmp/resolver.frag" \
    -v TITLE="$_title" '
    function emit(file,  line) {
      if (file == "") return
      while ((getline line < file) > 0) print line
      close(file)
    }
    /@@AGENT_LOCATIONS@@/ { emit(LOCATIONS); next }
    /@@GROUPS@@/ { emit(GROUPS); next }
    /@@GRID_CSS@@/ { emit(GRIDCSS); next }
    /@@TAB_NAV@@/ { emit(NAV); next }
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

# One ordered table of every pane, then the pages it is cut into. An agent gets exactly one nginx
# location however many pages could show it, so locations come from the original tables and the pages
# contribute only their own routes.
build_plan
page_total=$(agent_names "$tmp/columns.tsv" "$tmp/rows.tsv" | grep -c .)
if [ "$PANES_PER_TAB" = 0 ] || [ "$page_total" -le "$PANES_PER_TAB" ]; then
  page_tabs=1
  page_size=$page_total
else
  page_tabs=$(( (page_total + PANES_PER_TAB - 1) / PANES_PER_TAB ))
  page_size=$(( (page_total + page_tabs - 1) / page_tabs ))
fi
split_tabs "$page_total" "$page_tabs" "$page_size"
render_page_locations "$page_tabs" >>"$tmp/locations.frag"

# Where the extra pages go: beside the page the entrypoint was told to write, which keeps a configured
# HTML_OUT of any path working rather than assuming /usr/share/nginx/html.
HTML_DIR=${HTML_OUT%/*}
if [ "$HTML_DIR" = "$HTML_OUT" ]; then HTML_DIR=.; fi
if [ -z "$HTML_DIR" ]; then HTML_DIR=/; fi

# Render is not additive. A front that goes from 20 panes to 3 leaves tab-4.html and all.html sitting in
# the served directory, and a stale page is one that still works: it would show panes that are no longer on
# the desktop, framing locations that no longer exist. The front owns those names - validate_name refuses an
# agent that would collide with them - so it clears them before writing the set this render asked for.
rm -f "$HTML_DIR"/tab-*.html "$HTML_DIR/all.html" 2>/dev/null || true

# One page per tab, from one template. Tab 1 is index.html so the front's existing URL (/) keeps being
# the desktop, and the tabs after it are files a browser can be pointed at directly.
#
# The loop's own variables are named _page_* rather than the _k / _out the renderers use internally,
# because this script is written for busybox ash and calls no function-local variables: a renderer's _k
# is the same _k the caller is looping on. Left as _k, render_tab_nav's own tab loop finishes by setting
# _k past the end of the caller's, and the silent result is a desktop that renders tab 1, skips every
# other tab, and still prints a summary claiming it made them all.
_page=1
while [ "$_page" -le "$page_tabs" ]; do
  if [ "$_page" -gt 1 ]; then
    _page_title="$PAGE_TITLE - tab $_page"
    _page_out="$HTML_DIR/tab-$_page.html"
  else
    _page_title=$PAGE_TITLE
    _page_out=$HTML_OUT
  fi
  render_groups "$tmp/tab-$_page.columns.tsv" "$tmp/tab-$_page.rows.tsv" >"$tmp/groups.frag"
  render_grid_css "$tmp/tab-$_page.columns.tsv" "$tmp/tab-$_page.rows.tsv" "$page_tabs" >"$tmp/gridcss.frag"
  render_tab_nav "$page_tabs" "$_page" "$([ "$page_tabs" -gt 1 ] && echo all)" \
    "$tmp/tab-$_page.columns.tsv" "$tmp/tab-$_page.rows.tsv" >"$tmp/nav.frag"
  render "$TEMPLATE_DIR/index.html.template" "$_page_out" "$_page_title" "$tmp/nav.frag"
  _page=$((_page + 1))
done

# The escape hatch, and the only page that shows everything at once: worth having when tabs exist, and
# worth not having when they do not, because a one-page desktop would be rendering the same page twice.
if [ "$page_tabs" -gt 1 ] 2>/dev/null; then
  render_groups "$tmp/columns.tsv" "$tmp/rows.tsv" >"$tmp/groups.frag"
  render_grid_css "$tmp/columns.tsv" "$tmp/rows.tsv" "$page_tabs" >"$tmp/gridcss.frag"
  render_tab_nav "$page_tabs" 0 all "$tmp/columns.tsv" "$tmp/rows.tsv" >"$tmp/nav.frag"
  render "$TEMPLATE_DIR/index.html.template" "$HTML_DIR/all.html" "$PAGE_TITLE - all" "$tmp/nav.frag"
fi

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

printf '%s: layout=%s panes_per_tab=%s pages=%s\n' "$PROG" "$LAYOUT" "$PANES_PER_TAB" "$page_tabs"
printf '  columns: %s\n' "$(agent_names "$tmp/columns.tsv" | tr '\n' ' ')"
printf '  rows:    %s\n' "$(agent_names "$tmp/rows.tsv" | tr '\n' ' ')"
_page=1
while [ "$_page" -le "$page_tabs" ]; do
  printf '  tab %d:   %s\n' "$_page" "$(trim "$(agent_names "$tmp/tab-$_page.columns.tsv" "$tmp/tab-$_page.rows.tsv" | tr '\n' ' ')")"
  _page=$((_page + 1))
done
if [ "$DYNAMIC" = 1 ]; then
  printf '  upstreams resolved per request via %s\n' "$RESOLVER"
else
  printf '  upstreams resolved at start (no resolver found)\n'
fi

# An overridden command line is how a check (CI, or a human) validates the rendered config instead of
# serving it: docker run --entrypoint /docker-entrypoint.nginx.sh <image> nginx -t
if [ "$#" -gt 0 ]; then exec "$@"; fi
exec nginx -g 'daemon off;'
