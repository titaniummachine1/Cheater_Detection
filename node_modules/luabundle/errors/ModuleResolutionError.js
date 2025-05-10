"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
class ModuleResolutionError extends Error {
    constructor(moduleName, parentModuleName, line, column) {
        super(`Could not resolve module '${moduleName}' required by '${parentModuleName}' at ${line}:${column}`);
        this.moduleName = moduleName;
        this.parentModuleName = parentModuleName;
        this.line = line;
        this.column = column;
    }
}
exports.default = ModuleResolutionError;
//# sourceMappingURL=ModuleResolutionError.js.map