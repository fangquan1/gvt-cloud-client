import { copyFileSync, cpSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const files = ["index.html", "styles.css"];
for (const file of files) {
  copyFileSync(file, join("dist", file));
}

if (existsSync("assets")) {
  mkdirSync(join("dist", "assets"), { recursive: true });
  cpSync("assets", join("dist", "assets"), { recursive: true });
}
