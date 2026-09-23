#!/usr/bin/env escript
%%! -noshell
%% Measurements behind the erlang/otp documentation change
%% "kernel: document how to bind a distributed node to loopback"
%% (lib/kernel/doc/kernel_app.md, the inet_dist_use_interface entry).
%%
%% Native only: the nodes are peers from the OTP `peer` module (ports owned by
%% this VM, controlled over their standard I/O, no shell), sockets are read
%% inside each node over peer:call/4 (inet:sockname/1), epmd is probed with
%% gen_tcp:connect/4 and stopped with its own KILL_REQ, and `epmd -daemon`,
%% `erl -remsh` and `getent` are started with open_port/2.
%%
%% Cases are numbered as in README.md. Each case starts its own nodes and, where
%% needed, its own epmd on a private port (EPMD_PORT, default 4370), so a system
%% epmd on 4369 is never touched. Cases 8, 9 and 23 edit /etc/hosts or the
%% resolver; they run only with MEASURE_EDIT_ETC=1 set inside a container, which
%% run-docker.sh does for its throwaway (--rm) containers, and the files are
%% restored when the script ends.
%%
%% Usage: escript measure.escript          run every case
%%        escript measure.escript 5 19     selected cases (20 and 22 run with 19 and 21)
-mode(compile).
-include_lib("kernel/include/file.hrl").

-define(IDUI4, ["-kernel", "inet_dist_use_interface", "{127,0,0,1}"]).
-define(IDUI6, ["-kernel", "inet_dist_use_interface", "{0,0,0,0,0,0,0,1}"]).
-define(INET6, ["-proto_dist", "inet6_tcp"]).
-define(ETC, ["/etc/hosts", "/etc/resolv.conf", "/etc/nsswitch.conf"]).

main(Args) ->
    PortStr = os:getenv("EPMD_PORT", "4370"),
    PortStr =/= "4369" orelse
        begin io:format(standard_error, "measure.escript: refusing to run on the system epmd port 4369; set EPMD_PORT~n", []),
              halt(2) end,
    os:putenv("ERL_EPMD_PORT", PortStr),
    Port = list_to_integer(PortStr),
    %% random per run: the control rows listen on every interface for a few seconds
    Cookie = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
    Etc = [{F, file:read_file(F)} || F <- ?ETC],
    S = #{cookie => Cookie, port => Port, sel => selected(Args)},
    try run(S)
    after restore_etc(Etc), epmd_kill(Port)
    end,
    halt().

selected([]) -> all;
selected(Args) ->
    Ns = [list_to_integer(A) || A <- Args],
    %% 20 and 22 are measured inside 19 and 21
    Ns ++ [19 || lists:member(20, Ns)] ++ [21 || lists:member(22, Ns)].

