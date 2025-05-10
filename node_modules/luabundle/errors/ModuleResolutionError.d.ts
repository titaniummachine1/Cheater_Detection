export default class ModuleResolutionError extends Error {
    moduleName: string;
    parentModuleName: string;
    line: number;
    column: number;
    constructor(moduleName: string, parentModuleName: string, line: number, column: number);
}
//# sourceMappingURL=ModuleResolutionError.d.ts.map