import { bundle } from "luabundle";
import * as fs from "fs";
import * as path from "path";

const targetDir = path.join(process.env.LOCALAPPDATA || "", "lua");
const targetPath = path.join(targetDir, "Cheater_Detection.lua");
const prototypeRootMainPath = path.join(targetDir, "Main.lua");

function fileInfo(filePath) {
  const stat = fs.statSync(filePath);
  return `${filePath} (size=${stat.size}, mtime=${stat.mtime.toISOString()})`;
}

function bundleLua(entryPath) {
  return bundle(entryPath, {
    metadata: false,
    expressionHandler: (module, expression) => {
      const start = expression.loc.start;
      console.warn(
        `WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`
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

function main() {
  try {
    // Bundle main Cheater_Detection
    const bundledLua = bundleLua("./Cheater_Detection/Main.lua");
    writeLuaTarget(targetPath, bundledLua, "main");

    const prototypeEntryPath = "./Prototypes/Main.lua";
    if (fs.existsSync(prototypeEntryPath)) {
      const bundledPrototypeMain = bundleLua(prototypeEntryPath);
      writeLuaTarget(prototypeRootMainPath, bundledPrototypeMain, "prototype entrypoint");
      console.log(`[BundleAndDeploy] LOAD THIS FILE IN LMABOX: ${prototypeRootMainPath}`);
      console.log("[BundleAndDeploy] NOTE: Run On Save writes to the Output panel, not the integrated terminal.");
    } else {
      console.log("[BundleAndDeploy] SKIP prototype entrypoint: Prototypes/Main.lua not found");
    }

    const simplePrototypeEntryPath = "./Prototypes/LocalBridgeSimple/Main.lua";
    if (fs.existsSync(simplePrototypeEntryPath)) {
      const bundledSimplePrototype = bundleLua(simplePrototypeEntryPath);
      const simpleTargetPath = path.join(targetDir, "LocalBridgeSimple", "Main.lua");
      writeLuaTarget(simpleTargetPath, bundledSimplePrototype, "prototype package");
    }

    // Copy all .lua files in Prototypes folder (they use global libs, no bundling needed)
    const prototypesDir = "./Prototypes";
    if (fs.existsSync(prototypesDir)) {
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
    process.exitCode = 1;
  }
}

main();
