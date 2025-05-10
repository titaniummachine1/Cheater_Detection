"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
class ModuleBundlingError extends Error {
    constructor(moduleName, cause) {
        super(`Failed to bundle resolved module ${moduleName}`);
        this.moduleName = moduleName;
        this.cause = cause;
    }
}
exports.default = ModuleBundlingError;
//# sourceMappingURL=ModuleBundlingError.js.map