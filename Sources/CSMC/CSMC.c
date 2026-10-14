#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <string.h>
// AppleSMC's user-client ABI: 80 bytes, native-endian metadata, 32-byte payload.
// Keep the transport private; Swift exposes only typed, bounded fan operations.
static uint32_t code(const char *s) { return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3]; }
static void put(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static uint32_t get(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return v; }
static int32_t call(uint32_t c, uint8_t *in, uint8_t *out) {
    size_t size = 80;
    kern_return_t result = IOConnectCallStructMethod(c, 2, in, 80, out, &size);
    if (result) return result;
    if (size != 80) return -1;
    return out[40] == 0 ? 0 : -(int32_t)out[40];
}
int32_t af_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
void af_smc_close(uint32_t connection) { IOServiceClose(connection); }
int32_t af_smc_read(uint32_t c, const char *key, uint32_t *type, uint32_t *length, uint8_t *bytes) {
    if (!key || strlen(key) != 4) return -1;
    uint8_t in[80] = {0}, out[80] = {0};
    put(in, code(key)); in[42] = 9;
    int32_t result = call(c,in,out); if (result) return result;
    *length = get(out+28); *type = get(out+32);
    if (*length == 0 || *length > 32) return -1;
    put(in+28,*length); in[42] = 5;
    result = call(c,in,out); if (result) return result;
    memcpy(bytes,out+48,*length); return 0;
}
int32_t af_smc_write(uint32_t c, const char *key, uint32_t length, const uint8_t *bytes) {
    if (!key || strlen(key) != 4 || length == 0 || length > 32) return -1;
    uint8_t in[80] = {0}, out[80] = {0};
    put(in,code(key)); put(in+28,length); in[42] = 6;
    memcpy(in+48,bytes,length); return call(c,in,out);
}
int32_t af_smc_key(uint32_t c, uint32_t index, char *key) {
    uint8_t in[80] = {0}, out[80] = {0}; in[42] = 8; put(in+44,index);
    int32_t result = call(c,in,out); if (result) return result;
    uint32_t value = get(out);
    key[0] = value>>24; key[1] = value>>16; key[2] = value>>8; key[3] = value; key[4] = 0;
    return 0;
}

#include <IOKit/IOMessage.h>
uint32_t af_power_will_sleep(void) { return kIOMessageSystemWillSleep; }
uint32_t af_power_can_sleep(void) { return kIOMessageCanSystemSleep; }
uint32_t af_power_did_wake(void) { return kIOMessageSystemHasPoweredOn; }
