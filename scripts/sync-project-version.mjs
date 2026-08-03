#!/usr/bin/env node

import fs from "node:fs";

const [version] = process.argv.slice(2);

if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
  console.error("Usage: sync-project-version.mjs <major.minor.patch>");
  process.exit(1);
}

const path = "project.yml";
let project = fs.readFileSync(path, "utf8");

const buildMatch = project.match(/CURRENT_PROJECT_VERSION: (\d+)/);
if (!buildMatch) {
  console.error("CURRENT_PROJECT_VERSION was not found in project.yml");
  process.exit(1);
}

const nextBuild = Number.parseInt(buildMatch[1], 10) + 1;
project = project.replace(/MARKETING_VERSION: "[^"]+"/, `MARKETING_VERSION: "${version}"`);
project = project.replace(/CURRENT_PROJECT_VERSION: \d+/, `CURRENT_PROJECT_VERSION: ${nextBuild}`);

fs.writeFileSync(path, project);
