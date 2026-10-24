module orglistremo.internal.os;

package(orglistremo):

import std.typecons : Nullable;

/**
 * Checks whether a process with the given PID is currently alive on the local
 * system.
 *
 * Params:
 *   pid = Process identifier to check.
 *
 * Returns:
 *   True if the process is active, false if non-existent or invalid PID.
 */
bool isPidAlive(int pid) {
  if (pid <= 0) {
    return false;
  }
  version (Posix) {
    import core.stdc.errno : errno, ESRCH;
    import core.sys.posix.signal : kill;

    const int res = kill(pid, 0);
    if (res == 0) {
      return true;
    }
    return errno != ESRCH;
  } else version (Windows) {
    import core.sys.windows.basetsd : HANDLE;
    import core.sys.windows.winbase : CloseHandle, OpenProcess;
    import core.sys.windows.winnt : PROCESS_QUERY_INFORMATION;

    HANDLE handle = OpenProcess(
      PROCESS_QUERY_INFORMATION,
      0,
      cast(uint) pid
    );
    if (handle !is null) {
      CloseHandle(handle);
      return true;
    }
    return false;
  } else {
    return pid > 0;
  }
}

/**
 * Retrieves the available free space on the filesystem device hosting path.
 *
 * Params:
 *   path = Path to a file or directory on the filesystem.
 *
 * Returns:
 *   Nullable!long containing available bytes, or null if query failed or
 *   unsupported on the target platform.
 */
Nullable!long getDeviceFreeSpace(string path) {
  version (Posix) {
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import std.string : toStringz;

    statvfs_t st;
    if (statvfs(path.toStringz, &st) != 0) {
      return Nullable!long.init;
    }
    const ulong blockSize = st.f_frsize ? st.f_frsize : st.f_bsize;
    const ulong freeBytes = cast(ulong) st.f_bavail * blockSize;
    return Nullable!long(cast(long) freeBytes);
  } else version (Windows) {
    import core.sys.windows.winbase : GetDiskFreeSpaceExW;
    import core.sys.windows.winnt : ULARGE_INTEGER;
    import std.utf : toUTF16z;

    ULARGE_INTEGER freeBytes;
    if (GetDiskFreeSpaceExW(path.toUTF16z, &freeBytes, null, null) == 0) {
      return Nullable!long.init;
    }
    return Nullable!long(cast(long) freeBytes.QuadPart);
  } else {
    return Nullable!long.init;
  }
}

/**
 * Checks whether the given file descriptor is connected to a terminal (TTY).
 *
 * Params:
 *   fd = File descriptor to check.
 *
 * Returns:
 *   True if connected to a TTY device, false otherwise.
 */
bool isTty(int fd) {
  version (Posix) {
    import core.sys.posix.unistd : isatty;

    return isatty(fd) != 0;
  } else version (Windows) {
    extern (C) int _isatty(int fd) nothrow @nogc;

    return _isatty(fd) != 0;
  } else {
    return false;
  }
}

/**
 * Checks whether standard output (stdout) is connected to a terminal (TTY).
 *
 * Returns:
 *   True if stdout is a TTY, false otherwise.
 */
bool isStdoutTty() {
  version (Posix) {
    import core.sys.posix.unistd : STDOUT_FILENO;

    return isTty(STDOUT_FILENO);
  } else version (Windows) {
    import core.sys.windows.winbase : GetStdHandle, STD_OUTPUT_HANDLE;
    import core.sys.windows.wincon : GetConsoleMode;
    import core.sys.windows.windef : DWORD;

    DWORD mode;
    return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
  } else {
    return false;
  }
}

/**
 * Queries the current terminal width in columns for the given file descriptor.
 *
 * Params:
 *   fd = File descriptor (defaults to 1 for stdout).
 *
 * Returns:
 *   Terminal column width, or fallback default 80 on failure or redirection.
 */
uint getTerminalWidth(int fd = 1) {
  version (Posix) {
    import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;

    winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
      return cast(uint) ws.ws_col;
    }
    return 80;
  } else version (Windows) {
    import core.sys.windows.winbase : GetStdHandle, STD_OUTPUT_HANDLE;
    import core.sys.windows.wincon :
      CONSOLE_SCREEN_BUFFER_INFO, GetConsoleScreenBufferInfo;

    CONSOLE_SCREEN_BUFFER_INFO csbi;
    if (GetConsoleScreenBufferInfo(
      GetStdHandle(STD_OUTPUT_HANDLE), &csbi
    ) != 0) {
      const int width = csbi.srWindow.Right - csbi.srWindow.Left + 1;
      if (width > 0) {
        return cast(uint) width;
      }
    }
    return 80;
  } else {
    return 80;
  }
}

/**
 * Retrieves the local machine's host name without depending on std.socket.
 *
 * Returns:
 *   Hostname string, or fallback from environment or "localhost".
 */
string getLocalHostName() {
  version (Posix) {
    import core.sys.posix.unistd : gethostname;
    import std.string : fromStringz;

    char[256] buf;
    if (gethostname(buf.ptr, buf.length) == 0) {
      buf[$ - 1] = '\0';
      const string name = buf.ptr.fromStringz.idup;
      if (name.length > 0) {
        return name;
      }
    }
  } else version (Windows) {
    import core.sys.windows.winbase : GetComputerNameW;
    import core.sys.windows.windef : DWORD;
    import std.utf : toUTF8;

    wchar[256] buf;
    DWORD size = cast(DWORD) buf.length;
    if (GetComputerNameW(buf.ptr, &size) != 0 && size > 0) {
      return buf[0 .. size].toUTF8;
    }
  }

  import std.process : environment;

  version (Windows) {
    const string compName = environment.get("COMPUTERNAME", null);
    if (compName.length > 0) {
      return compName;
    }
  }

  const string hostEnv = environment.get(
    "HOSTNAME", environment.get("HOST", null)
  );
  if (hostEnv.length > 0) {
    return hostEnv;
  }
  return "localhost";
}

unittest {
  import std.file : tempDir;
  import std.process : thisProcessID;

  // 1. isPidAlive verification
  assert(isPidAlive(thisProcessID));
  assert(!isPidAlive(-1));
  assert(!isPidAlive(0));
  version (Posix) {
    assert(!isPidAlive(99_999_999));
  }

  // 2. getDeviceFreeSpace verification
  const freeOpt = getDeviceFreeSpace(tempDir());
  version (Posix) {
    assert(!freeOpt.isNull);
    assert(freeOpt.get > 0);
    assert(getDeviceFreeSpace("/nonexistent_path_987654").isNull);
  }

  // 3. isTty & isStdoutTty verification
  assert(!isTty(-1));
  version (Posix) {
    import core.sys.posix.unistd : STDOUT_FILENO;

    assert(isStdoutTty() == isTty(STDOUT_FILENO));
  }

  // 4. getTerminalWidth verification
  assert(getTerminalWidth(-1) == 80);
  assert(getTerminalWidth(1) > 0);

  // 5. getLocalHostName verification
  const string host = getLocalHostName();
  assert(host.length > 0);
  assert(host != "");
}
