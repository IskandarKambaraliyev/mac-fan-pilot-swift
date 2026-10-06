#ifndef SMCBridge_h
#define SMCBridge_h

#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

enum {
    kSMCCmdReadKey      = 5,
    kSMCCmdWriteKey     = 6,
    kSMCCmdKeyByIndex   = 8,
    kSMCCmdKeyInfo      = 9,
};

kern_return_t SMCOpen(io_connect_t *conn);
void          SMCClose(io_connect_t conn);
kern_return_t SMCCall(io_connect_t conn, SMCParamStruct *input, SMCParamStruct *output);

#endif
