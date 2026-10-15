@import Foundation;
#include "ioregistry.h"
#include "i2c.h"

static BOOL decodeReply(const UInt8 *bytes, UInt8 feature, UInt16 *current, UInt16 *maximum) {
    UInt8 checksum = 0x50;
    for (int i = 0; i < 11; i++) checksum ^= bytes[i];
    if (bytes[0] != 0x6e || bytes[1] != 0x88 || bytes[2] != 0x02 ||
        bytes[3] != 0 || bytes[4] != feature || checksum != 0) return NO;
    *maximum = (bytes[6] << 8) | bytes[7];
    *current = (bytes[8] << 8) | bytes[9];
    if (feature == STANDBY) return *current >= 1 && *current <= 4;
    // Power replies must never be mistaken for restorable brightness values.
    return *maximum >= 10 && *current <= *maximum;
}

static BOOL decodeBrightness(const UInt8 *bytes, UInt16 *current, UInt16 *maximum) {
    return decodeReply(bytes, LUMINANCE, current, maximum);
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
    UInt8 power[12] = {0x6e,0x88,2,0,0xd6,0,0,0,0,2,0,0};
    sum = 0x50; for (int i = 0; i < 10; i++) sum ^= power[i]; power[10] = sum;
    NSCAssert(decodeReply(power, STANDBY, &current, &maximum) && current == 2, @"non-continuous power reply");
    NSCAssert(!decodeBrightness(power, &current, &maximum), @"wrong VCP code");
    power[10] ^= 1;
    NSCAssert(!decodeReply(power, STANDBY, &current, &maximum), @"power checksum");
    puts("DDC reply validation: passed"); return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        if (argc < 3) return 64;
        BOOL power = strcmp(argv[1], "read-power") == 0 || strcmp(argv[1], "set-power") == 0;
        BOOL reading = strcmp(argv[1], "read") == 0 || strcmp(argv[1], "read-power") == 0;
        BOOL writing = strcmp(argv[1], "set") == 0 || strcmp(argv[1], "set-power") == 0;
        if (!reading && !writing) return 64;
        if ((reading && argc != 3) || (writing && argc != 4)) return 64;
        long value = 0;
        if (writing) {
            char *end = NULL; value = strtol(argv[3], &end, 10);
            if (!end || end == argv[3] || *end || value < 0 || value > UINT16_MAX) return 64;
            // Never expose write-only power-off (5). Waking must work even if
            // the monitor cannot answer Get-VCP while it is in standby.
            if (power && value != 1 && value != 2 && value != 4) return 64;
        }
        DisplayInfos displays[MAX_DISPLAYS];
        int count = getOnlineDisplayInfos(displays);
        char identifier[128];
        int length = strncmp(argv[2], "uuid=", 5) == 0
            ? snprintf(identifier, sizeof(identifier), "%s", argv[2])
            : snprintf(identifier, sizeof(identifier), "id=%s", argv[2]);
        if (length < 0 || (size_t)length >= sizeof(identifier)) return 64;
        DisplayInfos *display = selectDisplay(displays, count, identifier);
        if (!display) return 65;
        DDCTransport transport = getDisplayDDCTransport(display);
        if (!transport.service) return 66;
        UInt8 feature = power ? STANDBY : LUMINANCE;
        DDCPacket request = createDDCPacket(feature);
        if (writing && power) {
            prepareDDCWrite(&request, (UInt16)value);
            IOReturn result = performDDCWriteAtChipAddress(transport.service, transport.chipAddress, &request);
            CFRelease(transport.service);
            return result ? 68 : 0;
        }
        UInt16 current = 0, maximum = 0;
        BOOL valid = NO;
        for (int attempt = 0; attempt < 3 && !valid; attempt++) {
            prepareDDCRead(request.data);
            if (performDDCWriteAtChipAddress(transport.service, transport.chipAddress, &request)) continue;
            DDCPacket reply = createDDCPacket(feature);
            if (performDDCReadAtChipAddress(transport.service, transport.chipAddress, &reply)) continue;
            valid = decodeReply(reply.data, feature, &current, &maximum);
        }
        if (!valid) { CFRelease(transport.service); return 67; }
        if (reading) printf("{\"current\":%u,\"maximum\":%u}\n", current, maximum);
        else {
            if (value > maximum) { CFRelease(transport.service); return 64; }
            prepareDDCWrite(&request, (UInt16)value);
            IOReturn result = performDDCWriteAtChipAddress(transport.service, transport.chipAddress, &request);
            CFRelease(transport.service);
            return result ? 68 : 0;
        }
        CFRelease(transport.service);
        return 0;
    }
}
