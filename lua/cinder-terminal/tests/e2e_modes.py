#!/usr/bin/env python3
"""End-to-end check of the pane's two modes, driven through a real pty.

Headless Neovim cannot hold Terminal-Job mode, which is the mode this plugin
has to get right, so the headless suite leaves four things unproven:

  * focusing the pane hands the keyboard to the job right away,
  * the hint row follows the mode instead of naming keys that would be typed,
  * a lone <Esc> reaches the job without waiting for 'timeoutlen',
  * <Esc><Esc> leaves the job for normal mode, where `gg`, `v` and `y` are
    Neovim's own and `i` goes back.

This script answers them in a pty running Neovim with a large 'timeoutlen',
so the literal two-key mapping the gesture used to be would visibly fail.

    python3 tests/e2e_modes.py            # local provider
    python3 tests/e2e_modes.py --tmux     # same checks through tmux

The tmux phase runs against its own server in a throwaway `TMUX_TMPDIR`, so it
never touches the tmux sessions the user is working in. It needs a POSIX pty
and exits non-zero on the first failed step.
"""

import fcntl
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODE_LOG = "mode.log"
YANK_LOG = "yank.log"
PANE_LOG = "pane.log"
SOCKET_NAME = "cinder-e2e"

# Room for the whole workspace, like a normal editor window.
ROWS, COLUMNS = 40, 140

PROBE = """\
vim.opt.rtp:prepend([[{root}]])
local term = require("cinder_terminal")
term.setup({{
  refresh_interval = 0,
  confirm = false,
  providers = {{ {providers} }},
}})

local function append(path, text)
  local f = io.open(path, "a")
  if f then
    f:write(text .. "\\n")
    f:close()
  end
end

vim.api.nvim_create_autocmd("ModeChanged", {{
  callback = function()
    append([[{mode}]], table.concat({{
      vim.api.nvim_get_mode().mode,
      vim.bo.buftype,
      vim.fn.line("."),
      vim.fn.line("w0"),
    }}, " "))
  end,
}})

vim.api.nvim_create_autocmd("TextYankPost", {{
  callback = function()
    append([[{yank}]], vim.fn.getreg('"'))
  end,
}})

-- What the tests read instead of scraping the screen: the job's own output,
-- the hint row (the last line of every non-terminal buffer), the winbars and
-- where the pane is scrolled.
local function poll()
  local parts = {{}}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if vim.bo[buf].buftype == "terminal" then
        vim.list_extend(parts, lines)
      else
        for i = #lines, 1, -1 do
          if lines[i]:match("%S") then
            parts[#parts + 1] = lines[i]
            break
          end
        end
      end
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    parts[#parts + 1] = "WINBAR " .. (vim.wo[win].winbar or "")
    if vim.bo[buf].buftype == "terminal" then
      parts[#parts + 1] = string.format(
        "PANE mode=%s line=%d top=%d lines=%d",
        vim.api.nvim_get_mode().mode,
        vim.fn.line(".", win),
        vim.fn.line("w0", win),
        vim.fn.line("$", win)
      )
    end
  end
  local f = io.open([[{pane}]], "w")
  if f then
    f:write(table.concat(parts, "\\n"))
    f:close()
  end
  vim.defer_fn(poll, 100)
end
vim.defer_fn(poll, 100)

{open}
{focus}
"""

LOCAL_PROVIDERS = (
    'tmux = { enabled = false }, '
    '["local"] = { shell = { "sh", "-c", "seq 200; exec cat -v" } }'
)
TMUX_PROVIDERS = '["local"] = { enabled = false }, tmux = { socket_name = "%s" }' % SOCKET_NAME

# `term.open()` without a directory relies on the provider's prepare: the local
# container starts with a shell, so the workspace must land in the pane with a
# job already on screen instead of on the empty list waiting for `n`. No extra
# `term.focus()`: the deferred call used to land in the middle of the mode
# checks and pull the pane back into the job right after a key left it.
LOCAL_OPEN = """\
term.open()
"""

TMUX_OPEN = """\
term.open_tmux()
term.refresh()
"""


class Failure(Exception):
    pass


