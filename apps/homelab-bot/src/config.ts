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

  guildId: optional("DISCORD_GUILD_ID"),

  // Container address: the vhost is behind authelia and answers with its login page.
  slskdUrl: optional("SLSKD_URL"),
  slskdApiKey: optional("SLSKD_API_KEY"),

  beetsHintsDir: optional("BEETS_HINTS_DIR"),

  beetsLibrary: optional("BEETS_LIBRARY"),

  beetsRetagDir: optional("BEETS_RETAG_DIR"),

  gatusUrl: optional("GATUS_URL"),
} as const;
