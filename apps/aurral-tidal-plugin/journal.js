// aurral logs plugin failures only, and never for downloadSource.download, so
// the plugin keeps its own line-per-call record under the plugin data folder.
export async function appendLog(dataFolder, entry) {
  if (!dataFolder) return;
  try {
    const {appendFile, mkdir} = await import("node:fs/promises");
    await mkdir(dataFolder, {recursive: true});
    await appendFile(`${dataFolder}/plugin.log`, `${new Date().toISOString()} ${JSON.stringify(entry)}\n`);
  } catch {}
}
