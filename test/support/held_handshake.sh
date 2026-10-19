#!/bin/sh
# held_handshake.sh: a stand-in child for the Reaper's identified-launch
# tests (#198, test/sdr_agent/ai/claude_cli_reaper_unidentified_test.exs).
# Never a real CLI; no network, no files written.
#
# Started by a port as `{:spawn_executable, "/bin/sh"}` with
# `args: [this file]` or `args: [this file, FIFO]`, so the exec'd process is
# this shell and `$$` is the port's os_pid. Builtins only (printf, read,
# case, exec redirections): its process tree is this single pid and it needs
# no PATH. Invoked through /bin/sh, so it needs no executable bit.
#
# Protocol, on the port's own pipes:
#   at start           -> prints "READY <pid>"
#   stdin line "PING"  -> prints "PONG <pid>"
#   stdin line "EXIT"  -> exits 0
#   any other line     -> prints "ERR <pid>"
#   stdin EOF          -> eof-exit (no FIFO argument): exits 0.
#                         eof-hold (FIFO argument): keeps running, blocked
#                         reading the FIFO, until a line arrives there or it
#                         is killed (a child that does not exit on stdin EOF).
#
# The barrier: while its port is open and no EXIT was sent it cannot leave by
# itself (no sleep, no duration). In eof-hold mode the FIFO is opened
# read-write before READY, so that open never blocks, and a writer never
# blocks while this process lives.

fifo=${1-}

if [ -n "$fifo" ]; then
  exec 3<>"$fifo" || exit 70
fi

printf 'READY %s\n' "$$" || exit 0

while IFS= read -r line; do
  case $line in
    PING) printf 'PONG %s\n' "$$" || exit 0 ;;
    EXIT) exit 0 ;;
    *) printf 'ERR %s\n' "$$" || exit 0 ;;
  esac
done

# stdin EOF
if [ -n "$fifo" ]; then
  IFS= read -r _ <&3
fi

exit 0
