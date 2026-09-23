# homelab-bot

Discord bot for the lab. TypeScript, discord.js v14, built with Nix and run by
systemd on sorbet.

## Layout

| File | Role |
| --- | --- |
| `flake-module.nix` | The only file import-tree picks up. Exposes the package and the NixOS module. |
| `_package.nix` | How it is built. |
| `_module.nix` | How it is run on a host. |
| `src/` | The bot itself. |

The `_` prefix is load-bearing: import-tree skips any path containing `/_`, so
these are imported deliberately from `flake-module.nix` rather than evaluated
as flake-parts modules.

## First run

1. Create an application at <https://discord.com/developers/applications>, add
   a bot, copy the token and application ID.
2. Fill in the secret — it ships with placeholders:
   ```bash
   sops secrets/sorbet/homelab-bot.env
   ```
   `DISCORD_GUILD_ID` is optional. Set it and commands register to that one
   server instantly; leave it blank and they register globally, which Discord
   can take an hour to propagate.
3. Set `enabled = true` in `_module.nix`. It ships `false` so a placeholder
   token cannot leave a unit restart-looping on the lab. That one flag gates
   both `wantedBy` and the secret's `restartUnits`, which have to agree:
   sops-nix restarts listed units when a secret changes, and `systemctl
   restart` starts an inactive unit regardless of `wantedBy`.
4. Deploy, then register the commands once:
   ```bash
   just deploy sorbet
   ssh root@sorbet systemctl start homelab-bot-register
   ```

## Adding a command

Two lines. Write `src/commands/<name>.ts` exporting `data` and `execute`, then
import it into the `commands` array in `src/commands/index.ts`. Rebuild, deploy,
and run `homelab-bot-register` again — Discord only learns about a command when
you push the definitions.

## Working on it

Node and npm come from the dev shell -- nothing has to be installed globally.

```bash
nix develop .#homelab-bot
```

Or just `cd` into this directory: `.envrc` enters the shell automatically via
direnv. Run `direnv allow` once to trust it.

Inside the shell:

```bash
npm ci               # deps into ./node_modules (gitignored)
npm run typecheck    # tsc --noEmit
npm run build        # tsc -> dist/
nix build .#homelab-bot
```

The shell's nodejs is the same derivation `_package.nix` builds with, so a
lockfile written here is one Nix can consume. A mismatched npm produces a
lockfile that only fails in CI.

Dependencies are pinned by `package-lock.json` and nothing else. `importNpmLock`
derives every hash from that file, so bumping a dependency is `npm install` plus
committing the lockfile — there is no `npmDepsHash` to re-pin.
