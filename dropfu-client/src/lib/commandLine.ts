export function parseCommand(input: string): string[] {
  const result: string[] = [];
  let current = "";
  let quote: "'" | '"' | null = null;
  let escaped = false;

  for (const ch of input) {
    if (escaped) {
      current += ch;
      escaped = false;
    } else if (ch === "\\") {
      escaped = true;
    } else if (quote !== null) {
      if (ch === quote) quote = null;
      else current += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === " " || ch === "\t") {
      if (current) {
        result.push(current);
        current = "";
      }
    } else {
      current += ch;
    }
  }

  if (escaped) current += "\\";
  if (quote !== null) throw new Error("unterminated quote");
  if (current) result.push(current);
  return result;
}
