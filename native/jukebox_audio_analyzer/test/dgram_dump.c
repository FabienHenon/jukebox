/*
 * dgram_dump: a stand-in for the Phoenix application in the analyser's tests.
 * Binds a Unix datagram socket and prints every datagram it receives, one
 * per line.
 *
 *   dgram_dump --socket PATH [--idle-ms N] [--hold-ms N]
 *
 *   --idle-ms N   stop after N milliseconds without a datagram (default 1000)
 *   --hold-ms N   bind, then read nothing for N milliseconds: a receiver that
 *                 is present but not keeping up
 */
#define _POSIX_C_SOURCE 200809L

#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
  const char *path = NULL;
  int idle_ms = 1000;
  int hold_ms = 0;

  for (int i = 1; i + 1 < argc; i += 2) {
    if (strcmp(argv[i], "--socket") == 0) path = argv[i + 1];
    else if (strcmp(argv[i], "--idle-ms") == 0) idle_ms = atoi(argv[i + 1]);
    else if (strcmp(argv[i], "--hold-ms") == 0) hold_ms = atoi(argv[i + 1]);
  }

  struct sockaddr_un address;
  if (path == NULL || strlen(path) >= sizeof(address.sun_path)) {
    fprintf(stderr, "dgram_dump: --socket PATH is required (and must be short)\n");
    return 2;
  }

  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, path);
  unlink(path);

  int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
    perror("dgram_dump: bind");
    return 1;
  }

  /* Tell whoever started us that the socket exists. */
  fprintf(stderr, "dgram_dump: listening\n");

  if (hold_ms > 0) {
    struct timespec pause = {hold_ms / 1000, (long)(hold_ms % 1000) * 1000000L};
    nanosleep(&pause, NULL);
  } else {
    char buffer[2048];
    struct pollfd watched = {fd, POLLIN, 0};
    while (poll(&watched, 1, idle_ms) > 0) {
      ssize_t n = recv(fd, buffer, sizeof(buffer) - 1, 0);
      if (n < 0) break;
      buffer[n] = '\0';
      puts(buffer);
    }
    fflush(stdout);
  }

  close(fd);
  unlink(path);
  return 0;
}
