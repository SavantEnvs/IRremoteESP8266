// Fuzz harness: IRrecv::decode() over a raw IR capture, plus the consumers of a decoded result.
//
// Input layout:
//   byte 0   bits 0-1: max_skip (0..3), bits 2-7: decode
//            tolerance percent (0..63)
//   byte 1   noise_floor in usecs
//   rest     the capture's rawbuf as little-endian uint16 ticks (kRawTick usecs each), element 0 is the
//            leading gap, exactly as an IRrecv capture lays it out (decoders start at kStartOffset).
//
// The capture is allocated at rawlen + 1 entries: rawbuf[rawlen] is zeroed, exactly as the real
// IRrecv::decode() does ("Clear the entry we are currently pointing to when we got the timeout"), so a
// decoder reading further than that is seen by ASan. A capture is never empty (an IRrecv only reports
// one after at least the leading gap was recorded), so zero entries are rejected.
// decode() runs with UNIT_TEST defined (the header-only build upstream's own tests use, no Arduino
// core), which leaves results.rawbuf/rawlen to the caller; that is what is set here.
//
// Returns -1 when the capture is shorter than the skip: decode()'s max_skip is the "Maximum Nr. of
// pulses at the begining of a capture we can skip", so the last offset it tries (2 * max_skip +
// kStartOffset) must lie inside the capture. decode() does not check it and the decoders then compute
// rawlen - offset on a uint16_t, which wraps to ~65535 "remaining" entries.
//
// Otherwise returns 0: "no protocol matched" is the common outcome of a mutated capture, and rejecting
// it would keep the partial matches (header matched, body wrong) out of the corpus.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "IRac.h"
#include "IRrecv.h"
#include "IRremoteESP8266.h"
#include "IRutils.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 4) return -1;
  const size_t count = (size - 2) / 2;
  // decode_results::rawlen is a uint16_t.
  if (count > UINT16_MAX) return -1;

  const uint8_t max_skip = data[0] & 0x3;
  if (max_skip > 0 && 2u * max_skip + kStartOffset > count) return -1;
  const uint8_t tolerance = data[0] >> 2;
  const uint16_t noise_floor = data[1];

  uint16_t *raw = new uint16_t[count + 1];
  memcpy(raw, data + 2, count * sizeof(uint16_t));
  raw[count] = 0;

  {
    IRrecv irrecv(kGpioUnused);
    irrecv.setTolerance(tolerance);
    decode_results results;
    memset(&results, 0, sizeof(results));
    results.rawbuf = raw;
    results.rawlen = static_cast<uint16_t>(count);
    results.overflow = false;

    if (irrecv.decode(&results, NULL, max_skip, noise_floor)) {
      resultToHumanReadableBasic(&results);
      resultToSourceCode(&results);
      resultToTimingInfo(&results);
      resultToHexidecimal(&results);
      uint16_t *copy = resultToRawArray(&results);
      delete[] copy;
      IRAcUtils::resultAcToString(&results);
      stdAc::state_t state;
      IRAcUtils::decodeToState(&results, &state, NULL);
      IRAcUtils::decodeToState(&results, &state, &state);
    }
  }
  delete[] raw;
  return 0;
}