run(S0) ->
    say("environment", []),
    res("OTP ~s erts-~s ~s", [erlang:system_info(otp_release), erlang:system_info(version), erlang:system_info(system_architecture)]),
    {ok, L} = inet:getifaddrs(),
    As = [A || {_, Os} <- L, {addr, A} <- Os],
    First = fun([]) -> "-"; ([X | _]) -> inet:ntoa(X) end,
    V4 = First([A || A = {A1, _, _, _} <- As, A1 =/= 127]),
    V6 = First([A || A = {A1, _, _, _, _, _, _, _} <- As, A1 =/= 16#fe80, A =/= {0, 0, 0, 0, 0, 0, 0, 1}]),
    {ok, H} = inet:gethostname(),
    Host = hd(string:split(H, ".")),
    res("non-loopback IPv4: ~s, global IPv6: ~s, short hostname: ~s", [V4, V6, Host]),
    res("hostname resolves to: ~w; localhost (inet/inet6): ~w / ~w",
        [inet:getaddr(Host, inet), inet:getaddr("localhost", inet), inet:getaddr("localhost", inet6)]),
    res("private epmd port: ~w; in container: ~s", [maps:get(port, S0), yes_no(in_container())]),
    Probe = ["127.0.0.1", "::1"] ++ [V4 || V4 =/= "-"] ++ [V6 || V6 =/= "-"],
    S = S0#{v4 => V4, v6 => V6, host => Host, probe => Probe},
    lists:foreach(fun({N, Title, F}) -> run_case(S, N, Title, F) end, cases(S)),
    say("", []),
    say("done; private epmd stopped, nodes stopped", []).

run_case(S, N, Title, F) ->
    case maps:get(sel, S) =:= all orelse lists:member(N, maps:get(sel, S)) of
        false -> ok;
        true ->
            say("", []), say("## ~w. ~s", [N, Title]),
            try F()
            catch C:R:St -> res("error: ~p", [{C, R, lists:sublist(St, 1)}])
            end
    end.

cases(S = #{v4 := V4, v6 := V6, host := Host, probe := Probe, port := Port}) ->
    Recipe = ?IDUI4 ++ ["-env", "ERL_EPMD_ADDRESS", "127.0.0.1"],
    NoListen = ["-dist_listen", "false"],
    Shell = fun(Extra) -> client(S, "mynode@127.0.0.1", shell, "127.0.0.1", true, Extra) end,
    [
     %% ---- listener binding ----
     {1, "IPv4: -name alone",
      fun() -> epmd_kill(Port), with_node(S, c1, "127.0.0.1", true, [], fun(N) -> res("listeners: ~s", [listeners(N)]) end) end},
     {2, "IPv6: -proto_dist inet6_tcp -name alone",
      fun() -> with_node(S, c2, "::1", true, ?INET6, fun(N) -> res("listeners: ~s", [listeners(N)]) end) end},
     {3, "IPv4: -name + inet_dist_use_interface {127,0,0,1}; local node with the cookie connects",
      fun() -> with_node(S, c3, "127.0.0.1", true, ?IDUI4, fun(N) ->
                   res("listeners: ~s", [listeners(N)]),
                   res("~s", [ping(S, "c3@127.0.0.1", p, "127.0.0.1", true, NoListen)]) end) end},
     {4, "IPv6: -name + inet_dist_use_interface {0,0,0,0,0,0,0,1}; local IPv6 node connects",
      fun() -> with_node(S, c4, "::1", true, ?INET6 ++ ?IDUI6, fun(N) ->
                   res("listeners: ~s", [listeners(N)]),
                   res("~s", [ping(S, "c4@::1", p6, "::1", true, ?INET6 ++ NoListen)]) end) end},

     %% ---- name must resolve to the bound address ----
     {5, "IPv4: name resolves to the non-loopback address, listener on loopback (control: unbound listener)",
      fun() when V4 =:= "-" -> res("not measured: no non-loopback IPv4 address here", []);
         () ->
              with_node(S, c5, V4, true, ?IDUI4, fun(N) ->
                  res("loopback listener: ~s; ~s", [listeners(N), ping(S, "c5@" ++ V4, p, "127.0.0.1", true, NoListen)]) end),
              with_node(S, c5b, V4, true, [], fun(N) ->
                  res("unbound listener: ~s; ~s", [listeners(N), ping(S, "c5b@" ++ V4, p, "127.0.0.1", true, NoListen)]) end)
      end},
     {6, "IPv6: name resolves to the global IPv6 address, listener on ::1 (control: unbound listener)",
      fun() when V6 =:= "-" -> res("not measured: no global IPv6 address here", []);
         () ->
              with_node(S, c6, V6, true, ?INET6 ++ ?IDUI6, fun(N) ->
                  res("loopback listener: ~s; ~s", [listeners(N), ping(S, "c6@" ++ V6, p6, "::1", true, ?INET6 ++ NoListen)]) end),
              with_node(S, c6b, V6, true, ?INET6, fun(N) ->
                  res("unbound listener: ~s; ~s", [listeners(N), ping(S, "c6b@" ++ V6, p6, "::1", true, ?INET6 ++ NoListen)]) end)
      end},
     {7, "-sname with the hostname as it resolves on this machine, loopback listener, -sname client",
      fun() ->
              res("hostname ~s resolves to ~w", [Host, fresh(S, inet, getaddr, [Host, inet])]),
              sname_pair(S, c7, c7b)
      end},
     {8, "-sname where the hostname maps to 127.0.1.1 (Debian style; container only)",
      fun() -> case may_edit_etc() of
                   true -> sname_with_hosts_entry(S, "127.0.1.1", c8, c8b);
                   false -> res("not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container (edits /etc/hosts)", [])
               end end},
     {9, "-sname where the hostname maps to the non-loopback IPv4 address (container only)",
      fun() -> case may_edit_etc() andalso V4 =/= "-" of
                   true -> sname_with_hosts_entry(S, V4, c9, c9b);
                   false -> res("not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container with a non-loopback IPv4 address (edits /etc/hosts)", [])
               end end},
     {10, "-sname node@localhost + loopback listener; plain erl -remsh node@localhost",
      fun() -> with_node(S, c10, "localhost", false, ?IDUI4, fun(N) ->
                   res("listeners: ~s", [listeners(N)]),
                   res("~s", [client(S, "c10@localhost", none, none, false, ["-sname", "undefined"])]),
                   res("~s", [remsh(S, "c10@localhost", [])]) end) end},

     %% ---- the shell node ----
     {11, "recipe node; plain 'erl -remsh mynode@127.0.0.1' (a short-named client)",
      fun() -> epmd_kill(Port), with_node(S, mynode, "127.0.0.1", true, Recipe, fun(N) ->
                   res("listeners: ~s", [listeners(N)]),
                   res("~s", [client(S, "mynode@127.0.0.1", none, none, false, ["-sname", "undefined"])]),
                   res("~s", [remsh(S, "mynode@127.0.0.1", [])]) end) end},
     {12, "recipe node; 'erl -name shell@127.0.0.1 -remsh mynode@127.0.0.1' (client listens on all interfaces)",
      fun() -> with_node(S, mynode, "127.0.0.1", true, Recipe, fun(_) ->
                   res("~s", [Shell([])]),
                   res("~s", [remsh(S, "mynode@127.0.0.1", ["-name", "shell@127.0.0.1"])]) end) end},
     {13, "recipe node; 'erl -name shell@127.0.0.1 -dist_listen false -remsh mynode@127.0.0.1' (the documented shell)",
      fun() -> with_node(S, mynode, "127.0.0.1", true, Recipe, fun(_) ->
                   res("~s", [Shell(NoListen)]),
                   res("~s", [remsh(S, "mynode@127.0.0.1", ["-name", "shell@127.0.0.1"] ++ NoListen)]) end) end},

     %% ---- epmd ----
     {14, "epmd started by the node, no ERL_EPMD_ADDRESS (node listener still on loopback)",
      fun() -> epmd_kill(Port), with_node(S, c14, "127.0.0.1", true, ?IDUI4, fun(N) ->
                   res("node listeners: ~s", [listeners(N)]), res("~s", [epmd_probe(Port, Probe)]) end) end},
     {15, "epmd started by the node with -env ERL_EPMD_ADDRESS 127.0.0.1",
      fun() -> epmd_kill(Port), with_node(S, c15, "127.0.0.1", true, Recipe, fun(N) ->
                   res("node listeners: ~s", [listeners(N)]), res("~s", [epmd_probe(Port, Probe)]) end) end},
     {16, "fresh epmd with ERL_EPMD_ADDRESS=::1",
      fun() -> epmd_kill(Port), epmd(["-daemon"], [{"ERL_EPMD_ADDRESS", "::1"}]), res("~s", [epmd_probe(Port, Probe)]) end},
     {17, "epmd already running on all interfaces; node started with -env ERL_EPMD_ADDRESS 127.0.0.1",
      fun() -> epmd_kill(Port), epmd(["-daemon"], []), res("before: ~s", [epmd_probe(Port, Probe)]),
               with_node(S, c17, "127.0.0.1", true, Recipe, fun(N) ->
                   Ls = listeners(N),
                   res("node started, listeners: ~s; output: [~s]", [Ls, peek(N)]),
                   res("after:  ~s", [epmd_probe(Port, Probe)]) end) end},
     {18, "'epmd -address 127.0.0.1 -daemon' started by hand before the node",
      fun() -> epmd_kill(Port), epmd(["-address", "127.0.0.1", "-daemon"], []), res("~s", [epmd_probe(Port, Probe)]),
               with_node(S, c18, "127.0.0.1", true, ?IDUI4, fun(N) ->
                   res("node listeners: ~s; ~s", [listeners(N), client(S, "c18@127.0.0.1", shell, "127.0.0.1", true, NoListen)]) end) end},

     %% ---- only incoming connections are restricted ----
     {19, "loopback-bound node connects OUT to a peer named on the non-loopback address; peer runs code back",
      fun() when V4 =:= "-" -> res("not measured: no non-loopback IPv4 address here", []);
         () ->
              epmd_kill(Port), epmd(["-daemon"], []),
              with_node(S, other, V4, true, [], fun(Peer) ->
                  res("peer listeners [~s]", [listeners(Peer)]),
                  with_node(S, mynode, "127.0.0.1", true, ?IDUI4, fun(Me) ->
                      B = list_to_atom("other@" ++ V4),
                      C = call(Me, net_kernel, connect_node, [B]),
                      Back = call(Me, rpc, call, [B, rpc, call, ['mynode@127.0.0.1', os, getpid, []]]),
                      Sockets = dist_sockets(Me),
                      res("my listeners [~s]", [listeners(Me)]),
                      res("connect_node(~s) = ~w", [B, C]),
                      res("peer rpc:call back into me = ~p, my os pid = ~s", [Back, call(Me, os, getpid, [])]),
                      res("dist socket {local, peer} = ~w", [Sockets]),
                      true = call(Me, net_kernel, disconnect, [B]),
                      ok = call(Me, net_kernel, allow, [['nobody@127.0.0.1']]),
                      res("[case 20] after net_kernel:allow/1: connect_node(~s) = ~w", [B, call(Me, net_kernel, connect_node, [B])])
                  end)
              end)
      end},
     {20, "(measured inside case 19) net_kernel:allow/1 blocks the outgoing connection",
      fun() -> res("see case 19", []) end},

     %% ---- IPv6 example verbatim ----
     {21, "IPv6 example verbatim: -proto_dist inet6_tcp -name mynode@::1, {0,0,0,0,0,0,0,1}, -env ERL_EPMD_ADDRESS ::1 (case 22 follows on the same node)",
      fun() -> epmd_kill(Port),
               with_node(S, mynode, "::1", true, ?INET6 ++ ?IDUI6 ++ ["-env", "ERL_EPMD_ADDRESS", "::1"], fun(N) ->
                   res("node listeners: ~s", [listeners(N)]), res("~s", [epmd_probe(Port, Probe)]),
                   say("", []),
                   say("## 22. IPv6 shell: -proto_dist inet6_tcp -name shell@::1 -dist_listen false -remsh mynode@::1; an IPv4-carrier client", []),
                   res("~s", [client(S, "mynode@::1", shell, "::1", true, ?INET6 ++ NoListen)]),
                   res("~s", [remsh(S, "mynode@::1", ?INET6 ++ ["-name", "shell@::1"] ++ NoListen)]),
                   res("IPv4-carrier client: ~s", [client(S, "mynode@::1", shell4, "127.0.0.1", true, NoListen)]) end) end},

     %% ---- extra: the undocumented atom ----
     {24, "extra: inet_dist_use_interface loopback (atom; documented type is ip_address() only)",
      fun() ->
              Atom = ["-kernel", "inet_dist_use_interface", "loopback"],
              with_node(S, c24, "127.0.0.1", true, Atom, fun(N) -> res("inet_tcp:  ~s", [listeners(N)]) end),
              with_node(S, c24b, "::1", true, ?INET6 ++ Atom, fun(N) -> res("inet6_tcp: ~s", [listeners(N)]) end)
      end},

     %% ---- last: resolver fallback (kills DNS in the container) ----
     {23, "-sname where the hostname is in neither /etc/hosts nor DNS (Erlang's own-hostname fallback; container only, last)",
      fun() -> case may_edit_etc() of
                   false -> res("not measured: only with MEASURE_EDIT_ETC=1 inside a throwaway container (edits /etc/hosts and the resolver)", []);
                   true ->
                       ok = file:write_file("/etc/hosts", hosts_without(Host)),
                       ok = file:write_file("/etc/resolv.conf", "nameserver 127.0.0.2\noptions timeout:1 attempts:1\n"),
                       case file:read_file("/etc/nsswitch.conf") of
                           {ok, Ns} -> ok = file:write_file("/etc/nsswitch.conf", re:replace(Ns, "^hosts:.*$", "hosts: files dns", [multiline]));
                           _ -> ok
                       end,
                       res("getent hosts ~s: ~s; inet:getaddr = ~w; inet:gethostbyname_self = ~w",
                           [Host, getent(Host), fresh(S, inet, getaddr, [Host, inet]), fresh(S, inet, gethostbyname_self, [Host, inet])]),
                       epmd_kill(Port),
                       with_node(S, c23, none, false, ?IDUI4, fun(N) ->
                           res("loopback listener: ~s; ~s", [listeners(N), client(S, "c23@" ++ Host, p, none, false, ?IDUI4)]) end),
                       res("/etc/hosts, /etc/resolv.conf and /etc/nsswitch.conf are restored when the script ends", [])
               end end}
    ].

%% a loopback-bound -sname node and its unbound control, each tried by a -sname client
sname_pair(S = #{host := Host}, Bound, Unbound) ->
    with_node(S, Bound, none, false, ?IDUI4, fun(N) ->
        res("loopback listener: ~s; ~s", [listeners(N), client(S, atom_to_list(Bound) ++ "@" ++ Host, p, none, false, ?IDUI4)]) end),
    with_node(S, Unbound, none, false, [], fun(N) ->
        res("unbound listener: ~s; ~s", [listeners(N), client(S, atom_to_list(Unbound) ++ "@" ++ Host, p, none, false, ?IDUI4)]) end).

%% container only: rewrites the hostname line of /etc/hosts, restores it afterwards
sname_with_hosts_entry(S = #{host := Host}, Addr, Bound, Unbound) ->
    {ok, Saved} = file:read_file("/etc/hosts"),
    ok = file:write_file("/etc/hosts", [hosts_without(Host), Addr, " ", Host, "\n"]),
    res("/etc/hosts now maps ~s to ~s; inet:getaddr = ~w", [Host, Addr, fresh(S, inet, getaddr, [Host, inet])]),
    sname_pair(S, Bound, Unbound),
    ok = file:write_file("/etc/hosts", Saved).

%% /etc/hosts without the lines that name the host (as an alias, not as the address)
hosts_without(Host) ->
    {ok, Bin} = file:read_file("/etc/hosts"),
    Keep = [Line || Line <- string:split(binary_to_list(Bin), "\n", all),
                    not lists:member(Host, tl(string:lexemes(Line, " \t") ++ [""]))],
    lists:join("\n", Keep).

restore_etc(Etc) ->
    [case file:read_file(F) of
         {ok, Saved} -> ok;
         _ -> file:write_file(F, Saved)
     end || {F, {ok, Saved}} <- Etc],
    ok.

%% ---- nodes ---------------------------------------------------------------------

%% with_node(S, Name, Host, LongNames, Extra, Fun): a peer node "Name@Host" (-name when
%% LongNames, else -sname; Host none for a bare -sname, Name none for a node named
%% only by Extra), Fun applied to it, then stopped; whatever the node printed on its
%% own standard output or error is reported after it stops
with_node(S, Name, Host, Long, Extra, Fun) ->
    N = start(S, Name, Host, Long, Extra),
    try Fun(N)
    after case stop(N) of "" -> ok; Out -> res("node output: [~s]", [Out]) end
    end.

start(#{cookie := Cookie}, Name, Host, Long, Extra) ->
    Out = spawn_link(fun() -> collector([]) end),
    Opts0 = #{connection => standard_io, longnames => Long, wait_boot => 30000,
              args => ["-setcookie", Cookie | Extra]},
    Opts1 = case Name of none -> Opts0; _ -> Opts0#{name => Name} end,
    Opts = case Host of none -> Opts1; _ -> Opts1#{host => Host} end,
    %% the peer control process inherits this group leader and forwards to it every
    %% line the node prints that is not part of the peer protocol
    Old = group_leader(), group_leader(Out, self()),
    R = try peer:start(Opts) catch C:E -> {C, E} end,
    group_leader(Old, self()),
    case R of
        {ok, P, Node} -> #{pid => P, node => Node, out => Out};
        {ok, P} -> #{pid => P, node => peer:call(P, erlang, node, []), out => Out};
        Err -> Out ! stop, error({node_did_not_start, Err})
    end.

%% a rejection report is logged by the accepting node asynchronously, after it has
%% answered the peer: flush the logger before the node is stopped
stop(#{pid := P, out := Out}) ->
    _ = try peer:call(P, logger_std_h, filesync, [default]) catch _:_ -> ok end,
    _ = try peer:stop(P) catch _:_ -> ok end,
    Str = peek(#{out => Out}),
    Out ! stop,
    Str.

%% what the node has printed so far, as one line
peek(#{out := Out}) ->
    Out ! {get, self()},
    receive {out, Out, Str} -> string:trim(lists:flatten(string:replace(Str, "\n", " ", all))) after 2000 -> "" end.

%% an io server that only collects put_chars
collector(Acc) ->
    receive
        {io_request, From, ReplyAs, {put_chars, _Enc, Chars}} ->
            From ! {io_reply, ReplyAs, ok}, collector([chars(Chars) | Acc]);
        {io_request, From, ReplyAs, {put_chars, _Enc, M, F, A}} ->
            From ! {io_reply, ReplyAs, ok}, collector([chars(apply(M, F, A)) | Acc]);
        {io_request, From, ReplyAs, _} ->
            From ! {io_reply, ReplyAs, {error, request}}, collector(Acc);
        {get, From} -> From ! {out, self(), lists:flatten(lists:reverse(Acc))}, collector([]);
        stop -> ok
    end.

chars(Data) ->
    case unicode:characters_to_list(Data) of
        L when is_list(L) -> L;
        _ -> lists:flatten(io_lib:format("~p", [Data]))
    end.

call(#{pid := P}, M, F, A) -> peer:call(P, M, F, A, 30000).

%% evaluate inside the node (an escript fun cannot be sent to another node)
eval(N, Src) ->
    {ok, Ts, _} = erl_scan:string(Src), {ok, Es} = erl_parse:parse_exprs(Ts),
    {value, V, _} = call(N, erl_eval, exprs, [Es, []]),
    V.

%% the node's listening TCP sockets as "addr:port"
listeners(N) ->
    string:join(eval(N,
        "[begin {ok, {A, Po}} = inet:sockname(X), lists:flatten(io_lib:format(\"~s:~w\", [inet:ntoa(A), Po])) end"
        " || X <- erlang:ports(), erlang:port_info(X, name) =:= {name, \"tcp_inet\"}, element(1, inet:peername(X)) =:= error]."), " ").

%% the node's connected TCP sockets other than its epmd registration, as {local, peer}
dist_sockets(N) ->
    eval(N,
        "[{element(2, inet:sockname(X)), element(2, inet:peername(X))}"
        " || X <- erlang:ports(), erlang:port_info(X, name) =:= {name, \"tcp_inet\"}, element(1, inet:peername(X)) =:= ok,"
        " element(2, element(2, inet:peername(X))) =/= list_to_integer(os:getenv(\"ERL_EPMD_PORT\"))].").

%% one call in a throwaway node that is not distributed (a fresh resolver state)
fresh(S, M, F, A) ->
    N = start(S, none, none, false, []),
    try call(N, M, F, A) after stop(N) end.

%% connect from a throwaway node; its result and the client's own listeners
client(S, Target, Name, Host, Long, Extra) ->
    N = start(S, Name, Host, Long, Extra),
    Res = try {call(N, net_kernel, connect_node, [list_to_atom(Target)]), listeners(N)}
          catch C:E -> {error, {C, E}} end,
    Out = stop(N),
    case Res of
        {error, Err} -> error(Err);
        {R, Ls} -> io_lib:format("connect_node(~s) = ~w, client listeners [~s]~s", [Target, R, Ls, note(Out)])
    end.

%% net_adm:ping from a throwaway node
ping(S, Target, Name, Host, Long, Extra) ->
    N = start(S, Name, Host, Long, Extra),
    Res = try call(N, net_adm, ping, [list_to_atom(Target)]) catch C:E -> {error, {C, E}} end,
    Out = stop(N),
    case Res of
        {error, Err} -> error(Err);
        R -> io_lib:format("ping(~s) = ~w~s", [Target, R, note(Out)])
    end.

note("") -> "";
note(Out) -> io_lib:format(" (client output: [~s])", [Out]).

%% a real `erl -remsh`, its standard input a pipe with the line "node()." on it; the
%% prompt and the value it prints are reported. timeout(1) ends the erl after 6 s
%% (SIGTERM, which erl turns into init:stop/0), so no shell node outlives its case.
remsh(#{cookie := Cookie}, Target, Extra) ->
    Args = ["-k", "2", "6", os:find_executable("erl"), "-setcookie", Cookie] ++ Extra ++ ["-remsh", Target],
    P = open_port({spawn_executable, os:find_executable("timeout")},
                  [{args, Args}, binary, exit_status, stderr_to_stdout, use_stdio]),
    P ! {self(), {command, <<"node().\n">>}},
    Text = binary_to_list(collect(P, 12000)),
    Prompt = "(" ++ Target ++ ")1> ",
    Found = case string:find(Text, Prompt) of
                nomatch ->
                    case string:find(Text, "Could not connect") of
                        nomatch -> "<prompt not captured: " ++ string:slice(string:trim(Text), 0, 160) ++ ">";
                        Rest -> string:trim(hd(string:split(Rest, "\n")), trailing, "* \r")
                    end;
                Rest -> string:trim(hd(string:split(Rest, "\n")))
            end,
    "remsh through a pipe: " ++ Found.

%% output of a port until the program exits (or the cap)
collect(P, Cap) -> collect(P, erlang:monotonic_time(millisecond) + Cap, <<>>).
collect(P, Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {P, {data, D}} -> collect(P, Deadline, <<Acc/binary, D/binary>>);
        {P, {exit_status, _}} -> Acc
    after Left -> _ = try port_close(P) catch _:_ -> ok end, Acc
    end.

%% ---- epmd -----------------------------------------------------------------------

epmd(Args, Env) ->
    P = open_port({spawn_executable, os:find_executable("epmd")},
                  [{args, Args}, {env, Env}, binary, exit_status, stderr_to_stdout, use_stdio]),
    _ = collect(P, 5000),
    timer:sleep(500).

%% KILL_REQ of the epmd protocol, what `epmd -kill` sends; accepted from loopback only,
%% and only once no node is registered, so it is repeated until epmd no longer
%% answers: a node stopped just before may still be registered for a moment
epmd_kill(Port) -> epmd_kill(Port, 20).
epmd_kill(Port, 0) -> error({epmd_still_running, Port});
epmd_kill(Port, Tries) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 500) of
        {ok, So} ->
            ok = gen_tcp:send(So, <<1:16, $k>>),
            _ = gen_tcp:recv(So, 0, 1000),
            gen_tcp:close(So),
            timer:sleep(200),
            epmd_kill(Port, Tries - 1);
        {error, _} ->
            timer:sleep(100)
    end.

%% does epmd answer on each address? (behavioral, from the BEAM)
epmd_probe(Port, Addrs) ->
    F = fun(Str) ->
            {ok, A} = inet:parse_address(Str),
            Fam = case tuple_size(A) of 4 -> inet; 8 -> inet6 end,
            R = case gen_tcp:connect(A, Port, [Fam], 500) of
                    {ok, So} -> gen_tcp:close(So), "answers";
                    {error, E} -> atom_to_list(E)
                end,
            Str ++ "=" ++ R
        end,
    "epmd " ++ string:join([F(A) || A <- Addrs], " ").

%% ---- environment ------------------------------------------------------------------

getent(Host) ->
    P = open_port({spawn_executable, os:find_executable("getent")},
                  [{args, ["hosts", Host]}, binary, exit_status, stderr_to_stdout, use_stdio]),
    case string:trim(binary_to_list(collect(P, 5000))) of
        "" -> "<none>";
        Out -> Out
    end.

in_container() ->
    (filelib:is_file("/.dockerenv") orelse filelib:is_file("/run/.containerenv"))
        andalso case file:read_file_info("/etc/hosts") of
                    {ok, Info} -> Info#file_info.access =:= read_write;
                    _ -> false
                end.

may_edit_etc() -> os:getenv("MEASURE_EDIT_ETC") =:= "1" andalso in_container().

yes_no(true) -> "yes";
yes_no(false) -> "no".

say(Fmt, Args) -> io:format(Fmt ++ "~n", Args).
res(Fmt, Args) -> io:format("  -> " ++ Fmt ++ "~n", Args).
