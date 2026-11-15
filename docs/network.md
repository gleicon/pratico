# Networking

pratico-net is a user-space Ethernet switch inside `pratico-daemon`. Every VM's network
card is a datagram socket pair whose other end the daemon holds; there is no vmnet, no
host bridge, and no `bridge100`. Each Docker network is a broadcast domain on that
switch, and the rules that separate networks run on the Mac, outside every VM.

## One card, an address per network

A VM has one virtual NIC, `eth0`, and holds an address on each network it joins.
Virtualization.framework refuses a fifth network device and cannot add one to a running
VM, so a card per network would cap a container at four networks. With one card there
is no limit, and the guest kernel probes one virtio device at boot.

```
$ docker exec app ip -4 -o addr show eth0
eth0 172.18.0.2/24
eth0 172.18.1.2/24
eth0 172.18.2.2/24
```

- **MAC per network.** Each network sees the container under its own MAC, as on Docker:
  `docker inspect` lists one per network and peers learn it by ARP. The guest's card
  keeps the first network's MAC; the switch rewrites the Ethernet source and ARP sender
  on the way out, and the destination and ARP target on the way back.
- **Which network a frame is on.** The switch reads the source address (ARP sender or
  IPv4 source) and maps it to one of the VM's endpoints. A frame from any other address,
  or from a MAC other than the card's, is dropped.
- **Which peer gets a frame.** A peer receives a unicast frame only when both its MAC
  and its address on the sender's network match. Broadcast and multicast reach the
  sender's network only, and only for its subnet or `224.0.0.0/4`. A container on two
  networks cannot carry traffic between them, and a raw frame cannot reach a peer's
  address on a network the sender is not on.

## Addresses and routes

pratico assigns addresses per network and sets them through the guest agent; there is
no DHCP. `--ip` asks for one on a user-defined network (refused on `bridge`, as on
Docker; a taken address answers 409), and `--mac-address` sets the MAC that network
sees. The first network gets the default route and DNS; a network that reaches out
wins over an `--internal` one, then `NetworkMode`, then name.

- **Connect** (`docker network connect`) adds an address to the running VM, then plugs
  it into the switch. A container with no network yet makes it the primary one.
- **Disconnect** removes the endpoint from the switch first: from then on no frame
  from or to that address passes, whatever the guest does, and its flows to the Mac and
  the internet end. The link stays up for the other networks.
- The guest agent cannot delete an address or a route. A disconnected address stays on
  the card, reserved for that container until it restarts, and reconnecting to the same
  network gets it back. When the primary network goes, pratico bounces the link (which
  clears the old default route and keeps the addresses), adds the default through the
  next network's gateway, and points `/etc/resolv.conf` there. Published ports follow.

## DNS

Each network's gateway answers DNS, as Docker's embedded server does at `127.0.0.11`.
Nothing is written into the image, so distroless images resolve too.

| Name | Resolves on |
|---|---|
| container name, alias, short ID | user-defined networks (not `bridge`, as on Docker) |
| `<name>.pratico.internal` | every network, `bridge` included, for containers sharing a network with the asker |
| `host.docker.internal`, `host.pratico.internal` | the Mac |
| `gateway.docker.internal` | the network's gateway |
| anything else | the Mac's resolvers, except on `--internal` networks |

Every pratico gateway answers as the asker's own networks, so a stale `resolv.conf`
still works. `--dns`, `--dns-search`, and `--dns-option` replace the resolver, and stay
when the primary network changes. `--add-host` and `--link` add `/etc/hosts` entries.

## The internet

Traffic to addresses beyond the network goes to pratico's own TCP/IP stack, written in
Swift, in the style of slirp: it answers ARP and ICMP echo, relays UDP over host
sockets, and terminates guest TCP (handshake, sequence and window, retransmission, FIN,
RST), opening a host socket per flow. Connections leave from the Mac as the user, under
the Mac's own firewall and VPN.

- `--internal` networks have no route out and no DNS forwarding: names a container
  controls cannot be used to leak data through lookups.
- `--network none` gets no card.
- `--network host` is not supported: a VM has its own kernel and stack.

## Published ports

`-p` binds on the Mac, `0.0.0.0` unless an address is given (`-p 127.0.0.1:8080:80`).
`-P` binds every exposed port, the image's `EXPOSE` included, on a free host port.
Each connection is relayed through the uplink to the container's primary address. The
menubar flags a port reachable beyond loopback, once per container and port.

## Limits

- IPv4 only: `-p` with an IPv6 address and `--ip6` are refused.
- The guest sees one interface. Software that binds to `eth1` by name finds only `eth0`.
- Containers started by a pratico release from before one-card networking keep a card
  per network until restarted; connecting one beyond its cards answers 409.

Design notes: [design/runtime.md](design/runtime.md). Decisions: SPEC D-27, D-43, D-44.
Example: [examples/08-networks.sh](../examples/08-networks.sh).
