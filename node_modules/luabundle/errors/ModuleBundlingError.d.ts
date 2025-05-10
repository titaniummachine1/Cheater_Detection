export default class ModuleBundlingError extends Error {
    moduleName: string;
    cause: Error;
    constructor(moduleName: string, cause: Error);
}
//# sourceMappingURL=ModuleBundlingError.d.ts.map