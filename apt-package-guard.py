#!/usr/bin/python3
"""Check allowed package changes in an APT VERSION 2 pre-install hook.

Read only the hook's stdin; never invoke APT or write policy.
APT configuration values may contain credentials and must not be reported.
"""

import argparse
import re
import sys


PACKAGE = re.compile(r"[a-z0-9][a-z0-9+.-]+\Z")
VERSION = re.compile(r"(?:-|[0-9][A-Za-z0-9.+:~\-]*)\Z")


def check(stream, allow_timesyncd_removal=False, allow_upgrades=False):
    errors = []
    refused = []
    if stream.readline() != "VERSION 2\n":
        return ["expected VERSION 2 header"], refused

    for number, line in enumerate(stream, 2):
        if line == "\n":
            break
        # Consume configuration without retaining or exposing any values.
        key, separator, _ = line.partition("=")
        if not separator or not key or any(c.isspace() for c in key) or "\x00" in line:
            errors.append(f"invalid configuration entry on line {number}")
    else:
        errors.append("missing configuration section terminator")
        return errors, refused

    for number, line in enumerate(stream, number + 1):
        fields = line.rstrip("\n").split(maxsplit=4)
        if len(fields) != 5 or any(ord(c) < 32 and c not in "\t\n" for c in line):
            errors.append(f"invalid package action fields on line {number}")
            continue
        name, old, comparison, new, action = fields
        if (not PACKAGE.fullmatch(name) or not VERSION.fullmatch(old)
                or not VERSION.fullmatch(new) or comparison not in ("<", ">", "=")):
            errors.append(f"invalid package name or versions on line {number}")
            continue
        if action == "**REMOVE**":
            if old == "-" or new != "-" or comparison != ">":
                errors.append(f"invalid removal action on line {number}")
                continue
            if allow_timesyncd_removal and name == "systemd-timesyncd":
                continue
            refused.append((name, old, new, "REMOVE"))
        elif action == "**CONFIGURE**" or (action.startswith("/") and action.endswith(".deb")):
            if new == "-" or (old == "-" and comparison != "<"):
                errors.append(f"invalid installation action on line {number}")
                continue
            if old != "-" and not (allow_upgrades and comparison == "<"):
                refused.append((name, old, new, "CONFIGURE" if action == "**CONFIGURE**" else "UNPACK"))
        else:
            errors.append(f"invalid or unknown package action on line {number}")
    return errors, refused


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--allow-upgrades", action="store_true",
        help="allow upgrades of installed packages, including dependencies",
    )
    parser.add_argument(
        "--allow-timesyncd-removal", action="store_true",
        help="allow only removal of systemd-timesyncd when installing Orin chrony",
    )
    args = parser.parse_args()
    try:
        errors, refused = check(sys.stdin, args.allow_timesyncd_removal, args.allow_upgrades)
    except (OSError, UnicodeError):
        print("APT package guard: invalid or unreadable hook input.", file=sys.stderr)
        return 1
    for error in errors:
        print(f"APT package guard: invalid VERSION 2 input: {error}.", file=sys.stderr)
    if refused:
        print("APT package guard: refused changes to installed packages:", file=sys.stderr)
        for name, old, new, action in refused:
            print(f"  {name}: {old} -> {new} ({action})", file=sys.stderr)
    return 1 if errors or refused else 0


if __name__ == "__main__":
    sys.exit(main())
