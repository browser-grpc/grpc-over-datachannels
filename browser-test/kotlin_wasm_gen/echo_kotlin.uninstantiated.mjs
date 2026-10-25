
export async function instantiate(imports={}, runInitializer=true) {
    const cachedJsObjects = new WeakMap();
    // ref must be non-null
    function getCachedJsObject(ref, ifNotCached) {
        if (typeof ref !== 'object' && typeof ref !== 'function') return ifNotCached;
        const cached = cachedJsObjects.get(ref);
        if (cached !== void 0) return cached;
        cachedJsObjects.set(ref, ifNotCached);
        return ifNotCached;
    }


    
    const js_code = {
        'kotlin.captureStackTrace' : () => new Error().stack,
        'kotlin.wasm.internal.throwJsError' : (message, wasmTypeName, stack) => { 
            const error = new Error();
            error.message = message;
            error.name = wasmTypeName;
            error.stack = stack;
            throw error;
             },
        'kotlin.wasm.internal.stringLength' : (x) => x.length,
        'kotlin.wasm.internal.jsExportStringToWasm' : (src, srcOffset, srcLength, dstAddr) => { 
            const mem16 = new Uint16Array(wasmExports.memory.buffer, dstAddr, srcLength);
            let arrayIndex = 0;
            let srcIndex = srcOffset;
            while (arrayIndex < srcLength) {
                mem16.set([src.charCodeAt(srcIndex)], arrayIndex);
                srcIndex++;
                arrayIndex++;
            }     
             },
        'kotlin.wasm.internal.importStringFromWasm' : (address, length, prefix) => { 
            const mem16 = new Uint16Array(wasmExports.memory.buffer, address, length);
            const str = String.fromCharCode.apply(null, mem16);
            return (prefix == null) ? str : prefix + str;
             },
        'kotlin.wasm.internal.getJsEmptyString' : () => '',
        'kotlin.wasm.internal.externrefToString' : (ref) => String(ref),
        'kotlin.wasm.internal.externrefEquals' : (lhs, rhs) => lhs === rhs,
        'kotlin.wasm.internal.externrefHashCode' : 
        (() => {
        const dataView = new DataView(new ArrayBuffer(8));
        function numberHashCode(obj) {
            if ((obj | 0) === obj) {
                return obj | 0;
            } else {
                dataView.setFloat64(0, obj, true);
                return (dataView.getInt32(0, true) * 31 | 0) + dataView.getInt32(4, true) | 0;
            }
        }
        
        const hashCodes = new WeakMap();
        function getObjectHashCode(obj) {
            const res = hashCodes.get(obj);
            if (res === undefined) {
                const POW_2_32 = 4294967296;
                const hash = (Math.random() * POW_2_32) | 0;
                hashCodes.set(obj, hash);
                return hash;
            }
            return res;
        }
        
        function getStringHashCode(str) {
            var hash = 0;
            for (var i = 0; i < str.length; i++) {
                var code  = str.charCodeAt(i);
                hash  = (hash * 31 + code) | 0;
            }
            return hash;
        }
        
        return (obj) => {
            if (obj == null) {
                return 0;
            }
            switch (typeof obj) {
                case "object":
                case "function":
                    return getObjectHashCode(obj);
                case "number":
                    return numberHashCode(obj);
                case "boolean":
                    return obj ? 1231 : 1237;
                default:
                    return getStringHashCode(String(obj)); 
            }
        }
        })(),
        'kotlin.wasm.internal.isNullish' : (ref) => ref == null,
        'kotlin.wasm.internal.externrefToInt' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToBoolean' : (ref) => Boolean(ref),
        'kotlin.wasm.internal.externrefToLong' : (ref) => BigInt(ref),
        'kotlin.wasm.internal.externrefToFloat' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToDouble' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToUByte' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToUShort' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToUInt' : (ref) => Number(ref),
        'kotlin.wasm.internal.externrefToULong' : (ref) => BigInt(ref),
        'kotlin.wasm.internal.intToExternref' : (x) => x,
        'kotlin.wasm.internal.getJsTrue' : () => true,
        'kotlin.wasm.internal.getJsFalse' : () => false,
        'kotlin.wasm.internal.longToExternref' : (x) => x,
        'kotlin.wasm.internal.floatToExternref' : (x) => x,
        'kotlin.wasm.internal.doubleToExternref' : (x) => x,
        'kotlin.wasm.internal.kotlinUByteToJsNumberUnsafe' : (x) => x & 0xFF,
        'kotlin.wasm.internal.kotlinUShortToJsNumberUnsafe' : (x) => x & 0xFFFF,
        'kotlin.wasm.internal.kotlinUIntToJsNumberUnsafe' : (x) => x >>> 0,
        'kotlin.wasm.internal.kotlinULongToJsBigIntUnsafe' : (x) => x & 0xFFFFFFFFFFFFFFFFn,
        'kotlin.wasm.internal.newJsArray' : () => [],
        'kotlin.wasm.internal.jsArrayPush' : (array, element) => { array.push(element); },
        'kotlin.wasm.internal.getCachedJsObject_$external_fun' : (p0, p1) => getCachedJsObject(p0, p1),
        'kotlin.js.jsArraySet' : (array, index, value) => { array[index] = value },
        'kotlin.js.JsArray_$external_fun' : () => new Array(),
        'kotlin.js.length_$external_prop_getter' : (_this) => _this.length,
        'kotlin.js.JsArray_$external_class_instanceof' : (x) => x instanceof Array,
        'kotlin.js.JsArray_$external_class_get' : () => Array,
        'kotlin.js.JsBigInt_$external_fun' : () => new JsBigInt(),
        'kotlin.js.JsBigInt_$external_class_instanceof' : (x) => typeof x === 'bigint',
        'kotlin.js.JsBigInt_$external_class_get' : () => JsBigInt,
        'kotlin.js.JsBoolean_$external_fun' : () => new JsBoolean(),
        'kotlin.js.JsBoolean_$external_class_instanceof' : (x) => typeof x === 'boolean',
        'kotlin.js.JsBoolean_$external_class_get' : () => JsBoolean,
        'kotlin.js.stackPlaceHolder_js_code' : () => (''),
        'kotlin.js.JsError_$external_fun' : () => new Error(),
        'kotlin.js.message_$external_prop_getter' : (_this) => _this.message,
        'kotlin.js.stack_$external_prop_getter' : (_this) => _this.stack,
        'kotlin.js.JsError_$external_class_instanceof' : (x) => x instanceof Error,
        'kotlin.js.JsError_$external_class_get' : () => Error,
        'kotlin.js.JsNumber_$external_fun' : () => new JsNumber(),
        'kotlin.js.JsNumber_$external_class_instanceof' : (x) => typeof x === 'number',
        'kotlin.js.JsNumber_$external_class_get' : () => JsNumber,
        'kotlin.js.JsString_$external_fun' : () => new JsString(),
        'kotlin.js.JsString_$external_class_instanceof' : (x) => typeof x === 'string',
        'kotlin.js.JsString_$external_class_get' : () => JsString,
        'kotlin.js.Promise_$external_fun' : (p0) => new Promise(p0),
        'kotlin.js.__callJsClosure_((Js?)->Unit)' : (f, p0) => f(p0),
        'kotlin.js.__callJsClosure_((Js)->Unit)' : (f, p0) => f(p0),
        'kotlin.js.__convertKotlinClosureToJsClosure_((((Js?)->Unit),((Js)->Unit))->Unit)' : (f) => getCachedJsObject(f, (p0, p1) => wasmExports['__callFunction_((((Js?)->Unit),((Js)->Unit))->Unit)'](f, p0, p1)),
        'kotlin.js.then_$external_fun' : (_this, p0) => _this.then(p0),
        'kotlin.js.__convertKotlinClosureToJsClosure_((Js?)->Js?)' : (f) => getCachedJsObject(f, (p0) => wasmExports['__callFunction_((Js?)->Js?)'](f, p0)),
        'kotlin.js.then_$external_fun_1' : (_this, p0, p1) => _this.then(p0, p1),
        'kotlin.js.__convertKotlinClosureToJsClosure_((Js)->Js?)' : (f) => getCachedJsObject(f, (p0) => wasmExports['__callFunction_((Js)->Js?)'](f, p0)),
        'kotlin.js.catch_$external_fun' : (_this, p0) => _this.catch(p0),
        'kotlin.js.finally_$external_fun' : (_this, p0) => _this.finally(p0),
        'kotlin.js.__convertKotlinClosureToJsClosure_(()->Unit)' : (f) => getCachedJsObject(f, () => wasmExports['__callFunction_(()->Unit)'](f, )),
        'kotlin.js.Companion_$external_fun' : () => new Promise(),
        'kotlin.js.all_$external_fun' : (_this, p0) => _this.all(p0),
        'kotlin.js.race_$external_fun' : (_this, p0) => _this.race(p0),
        'kotlin.js.reject_$external_fun' : (_this, p0) => _this.reject(p0),
        'kotlin.js.resolve_$external_fun' : (_this, p0) => _this.resolve(p0),
        'kotlin.js.resolve_$external_fun_1' : (_this, p0) => _this.resolve(p0),
        'kotlin.js.Companion_$external_object_getInstance' : () => Promise,
        'kotlin.js.Companion_$external_class_instanceof' : (x) => x instanceof Promise,
        'kotlin.js.Companion_$external_class_get' : () => Promise,
        'kotlin.js.Promise_$external_class_instanceof' : (x) => x instanceof Promise,
        'kotlin.js.Promise_$external_class_get' : () => Promise,
        'kotlin.random.initialSeed' : () => ((Math.random() * Math.pow(2, 32)) | 0),
        'kotlin.wasm.internal.getJsClassName' : (jsKlass) => jsKlass.name,
        'kotlin.wasm.internal.instanceOf' : (ref, jsKlass) => ref instanceof jsKlass,
        'kotlin.wasm.internal.getConstructor' : (obj) => obj.constructor,
        'grpcdcwasm.jsUint8Get' : (array, index) => array[index],
        'grpcdcwasm.jsUint8Set' : (array, index, value) => { array[index] = value },
        'grpcdcwasm.jsArrayLength' : (array) => array.length,
        'grpcdcwasm.jsArrayString' : (array, index) => array[index],
        'grpcdcwasm.jsErrorObject' : (code, message) => ({ code: code, message: message }),
        'grpcdcwasm.jsArrayBytes' : (array, index) => array[index],
        'grpcdcwasm.JsUint8Array_$external_fun' : (p0) => new Uint8Array(p0),
        'grpcdcwasm.length_$external_prop_getter' : (_this) => _this.length,
        'grpcdcwasm.JsUint8Array_$external_class_instanceof' : (x) => x instanceof Uint8Array,
        'grpcdcwasm.JsUint8Array_$external_class_get' : () => Uint8Array,
        'grpcdcwasm.unary_$external_fun' : (_this, p0, p1) => _this.unary(p0, p1),
        'grpcdcwasm.unary_$external_fun_1' : (_this, p0, p1, p2) => _this.unary(p0, p1, p2),
        'grpcdcwasm.serverStream_$external_fun' : (_this, p0, p1, p2, p3) => _this.serverStream(p0, p1, p2, p3),
        'grpcdcwasm.__convertKotlinClosureToJsClosure_((Js)->Unit)' : (f) => getCachedJsObject(f, (p0) => wasmExports['__callFunction_((Js)->Unit)'](f, p0)),
        'grpcdcwasm.serverStream_$external_fun_1' : (_this, p0, p1, p2) => _this.serverStream(p0, p1, p2),
        'grpcdcwasm.clientStream_$external_fun' : (_this, p0, p1) => _this.clientStream(p0, p1),
        'grpcdcwasm.bidi_$external_fun' : (_this, p0, p1, p2) => _this.bidi(p0, p1, p2),
        'grpcdcwasm.code_$external_prop_getter' : (_this) => _this.code,
        'grpcdcwasm.message_$external_prop_getter' : (_this) => _this.message,
        'grpcdcwasm.next_$external_fun' : (_this, ) => _this.next(),
        'grpcdcwasm.registerUnary_$external_fun' : (_this, p0, p1) => _this.registerUnary(p0, p1),
        'grpcdcwasm.__convertKotlinClosureToJsClosure_((Js,Js)->Js)' : (f) => getCachedJsObject(f, (p0, p1) => wasmExports['__callFunction_((Js,Js)->Js)'](f, p0, p1)),
        'grpcdcwasm.registerServerStream_$external_fun' : (_this, p0, p1) => _this.registerServerStream(p0, p1),
        'grpcdcwasm.__convertKotlinClosureToJsClosure_((Js,Js,((Js)->Unit))->Js)' : (f) => getCachedJsObject(f, (p0, p1, p2) => wasmExports['__callFunction_((Js,Js,((Js)->Unit))->Js)'](f, p0, p1, p2)),
        'grpcdcwasm.registerClientStream_$external_fun' : (_this, p0, p1) => _this.registerClientStream(p0, p1),
        'grpcdcwasm.registerBidi_$external_fun' : (_this, p0, p1) => _this.registerBidi(p0, p1),
        'grpcdcwasm.registerClientStreamInc_$external_fun' : (_this, p0, p1) => _this.registerClientStreamInc(p0, p1),
        'grpcdcwasm.registerBidiInc_$external_fun' : (_this, p0, p1) => _this.registerBidiInc(p0, p1),
        'grpcdcwasm.start_$external_fun' : (_this, p0) => _this.start(p0),
        'echo.jsErrorCode' : (e) => e.code,
        'echo.jsOptions' : (json) => JSON.parse(json),
        'echo.nowMs' : () => performance.now(),
        'grpcdc.grpcdcNowMs' : () => performance.now()
    }
    
    // Placed here to give access to it from externals (js_code)
    let wasmInstance;
    let require; 
    let wasmExports;

    const isNodeJs = (typeof process !== 'undefined') && (process.release.name === 'node');
    const isDeno = !isNodeJs && (typeof Deno !== 'undefined')
    const isStandaloneJsVM =
        !isDeno && !isNodeJs && (
            typeof d8 !== 'undefined' // V8
            || typeof inIon !== 'undefined' // SpiderMonkey
            || typeof jscOptions !== 'undefined' // JavaScriptCore
        );
    const isBrowser = !isNodeJs && !isDeno && !isStandaloneJsVM && (typeof window !== 'undefined' || typeof self !== 'undefined');
    
    if (!isNodeJs && !isDeno && !isStandaloneJsVM && !isBrowser) {
      throw "Supported JS engine not detected";
    }
    
    const wasmFilePath = './echo_kotlin.wasm';
    const importObject = {
        js_code,
        intrinsics: {
            
        },

    };
    
    try {
      if (isNodeJs) {
        const module = await import(/* webpackIgnore: true */'node:module');
        const importMeta = import.meta;
        require = module.default.createRequire(importMeta.url);
        const fs = require('fs');
        const url = require('url');
        const filepath = import.meta.resolve(wasmFilePath);
        const wasmBuffer = fs.readFileSync(url.fileURLToPath(filepath));
        const wasmModule = new WebAssembly.Module(wasmBuffer);
        wasmInstance = new WebAssembly.Instance(wasmModule, importObject);
      }
      
      if (isDeno) {
        const path = await import(/* webpackIgnore: true */'https://deno.land/std/path/mod.ts');
        const binary = Deno.readFileSync(path.fromFileUrl(import.meta.resolve(wasmFilePath)));
        const module = await WebAssembly.compile(binary);
        wasmInstance = await WebAssembly.instantiate(module, importObject);
      }
      
      if (isStandaloneJsVM) {
        const wasmBuffer = read(wasmFilePath, 'binary');
        const wasmModule = new WebAssembly.Module(wasmBuffer);
        wasmInstance = new WebAssembly.Instance(wasmModule, importObject);
      }
      
      if (isBrowser) {
        wasmInstance = (await WebAssembly.instantiateStreaming(fetch(new URL('./echo_kotlin.wasm',import.meta.url).href), importObject)).instance;
      }
    } catch (e) {
      if (e instanceof WebAssembly.CompileError) {
        let text = `Please make sure that your runtime environment supports the latest version of Wasm GC and Exception-Handling proposals.
For more information, see https://kotl.in/wasm-help
`;
        if (isBrowser) {
          console.error(text);
        } else {
          const t = "\n" + text;
          if (typeof console !== "undefined" && console.log !== void 0) 
            console.log(t);
          else 
            print(t);
        }
      }
      throw e;
    }
    
    wasmExports = wasmInstance.exports;
    if (runInitializer) {
        wasmExports._initialize();
    }

    return { instance: wasmInstance,  exports: wasmExports };
}
