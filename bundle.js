import { bundle } from "luabundle";
import * as fs from "fs";
import * as path from "path";

const bundleCiOnly = process.env.BUNDLE_CI === "1";
const bundleOutputPath = process.env.BUNDLE_OUTPUT_PATH;
const targetDir = bundleOutputPath
  ? path.dirname(path.resolve(bundleOutputPath))
  : path.join(process.env.LOCALAPPDATA || "", "lua");
const targetPath = bundleOutputPath
  ? path.resolve(bundleOutputPath)
  : path.join(targetDir, "Cheater_Detection.lua");
const prototypeRootMainPath = path.join(
  process.env.LOCALAPPDATA || targetDir,
  "lua",
  "Main.lua"
);

function fileInfo(filePath) {
  const stat = fs.statSync(filePath);
  return `${filePath} (size=${stat.size}, mtime=${stat.mtime.toISOString()})`;
}

function bundleLua(entryPath) {
  return bundle(entryPath, {
    metadata: false,
    expressionHandler: (module, expression) => {
      const loc = expression.loc && expression.loc.start;
      console.warn(
        `WARNING: Non-literal require found in '${module.name}' at ${loc ? `${loc.line}:${loc.column}` : "unknown"}`
      );
    },
  });
}

function writeLuaTarget(targetFilePath, content, label) {
  fs.mkdirSync(path.dirname(targetFilePath), { recursive: true });
  fs.writeFileSync(targetFilePath, content, "utf8");
  console.log(`[BundleAndDeploy] DEPLOYED ${label}: ${fileInfo(targetFilePath)}`);
}

function copyLuaTarget(sourcePath, targetFilePath, label) {
  fs.mkdirSync(path.dirname(targetFilePath), { recursive: true });
  fs.copyFileSync(sourcePath, targetFilePath);
  console.log(`[BundleAndDeploy] DEPLOYED ${label}: ${fileInfo(targetFilePath)}`);
}

function stripBomFromDir(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      stripBomFromDir(fullPath);
    } else if (entry.isFile() && entry.name.endsWith(".lua")) {
      const content = fs.readFileSync(fullPath, "utf8");
      if (content.charCodeAt(0) === 0xfeff) {
        fs.writeFileSync(fullPath, content.slice(1), "utf8");
        console.log(`[BundleAndDeploy] Stripped BOM: ${fullPath}`);
      }
    }
  }
}

function main() {
  try {
    stripBomFromDir("./Cheater_Detection");

    // Bundle main Cheater_Detection
    const bundledLua = bundleLua("./Cheater_Detection/Main.lua");
    writeLuaTarget(targetPath, bundledLua, "main");

    const embedKeyCount = (bundledLua.match(/\["7656119/g) || []).length;
    if (embedKeyCount < 30000) {
      console.error(
        `[BundleAndDeploy] NOT DEPLOYED: bundle only contains ${embedKeyCount} embedded SteamIDs (expected ~34000). unified_embedded may be missing from the bundle.`
      );
      process.exitCode = 1;
      return;
    }
    console.log(`[BundleAndDeploy] Embedded SteamIDs in bundle: ${embedKeyCount}`);

    const prototypeEntryPath = "./Prototypes/Main.lua";
    if (!bundleCiOnly && fs.existsSync(prototypeEntryPath)) {
      const bundledPrototypeMain = bundleLua(prototypeEntryPath);
      writeLuaTarget(prototypeRootMainPath, bundledPrototypeMain, "prototype entrypoint");
      console.log(`[BundleAndDeploy] LOAD THIS FILE IN LMABOX: ${prototypeRootMainPath}`);
      console.log("[BundleAndDeploy] NOTE: Run On Save writes to the Output panel, not the integrated terminal.");
    } else {
      console.log("[BundleAndDeploy] SKIP prototype entrypoint: Prototypes/Main.lua not found");
    }

    const simplePrototypeEntryPath = "./Prototypes/LocalBridgeSimple/Main.lua";
    if (!bundleCiOnly && fs.existsSync(simplePrototypeEntryPath)) {
      const bundledSimplePrototype = bundleLua(simplePrototypeEntryPath);
      const simpleTargetPath = path.join(targetDir, "LocalBridgeSimple", "Main.lua");
      writeLuaTarget(simpleTargetPath, bundledSimplePrototype, "prototype package");
    }

    // Copy all .lua files in Prototypes folder (they use global libs, no bundling needed)
    const prototypesDir = "./Prototypes";
    if (!bundleCiOnly && fs.existsSync(prototypesDir)) {
      const prototypeFiles = fs
        .readdirSync(prototypesDir)
        .filter((file) => file.endsWith(".lua") && file !== "Main.lua");

      for (const file of prototypeFiles) {
        const sourcePath = path.join(prototypesDir, file);
        const prototypeTargetPath = path.join(targetDir, file);
        copyLuaTarget(sourcePath, prototypeTargetPath, `prototype ${file}`);
      }
    } else {
      console.log("[BundleAndDeploy] SKIP prototypes: Prototypes directory not found");
    }

    process.exitCode = 0;
  } catch (err) {
    console.error(`[BundleAndDeploy] NOT DEPLOYED: ${err instanceof Error ? err.message : String(err)}`);
    if (err instanceof Error && err.stack) console.error(err.stack);
    process.exitCode = 1;
  }
}

main();
