#!/usr/bin/env bash
# Measurements behind the erlang/otp documentation change
# "kernel: document how to bind a distributed node to loopback"
# (lib/kernel/doc/kernel_app.md, the inet_dist_use_interface entry).
#
# Cases are numbered as in README.md. Each case starts its own nodes and, where
# needed, its own epmd on a private port (EPMD_PORT, default 4370), so a system
# epmd on 4369 is never touched. Sockets are read from inside the BEAM
# (inet:sockname/1 on the node's own ports, gen_tcp:connect/4 against epmd,
# inet:getifaddrs/0 for the host addresses), so the only requirements are bash,
# erl and epmd on PATH. Cases 8, 9 and 23 edit /etc/hosts or the resolver; they
# run only with MEASURE_EDIT_ETC=1 set inside a container, which run-docker.sh
# does for its throwaway (--rm) containers, and the files are restored on exit.
#
# Usage: ./measure.sh          run every case
#        ./measure.sh 5 19     run selected cases (20 and 22 run with 19 and 21)
set -u
export ERL_EPMD_PORT="${EPMD_PORT:-4370}"
[ "$ERL_EPMD_PORT" != 4369 ] || { echo "measure.sh: refusing to run on the system epmd port 4369; set EPMD_PORT" >&2; exit 2; }
COOKIE="m$$"
TMP="$(mktemp -d)"
NODE_PIDS=()
trap 'cleanup' EXIT

