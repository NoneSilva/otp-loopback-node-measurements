# otp-loopback-node-measurements

Measurements behind a documentation change proposed to Erlang/OTP,
"kernel: document how to bind a distributed node to loopback"
([erlang/otp#11617](https://github.com/erlang/otp/pull/11617), target
`maint`): with it, the `inet_dist_use_interface` entry of
`lib/kernel/doc/kernel_app.md` explains how to make a distributed node accept
connections only from the local host, what each of the involved settings does
and does not do, and how to open a shell on such a node. This repository holds
the script that produces every row behind that text, the captured outputs per
OTP version and network setup, and the list of what was deliberately not
measured.

The case that motivated it is the VS Code Erlang extension advisory
GHSA-573p-mcvv-hchg: <https://github.com/pgourlain/vscode_erlang/security/advisories/GHSA-573p-mcvv-hchg>

Companions: [otp-dist-tls-measurements](https://github.com/NoneSilva/otp-dist-tls-measurements)
(what `-proto_dist inet_tls` protects, and that it does not change the bind)
and [elixir-ls-mcp-bind-measurements](https://github.com/NoneSilva/elixir-ls-mcp-bind-measurements)
(the same bind question for the elixir-ls MCP server,
[elixir-lsp/elixir-ls#1275](https://github.com/elixir-lsp/elixir-ls/pull/1275)).

## Run it

Requirements: `escript`, `erl` and `epmd` on `PATH`, and a GNU/Linux userland
(coreutils `timeout` for the remote-shell rows, glibc `getent` for row 23;
`bash` and Docker for `run-docker.sh` only). The script is Erlang: the nodes
are peers from the OTP `peer` module, ports owned by the script's VM and
controlled over their standard I/O, and everything is read from inside the
BEAM (`inet:sockname/1` for the listeners, `gen_tcp:connect/4` against `epmd`,
`inet:getifaddrs/0`), not with `ss` or `ip`. A private `epmd` on port 4370
(`EPMD_PORT` to change; 4369 is refused) is used throughout, so a system `epmd`
is never touched; each node is stopped when its case ends and the private
`epmd` at the end of the run (its own `KILL_REQ`, what `epmd -kill` sends).
The cookie is random per run, since the control rows listen on every interface
for a few seconds.

```text
escript measure.escript        # every case, on the local OTP
escript measure.escript 5 19   # selected cases (20 and 22 run with 19 and 21)
./run-docker.sh 27 28 29       # official erlang:<v> images, --network host
./run-docker.sh --bridge 29    # same, in the container's own network namespace
```

Cases 8, 9 and 23 edit `/etc/hosts` or the resolver (`/etc/resolv.conf`,
`/etc/nsswitch.conf`). They run only with `MEASURE_EDIT_ETC=1` set inside a
container, which `run-docker.sh` sets for its throwaway (`--rm`) containers,
and the files are restored when the script ends; anywhere else they print
"not measured". Case 23 runs last, after case 24, because it disables the
resolver for the rest of the run.
The remote-shell rows start a real `erl -remsh` with `open_port/2`, its
standard input a pipe carrying the line `node().`; the prompt and the value
the shell prints are reported next to the equivalent
`net_kernel:connect_node/1`. Whatever a node prints on its own standard output
or error is reported after it stops ("node output", "client output"); rows 11
and 20 show the reports behind their refusals.

## Cases and results

Within each environment, results were identical across OTP 27.3.4.17
(erts 15.2.7.13; host and the `erlang:27` image), OTP 28.5.0.6
(erts 16.4.0.6) and OTP 29.0.6 (erts 17.0.6, the version of the `maint`
branch), the latter two in the official Docker images, in both network modes.
The outputs print the
major release and the erts version; the erts version identifies the patch
release (`otp_versions.table` in the OTP repository). Row 7 depends on the
environment (see its cell), and rows an environment cannot run print
"not measured". Outputs are in [`results/`](results/), verbatim except that
the host's global IPv6 address, the only routable address in them, is written
`<global IPv6>`; the LAN address `10.0.0.203` and the hostname `one` are
private to the lab and left as printed.

Terms used in the table. `P` is the node's distribution port. "Loopback
listener" means the node was started with `inet_dist_use_interface` set to
`{127,0,0,1}` or `{0,0,0,0,0,0,0,1}`; "unbound listener" means the same node
without that parameter, whose listener is then bound to the wildcard address
(rows 1 and 2), the case the entry describes as "listens on all interfaces".
"Recipe node" (rows 11-13) is the IPv4 example of the entry started verbatim:
`-name mynode@127.0.0.1`, `inet_dist_use_interface '{127,0,0,1}'`,
`-env ERL_EPMD_ADDRESS 127.0.0.1`. Addresses are as `inet:ntoa/1` prints them:
`:::P` is the IPv6 wildcard, `::1:P` the IPv6 loopback.

| # | Setup | Result |
|---|-------|--------|
| 1 | `-name n@127.0.0.1` alone | listener `0.0.0.0:P` |
| 2 | `-proto_dist inet6_tcp -name n@::1` alone | listener `:::P` (IPv6 wildcard) |
| 3 | 1 + `inet_dist_use_interface {127,0,0,1}` | listener `127.0.0.1:P`; a local node with the cookie: `pong` |
| 4 | 2 + `inet_dist_use_interface {0,0,0,0,0,0,0,1}` | listener `::1:P`; a local IPv6 node: `pong` |
| 5 | `-name n@<LAN IPv4>` + loopback listener; control: same name, unbound listener | `pang`; control `pong` |
| 6 | `-name n@<global IPv6>` + `::1` listener; control: unbound | `pang`; control `pong` (needs a global IPv6 address; "not measured" in the bridge runs) |
| 7 | `-sname n` with the hostname as it resolves on the machine + loopback listener; control: unbound | host and host-network containers (hostname → `127.0.0.1`): `true`; bridge containers (hostname → `172.17.0.2`): `false`, control `true` |
| 8 | `-sname n` where the hostname maps to `127.0.1.1` (Debian style) + loopback listener; control: unbound | `false`; control `true` |
| 9 | `-sname n` where the hostname maps to the LAN IPv4 address + loopback listener; control: unbound | `false`; control `true` |
| 10 | `-sname n@localhost` + loopback listener; plain `erl -remsh n@localhost` | remote prompt `(n@localhost)1>`; `localhost` → `127.0.0.1` |
| 11 | recipe node; plain `erl -remsh mynode@127.0.0.1` (a short-named client) | `Could not connect`; `-sname undefined` client → `false`, reporting `Hostname 127.0.0.1 is illegal` |
| 12 | recipe node; `erl -name shell@127.0.0.1 -remsh mynode@127.0.0.1` | remote prompt; but the shell node listens on `0.0.0.0:P` |
| 13 | recipe node; `erl -name shell@127.0.0.1 -dist_listen false -remsh mynode@127.0.0.1` | remote prompt; the shell node has no listening socket |
| 14 | `epmd` started by the node, no `ERL_EPMD_ADDRESS` | `epmd` answers on `127.0.0.1`, `::1`, the LAN IPv4 and the global IPv6 address; the node's listener is still `127.0.0.1:P` |
| 15 | `epmd` started by the node with `-env ERL_EPMD_ADDRESS 127.0.0.1` | answers on `127.0.0.1` and `::1`; refuses the LAN and global IPv6 addresses (`epmd_cmd.md` says "the loopback address" is implicitly added; `epmd_srv.c` adds both `INADDR_LOOPBACK` and `in6addr_loopback`) |
| 16 | fresh `epmd` with `ERL_EPMD_ADDRESS=::1` | same as 15 |
| 17 | `epmd` already running on all interfaces; node started with the loopback listener and `-env ERL_EPMD_ADDRESS 127.0.0.1` | `epmd` unchanged (still answers everywhere); the node starts and registers with no output, its listener is `127.0.0.1:P` |
| 18 | `epmd -address 127.0.0.1 -daemon` by hand, then the node | answers on `127.0.0.1` and `::1` only; the node registers; a loopback client connects |
| 19 | loopback-bound node, `net_kernel:connect_node('other@<LAN IPv4>')`; the peer listens on `0.0.0.0:P` | `true`; dist socket `<LAN>:x` ↔ `<LAN>:P`; the peer's `rpc:call` back into the node returns the node's own OS pid |
| 20 | 19, then `net_kernel:allow(['nobody@127.0.0.1'])` | `connect_node` → `false`; the node reports `Connection attempt with disallowed node` |
| 21 | the IPv6 example verbatim: `-proto_dist inet6_tcp -name mynode@::1`, `{0,0,0,0,0,0,0,1}`, `-env ERL_EPMD_ADDRESS ::1` | listener `::1:P`; `epmd` answers on `127.0.0.1` and `::1` only |
| 22 | IPv6 shell `erl -proto_dist inet6_tcp -name shell@::1 -dist_listen false -remsh mynode@::1`; an IPv4-carrier client | remote prompt, no listening socket; IPv4-carrier client → `false` |
| 23 | `-sname n` where the hostname is in neither `/etc/hosts` nor DNS + loopback listener | `inet:getaddr` → `{127,0,0,1}` (`inet:gethostbyname_self/2`); `connect_node` → `true` |
| 24 | extra: `inet_dist_use_interface loopback` (atom; the documented type is `ip_address()` only) | `inet_tcp` → `127.0.0.1:P`; `inet6_tcp` → `::1:P` |

How the rows back the text: 1-4 and 21-22 "the node name alone does not bind"
and the IPv6 example; 5-9 and 23 "the host part must resolve to the bound
address" and the `-sname` sentences; 10-13 the shell paragraph; 14-18 the
`ERL_EPMD_ADDRESS` paragraph (17 is the "still confined" clause); 19-20 "only
incoming connections are restricted"; 3 also the warning that binding does not
replace the cookie. Row 24 is not used in the text.

## Environments

- Host: Linux, `ufw` active, hostname mapped to `127.0.0.1` in `/etc/hosts`,
  LAN IPv4 and a global IPv6 address, IPv6 enabled. OTP 27 from the operating
  system's packages. Facts in this line that the script does not print (`ufw`,
  package origin) were checked by hand (`ufw status`) and are not in
  `results/`. `results/otp27-host.txt` was produced by the earlier shell
  version of the script (`measure.sh`, in the git history), which reported
  the same rows through a pty; it was not rerun.
- `run-docker.sh 27 28 29`: official images with `--network host`, so the same
  interfaces, addresses and firewall as the host.
- `run-docker.sh --bridge 27 28 29`: the container's own network namespace
  (`172.17.0.0/16`, no global IPv6), where the host's `ufw`/nftables rules do
  not apply; row 6 prints "not measured" there.

Every "refused" row has a control on the same path that succeeds (5, 6, 8, 9,
and 7 in the bridge run: the same name with an unbound listener connects, over
the LAN IPv4 address and over the global IPv6 address; row 20's control is the
same call in row 19 before `net_kernel:allow/1`; row 11's is row 13), and
row 19 connects out over the LAN address, so refusals are attributable to the
socket binding, not to filtering. The bridge run repeats the matrix where no
host rules exist.

## Not measured, and why

- A second physical host: single-host lab. Network reachability is read from
  the bound address of the listening socket and from connecting to the host's
  own LAN address, which takes the same path a remote host would.
- Windows and macOS: Linux only. Hostname resolution (rows 7-9, 23) is OS- and
  configuration-specific, which is why the documented example uses the literal
  address rather than `-sname`.
- `-sname n@localhost` over IPv6: no case runs it. `inet:getaddr("localhost",
  inet6)` returned `nxdomain` on the host and `::1` in the bridge containers,
  which is itself a reason the documented IPv6 example uses the literal `::1`.
- Custom `-proto_dist` modules. What `inet_tls_dist` does and does not protect
  (the client certificate authenticates before the cookie; the listener stays
  on `0.0.0.0`; `inet_dist_use_interface` applies to it unchanged) is measured
  in the companion
  [otp-dist-tls-measurements](https://github.com/NoneSilva/otp-dist-tls-measurements).
- Versions before OTP 27. The entry uses two features from OTP 23.0:
  `-dist_listen false` (the documented shell command) and `-remsh` without
  `-name` or `-sname` (the plain `erl -remsh n@localhost` and the "starts a
  short-named node" sentence).

## Known interaction

`epmd` adds the loopback address of both families when given an address
(row 15). On a host with IPv6 disabled, OTP 27.3.4.15, 28.5.0.4 and 29.0.4 fail
to start such an `epmd` because the `::1` bind fails (erlang/otp#11402, fixed
in the next patch of each branch). Not part of this repository's runs, which
all have IPv6 enabled.

## References

- `epmd -address` / `ERL_EPMD_ADDRESS`: erts `epmd` reference page;
  `erts/epmd/src/epmd_srv.c` for the loopback of both families
- `-remsh`, `-dist_listen`, `-hidden`: erts `erl` reference page; dynamic node
  names: Erlang Reference Manual, Distributed Erlang
- `net_kernel:allow/1`: kernel `net_kernel` module
- `inet:gethostbyname_self/2`: `lib/kernel/src/inet.erl`, the clause commented
  "This is the final fallback that pretends /etc/hosts has got a line for the
  hostname on the loopback address"

License: MIT.
