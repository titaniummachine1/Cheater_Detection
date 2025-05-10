export { Module, ModuleMap } from './bundle/module';
export { RealizedMetadata as Metadata } from './metadata';
export { bundle, bundleString } from './bundle';
export { Options as BundleOptions } from './bundle/options';
export { unbundle, unbundleString, UnbundledData } from './unbundle';
export { Options as UnbundleOptions } from './unbundle/options';
import { bundle, bundleString } from './bundle';
import { unbundle, unbundleString } from './unbundle';
declare const _default: {
    bundle: typeof bundle;
    bundleString: typeof bundleString;
    unbundle: typeof unbundle;
    unbundleString: typeof unbundleString;
};
export default _default;
//# sourceMappingURL=index.d.ts.map