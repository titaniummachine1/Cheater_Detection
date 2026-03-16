import { bundle } from "luabundle";
import * as fs from "fs";
import * as path from "path";

const targetDir = path.join(process.env.LOCALAPPDATA || "", "lua");
const targetPath = path.join(targetDir, "Cheater_Detection.lua");

function fileInfo(filePath) {
  const stat = fs.statSync(filePath);
  return `${filePath} (size=${stat.size}, mtime=${stat.mtime.toISOString()})`;
}

function main() {
  try {
    // Bundle main Cheater_Detection
    const bundledLua = bundle("./Cheater_Detection/Main.lua", {
      metadata: false,
      expressionHandler: (module, expression) => {
        const start = expression.loc.start;
        console.warn(
          `WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`
        );
      },
    });

    fs.mkdirSync(targetDir, { recursive: true });
    fs.writeFileSync(targetPath, bundledLua, "utf8");
    console.log(`[BundleAndDeploy] DEPLOYED main: ${fileInfo(targetPath)}`);

    // Copy all .lua files in Prototypes folder (they use global libs, no bundling needed)
    const prototypesDir = "./Prototypes";
    if (fs.existsSync(prototypesDir)) {
      const prototypeFiles = fs
        .readdirSync(prototypesDir)
        .filter((file) => file.endsWith(".lua"));

      for (const file of prototypeFiles) {
        const sourcePath = path.join(prototypesDir, file);
        const prototypeTargetPath = path.join(targetDir, file);
        fs.copyFileSync(sourcePath, prototypeTargetPath);
        console.log(`[BundleAndDeploy] DEPLOYED prototype: ${fileInfo(prototypeTargetPath)}`);
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
