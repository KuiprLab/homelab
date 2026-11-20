import {subsonicError, subtidalFile} from "./subtidal.js";

const MIN_AUDIO_BYTES = 4096;
const CONTENT_TYPE_EXTENSIONS = {
  "audio/flac": "flac",
  "audio/x-flac": "flac",
  "audio/mp4": "m4a",
  "audio/mpeg": "mp3",
  "audio/ogg": "ogg",
};

// Most stream failures come back as HTTP 200 with a JSON body, so the content
// type decides whether the bytes are audio at all.
const isAudioContent = (contentType) =>
  /^(audio\/|application\/octet-stream)/i.test(String(contentType || ""));

function attachmentName(header, fallback) {
  const match = String(header || "").match(/filename="?([^";]+)"?/i);
  const base = match ? match[1].split(/[\\/]/).pop().trim() : "";
  return base && base !== "." && base !== ".." ? base : fallback;
}

function extensionFor(contentType, result, attachment) {
  const named = CONTENT_TYPE_EXTENSIONS[String(contentType || "").split(";")[0].trim().toLowerCase()];
  const format = String(result?.format || "").trim().toLowerCase();
  const fromAttachment = String(attachment || "").split(".").pop() || "";
  return named ?? ((format || fromAttachment).replace(/[^a-z0-9]/g, "") || "flac");
}

const safeName = (value) =>
  String(value || "")
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_")
    .trim()
    .slice(0, 180);

// aurral reads the file name as identity evidence before it tags the file, so a
// bare t<id> name leaves the title check blind.
export function taggedFileName(result, extension) {
  const base = safeName(
    [String(result?.artist || "").trim(), String(result?.title || "").trim()]
      .filter(Boolean)
      .join(" - "),
  );
  return base ? `${base}.${extension}` : null;
}

// "03. Artist - Title.flac": aurral strips the leading number, then reads the
// artist and title, which is all the evidence an untagged Tidal file carries.
export function albumFileName(entry, position, extension) {
  const track = Number(entry?.track);
  const number = String(track > 0 ? track : position).padStart(2, "0");
  const base = safeName(
    [`${number}.`, String(entry?.artist || "").trim(), "-", String(entry?.title || "").trim()]
      .filter(Boolean)
      .join(" "),
  );
  return `${base}.${extension}`;
}

async function fetchAudio(settings, tidalId) {
  const response = await subtidalFile(settings, "download", {id: tidalId});
  const contentType = String(response.headers.get("content-type") || "");
  if (!isAudioContent(contentType)) {
    throw new Error(
      subsonicError(await response.text()) ??
        `subtidal sent ${contentType || "no content type"} instead of audio`,
    );
  }
  const audio = Buffer.from(await response.arrayBuffer());
  if (audio.length < MIN_AUDIO_BYTES) throw new Error(`subtidal sent ${audio.length} bytes of audio`);
  return {
    audio,
    contentType,
    attachment: attachmentName(response.headers.get("content-disposition"), ""),
  };
}

export async function writeTrack(settings, directory, tidalId, result, nameOf) {
  const {audio, contentType, attachment} = await fetchAudio(settings, tidalId);
  const fileName = nameOf(extensionFor(contentType, result, attachment));
  const {writeFile} = await import("node:fs/promises");
  await writeFile(`${directory}/${fileName}`, audio);
  return fileName;
}
