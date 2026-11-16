#ifndef PLUM_CPTY_H
#define PLUM_CPTY_H

#include <sys/types.h>

/// Starts `path` (argv/envp are NULL-terminated) on a new pty with `cwd` as
/// its working directory. Returns the pty master fd, or -1 with errno set.
int plum_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   pid_t *pid_out);

/// Tells the pty (and the foreground program, via SIGWINCH) its new size.
int plum_pty_resize(int fd, unsigned short cols, unsigned short rows,
                    unsigned short width_px, unsigned short height_px);

#endif
