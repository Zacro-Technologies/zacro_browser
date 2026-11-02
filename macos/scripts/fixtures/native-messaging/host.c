/* Disposable native-messaging acceptance host. Never used by the browser product.
 * Uses Chromium's native-endian 32-bit framing and bounded JSON echo payloads.
 * Executable basename selects a fixed fixture behavior; no commands are run.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int exact_read(void *bytes, size_t count) {
  char *out = bytes;
  while (count) {
    ssize_t result = read(STDIN_FILENO, out, count);
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) return 0;
    out += result; count -= (size_t)result;
  }
  return 1;
}
static int exact_write(const void *bytes, size_t count) {
  const char *in = bytes;
  while (count) {
    ssize_t result = write(STDOUT_FILENO, in, count);
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0) return 0;
    in += result; count -= (size_t)result;
  }
  return 1;
}
static int reply(const char *body, int fragmented) {
  uint32_t size = (uint32_t)strlen(body);
  if (!fragmented) return exact_write(&size, sizeof(size)) && exact_write(body, size);
  if (!exact_write(&size, 2)) return 0;
  usleep(1000);
  if (!exact_write((const char *)&size + 2, 2)) return 0;
  for (size_t offset = 0; offset < size;) {
    size_t count = size - offset < 7 ? size - offset : 7;
    if (!exact_write(body + offset, count)) return 0;
    offset += count;
  }
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2 || strlen(argv[1]) != 52 || strncmp(argv[1], "chrome-extension://", 19) || argv[1][51] != '/') return 2;
  for (int i = 19; i < 51; ++i) if (argv[1][i] < 'a' || argv[1][i] > 'p') return 2;
  const char *kind = strrchr(argv[0], '/'); kind = kind ? kind + 1 : argv[0];
  if (strcmp(kind,"echo") && strcmp(kind,"fragments") && strcmp(kind,"batch") &&
      strcmp(kind,"oversized") && strcmp(kind,"truncated") && strcmp(kind,"invalidjson") &&
      strcmp(kind,"hold") && strcmp(kind,"denied")) return 2;
  umask(0077); signal(SIGPIPE, SIG_IGN); alarm(20);
  char marker[4096];
  if (snprintf(marker, sizeof(marker), "%s.pid", argv[0]) >= (int)sizeof(marker)) return 2;
  int file = open(marker, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (file < 0) return 2;
  dprintf(file,"%ld\n",(long)getpid()); close(file);
  for (;;) {
    uint32_t size = 0;
    if (!exact_read(&size,sizeof(size))) return 0;
    if (size == 0 || size > 1024 * 1024) return 2;
    char *body = malloc((size_t)size + 1);
    if (!body) return 2;
    if (!exact_read(body,size)) { free(body); return 2; }
    body[size] = 0;
    if (!strcmp(kind,"oversized")) {
      uint32_t oversized = 1024 * 1024 + 1;
      exact_write(&oversized,sizeof(oversized)); free(body);
      char ignored; while (read(STDIN_FILENO,&ignored,1) > 0) {} return 0;
    }
    if (!strcmp(kind,"truncated")) {
      uint32_t incomplete = 50;
      exact_write(&incomplete,sizeof(incomplete)); exact_write("{\"x\":",5); free(body); return 0;
    }
    if (!strcmp(kind,"invalidjson")) { reply("not-json",0); free(body); return 0; }
    char *response = malloc((size_t)size + 128);
    if (!response) { free(body); return 2; }
    for (int sequence = 1; sequence <= (!strcmp(kind,"batch") ? 2 : 1); ++sequence) {
      snprintf(response,(size_t)size + 128,"{\"origin\":\"%s\",\"sequence\":%d,\"payload\":%s}",argv[1],sequence,body);
      if (!reply(response,!strcmp(kind,"fragments"))) { free(response); free(body); return 0; }
    }
    free(response); free(body);
  }
}