class Pane:
    """Neovim in a pty, plus the files its probes write."""

    def __init__(self, workdir, providers, open_code):
        self.workdir = workdir
        self.mode_path = os.path.join(workdir, MODE_LOG)
        self.yank_path = os.path.join(workdir, YANK_LOG)
        self.pane_path = os.path.join(workdir, PANE_LOG)
        probe = os.path.join(workdir, "probe.lua")
        with open(probe, "w") as handle:
            handle.write(
                PROBE.format(
                    root=ROOT,
                    mode=self.mode_path,
                    yank=self.yank_path,
                    pane=self.pane_path,
                    providers=providers,
                    open=open_code,
                    focus="",
                )
            )
        pid, fd = pty.fork()
        if pid == 0:
            # Neovim's own state goes to the workdir, so a sandboxed run never
            # has to fall back to a log file in the middle of the workspace.
            os.environ["XDG_STATE_HOME"] = os.path.join(workdir, "state")
            os.environ["XDG_CACHE_HOME"] = os.path.join(workdir, "cache")
            os.environ["XDG_DATA_HOME"] = os.path.join(workdir, "data")
            # Without this Neovim warns that its startup query went unanswered
            # and raises a hit-enter prompt, which would eat every key.
            os.environ["NVIM_TEST"] = "1"
            os.chdir(workdir)
            os.execvp(
                "nvim",
                ["nvim", "-u", "NONE", "--cmd", "set timeoutlen=3000", "-c", "luafile " + probe],
            )
            os._exit(1)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    def close(self):
        try:
            os.kill(self.pid, 9)
        except ProcessLookupError:
            pass
        os.close(self.fd)

    def pump(self, seconds=0.1):
        while True:
            ready, _, _ = select.select([self.fd], [], [], seconds)
            if not ready:
                return
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            # Answer Neovim's terminal queries the way a terminal would.
            if b"\x1b[5n" in data:
                os.write(self.fd, b"\x1b[0n")
            if b"\x1b[6n" in data:
                os.write(self.fd, b"\x1b[1;1R")
            if b"Error in command line" in data:
                raise Failure("Neovim refused the probe")
            seconds = 0.02

    def send(self, text):
        os.write(self.fd, text if isinstance(text, bytes) else text.encode())

    def escape_escape(self, gap=0.1):
        self.send(b"\x1b")
        time.sleep(gap)
        self.send(b"\x1b")

    def _lines(self, path):
        try:
            with open(path) as handle:
                return handle.read().splitlines()
        except FileNotFoundError:
            return []

    def state(self):
        """`mode buftype cursor_line window_top` of the last transition."""
        lines = self._lines(self.mode_path)
        return lines[-1].split() if lines else ["-", "-", "-", "-"]

    def yanks(self):
        return self._lines(self.yank_path)

    def screen(self):
        """Job output, hint rows, winbars and pane positions."""
        return "\n".join(self._lines(self.pane_path))

    def pane(self):
        """The pane's mode, cursor line and scroll position, as polled."""
        fields = {}
        for line in self._lines(self.pane_path):
            if line.startswith("PANE "):
                fields = {}
                for pair in line.split()[1:]:
                    name, _, value = pair.partition("=")
                    fields[name] = value
        return fields

    def winbars(self):
        return [line for line in self._lines(self.pane_path) if line.startswith("WINBAR ")]

    def wait_state(self, mode, timeout=6.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.1)
            if self.state()[0] == mode:
                return True
        return False

    def wait_screen(self, text, timeout=1.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.05)
            if text in self.screen():
                return True
        return False

    def wait_pane(self, field, value, timeout=2.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.1)
            if self.pane().get(field) == value:
                return True
        return False


def require(value, message):
    if not value:
        raise Failure(message)
    return value


class Report:
    def __init__(self, phase):
        self.phase = phase
        self.results = []
        print("\n== %s" % phase)

    def step(self, description, fn):
        """Run one check, print the outcome and remember it."""
        started = time.time()
        try:
            detail = fn()
            self.results.append(True)
            print("ok   %-46s %5.0fms  %s" % (description, (time.time() - started) * 1000, detail or ""))
        except Failure as error:
            self.results.append(False)
            print("FAIL %-46s %5.0fms  %s" % (description, (time.time() - started) * 1000, error))

    @property
    def failed(self):
        return self.results.count(False)


