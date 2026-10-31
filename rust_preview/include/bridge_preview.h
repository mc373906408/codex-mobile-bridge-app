#ifndef BRIDGE_PREVIEW_H
#define BRIDGE_PREVIEW_H
#include <stddef.h>
#include <stdint.h>

uint8_t *bridge_preview_decrypt(const uint8_t *credentials, size_t credentials_len,
    const uint8_t *envelope, size_t envelope_len, int64_t now, size_t *output_len);
void bridge_preview_free(uint8_t *buffer, size_t length);
#endif
