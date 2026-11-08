"""Runs a command on a pty of a given size and prints everything it wrote.
Usage: pty.py <rows> <cols> <command...>"""
import fcntl, os, pty, select, struct, sys, termios, time

rows, cols, argv = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
out, deadline = b"", time.time() + 30
while time.time() < deadline:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
