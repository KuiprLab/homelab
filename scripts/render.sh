#!/usr/bin/env bash
set -euo pipefail
target=${1:-dev}

src=$(nix build --no-link --print-out-paths .#manifests)
rev=$(git rev-parse --short HEAD)

git worktree prune
tmp=$(mktemp -d)
trap 'git worktree remove --force "$tmp" 2>/dev/null || true' EXIT

# Detached HEAD: the rendered branch never exists locally, so no worktree can pin it.
if git fetch --quiet origin rendered 2>/dev/null; then
  git worktree add --detach "$tmp" FETCH_HEAD
else
  git worktree add --detach "$tmp"
  find "$tmp" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi

rm -rf "${tmp:?}/$target"
cp -RL "$src" "$tmp/$target"

git -C "$tmp" add -A
if git -C "$tmp" diff --cached --quiet; then
  echo "rendered/$target is up to date"
else
  git -C "$tmp" commit -qm "render: $target from $rev"
  git -C "$tmp" push --force origin HEAD:rendered
fi
