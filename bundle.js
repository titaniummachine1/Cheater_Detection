import { bundle } from "luabundle";
import * as fs from "fs";
import * as path from "path";

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

const targetDir = path.join(process.env.LOCALAPPDATA || "", "lua");
if (!fs.existsSync(targetDir)) {
  fs.mkdirSync(targetDir, { recursive: true });
}

const targetPath = path.join(targetDir, "Cheater_Detection.lua");

// Write main bundle
fs.writeFile(targetPath, bundledLua, (err) => {
  if (err) {
    console.error("Error writing Cheater_Detection.lua:", err);
  } else {
    console.log(`Library bundle created at ${targetPath}`);
  }
});

// Copy all .lua files in Prototypes folder (they use global libs, no bundling needed)
const prototypesDir = "./Prototypes";
if (fs.existsSync(prototypesDir)) {
  const prototypeFiles = fs
    .readdirSync(prototypesDir)
    .filter((file) => file.endsWith(".lua"));

  prototypeFiles.forEach((file) => {
    const sourcePath = path.join(prototypesDir, file);
    const prototypeTargetPath = path.join(targetDir, file);

    // Copy directly - prototypes use global libraries (lnxLib, TimMenu, etc.)
    fs.copyFile(sourcePath, prototypeTargetPath, (err) => {
      if (err) {
        console.error(`Error copying ${file}:`, err);
      } else {
        console.log(`Prototype deployed: ${prototypeTargetPath}`);
      }
    });
  });
} else {
  console.warn("Prototypes directory not found!");
}
