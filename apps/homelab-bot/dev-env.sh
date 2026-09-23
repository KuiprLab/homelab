#!/usr/bin/env sh
# Load dev credentials into the environment, for sourcing by npm run dev.
#
# Deliberately NOT node's --env-file. Node watches whatever it is given there,
# and a 1Password Environments .env is a named pipe that gets re-served on
# every read -- so --watch sees a change the instant the process starts and
# restart-loops. Measured before this existed: 29 restarts in 8 seconds.
# --watch-path does not help; node watches the env file regardless of it.
# Sourcing the file here means node is never told a file was involved.
#
# Repo root first, app-local second so a per-app file wins. Uses -e rather
# than -f because a 1Password Environments .env is a FIFO, not a regular file.
set -a
if [ -e ../../.env ]; then . ../../.env; fi
if [ -e .env ]; then . .env; fi
set +a
