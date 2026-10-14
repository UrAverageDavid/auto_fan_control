#pragma once
#include <stdint.h>
int32_t af_smc_open(uint32_t *connection);
void af_smc_close(uint32_t connection);
int32_t af_smc_read(uint32_t connection, const char *key, uint32_t *type, uint32_t *length, uint8_t *bytes);
int32_t af_smc_write(uint32_t connection, const char *key, uint32_t length, const uint8_t *bytes);
int32_t af_smc_key(uint32_t connection, uint32_t index, char *key);

uint32_t af_power_will_sleep(void);
uint32_t af_power_can_sleep(void);
uint32_t af_power_did_wake(void);
