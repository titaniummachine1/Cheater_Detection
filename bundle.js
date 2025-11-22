import { bundle } from 'luabundle'
import * as fs from 'fs';
import * as path from 'path';

// Bundle main Cheater_Detection
const bundledLua = bundle('./Cheater_Detection/Main.lua', {
	metadata: false,
	expressionHandler: (module, expression) => {
		const start = expression.loc.start
		console.warn(`WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`)
	}
});

// Bundle Prototypes folder
const bundledPrototypes = bundle('./Prototypes/AngleExtrapolation.lua', {
	metadata: false,
	expressionHandler: (module, expression) => {
		const start = expression.loc.start
		console.warn(`WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`)
	}
});

const targetDir = path.join(process.env.LOCALAPPDATA || '', 'lua');
if (!fs.existsSync(targetDir)) {
	fs.mkdirSync(targetDir, { recursive: true });
}

const targetPath = path.join(targetDir, 'Cheater_Detection.lua');
const prototypesPath = path.join(targetDir, 'AngleExtrapolation.lua');

// Write main bundle
fs.writeFile(targetPath, bundledLua, err => {
	if (err) {
		console.error('Error writing Cheater_Detection.lua:', err);
	} else {
		console.log(`Library bundle created at ${targetPath}`);
	}
});

// Write prototypes bundle
fs.writeFile(prototypesPath, bundledPrototypes, err => {
	if (err) {
		console.error('Error writing AngleExtrapolation.lua:', err);
	} else {
		console.log(`Prototypes bundle created at ${prototypesPath}`);
	}
});