

import { instantiate } from './echo_kotlin.uninstantiated.mjs';


const exports = (await instantiate({

})).exports;

export const {
runEchoClient,
registerEchoFacadeServer,
registerEchoStreamFacadeServer,
memory,
_initialize
} = exports


