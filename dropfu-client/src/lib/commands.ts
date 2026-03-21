export interface CommandDef {
  usage: string;
  description: string;
  local?: boolean;
}

export interface CommandSection {
  title: string;
  commands: CommandDef[];
}

export interface PluginDef {
  name: string;
  usage: string;
  description: string;
}

export const SECTIONS: CommandSection[] = [
  {
    title: "File & Navigation",
    commands: [
      { usage: "pwd",                    description: "Print the agent's current working directory" },
      { usage: "ls [path]",              description: "List directory contents" },
      { usage: "cat <file>",             description: "Display file contents (up to ~1 KB)" },
      { usage: "find <path> <pattern>",  description: "Search for files matching a glob (max 500)" },
      { usage: "cp <source> <dest>",     description: "Copy a file" },
      { usage: "mv <source> <dest>",     description: "Move or rename a file" },
      { usage: "rm <file>",              description: "Delete a file" },
      { usage: "download <remote_path>", description: "Download a file from the agent" },
      { usage: "upload <remote_path>",   description: "Upload a file to the agent" },
    ],
  },
  {
    title: "System",
    commands: [
      { usage: "systeminfo",             description: "Show host, OS, CPU, memory, and network info" },
      { usage: "shell",                  description: "Open an interactive shell session" },
      { usage: "seppuku",                description: "Self-destruct: remove plugins and agent binary" },
    ],
  },
  {
    title: "Plugin Management",
    commands: [
      { usage: "plugin list",              description: "List available plugins and install status" },
      { usage: "plugin install <name>",    description: "Download and install a plugin" },
      { usage: "plugin uninstall <name>",  description: "Remove an installed plugin" },
      { usage: "plugin run <name> [args]", description: "Run an installed plugin" },
    ],
  },
];

export const PLUGINS: PluginDef[] = [
  { name: "file",     usage: "file <path> [path2 ...]",                description: "Identify file types" },
  { name: "ipconfig", usage: "ipconfig",                               description: "Display network interfaces" },
  { name: "ping",     usage: "ping [--count N] [--timeout N] <target>", description: "Ping a host" },
  { name: "ps",       usage: "ps [--sort cpu|mem|pid] [--top N]",      description: "List running processes" },
  { name: "gzip",     usage: "gzip compress|decompress <path> [opts]", description: "Compress/decompress files" },
];

export function formatHelp(): string {
  const allUsages = SECTIONS.flatMap((s) => s.commands.map((c) => c.usage));
  const pluginUsages = PLUGINS.map((p) => p.usage);
  const maxWidth = Math.max(...allUsages.map((u) => u.length), ...pluginUsages.map((u) => u.length)) + 2;

  const lines: string[] = [];

  for (const section of SECTIONS) {
    lines.push(`${section.title}:`);
    for (const cmd of section.commands) {
      const tag = cmd.local ? " (local)" : "";
      lines.push(`  ${cmd.usage.padEnd(maxWidth)}  ${cmd.description}${tag}`);
    }
    lines.push("");
  }

  lines.push("Plugins (run with: plugin run <name> [args]):");
  for (const p of PLUGINS) {
    lines.push(`  ${p.usage.padEnd(maxWidth)}  ${p.description}`);
  }
  lines.push("");

  lines.push("Shortcuts:");
  lines.push("  Shift+Arrow              Split pane");
  lines.push("  Shift+Delete             Close active pane");
  lines.push("  Shift+Ctrl+Arrow         Navigate between panes");
  lines.push("  Shift+Backspace          Clear screen");
  lines.push("");
  lines.push("Type 'help' to show this menu.");

  return lines.join("\n");
}
