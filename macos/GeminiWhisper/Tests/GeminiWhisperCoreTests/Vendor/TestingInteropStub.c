#include "TestingInteropStub.h"

/* Command Line Tools ship Testing.framework without lib_TestingInterop.dylib.
   Weak so a full Xcode Testing.framework can override this symbol. */
__attribute__((weak))
void *_swift_testing_getFallbackEventHandler(void) {
    return 0;
}