def check_modes(pane, report, drive, scrollback):
    """Every mode check, shared by the local and the tmux phase.

    `scrollback` says whether the pane's buffer holds history the pane can
    scroll through: a local pty keeps every line it printed, while a tmux
    client redraws one screenful and keeps its own scrollback inside tmux.
    """

    def focus_pane():
        # Reaching the pane is the "hand me the keyboard" path: it has to end
        # in Terminal-Job mode on its own, even though the terminal buffer
        # only arrives from the provider after the focus moved.
        if not drive():
            raise Failure("the pane was not focused in time: %s" % pane.state())
        deadline = time.time() + 10
        while time.time() < deadline:
            pane.pump(0.2)
            if pane.state()[:2] == ["t", "terminal"]:
                return "focused straight into the job"
        raise Failure("focusing the pane did not reach Terminal-Job mode: %s" % pane.state())

    report.step("focusing the pane hands over the keyboard", focus_pane)

    def typing_hint():
        require(pane.wait_screen("[C-\\ / Esc Esc] normal mode"), "the escape keys are not advertised")
        require(pane.wait_screen("[C-b] items"), "the way back to the list is not advertised")
        screen = pane.screen()
        require("[Tab]" not in screen, "the hint row offers <Tab>, which the job would receive")
        require("prefix" not in screen, "no provider advertises a tmux prefix any more")
        return "escape keys and the way back to the list"

    report.step("while typing the hint row names keys the job keeps", typing_hint)

    def lone_escape():
        # 'timeoutlen' is 3000 here on purpose: if <Esc> were bound as part of
        # a two-key mapping, the job would not see this byte in time.
        started = time.time()
        pane.send(b"\x1b")
        if not pane.wait_screen("^[", timeout=1.0):
            raise Failure("the job never received the lone Esc (waited %.1fs)" % (time.time() - started))
        require(pane.state()[0] == "t", "a lone Esc left the job: %s" % pane.state())
        return "reached the job in %.0fms" % ((time.time() - started) * 1000)

    report.step("a lone <Esc> reaches the job at once", lone_escape)

    def leave():
        pane.escape_escape()
        require(pane.wait_state("nt", timeout=2), "still in %s" % pane.state())
        return "left in normal mode"

    report.step("<Esc><Esc> leaves the job for normal mode", leave)

    def normal_hint():
        require(pane.wait_screen("[i] insert"), "normal mode does not offer the way back")
        require(pane.wait_screen("[j/k] scroll"), "normal mode does not advertise its native motions")
        require(pane.wait_screen("[Tab] items"), "normal mode does not offer the way back to the list")
        require("[q] items" not in pane.screen(), "the pane still spends q, which normal mode keeps")
        require(
            any(" normal " in bar for bar in pane.winbars()),
            "the pane title does not mark normal mode: %s" % pane.winbars(),
        )
        return "hint row and title follow the mode"

    report.step("normal mode advertises its own keys", normal_hint)

    def select():
        pane.send("ggvj")
        require(pane.wait_state("v"), "ggvj did not start a visual selection: %s" % pane.state())
        deadline = time.time() + 2
        while time.time() < deadline:
            pane.pump(0.1)
            if pane.pane().get("mode") == "v" and pane.pane().get("top") == "1":
                return "selection starts at the top of the scrollback"
        raise Failure("gg did not scroll the pane to its top: %s" % pane.pane())

    report.step("normal mode selects with native v", select)

    def yank():
        pane.send("y")
        deadline = time.time() + 2
        while time.time() < deadline and not pane.yanks():
            pane.pump(0.1)
        require(pane.yanks(), "y did not reach the unnamed register")
        return "%d lines yanked" % len(pane.yanks())

    report.step("normal mode yanks with native y", yank)

    def scroll():
        pane.send("G")
        deadline = time.time() + 2
        while time.time() < deadline:
            pane.pump(0.1)
            fields = pane.pane()
            if fields.get("mode") == "nt" and fields.get("line") == fields.get("lines"):
                if scrollback and int(fields.get("top", "0")) <= 1:
                    continue
                return "cursor on the last of %s lines" % fields["lines"]
        raise Failure("G did not reach the end of the pane: %s" % pane.pane())

    report.step("normal mode scrolls the pane", scroll)

    def back_to_job():
        pane.send("i")
        require(pane.wait_state("t"), "i did not return to the job: %s" % pane.state())
        return "typing again"

    report.step("i goes back to the job", back_to_job)

    def instant():
        start = time.time()
        pane.send(b"\x1c")  # <C-\>
        require(pane.wait_state("nt", timeout=1), "<C-\\> did not leave the job: %s" % pane.state())
        return "left in %.0fms" % ((time.time() - start) * 1000)

    report.step("<C-\\> leaves without waiting either", instant)

    def round_trip():
        pane.send("i")
        require(pane.wait_state("t"), "i did not return to the job")
        pane.escape_escape()
        require(pane.wait_state("nt", timeout=2), "the second round did not leave the job")
        return "the gesture repeats"

    report.step("<Esc><Esc> works on a second round", round_trip)

    def swap():
        # Tab is a swap, not a walk: from the pane it reaches the list, and
        # from the list it hands the keyboard back to the job. It must never
        # stop on the container tree on the way.
        pane.send("\t")
        require(pane.wait_screen("[h] containers"), "Tab did not reach the list: %s" % pane.screen())
        require("[Tab] terminal" in pane.screen(), "the list does not advertise the way back")
        pane.send("\t")
        require(pane.wait_state("t"), "the second Tab did not hand the keyboard to the job")
        return "pane <-> list"

    report.step("Tab swaps the sidebar and the pane", swap)

    def list_from_job():
        # <C-b> is the provider-independent way back to the list; the tmux
        # prefix is gone, so nothing inside the job is left to receive it.
        pane.send(b"\x02")
        require(pane.wait_screen("[h] containers"), "<C-b> did not reach the list: %s" % pane.screen())
        deadline = time.time() + 2
        while time.time() < deadline:
            pane.pump(0.1)
            if pane.state()[0] in ("n", "nt") and pane.state()[1] != "terminal":
                return "typing -> list"
        raise Failure("<C-b> reached the list but the job still owns the mode: %s" % pane.state())

    report.step("<C-b> leaves the job for the list", list_from_job)

    def digit_jump():
        pane.send("1")
        require(pane.wait_state("t"), "the digit did not hand the keyboard to the pane: %s" % pane.state())
        return "list -> typing"

    report.step("a digit in the list jumps to its terminal", digit_jump)


