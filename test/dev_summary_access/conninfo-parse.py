"""ADR-0016 test helper: parse libpq conninfo strings with the pinned libpq.

Usage: python3 -I conninfo-parse.py /path/to/libpq.5.dylib < strings

Each input line is one conninfo string. For each, prints one line:
  host=<v>|hostaddr=<v>|port=<v>|dbname=<v>|user=<v>|service=<v>
with <v> '(unset)' for a NULL value, or 'PARSE-ERROR' for the whole line.
It only calls PQconninfoParse; it never connects.
"""

import ctypes
import sys


class Option(ctypes.Structure):
    _fields_ = [
        ("keyword", ctypes.c_char_p),
        ("envvar", ctypes.c_char_p),
        ("compiled", ctypes.c_char_p),
        ("val", ctypes.c_char_p),
        ("label", ctypes.c_char_p),
        ("dispchar", ctypes.c_char_p),
        ("dispsize", ctypes.c_int),
    ]


def main():
    lib = ctypes.CDLL(sys.argv[1])
    lib.PQconninfoParse.restype = ctypes.POINTER(Option)
    lib.PQconninfoParse.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
    lib.PQconninfoFree.argtypes = [ctypes.POINTER(Option)]
    wanted = ("host", "hostaddr", "port", "dbname", "user", "service")
    for line in sys.stdin.read().splitlines():
        err = ctypes.c_char_p()
        opts = lib.PQconninfoParse(line.encode(), ctypes.byref(err))
        if not opts:
            print("PARSE-ERROR")
            continue
        vals = {}
        i = 0
        while opts[i].keyword is not None:
            vals[opts[i].keyword.decode()] = opts[i].val
            i += 1
        lib.PQconninfoFree(opts)
        print("|".join(
            "%s=%s" % (k, vals.get(k).decode() if vals.get(k) is not None else "(unset)")
            for k in wanted))


main()
