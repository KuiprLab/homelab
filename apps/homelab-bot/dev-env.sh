#!/usr/bin/env sh
# Not node --env-file: a 1Password .env is a FIFO that --watch restart-loops on.
# Repo root first, then app-local, so a per-app file wins.
set -a
if [ -e ../../.env ]; then . ../../.env; fi
if [ -e .env ]; then . .env; fi
set +a
