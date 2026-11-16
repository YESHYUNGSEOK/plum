#include "cpty.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int plum_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   pid_t *pid_out) {
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) return -1;

  if (pid == 0) {
    // Child. Only async-signal-safe calls from here to execve.
    // A GUI parent may ignore or block signals; a shell must not inherit that.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
    if (cwd && chdir(cwd) != 0) {
      // Fall through: the shell still starts, in the parent's directory.
    }
    execve(path, argv, envp);
    _exit(127);
  }

  fcntl(master, F_SETFD, FD_CLOEXEC);

  // Without IUTF8 the kernel's line editing erases one byte per backspace
  // and corrupts multi-byte characters such as Hangul.
  struct termios attrs;
  if (tcgetattr(master, &attrs) == 0) {
    attrs.c_iflag |= IUTF8;
    tcsetattr(master, TCSANOW, &attrs);
  }

  *pid_out = pid;
  return master;
}

int plum_pty_resize(int fd, unsigned short cols, unsigned short rows,
                    unsigned short width_px, unsigned short height_px) {
  struct winsize ws = {
      .ws_row = rows, .ws_col = cols, .ws_xpixel = width_px, .ws_ypixel = height_px};
  return ioctl(fd, TIOCSWINSZ, &ws);
}