cleanup() {
  for p in ${NODE_PIDS[@]+"${NODE_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  epmd -kill >/dev/null 2>&1
  for f in hosts resolv.conf nsswitch.conf; do [ -f "$TMP/etc.$f" ] && cat "$TMP/etc.$f" >"/etc/$f"; done
  rm -rf "$TMP"
}
backup_etc() { for f in hosts resolv.conf nsswitch.conf; do [ -f "$TMP/etc.$f" ] || cp "/etc/$f" "$TMP/etc.$f" 2>/dev/null; done; }

say() { printf '%s\n' "$*"; }
res() { printf '  -> %s\n' "$*"; }

# erl_eval ARGS... -- EXPR : run a throwaway node, print what EXPR prints.
erl_eval() {
  local args=(); while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  erl -noshell -setcookie "$COOKIE" "${args[@]}" -eval "$1, halt()." 2>&1
}

# Erlang expression: this node's listening TCP sockets as "addr:port" strings.
LISTENERS='string:join([begin {ok,{A,Po}} = inet:sockname(P), lists:flatten(io_lib:format("~s:~w", [inet:ntoa(A), Po])) end || P <- erlang:ports(), erlang:port_info(P, name) == {name, "tcp_inet"}, element(1, inet:peername(P)) == error], " ")'

# start_node LABEL SECONDS ARGS... : background node that prints its listeners
# to $TMP/LABEL.listeners, then sleeps SECONDS and halts.
start_node() {
  local label=$1 secs=$2; shift 2
  erl -noshell -setcookie "$COOKIE" "$@" \
    -eval "file:write_file(\"$TMP/$label.listeners\", $LISTENERS), timer:sleep($secs * 1000), halt()." \
    >"$TMP/$label.out" 2>&1 &
  NODE_PIDS+=("$!"); NODE_PID=$!
  sleep 1.5
}
listeners() { [ -s "$TMP/$1.listeners" ] && cat "$TMP/$1.listeners" || echo "<node did not start: $(tr '\n' ' ' <"$TMP/$1.out" | cut -c1-120)>"; }
stop_node() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# client TARGET ARGS... : connect from a throwaway node, report result and the client's own listeners.
client() {
  local target=$1; shift
  erl_eval "$@" -- "io:format(\"connect_node(~s) = ~w, client listeners [~s]~n\", ['$target', net_kernel:connect_node('$target'), $LISTENERS])" | grep -E '^connect_node' | tail -1
}
# ping TARGET ARGS... : net_adm:ping from a throwaway node.
ping_node() { local target=$1; shift; erl_eval "$@" -- "io:format(\"ping(~s) = ~w~n\", ['$target', net_adm:ping('$target')])" | grep -E '^ping\(' | tail -1; }

# remsh TARGET ARGS... : a real interactive remsh through a pty, if script(1) exists.
remsh() {
  local target=$1; shift
  if command -v script >/dev/null 2>&1; then
    local out; out=$(printf 'node().\n' | TERM=xterm timeout 8 script -qec "erl -setcookie $COOKIE $* -remsh $target" /dev/null 2>&1 | tr -d '\r')
    local hit; hit=$(printf '%s' "$out" | grep -oE "\($target\)1> node\(\)\.|Could not connect[^*]*" | head -1)
    echo "interactive remsh: ${hit:-<prompt not captured through this pty; see connect_node line>}"
  else echo "interactive remsh: script(1) not available, not measured"; fi
}

# epmd_probe ADDR... : does epmd answer on each address? (behavioral, from the BEAM)
epmd_probe() {
  local list; list=$(printf '"%s",' "$@"); list="[${list%,}]"
  erl_eval -- "P = list_to_integer(os:getenv(\"ERL_EPMD_PORT\")), F = fun(S) -> {ok, A} = inet:parse_address(S), Fam = case tuple_size(A) of 4 -> inet; 8 -> inet6 end, R = case gen_tcp:connect(A, P, [Fam], 500) of {ok, So} -> gen_tcp:close(So), \"answers\"; {error, E} -> atom_to_list(E) end, io_lib:format(\"~s=~s\", [S, R]) end, io:format(\"epmd ~s~n\", [string:join([F(S) || S <- $list], \" \")])" | tail -1
}
epmd_kill() { epmd -kill >/dev/null 2>&1; sleep 0.3; }
in_container() { [ -f /.dockerenv ] && [ -w /etc/hosts ]; }
may_edit_etc() { [ "${MEASURE_EDIT_ETC:-}" = 1 ] && in_container; }

# ---- environment -------------------------------------------------------------
say "environment"
res "$(erl_eval -- 'io:format("OTP ~s erts-~s ~s", [erlang:system_info(otp_release), erlang:system_info(version), erlang:system_info(system_architecture)])')"
read -r V4 V6 < <(erl_eval -- '{ok, L} = inet:getifaddrs(), As = [A || {_, Os} <- L, {addr, A} <- Os], V4 = [A || A = {A1, _, _, _} <- As, A1 =/= 127], V6 = [A || A = {A1, _, _, _, _, _, _, _} <- As, A1 =/= 16#fe80, A =/= {0, 0, 0, 0, 0, 0, 0, 1}], P = fun([]) -> "-"; ([X | _]) -> inet:ntoa(X) end, io:format("~s ~s", [P(V4), P(V6)])' | tail -1)
HOST=$(erl_eval -- '{ok, H} = inet:gethostname(), io:format("~s", [hd(string:split(H, "."))])' | tail -1)
res "non-loopback IPv4: $V4, global IPv6: $V6, short hostname: $HOST"
res "hostname resolves to: $(erl_eval -- "io:format(\"~w\", [inet:getaddr(\"$HOST\", inet)])" | tail -1); localhost (inet/inet6): $(erl_eval -- 'io:format("~w / ~w", [inet:getaddr("localhost", inet), inet:getaddr("localhost", inet6)])' | tail -1)"
res "private epmd port: $ERL_EPMD_PORT; in container: $(in_container && echo yes || echo no)"
PROBE_ADDRS=(127.0.0.1 ::1); [ "$V4" != "-" ] && PROBE_ADDRS+=("$V4"); [ "$V6" != "-" ] && PROBE_ADDRS+=("$V6")
IDUI4='-kernel inet_dist_use_interface {127,0,0,1}'
IDUI6='-kernel inet_dist_use_interface {0,0,0,0,0,0,0,1}'

want() { [ $# -eq 0 ] && return 0; local c; for c in "$@"; do [ "$c" = "$CASE" ] && return 0; done; return 1; }
SELECTED=("$@")
for c in ${SELECTED[@]+"${SELECTED[@]}"}; do case $c in 20) SELECTED+=(19);; 22) SELECTED+=(21);; esac; done  # 20 and 22 are measured inside 19 and 21
run_case() { CASE=$1; want ${SELECTED[@]+"${SELECTED[@]}"} || return 1; say; say "## $1. $2"; }

# ---- listener binding ----------------------------------------------------------
if run_case 1 "IPv4: -name alone"; then
  epmd_kill; start_node c1 4 -name c1@127.0.0.1; res "listeners: $(listeners c1)"; stop_node $NODE_PID; fi
if run_case 2 "IPv6: -proto_dist inet6_tcp -name alone"; then
  start_node c2 4 -proto_dist inet6_tcp -name 'c2@::1'; res "listeners: $(listeners c2)"; stop_node $NODE_PID; fi
if run_case 3 "IPv4: -name + inet_dist_use_interface {127,0,0,1}; local node with the cookie connects"; then
  start_node c3 6 -name c3@127.0.0.1 $IDUI4; res "listeners: $(listeners c3)"; res "$(ping_node c3@127.0.0.1 -name p@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID; fi
if run_case 4 "IPv6: -name + inet_dist_use_interface {0,0,0,0,0,0,0,1}; local IPv6 node connects"; then
  start_node c4 6 -proto_dist inet6_tcp -name 'c4@::1' $IDUI6; res "listeners: $(listeners c4)"; res "$(ping_node 'c4@::1' -proto_dist inet6_tcp -name 'p6@::1' -dist_listen false)"; stop_node $NODE_PID; fi

# ---- name must resolve to the bound address ------------------------------------
if run_case 5 "IPv4: name resolves to the non-loopback address, listener on loopback (control: unbound listener)"; then
  if [ "$V4" = "-" ]; then res "not measured: no non-loopback IPv4 address here"; else
  start_node c5 6 -name "c5@$V4" $IDUI4; res "loopback listener: $(listeners c5); $(ping_node "c5@$V4" -name p@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID
  start_node c5b 6 -name "c5b@$V4"; res "unbound listener: $(listeners c5b); $(ping_node "c5b@$V4" -name p@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID; fi; fi
if run_case 6 "IPv6: name resolves to the global IPv6 address, listener on ::1 (control: unbound listener)"; then
  if [ "$V6" = "-" ]; then res "not measured: no global IPv6 address here"; else
  start_node c6 6 -proto_dist inet6_tcp -name "c6@$V6" $IDUI6; res "loopback listener: $(listeners c6); $(ping_node "c6@$V6" -proto_dist inet6_tcp -name 'p6@::1' -dist_listen false)"; stop_node $NODE_PID
  start_node c6b 6 -proto_dist inet6_tcp -name "c6b@$V6"; res "unbound listener: $(listeners c6b); $(ping_node "c6b@$V6" -proto_dist inet6_tcp -name 'p6@::1' -dist_listen false)"; stop_node $NODE_PID; fi; fi
if run_case 7 "-sname with the hostname as it resolves on this machine, loopback listener, -sname client"; then
  res "hostname $HOST resolves to $(erl_eval -- "io:format(\"~w\", [inet:getaddr(\"$HOST\", inet)])" | tail -1)"
  start_node c7 6 -sname c7 $IDUI4; res "loopback listener: $(listeners c7); $(client "c7@$HOST" -sname p $IDUI4)"; stop_node $NODE_PID
  start_node c7b 6 -sname c7b; res "unbound listener: $(listeners c7b); $(client "c7b@$HOST" -sname p $IDUI4)"; stop_node $NODE_PID; fi
sname_with_hosts_entry() { # ADDR CASE-LABEL : container only, rewrites the hostname line of /etc/hosts
  { grep -vE "[[:space:]]$HOST([[:space:]]|$)" /etc/hosts; echo "$1 $HOST"; } >"$TMP/hosts" && cat "$TMP/hosts" >/etc/hosts
  res "/etc/hosts now maps $HOST to $1; inet:getaddr = $(erl_eval -- "io:format(\"~w\", [inet:getaddr(\"$HOST\", inet)])" | tail -1)"
  start_node "$2" 6 -sname "$2" $IDUI4; res "loopback listener: $(listeners "$2"); $(client "$2@$HOST" -sname p $IDUI4)"; stop_node $NODE_PID
  start_node "${2}b" 6 -sname "${2}b"; res "unbound listener: $(listeners "${2}b"); $(client "$2b@$HOST" -sname p $IDUI4)"; stop_node $NODE_PID
}
if run_case 8 "-sname where the hostname maps to 127.0.1.1 (Debian style; container only)"; then
  if may_edit_etc; then backup_etc; sname_with_hosts_entry 127.0.1.1 c8; cat "$TMP/etc.hosts" >/etc/hosts; else res "not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container (edits /etc/hosts)"; fi; fi
if run_case 9 "-sname where the hostname maps to the non-loopback IPv4 address (container only)"; then
  if may_edit_etc && [ "$V4" != "-" ]; then backup_etc; sname_with_hosts_entry "$V4" c9; cat "$TMP/etc.hosts" >/etc/hosts; else res "not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container with a non-loopback IPv4 address (edits /etc/hosts)"; fi; fi
if run_case 10 "-sname node@localhost + loopback listener; plain erl -remsh node@localhost"; then
  start_node c10 20 -sname c10@localhost $IDUI4; res "listeners: $(listeners c10)"; res "$(client c10@localhost -sname undefined)"; res "$(remsh c10@localhost)"; stop_node $NODE_PID; fi

# ---- the shell node --------------------------------------------------------------
if run_case 11 "recipe node; plain 'erl -remsh mynode@127.0.0.1' (a short-named client)"; then
  epmd_kill; start_node c11 20 -name mynode@127.0.0.1 $IDUI4 -env ERL_EPMD_ADDRESS 127.0.0.1; res "listeners: $(listeners c11)"
  res "$(client mynode@127.0.0.1 -sname undefined)"; res "$(remsh mynode@127.0.0.1)"; stop_node $NODE_PID; fi
if run_case 12 "recipe node; 'erl -name shell@127.0.0.1 -remsh mynode@127.0.0.1' (client listens on all interfaces)"; then
  start_node c12 20 -name mynode@127.0.0.1 $IDUI4 -env ERL_EPMD_ADDRESS 127.0.0.1
  res "$(client mynode@127.0.0.1 -name shell@127.0.0.1)"; res "$(remsh mynode@127.0.0.1 -name shell@127.0.0.1)"; stop_node $NODE_PID; fi
if run_case 13 "recipe node; 'erl -name shell@127.0.0.1 -dist_listen false -remsh mynode@127.0.0.1' (the documented shell)"; then
  start_node c13 20 -name mynode@127.0.0.1 $IDUI4 -env ERL_EPMD_ADDRESS 127.0.0.1
  res "$(client mynode@127.0.0.1 -name shell@127.0.0.1 -dist_listen false)"; res "$(remsh mynode@127.0.0.1 -name shell@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID; fi

# ---- epmd ------------------------------------------------------------------------
if run_case 14 "epmd started by the node, no ERL_EPMD_ADDRESS (node listener still on loopback)"; then
  epmd_kill; start_node c14 6 -name c14@127.0.0.1 $IDUI4; res "node listeners: $(listeners c14)"; res "$(epmd_probe "${PROBE_ADDRS[@]}")"; stop_node $NODE_PID; fi
if run_case 15 "epmd started by the node with -env ERL_EPMD_ADDRESS 127.0.0.1"; then
  epmd_kill; start_node c15 6 -name c15@127.0.0.1 $IDUI4 -env ERL_EPMD_ADDRESS 127.0.0.1; res "node listeners: $(listeners c15)"; res "$(epmd_probe "${PROBE_ADDRS[@]}")"; stop_node $NODE_PID; fi
if run_case 16 "fresh epmd with ERL_EPMD_ADDRESS=::1"; then
  epmd_kill; ERL_EPMD_ADDRESS=::1 epmd -daemon; sleep 0.5; res "$(epmd_probe "${PROBE_ADDRS[@]}")"; fi
if run_case 17 "epmd already running on all interfaces; node started with -env ERL_EPMD_ADDRESS 127.0.0.1"; then
  epmd_kill; epmd -daemon; sleep 0.5; res "before: $(epmd_probe "${PROBE_ADDRS[@]}")"
  start_node c17 6 -name c17@127.0.0.1 $IDUI4 -env ERL_EPMD_ADDRESS 127.0.0.1; res "node started, listeners: $(listeners c17); output: [$(tr '\n' ' ' <"$TMP/c17.out")]"; res "after:  $(epmd_probe "${PROBE_ADDRS[@]}")"; stop_node $NODE_PID; fi
if run_case 18 "'epmd -address 127.0.0.1 -daemon' started by hand before the node"; then
  epmd_kill; epmd -address 127.0.0.1 -daemon; sleep 0.5; res "$(epmd_probe "${PROBE_ADDRS[@]}")"
  start_node c18 6 -name c18@127.0.0.1 $IDUI4; res "node listeners: $(listeners c18); $(client c18@127.0.0.1 -name shell@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID; fi

# ---- only incoming connections are restricted ---------------------------------------
if run_case 19 "loopback-bound node connects OUT to a peer named on the non-loopback address; peer runs code back"; then
  if [ "$V4" = "-" ]; then res "not measured: no non-loopback IPv4 address here"; else
  epmd_kill; epmd -daemon; sleep 0.5; start_node c19peer 12 -name "other@$V4"; res "peer listeners [$(listeners c19peer)]"
  erl_eval -name mynode@127.0.0.1 $IDUI4 -- "B = 'other@$V4', C = net_kernel:connect_node(B), Back = rpc:call(B, rpc, call, [node(), os, getpid, []]), S = [{element(2, inet:sockname(P)), element(2, inet:peername(P))} || P <- erlang:ports(), erlang:port_info(P, name) == {name, \"tcp_inet\"}, element(1, inet:peername(P)) == ok, element(2, element(2, inet:peername(P))) =/= list_to_integer(os:getenv(\"ERL_EPMD_PORT\"))], io:format(\"  -> my listeners [~s]~n  -> connect_node(~s) = ~w~n  -> peer rpc:call back into me = ~p, my os pid = ~s~n  -> dist socket {local, peer} = ~w~n\", [$LISTENERS, B, C, Back, os:getpid(), S]), true = net_kernel:disconnect(B), ok = net_kernel:allow(['nobody@127.0.0.1']), io:format(\"  -> [case 20] after net_kernel:allow/1: connect_node(~s) = ~w~n\", [B, net_kernel:connect_node(B)])" | grep -- '->'
  stop_node $NODE_PID; fi; fi
if run_case 20 "(measured inside case 19) net_kernel:allow/1 blocks the outgoing connection"; then res "see case 19"; fi

# ---- IPv6 example verbatim --------------------------------------------------------
if run_case 21 "IPv6 example verbatim: -proto_dist inet6_tcp -name mynode@::1, {0,0,0,0,0,0,0,1}, -env ERL_EPMD_ADDRESS ::1 (case 22 follows on the same node)"; then
  epmd_kill; start_node c21 20 -proto_dist inet6_tcp -name 'mynode@::1' $IDUI6 -env ERL_EPMD_ADDRESS ::1; res "node listeners: $(listeners c21)"; res "$(epmd_probe "${PROBE_ADDRS[@]}")"
  say; say "## 22. IPv6 shell: -proto_dist inet6_tcp -name shell@::1 -dist_listen false -remsh mynode@::1; an IPv4-carrier client"
  res "$(client 'mynode@::1' -proto_dist inet6_tcp -name 'shell@::1' -dist_listen false)"; res "$(remsh 'mynode@::1' -proto_dist inet6_tcp -name 'shell@::1' -dist_listen false)"
  res "IPv4-carrier client: $(client 'mynode@::1' -name shell4@127.0.0.1 -dist_listen false)"; stop_node $NODE_PID; fi

# ---- extra: the undocumented atom ----------------------------------------------------
if run_case 24 "extra: inet_dist_use_interface loopback (atom; documented type is ip_address() only)"; then
  start_node c24 4 -name c24@127.0.0.1 -kernel inet_dist_use_interface loopback; res "inet_tcp:  $(listeners c24)"; stop_node $NODE_PID
  start_node c24b 4 -proto_dist inet6_tcp -name 'c24b@::1' -kernel inet_dist_use_interface loopback; res "inet6_tcp: $(listeners c24b)"; stop_node $NODE_PID; fi

# ---- last: resolver fallback (kills DNS in the container) -------------------------------
if run_case 23 "-sname where the hostname is in neither /etc/hosts nor DNS (Erlang's own-hostname fallback; container only, last)"; then
  if may_edit_etc; then
    backup_etc
    grep -vE "[[:space:]]$HOST([[:space:]]|$)" /etc/hosts >"$TMP/hosts" && cat "$TMP/hosts" >/etc/hosts
    printf 'nameserver 127.0.0.2\noptions timeout:1 attempts:1\n' >/etc/resolv.conf; sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf 2>/dev/null
    res "getent hosts $HOST: $(getent hosts "$HOST" 2>/dev/null || echo '<none>'); inet:getaddr = $(erl_eval -- "io:format(\"~w\", [inet:getaddr(\"$HOST\", inet)])" | tail -1); inet:gethostbyname_self = $(erl_eval -- "io:format(\"~w\", [inet:gethostbyname_self(\"$HOST\", inet)])" | tail -1)"
    epmd_kill; start_node c23 6 -sname c23 $IDUI4; res "loopback listener: $(listeners c23); $(client "c23@$HOST" -sname p $IDUI4)"; stop_node $NODE_PID
    res "/etc/hosts, /etc/resolv.conf and /etc/nsswitch.conf are restored by the cleanup trap"
  else res "not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container (edits /etc/hosts and the resolver)"; fi; fi

say; say "done; private epmd stopped, nodes stopped"
