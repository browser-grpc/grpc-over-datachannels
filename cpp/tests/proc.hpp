#pragma once

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace tests {

/// Minimal child-process helper (fork/exec with pipes) for the
/// interop/oracle harnesses.
struct Proc {
  pid_t pid = -1;
  FILE* to_stdin = nullptr;    // write end -> child's stdin
  FILE* from_stdout = nullptr; // read end <- child's stdout
  FILE* from_stderr = nullptr; // read end <- child's stderr (if piped)

  ~Proc() { Kill(); }

  void Kill() {
    if (pid > 0) {
      kill(pid, SIGKILL);
      int status = 0;
      waitpid(pid, &status, 0);
      pid = -1;
    }
    if (to_stdin) std::fclose(to_stdin);
    if (from_stdout) std::fclose(from_stdout);
    if (from_stderr) std::fclose(from_stderr);
    to_stdin = from_stdout = from_stderr = nullptr;
  }

  /// Exit code, or -1 on timeout (process killed).
  int WaitForExit(int timeout_ms) {
    if (pid <= 0) return -1;
    int waited = 0;
    while (waited < timeout_ms) {
      int status = 0;
      pid_t r = waitpid(pid, &status, WNOHANG);
      if (r == pid) {
        pid = -1;
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        return -2;
      }
      usleep(10000);
      waited += 10;
    }
    Kill();
    return -1;
  }
};

inline bool Spawn(const std::vector<std::string>& argv, bool pipe_stderr,
                  Proc& out) {
  int in_pipe[2], out_pipe[2], err_pipe[2];
  if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) return false;
  if (pipe_stderr && pipe(err_pipe) != 0) return false;
  pid_t pid = fork();
  if (pid < 0) return false;
  if (pid == 0) {
    dup2(in_pipe[0], STDIN_FILENO);
    dup2(out_pipe[1], STDOUT_FILENO);
    if (pipe_stderr) dup2(err_pipe[1], STDERR_FILENO);
    close(in_pipe[0]); close(in_pipe[1]);
    close(out_pipe[0]); close(out_pipe[1]);
    if (pipe_stderr) { close(err_pipe[0]); close(err_pipe[1]); }
    std::vector<char*> cargv;
    for (auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
    cargv.push_back(nullptr);
    execvp(cargv[0], cargv.data());
    _exit(127);
  }
  close(in_pipe[0]);
  close(out_pipe[1]);
  if (pipe_stderr) close(err_pipe[1]);
  out.pid = pid;
  out.to_stdin = fdopen(in_pipe[1], "w");
  out.from_stdout = fdopen(out_pipe[0], "r");
  if (pipe_stderr) out.from_stderr = fdopen(err_pipe[0], "r");
  return true;
}

inline std::string ReadAll(FILE* f) {
  std::string out;
  char buf[4096];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
  return out;
}

inline bool FileExists(const std::string& path) {
  return access(path.c_str(), F_OK) == 0;
}

inline int FreePort() {
  // Bind port 0 via a temporary socket to find a free port.
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  int port = 0;
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
    socklen_t len = sizeof(addr);
    getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len);
    port = ntohs(addr.sin_port);
  }
  close(fd);
  return port;
}

}  // namespace tests
