// Fuzz harness: the A/C message consumers (IRAcUtils::resultAcToString / decodeToState) fed a
// decode_results built directly from the input, so every protocol's setRaw()/toString()/toCommon()
// sees arbitrary state bytes without having to forge a valid checksum through the timing decoders.
//
// Input layout:
//   byte 0   protocol: decode_type_t value, taken modulo kLastDecodeType + 1
//   byte 1   bits: the result's bit length in whole bytes, taken modulo kStateSizeMax + 1
//            (decode_results::state holds kStateSizeMax bytes, so no decoder reports more)
//   rest     the state bytes (value/address/command alias them, as in a real result), zero padded
//
// Returns -1 for a result whose length no decoder could report, for the three protocols whose setRaw()
// memcpy()s `length` bytes (bits / 8) into a fixed array without clamping it (the length is the size of
// the array being copied, per the setRaw() docs); each decoder only accepts the lengths below:
//   SAMSUNG_AC  kSamsungAcBits, kSamsungAcExtendedBits            (decodeSamsungAC)
//   TOSHIBA_AC  kToshibaACBits, kToshibaACBitsShort/Long          (decodeToshibaAC, strict)
//   ARGO        at most kArgoBits (decodeArgo, decodeArgoWREM3: 16..96 bits; raw[] is 12 bytes)
// Otherwise returns 0: every combination is a valid argument to these functions.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "IRac.h"
#include "IRrecv.h"
#include "IRremoteESP8266.h"
#include "IRutils.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 2) return -1;

  decode_results results;
  memset(&results, 0, sizeof(results));
  results.decode_type =
      static_cast<decode_type_t>(data[0] % (kLastDecodeType + 1));
  results.bits = (data[1] % (kStateSizeMax + 1)) * 8;
  switch (results.decode_type) {
    case decode_type_t::SAMSUNG_AC:
      if (results.bits != kSamsungAcBits &&
          results.bits != kSamsungAcExtendedBits)
        return -1;
      break;
    case decode_type_t::TOSHIBA_AC:
      if (results.bits != kToshibaACBits &&
          results.bits != kToshibaACBitsShort &&
          results.bits != kToshibaACBitsLong)
        return -1;
      break;
    case decode_type_t::ARGO:
      if (results.bits > kArgoBits) return -1;
      break;
    default:
      break;
  }
  const size_t n = size - 2 < kStateSizeMax ? size - 2 : kStateSizeMax;
  memcpy(results.state, data + 2, n);

  IRAcUtils::resultAcToString(&results);
  stdAc::state_t state;
  if (IRAcUtils::decodeToState(&results, &state, NULL)) {
    IRAcUtils::decodeToState(&results, &state, &state);
  }
  return 0;
}
