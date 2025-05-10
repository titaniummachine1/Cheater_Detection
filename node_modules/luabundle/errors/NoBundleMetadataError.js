"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
class NoBundleMetadataError extends Error {
    constructor() {
        super("No metadata found. Only bundles with metadata may be unbundled");
    }
}
exports.default = NoBundleMetadataError;
//# sourceMappingURL=NoBundleMetadataError.js.map