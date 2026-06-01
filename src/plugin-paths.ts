import { join } from "path";

const PLUGIN_ID = "alembic";
const HELPER_APP_NAME = "audio-capture.app";

export function getPluginDir(vaultBasePath: string): string {
  return join(vaultBasePath, ".obsidian", "plugins", PLUGIN_ID);
}

export function getLegacyHelperDir(homeDir: string): string {
  return join(homeDir, "Library", "Application Support", PLUGIN_ID);
}

export function resolveHelperRoot(options: {
  pluginDir: string;
  homeDir?: string;
  helperExists: (helperAppPath: string) => boolean;
}): string {
  if (options.helperExists(join(options.pluginDir, HELPER_APP_NAME))) {
    return options.pluginDir;
  }

  if (options.homeDir) {
    const legacyDir = getLegacyHelperDir(options.homeDir);
    if (options.helperExists(join(legacyDir, HELPER_APP_NAME))) {
      return legacyDir;
    }
  }

  return options.pluginDir;
}
