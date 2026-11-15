# Sends three ICMP echo requests as raw Ethernet frames on eth0, bypassing the guest's
# routing: frame.py <dst MAC> <dst IP> <src IP>. Needs CAP_NET_RAW (a container's default).
import socket
import struct
import sys


def checksum(b):
    if len(b) % 2:
        b += b"\0"
    t = sum(struct.unpack(f"!{len(b) // 2}H", b))
    t = (t >> 16) + (t & 0xFFFF)
    t += t >> 16
    return ~t & 0xFFFF


dst_mac = bytes.fromhex(sys.argv[1].replace(":", ""))
dst_ip, src_ip = socket.inet_aton(sys.argv[2]), socket.inet_aton(sys.argv[3])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind(("eth0", 0))
icmp = struct.pack("!BBHHH", 8, 0, 0, 1, 1) + b"pratico!"
icmp = icmp[:2] + struct.pack("!H", checksum(icmp)) + icmp[4:]
ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(icmp), 1, 0, 64, 1, 0, src_ip, dst_ip)
ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
for _ in range(3):
    s.send(dst_mac + s.getsockname()[4] + b"\x08\x00" + ip + icmp)
