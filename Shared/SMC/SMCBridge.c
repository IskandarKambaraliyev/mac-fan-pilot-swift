#include "SMCBridge.h"

kern_return_t SMCOpen(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr;
}

void SMCClose(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

kern_return_t SMCCall(io_connect_t conn, SMCParamStruct *input, SMCParamStruct *output) {
    size_t outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, 2 /* kSMCHandleYPCEvent */,
                                     input, sizeof(SMCParamStruct),
                                     output, &outSize);
}
