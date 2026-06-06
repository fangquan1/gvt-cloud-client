const SECRET_PATTERNS: Array<[RegExp, string]> = [
  [/(password|passwd|pwd)\s*[:=]\s*[^,\s;]+/gi, "$1=<redacted>"],
  [/(token|session|secret)\s*[:=]\s*[^,\s;]+/gi, "$1=<redacted>"],
  [/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer <redacted>"],
  [/([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g, "<email-redacted>"]
];

export function redactSecrets(value: string): string {
  return SECRET_PATTERNS.reduce((text, [pattern, replacement]) => {
    return text.replace(pattern, replacement);
  }, value);
}

export function trimLogLines(lines: string[], maxLines = 80): { lines: string[]; truncated: boolean } {
  const cleaned = lines.map(redactSecrets);
  if (cleaned.length <= maxLines) {
    return { lines: cleaned, truncated: false };
  }
  return { lines: cleaned.slice(cleaned.length - maxLines), truncated: true };
}

export function publicServerConfig<T extends { password?: string; token?: string }>(config: T): Omit<T, "password" | "token"> {
  const copy = { ...config };
  delete copy.password;
  delete copy.token;
  return copy;
}