def tmux_server(workdir):
    """A private tmux server, so the checks never touch the user's sessions."""
    binary = shutil.which("tmux")
    if not binary:
        return None
    env = dict(os.environ, TMUX_TMPDIR=os.path.join(workdir, "tmux"))
    os.makedirs(env["TMUX_TMPDIR"], exist_ok=True)
    try:
        subprocess.run(
            [
                binary,
                "-L",
                SOCKET_NAME,
                "new-session",
                "-d",
                "-s",
                "e2e",
                "-x",
                str(COLUMNS),
                "-y",
                str(ROWS - 4),
                "sh",
                "-c",
                "seq 200; exec cat -v",
            ],
            env=env,
            check=True,
            timeout=15,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        print("skipping the tmux phase: %s" % error)
        return None
    return env


def kill_tmux(env):
    subprocess.run(
        [shutil.which("tmux"), "-L", SOCKET_NAME, "kill-server"],
        env=env,
        timeout=15,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def local_phase(workdir):
    pane = Pane(workdir, LOCAL_PROVIDERS, LOCAL_OPEN)
    report = Report("local provider")
    try:
        check_modes(pane, report, lambda: True, scrollback=True)
    finally:
        pane.close()
    return report


def tmux_phase(workdir):
    env = tmux_server(workdir)
    if not env:
        return None
    report = Report("tmux provider")
    # The tmux probe needs the socket of the server the test started.
    for key in ("TMUX_TMPDIR",):
        os.environ[key] = env[key]
    pane = Pane(os.path.join(workdir, "tmux"), TMUX_PROVIDERS, TMUX_OPEN)
    os.makedirs(pane.workdir, exist_ok=True)

    def drive():
        # containers -> the session, items -> the window, then the pane.
        pane.send("l")
        pane.pump(0.3)
        pane.send("l")
        return True

    try:
        check_modes(pane, report, drive, scrollback=False)
    finally:
        pane.close()
        kill_tmux(env)
    return report


def main():
    workdir = tempfile.mkdtemp(prefix="cinder-e2e-")
    reports = [local_phase(workdir)]
    if "--tmux" in sys.argv[1:]:
        tmux_workdir = os.path.join(workdir, "tmux-phase")
        os.makedirs(tmux_workdir, exist_ok=True)
        tmux_report = tmux_phase(tmux_workdir)
        if tmux_report:
            reports.append(tmux_report)

    passed = sum(len(report.results) - report.failed for report in reports)
    failed = sum(report.failed for report in reports)
    print("\n%s: %d passed, %d failed" % (os.path.basename(sys.argv[0]), passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
