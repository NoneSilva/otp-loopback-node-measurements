# otp-loopback-node-measurements

Measurements behind a documentation change to Erlang/OTP: the
`inet_dist_use_interface` entry of `lib/kernel/doc/kernel_app.md` now explains
how to make a distributed node accept connections only from the local host,
what each of the involved settings does and does not do, and how to open a
shell on such a node. This repository holds the script that produced every
claim in that text, the captured outputs per OTP version and network setup,
and the list of what was deliberately not measured.

Companion write-up of the case that motivated it (VS Code Erlang extension,
GHSA-573p-mcvv-hchg): <https://erts-sched.github.io/security/vscode-erlang-loopback-rce/>

## Run it

Requirements: `bash`, `erl` and `epmd` on `PATH`. Nothing else: sockets are
read from inside the BEAM (`inet:sockname/1`, `gen_tcp:connect/4` against
`epmd`, `inet:getifaddrs/0`), not with `ss` or `ip`. A private `epmd` on port
4370 (`EPMD_PORT` to change) is used throughout, so a system `epmd` on 4369 is
never touched; every node is stopped at the end.

```text
./measure.sh                 # every case, on the local OTP
./measure.sh 5 19            # selected cases
./run-docker.sh 27 28 29     # official erlang:<v> images, --network host
./run-docker.sh --bridge 29  # same, in the container's own network namespace
```

Three cases edit `/etc/hosts` or `/etc/resolv.conf` (8, 9, 23) and run only
inside a throwaway container; on a host they print "not measured". An
interactive `remsh` is exercised through a pty when `script(1)` exists;
otherwise only the equivalent `net_kernel:connect_node/1` is reported. In the
Docker runs the pty does not echo the remote prompt back, so those outputs say
"prompt not captured" and the `connect_node` line on the same case is the
evidence; the prompt itself is captured in the host run.

## Cases and results

Results were identical on OTP 27.3.4.17 (erts 15.2.7.13, host), OTP 28
(erts 16.4.0.6) and OTP 29 (erts 17.0.6, the version of the `maint` branch),
the latter two in the official Docker images. Exact outputs are in
[`results/`](results/). `P` is the node's distribution port.

| # | Setup | Result |
|---|-------|--------|
| 1 | `-name n@127.0.0.1` alone | listener `0.0.0.0:P` |
| 2 | `-proto_dist inet6_tcp -name n@::1` alone | listener `:::P` (IPv6 wildcard) |
| 3 | 1 + `inet_dist_use_interface {127,0,0,1}` | listener `127.0.0.1:P`; a local node with the cookie: `pong` |
| 4 | 2 + `inet_dist_use_interface {0,0,0,0,0,0,0,1}` | listener `::1:P`; a local IPv6 node: `pong` |
| 5 | `-name n@<LAN IPv4>` + loopback listener; control: same name, unbound listener | `pang`; control `pong` |
| 6 | `-name n@<global IPv6>` + `::1` listener; control: unbound | `pang`; control `pong` |
| 7 | `-sname n` with the hostname as it resolves on the machine + loopback listener; control: unbound | host and host-network containers (hostname → `127.0.0.1`): `true`; bridge containers (hostname → `172.17.0.2`): `false`, control `true` |
| 8 | `-sname n` where the hostname maps to `127.0.1.1` (Debian style) + loopback listener; control: unbound | `false`; control `true` |
| 9 | `-sname n` where the hostname maps to the LAN IPv4 address + loopback listener; control: unbound | `false`; control `true` |
| 10 | `-sname n@localhost` + loopback listener; plain `erl -remsh n@localhost` | remote prompt `(n@localhost)1>`; `localhost` → `127.0.0.1` |
| 11 | recipe node; bare `erl -remsh mynode@127.0.0.1` (a short-named client) | `Could not connect`; `-sname undefined` client → `false` |
| 12 | recipe node; `erl -name shell@127.0.0.1 -remsh mynode@127.0.0.1` | remote prompt; but the shell node listens on `0.0.0.0:P` |
| 13 | recipe node; `erl -name shell@127.0.0.1 -dist_listen false -remsh mynode@127.0.0.1` | remote prompt; the shell node has no listening socket |
| 14 | `epmd` started by the node, no `ERL_EPMD_ADDRESS` | `epmd` answers on `127.0.0.1`, `::1`, the LAN IPv4 and the global IPv6 address; the node's listener is still `127.0.0.1:P` |
| 15 | `epmd` started by the node with `-env ERL_EPMD_ADDRESS 127.0.0.1` | answers on `127.0.0.1` and `::1`; refuses the LAN and global IPv6 addresses |
| 16 | fresh `epmd` with `ERL_EPMD_ADDRESS=::1` | same as 15: loopback of both families |
| 17 | `epmd` already running on all interfaces; node started with `-env ERL_EPMD_ADDRESS 127.0.0.1` | `epmd` unchanged (still answers everywhere); the node starts and registers with no output |
| 18 | `epmd -address 127.0.0.1 -daemon` by hand, then the node | answers on `127.0.0.1` and `::1` only; the node registers; a loopback client connects |
| 19 | loopback-bound node, `net_kernel:connect_node('other@<LAN IPv4>')` | `true`; dist socket `<LAN>:x` ↔ `<LAN>:P`; the peer's `rpc:call` back into the node returns the node's own OS pid |
| 20 | 19, then `net_kernel:allow(['nobody@127.0.0.1'])` | `connect_node` → `false` ("Connection attempt with disallowed node") |
| 21 | the IPv6 example verbatim: `-proto_dist inet6_tcp -name mynode@::1`, `{0,0,0,0,0,0,0,1}`, `-env ERL_EPMD_ADDRESS ::1` | listener `::1:P`; `epmd` answers on `127.0.0.1` and `::1` only |
| 22 | IPv6 shell `erl -proto_dist inet6_tcp -name shell@::1 -dist_listen false -remsh mynode@::1`; an IPv4-carrier client | remote prompt, no listening socket; IPv4-carrier client → `false` |
| 23 | `-sname n` where the hostname is in neither `/etc/hosts` nor DNS + loopback listener | `inet:getaddr` → `{127,0,0,1}` (`inet:gethostbyname_self/2`); `connect_node` → `true` |
| 24 | extra: `inet_dist_use_interface loopback` (atom; the documented type is `ip_address()` only) | `inet_tcp` → `127.0.0.1:P`; `inet6_tcp` → `::1:P` |

