# Egress

Every connection a container makes beyond its networks leaves through pratico's own
network stack on the Mac, which the container cannot reach or change. pratico names
each one, records it, and refuses it when a threat feed lists the destination or when
the container has an allowlist the destination is not on.

## What is recorded

For each container, its last 2,000 connections and refused lookups: time, protocol,
address, port, and name. The name comes from pratico's own DNS answers, from the TLS
ClientHello's server name (SNI) for HTTPS, or from the HTTP `Host` header, so it is
there even when the container resolved the name elsewhere. Traffic is not decrypted:
pratico sees which host, not which URL.

- Menubar: **Containers › (a container) › Network Activity…**
- API: `GET /pratico/egress?container=NAME`
- Agents: the MCP `egress` tool, and the `connections` a `run` reports
  ([agents](agents.md)).

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

Only listed names resolve, connections go only to addresses pratico resolved for them,
and an HTTPS or HTTP connection must name one of them too. The Mac
(`host.docker.internal`) counts as a name. Containers' own networks are not affected.
The MCP `run` and `start` tools set the label from `egress`.

Decision: SPEC D-51. Example: [examples/11-egress.sh](../examples/11-egress.sh).
