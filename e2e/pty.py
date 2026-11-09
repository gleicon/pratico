"""Runs a command on a pty of a given size and prints everything it wrote.
Piped stdin is typed into the pty, as keystrokes would be.
Usage: pty.py <rows> <cols> <command...>"""
import fcntl, os, pty, select, struct, sys, termios, time

rows, cols, argv = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
out, deadline = b"", time.time() + 30
typing = not os.isatty(0)
while time.time() < deadline:
    ready = select.select([fd] + ([0] if typing else []), [], [], 0.5)[0]
    if 0 in ready:
        keys = os.read(0, 4096)
        if keys:
            os.write(fd, keys)
        else:
            typing = False
    if fd in ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
if time.time() >= deadline:
    os.kill(pid, 9)
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
