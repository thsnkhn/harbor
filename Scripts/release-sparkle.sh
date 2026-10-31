#!/bin/sh
set -eu

# Preparation is local. Only the explicit publish command changes GitHub or the live feed.
exec python3 "$(dirname "$0")/release.py" "$@"
