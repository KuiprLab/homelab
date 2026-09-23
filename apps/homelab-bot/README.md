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

Inside `src/`, code is divided by **feature** — what it is for — not by what
kind of thing it is:

```
src/
├── feature.ts              the Feature and Command contracts
├── features/
│   ├── index.ts            the feature list; everything else is reached from here
│   └── diagnostics/        one feature
│       ├── index.ts        declares the feature
│       └── ping.ts         one of its commands
├── config.ts               environment
├── register.ts             syncing commands with Discord
└── index.ts                client bootstrap
```

A feature owns everything it needs. Adding `music/` or `management/` means
adding a directory and one line in `features/index.ts` — never editing a
shared commands file, a shared handler switch, and a shared registration list
for the same change. Removing one means deleting the directory.

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
4. Deploy:
   ```bash
   just deploy sorbet
   ```
   The bot registers its commands with Discord on startup, so there is nothing
   else to run.

## Adding a feature

Create `src/features/<name>/index.ts` exporting a `Feature`, then import it
into the `features` array in `src/features/index.ts`.

A command is declared, not built. The framework turns one declaration into
both the schema Discord receives and the routing table the bot dispatches on,
so the two cannot disagree:

```ts
import type { Command } from "../../feature.ts";

export const music: Command = {
  name: "music",
  description: "Music controls",

  // /music play <query>, /music stop
  subcommands: [
    {
      name: "play",
      description: "Play a track",
      options: (b) =>
        b.addStringOption((o) =>
          o.setName("query").setDescription("Track or URL").setRequired(true),
        ),
      execute: async (interaction) => { /* ... */ },
    },
    { name: "stop", description: "Stop playback", execute: async () => {} },
  ],

  // /music queue add, /music queue clear
  groups: [
    {
      name: "queue",
      description: "Queue management",
      subcommands: [
        { name: "add", description: "Add to queue", execute: async () => {} },
        { name: "clear", description: "Clear it", execute: async () => {} },
      ],
    },
  ],
};
```

A command with no subcommands takes an `execute` (and optionally `options`)
directly — see `src/features/diagnostics/ping.ts`.

Discord nests exactly this deep: command → group → subcommand. There is no
third level.

Features can also take an optional `setup(client)`, run once after connect,
for anything that is not a slash command: event listeners, timers, voice
connections.

### What fails at startup rather than in production

- **Two features defining the same command name.** Names are global to the
  application, so Discord would keep whichever was sent last.
- **A command with both `execute` and subcommands.** Discord never invokes a
  parent on its own, so that `execute` could not run.
- **A command with neither.**
- **Both `options` and subcommands**, or more than 25 subcommands — Discord
  rejects these, so they are caught before they are sent.

A feature whose `setup` throws is logged and skipped, not fatal: a broken
`music` still leaves `/ping` answering.

Restart the bot and it registers the new command set itself.

Registration reads before it writes: it fetches the current commands and only
writes when they differ from this build. That is what makes it safe to do on
every startup, including the restart `npm run dev` performs on each save — the
common case costs one cheap read and no write.

`homelab-bot-register` (or `npm run dev:register`) does the same thing as a
one-shot, for pushing a change without restarting the bot and for seeing the
result as a real exit status.

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
npm run dev          # run from src/, restart on change
npm run dev:register # register this build's commands to your dev guild
npm run typecheck    # tsc --noEmit
npm run build        # tsc -> dist/
nix build .#homelab-bot
```

`npm run dev` skips the build entirely: Node 24 strips types and runs
`src/index.ts` directly, and `--watch` restarts on save. There is no `dist/`
involved, so what you edit is what runs.

### Credentials for `npm run dev`

`dev-env.sh` sources two files if they exist — repo root first, then
`apps/homelab-bot/.env`, so a per-app file wins. Both are gitignored:

```
DISCORD_TOKEN=...
DISCORD_APPLICATION_ID=...
DISCORD_GUILD_ID=...
```

A 1Password Environments `.env` works unmodified: it is a named pipe, so the
plaintext never touches disk.

**Why a shell script instead of node's `--env-file`.** Node watches whatever it
is handed there, and a 1Password `.env` is re-served on every read, so `--watch`
sees a change the moment the process starts and restart-loops — 29 restarts in
8 seconds when measured. `--watch-path` does not help; the env file is watched
regardless of it. Sourcing the file means node is never told a file was
involved, and `--watch` goes back to reacting only to source edits.

`dev-env.sh` is dev-only. It is not in `_package.nix`'s fileset, so it never
enters the build.

**Use a second Discord application for this, not the deployed bot's token.**
Two instances on one token both receive the same interaction, so `/ping` gets
answered twice and the loser errors on an already-acknowledged interaction.
It also keeps the production token out of plaintext on your laptop — the real
one stays in `secrets/sorbet/homelab-bot.env`, encrypted.

Point `DISCORD_GUILD_ID` at a throwaway server and `npm run dev:register`
puts the commands there instantly, without touching the real one.

The shell's nodejs is the same derivation `_package.nix` builds with, so a
lockfile written here is one Nix can consume. A mismatched npm produces a
lockfile that only fails in CI.

Relative imports in `src/` are written with `.ts` extensions so Node can
resolve them when running the source directly. `rewriteRelativeImportExtensions`
in `tsconfig.json` turns them into `.js` on emit, which is what the built
`dist/` needs. Change one without the other and dev and build stop agreeing.

Dependencies are pinned by `package-lock.json` and nothing else. `importNpmLock`
derives every hash from that file, so bumping a dependency is `npm install` plus
committing the lockfile — there is no `npmDepsHash` to re-pin.
