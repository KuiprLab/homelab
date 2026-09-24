/**
 * Configuration comes from the environment, which systemd populates from a
 * sops-encrypted EnvironmentFile. Nothing here reads a file directly, so the
 * secret never has to be readable by the service's own user.
 */

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(
      `Missing required environment variable ${name}.\n` +
        `  dev:  .env at the repo root, or apps/homelab-bot/.env\n` +
        `  host: sops secrets/sorbet/homelab-bot.env`,
    );
  }
  return value;
}

function optional(name: string): string | null {
  const value = process.env[name];
  return value === undefined || value === "" ? null : value;
}

export const config = {
  token: required("DISCORD_TOKEN"),
  applicationId: required("DISCORD_APPLICATION_ID"),

  /**
   * When set, slash commands register to this one guild and appear instantly.
   * When null they register globally, which Discord can take up to an hour to
   * propagate. Keep it set for a single-server lab bot.
   */
  guildId: optional("DISCORD_GUILD_ID"),

  /**
   * slskd, for the music feature's Soulseek side. Optional, and optional on
   * purpose: a missing key should cost the one command that needs it, not the
   * bot's startup.
   *
   * SLSKD_URL wants the container's own address -- http://127.0.0.1:5030 --
   * rather than slskd.int.kuipr.de, which is behind authelia and answers an
   * API-key request with its login page. SLSKD_API_KEY is one of the keys
   * under web.authentication.api_keys in secrets/sorbet/slskd.yml.
   */
  slskdUrl: optional("SLSKD_URL"),
  slskdApiKey: optional("SLSKD_API_KEY"),

  /**
   * Where to drop beets import hints -- the MusicBrainz release a download was
   * queued for, which the slskd -> beets import unit picks up so it does not
   * have to guess the release from a Soulseek folder name. See
   * features/music/hints.ts and services/music/beets.nix.
   *
   * Optional: with it unset the bot simply queues downloads and beets keeps
   * matching on its own, which is what it did before.
   */
  beetsHintsDir: optional("BEETS_HINTS_DIR"),
} as const;