How the rows back the text: 1-4 "the node name alone does not bind" and the
IPv6 example; 5-9 and 23 "the host part must resolve to the bound address" and
the `-sname` sentences; 10-13 the shell paragraph; 14-18 the
`ERL_EPMD_ADDRESS` paragraph; 19-20 "only incoming connections are
restricted"; 3 also the warning that binding does not replace the cookie.
Row 24 is not used in the text.

## Environments

- Host: Linux, `ufw` active, hostname mapped to `127.0.0.1` in `/etc/hosts`,
  LAN IPv4 and a global IPv6 address, IPv6 enabled. OTP 27 from the
  distribution packages.
- `run-docker.sh 27 28 29`: official images with `--network host`, so the same
  interfaces, addresses and firewall as the host.
- `run-docker.sh --bridge 29 27`: the container's own network namespace
  (`172.17.0.0/16`, zero nftables tables, no global IPv6). This is the
  environment without the host's security rules; rows that need a global IPv6
  address print "not measured" there.

Every "refused" row has a control on the same path that succeeds (5, 6, 8, 9
and 19: the same name with an unbound listener connects, over the LAN IPv4
address and over the global IPv6 address), so refusals are attributable to the
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
- Other distribution carriers (`inet_tls_dist`, custom `-proto_dist` modules).
- Versions before OTP 27. The documented shell relies on `-remsh` without a
  name being allowed (OTP 23+).

## Known interaction

`epmd` adds the loopback address of both families when given an address
(row 15). On a host with IPv6 disabled, OTP 27.3.4.15, 28.5.0.4 and 29.0.4 fail
to start such an `epmd` because the `::1` bind fails (erlang/otp#11402, fixed
in the next patch of each branch). Not part of this repository's runs, which
all have IPv6 enabled.

## References

- `epmd -address` / `ERL_EPMD_ADDRESS`: erts `epmd` reference page
- `-remsh`, `-dist_listen`: erts `erl` reference page
- `net_kernel:allow/1`: kernel `net_kernel` module
- `inet:gethostbyname_self/2`: `lib/kernel/src/inet.erl`, "the final fallback
  that pretends /etc/hosts has got a line for the hostname on the loopback
  address"

License: MIT.
