@import Foundation;
#include "ioregistry.h"
#include "i2c.h"

static BOOL decodeBrightness(const UInt8 *bytes, UInt16 *current, UInt16 *maximum) {
    UInt8 checksum = 0x50;
    for (int i = 0; i < 11; i++) checksum ^= bytes[i];
    if (bytes[0] != 0x6e || bytes[1] != 0x88 || bytes[2] != 0x02 ||
        bytes[3] != 0 || bytes[4] != LUMINANCE || checksum != 0) return NO;
    *maximum = (bytes[6] << 8) | bytes[7];
    *current = (bytes[8] << 8) | bytes[9];
    // Reject ambiguous power-mode-shaped ranges rather than treating them as
    // safely restorable brightness values.
    return *maximum >= 10 && *current <= *maximum;
}

static int selfTest(void) {
    DDCPacket request = createDDCPacket(LUMINANCE);
    prepareDDCRead(request.data);
    NSCAssert(request.data[3] == 0xac, @"Get-VCP source-address checksum");
    prepareDDCRead(request.data);
    NSCAssert(request.data[3] == 0xac, @"Retries must preserve the correct checksum");
    UInt8 good[12] = {0x6e, 0x88, 2, 0, 0x10, 0, 0, 100, 0, 40, 0, 0};
    UInt8 sum = 0x50; for (int i = 0; i < 10; i++) sum ^= good[i]; good[10] = sum;
    UInt16 current = 0, maximum = 0;
    NSCAssert(decodeBrightness(good, &current, &maximum) && current == 40 && maximum == 100, @"valid reply");
    good[10] ^= 1; NSCAssert(!decodeBrightness(good, &current, &maximum), @"bad checksum");
    UInt8 empty[12] = {0}; NSCAssert(!decodeBrightness(empty, &current, &maximum), @"empty reply");
    UInt8 zero[12] = {0x6e,0x88,2,0,0x10,0,0,0,0,0,0xa4,0};
    NSCAssert(!decodeBrightness(zero, &current, &maximum), @"zero maximum");
    UInt8 powerLike[12] = {0x6e,0x88,2,0,0x10,0,0,5,0,1,0xa0,0};
    NSCAssert(!decodeBrightness(powerLike, &current, &maximum), @"ambiguous power-shaped reply");
    puts("DDC reply validation: passed"); return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        if (argc < 3) return 64;
        BOOL reading = strcmp(argv[1], "read") == 0;
        BOOL writing = strcmp(argv[1], "set") == 0;
        if (!reading && !writing) return 64;
        if (writing && argc != 4) return 64;
        DisplayInfos displays[MAX_DISPLAYS];
        int count = getOnlineDisplayInfos(displays);
        char identifier[32]; snprintf(identifier, sizeof(identifier), "id=%s", argv[2]);
        DisplayInfos *display = selectDisplay(displays, count, identifier);
        if (!display) return 65;
        DDCTransport transport = getDisplayDDCTransport(display);
        if (!transport.service) return 66;
        DDCPacket request = createDDCPacket(LUMINANCE);
        UInt16 current = 0, maximum = 0;
        BOOL valid = NO;
        for (int attempt = 0; attempt < 3 && !valid; attempt++) {
            prepareDDCRead(request.data);
            if (performDDCWriteAtChipAddress(transport.service, transport.chipAddress, &request)) continue;
            DDCPacket reply = createDDCPacket(LUMINANCE);
            if (performDDCReadAtChipAddress(transport.service, transport.chipAddress, &reply)) continue;
            valid = decodeBrightness(reply.data, &current, &maximum);
        }
        if (!valid) { CFRelease(transport.service); return 67; }
        if (reading) printf("{\"current\":%u,\"maximum\":%u}\n", current, maximum);
        else {
            char *end = NULL; long value = strtol(argv[3], &end, 10);
            if (!end || *end || value < 0 || value > maximum) { CFRelease(transport.service); return 64; }
            prepareDDCWrite(&request, (UInt16)value);
            IOReturn result = performDDCWriteAtChipAddress(transport.service, transport.chipAddress, &request);
            CFRelease(transport.service);
            return result ? 68 : 0;
        }
        CFRelease(transport.service);
        return 0;
    }
}
