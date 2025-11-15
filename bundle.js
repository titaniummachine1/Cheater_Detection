import { bundle } from 'luabundle'
import * as fs from 'fs';
import * as path from 'path';

const bundledLua = bundle('./Cheater_Detection/Main.lua', {
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

fs.writeFile(targetPath, bundledLua, err => {
    if (err) {
        console.error(err);
    } else {
		console.log(`Library bundle created at ${targetPath}`);
	}
});