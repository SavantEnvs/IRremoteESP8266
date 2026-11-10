// Seed generator (not part of the build): writes a valid capture per protocol for fuzz_irrecv_decode
// and an A/C state of the protocol's length for fuzz_ac_state, using the library's own senders, so a
// capture seed already carries the header/footer framing a mutated input would have to forge.
//
//   build (inside the image, after mayhem/build.sh):
//     clang++ -std=gnu++11 -DUNIT_TEST -D_IR_LOCALE_=en-AU -I src -I test mayhem/gen_seeds.cpp \
//       mayhem/build-tests/libir.a -o /tmp/gen_seeds
//   run:  /tmp/gen_seeds mayhem/fuzz_irrecv_decode/testsuite mayhem/fuzz_ac_state/testsuite
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <memory>
#include <string>

#include "IRac.h"
#include "IRrecv.h"
#include "IRsend.h"
#include "IRsend_test.h"
#include "IRutils.h"

static void write_file(const std::string &dir, const std::string &name,
                       const std::string &bytes) {
  FILE *f = fopen((dir + "/" + name).c_str(), "wb");
  if (!f) {
    perror(name.c_str());
    return;
  }
  fwrite(bytes.data(), 1, bytes.size(), f);
  fclose(f);
}

// [ctrl, noise_floor, rawbuf as LE16...] from the capture IRsendTest recorded.
static std::string capture_seed(IRsendTest *irsend) {
  irsend->makeDecodeResult();
  std::string s;
  s.push_back(static_cast<char>(kTolerance << 2));
  s.push_back(0);
  for (uint16_t i = 0; i < irsend->capture.rawlen; i++) {
    s.push_back(static_cast<char>(irsend->rawbuf[i] & 0xFF));
    s.push_back(static_cast<char>(irsend->rawbuf[i] >> 8));
  }
  return s;
}

static bool decodes(IRsendTest *irsend, IRrecv *recv) {
  irsend->makeDecodeResult();
  return recv->decode(&irsend->capture);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <decode-seed-dir> <ac-seed-dir>\n", argv[0]);
    return 2;
  }
  const std::string decode_dir = argv[1], ac_dir = argv[2];
  IRrecv recv(kGpioUnused);
  int n_decode = 0, n_ac = 0;
  const uint64_t datas[] = {0x1234567890ABCDEFULL, 0x00FF00FF00FF00FFULL, 0x1};

  for (int t = 1; t <= kLastDecodeType; t++) {
    const decode_type_t type = static_cast<decode_type_t>(t);
    const std::string base = typeToString(type, false);
    IRsendTest irsend(kGpioUnused);
    irsend.begin();

    if (hasACState(type)) {
      // setRaw() does not verify checksums, so any state of the protocol's length reaches the
      // toString()/toCommon() code; the sender adds the framing for the capture seed.
      const uint16_t nbytes = IRsend::defaultBits(type) / 8;
      if (nbytes == 0 || nbytes > kStateSizeMax) continue;
      for (int k = 0; k < 2; k++) {
        uint8_t state[kStateSizeMax];
        for (uint16_t i = 0; i < nbytes; i++) state[i] = k ? 0x5A + 7 * i : 0;
        std::string a;
        a.push_back(static_cast<char>(t));
        a.push_back(static_cast<char>(nbytes));
        a.append(reinterpret_cast<const char *>(state), nbytes);
        write_file(ac_dir, base + "_" + std::to_string(k), a);
        n_ac++;

        irsend.reset();
        if (irsend.send(type, state, nbytes) && decodes(&irsend, &recv)) {
          irsend.reset();
          irsend.send(type, state, nbytes);
          write_file(decode_dir, base + "_" + std::to_string(k), capture_seed(&irsend));
          n_decode++;
        }
      }
      continue;
    }

    const uint16_t nbits = IRsend::defaultBits(type);
    if (nbits == 0 || nbits > 64) continue;
    int k = 0;
    for (uint64_t d : datas) {
      const uint64_t v = nbits == 64 ? d : d & ((1ULL << nbits) - 1);
      irsend.reset();
      if (!irsend.send(type, v, nbits) || !decodes(&irsend, &recv)) continue;
      irsend.reset();
      irsend.send(type, v, nbits);
      write_file(decode_dir, base + "_" + std::to_string(k++), capture_seed(&irsend));
      n_decode++;
    }
  }
  printf("decode seeds: %d, ac seeds: %d\n", n_decode, n_ac);
  return 0;
}
