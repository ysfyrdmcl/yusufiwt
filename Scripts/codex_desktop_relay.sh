#!/bin/sh
set -eu
binary_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../MacOS" && pwd)
exec "$binary_dir/agentcontrol-hook" codex-desktop-proxy "$@"
