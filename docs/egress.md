# Egress

Every connection a container makes beyond its networks leaves through pratico's own
network stack on the Mac, which the container cannot reach or change. pratico names
each one, records it, and refuses it when a threat feed lists the destination or when
the container has an allowlist the destination is not on.

## What is recorded

For each container, its last 2,000 connections and refused lookups: time, protocol,
address, port, the container's source port, and name. The name comes from pratico's own DNS answers, from the TLS
ClientHello's server name (SNI) for HTTPS, or from the HTTP `Host` header, so it is
there even when the container resolved the name elsewhere. Traffic is not decrypted:
pratico sees which host, not which URL.

- Menubar: **Connections…** (or **Containers › (a container) › Connections…**): a table of
  every container's connections, the same process reaching the same destination folded
  into one row with its count, newest first; search, **Refused Only**, and for the
  selected row the refusal's reason, the addresses, the process and its PIDs, and the
  source ports.
- API: `GET /pratico/egress[?container=NAME]`. Each TCP, UDP and DNS flow carries `Command` and `Pid`,
  the process that opened it, where the flight recorder saw it.
- Agents: the MCP `egress` tool, and the `connections` a `run` reports
  ([agents](agents.md)).
- The process behind each TCP connection and UDP flow: the [flight recorder](vm.md#flight-recorder),
  whose connections carry these names and refusals.

## Threat feeds

| Feed | Lists | Needs |
|---|---|---|
| [Feodo Tracker](https://feodotracker.abuse.ch) (abuse.ch) | botnet command-and-control servers | nothing |
| [SSL Blacklist](https://sslbl.abuse.ch) (abuse.ch) | botnet C2 addresses | nothing |
| [Spamhaus DROP](https://www.spamhaus.org/drop/) | hijacked networks no one should route to | nothing |
| [URLhaus](https://urlhaus.abuse.ch) (abuse.ch) | hosts distributing malware | a free abuse.ch Auth-Key |
| [ThreatFox](https://threatfox.abuse.ch) (abuse.ch) | C2 domains and `ip:port`s, malware URLs | a free abuse.ch Auth-Key |

pratico fetches them on this Mac (abuse.ch hourly, Spamhaus daily), keeps the last copy
in `~/.pratico/scan-db/egress/`, and redistributes nothing. Without a network the last
copy stays in use. The key, from [auth.abuse.ch](https://auth.abuse.ch), goes in through
the menubar's **Threat Feeds › Add abuse.ch Key…** (or `POST /pratico/egress/key`) and is
kept in the Keychain, never in `config.toml`.

A listed name gets no DNS answer; a listed address, or a connection whose SNI or Host
names a listed host, is reset. Each raises an alert. `egress_block = false` keeps the
alerts and lets the connections through.

URL feeds list addresses on shared hosts too (a file on GitHub, Google Drive, Discord's
CDN). pratico sees only the host, and blocking `github.com` for one file would break
everything else, so entries on those hosts are skipped.

Feed terms: Feodo Tracker and SSL Blacklist are CC0. URLhaus and ThreatFox are free with
a key; abuse.ch's terms ask commercial users to check whether they need a subscription.
Spamhaus DROP is free of charge to use, not to redistribute, and asks for no more than
one fetch an hour.

## Allowlists

A container labeled `dev.pratico.egress.allow` reaches only the names it lists, comma
separated; `*.example.com` covers subdomains:

```sh
docker run --label dev.pratico.egress.allow=pypi.org,files.pythonhosted.org python:3.13-slim pip install requests
```

Only listed names resolve, connections and pings go only to addresses pratico resolved
for them, and an HTTPS or HTTP connection must name one of them too. TLS or HTTP whose
name pratico cannot read (no SNI, a ClientHello split across records, two `Host`
headers, a request target naming another host) is refused: on a CDN the same address
serves many sites. Other protocols (SSH, a database) are held to the addresses alone,
so on a shared address an allowlist is as narrow as that address. Queries to outside
DNS servers are checked one by one, and so is every request on a plain-HTTP connection
(keep-alive and pipelined ones too, any method). Under an allowlist pratico reads plain
HTTP line by line and refuses what it cannot read, so a plain-HTTP body with a line over
8 KiB is refused; HTTPS, which most traffic is, is not affected. The Mac (`host.docker.internal`) counts as a name.
Containers' own networks are not affected.
The MCP `run` and `start` tools set the label from `egress`.

## Ask mode

A container labeled `dev.pratico.egress.ask=true` reaches what is not on its allowlist
(none at first) only once you allow it. Each destination waits for an answer in a
notification and in the menubar's **Waiting for You**:

```sh
docker run --label dev.pratico.egress.ask=true alpine wget -qO- https://example.com
```

- **Allow** lets that destination through until the container stops; **Always Allow**
  adds it (a name, or an address no name led to) to the container's allowlist, kept
  while the container exists; **Deny** refuses
  it until the container stops. A question nobody answers is refused after 30 s, and the
  next connection asks again.
- Nothing leaves the Mac before an answer. A name waits at pratico's DNS, so it is not
  even looked up (the container's resolver waits up to 30 s in ask mode, set in its
  `resolv.conf`); a connection to an address no allowed name resolved waits at its first
  packet, and goes on the moment you answer. Once a connection is open, the name its TLS
  or HTTP carries is checked too, and asked about if it is another.
- Threat feeds still refuse what they list, whatever the answer.
- Running a file that did not come with the image (`FromImage` false in its
  [activity](vm.md#flight-recorder)) raises an alert for a container in ask mode.
- The MCP `run` and `start` tools set the label from `ask_egress`.
- With `--network none` there is nothing to ask, and the label is refused.

Decision: SPEC D-51, D-62. Example: [examples/11-egress.sh](../examples/11-egress.sh).
