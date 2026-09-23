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
} as const;
