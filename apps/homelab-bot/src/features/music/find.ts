import { ButtonBuilder, ButtonStyle, Colors, ContainerBuilder, MessageFlags, SectionBuilder, SeparatorBuilder, SeparatorSpacingSize, TextDisplayBuilder, ThumbnailBuilder } from "discord.js";
import type { Subcommand } from "../../feature.ts";
import { fetchCoverArt, mbApi } from "./musicbrainz.ts";
import type { IRecordingMatch, IReleaseList, IReleaseMatch } from "musicbrainz-api";

export const find: Subcommand = {
    name: "find",
    description: "Search the music library",

    options: (builder) =>
        builder.addStringOption((option) =>
            option
                .setName("query")
                .setDescription("Artist, album or track to look for")
                .setRequired(true)
                // Discord enforces these itself, so a junk query is rejected in the
                // client before it ever reaches us.
                .setMinLength(2)
                .setMaxLength(100),
        ),

    execute: async (interaction) => {
        const query = interaction.options.getString("query", true).trim();

        const albums: IReleaseList = await mbApi.search("release", {
            query: query,
            limit: 5,
        });

        if (albums.count === 0 || albums.releases.length < 1) {
            await interaction.reply({
                content: "Error no albums found for query: " + query,
                allowedMentions: { parse: [] },
            });
        } else {
            const album: IReleaseMatch = albums.releases[0]!;

            await interaction.reply({
                components: [await buildMessageForRelease(album)],
                allowedMentions: { parse: [] },
                flags: MessageFlags.IsComponentsV2,
            });
        }



    },
};


async function buildMessageForRelease(release: IReleaseMatch,): Promise<ContainerBuilder> {
    const cover = await fetchCoverArt(release.id) ?? "";
    const artistCredit = release["artist-credit"]?.map((ac) => ac.name).join(", ") ?? "Unknown";


    const section1 = new SectionBuilder()
        .addTextDisplayComponents((textDisplay) =>
            textDisplay.setContent(
                `## ${release.title} by ${artistCredit}\n` +
                `Released: ${release.date ?? "Unknown"}\n` +
                `Track Count: ${release["track-count"] ?? "Unknown"}\n`
            ),
        )
        .setThumbnailAccessory(
            (thumbnail) => thumbnail.setDescription('alt text displaying on the image').setURL(cover),
        );



    return new ContainerBuilder()
        .setAccentColor(0x0099ff)
        .addSectionComponents(section1)
        .addActionRowComponents((actionRow) =>
            actionRow.setComponents(new ButtonBuilder().setCustomId('exampleSelect').setLabel('Download').setStyle(ButtonStyle.Primary)),
        )
}
