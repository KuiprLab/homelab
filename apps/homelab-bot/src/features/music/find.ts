import { MessageFlags, SectionBuilder, TextDisplayBuilder } from "discord.js";
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


async function buildMessageForRelease(release: IReleaseMatch ,): Promise<SectionBuilder> {
    const cover = await fetchCoverArt(release.id) ?? "";

    return new SectionBuilder()
        .addTextDisplayComponents((textDisplay) =>
            textDisplay.setContent(
                'This text is inside a Text Display component! You can use **any __markdown__** available inside this component too.',
            ),
        )
        .setThumbnailAccessory(
            (thumbnail) => thumbnail.setDescription('alt text displaying on the image').setURL(cover), // Supports arbitrary URLs such as 'https://i.imgur.com/AfFp7pu.png' as well.
        );

}
