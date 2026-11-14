"""Timing and concurrency helpers for e2e/bench.sh (SPEC AC-44 to AC-47).

  bench.py runs N CMD...                 time N sequential runs of CMD; print p99 and max ms
  bench.py calls SOCK N PATH...          N keep-alive GETs per PATH; print p99 ms per path
  bench.py concurrent SOCK CLIENTS N PATH  CLIENTS threads, N GETs each; print errors
  bench.py hold SOCK COUNT               open COUNT connections at once, each sends /_ping and
                                         keeps the connection; print how many were answered
                                         within 2 s, then how many after one closes
"""
import socket
import subprocess
import sys
import threading
import time


def p99(samples):
    s = sorted(samples)
    return s[max(0, int(len(s) * 0.99 + 0.999) - 1)]


def connect(sock):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(10)
    c.connect(sock)
    return c


def get(c, path):
    """One keep-alive GET; returns the status. Reads exactly Content-Length."""
    c.sendall(f"GET {path} HTTP/1.1\r\nHost: d\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    head, body = buf.split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    status = int(lines[0].split()[1])
    length = next(int(l.split(":", 1)[1]) for l in lines if l.lower().startswith("content-length:"))
    while len(body) < length:
        chunk = c.recv(65536)
        if not chunk:
            raise ConnectionError("closed")
        body += chunk
    return status


def runs(n, cmd):
    times = []
    for _ in range(n):
        t = time.monotonic()
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        times.append((time.monotonic() - t) * 1000)
        if r.returncode != 0:
            print(f"failed exit {r.returncode}")
            return
    print(f"{p99(times):.0f} {max(times):.0f}")


def calls(sock, n, paths):
    out = []
    for path in paths:
        c = connect(sock)
        times = []
        for _ in range(n):
            t = time.monotonic()
            if get(c, path) != 200:
                print(f"error on {path}")
                return
            times.append((time.monotonic() - t) * 1000)
        c.close()
        out.append(f"{p99(times):.1f}")
    print(" ".join(out))


def concurrent(sock, clients, n, path):
    errors = []

    def client():
        try:
            c = connect(sock)
            for _ in range(n):
                if get(c, path) != 200:
                    errors.append("status")
            c.close()
        except Exception as e:  # noqa: BLE001 - every failure counts as an error
            errors.append(str(e))

    threads = [threading.Thread(target=client) for _ in range(clients)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print(len(errors))


def hold(sock, count):
    conns, answered, lock = [], [0], threading.Lock()

    def ping(c):
        try:
            if get(c, "/_ping") == 200:
                with lock:
                    answered[0] += 1
        except Exception:  # noqa: BLE001 - a refused or reset one is simply not answered
            pass

    threads = []
    for _ in range(count):
        c = connect(sock)
        conns.append(c)
        t = threading.Thread(target=ping, args=(c,))
        t.start()
        threads.append(t)
    time.sleep(2)
    first = answered[0]
    conns[0].close()  # frees a slot: a waiting connection is served next
    for t in threads:
        t.join(timeout=5)
    print(first, answered[0])
    for c in conns[1:]:
        c.close()


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "runs":
        runs(int(args[0]), args[1:])
    elif mode == "calls":
        calls(args[0], int(args[1]), args[2:])
    elif mode == "concurrent":
        concurrent(args[0], int(args[1]), int(args[2]), args[3])
    elif mode == "hold":
        hold(args[0], int(args[1]))
