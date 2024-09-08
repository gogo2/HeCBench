/*
 * Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <chrono>
#include <cstdio>
#include <cmath>
#include <stdexcept>
#include <vector>
#include <hip/hip_runtime.h>
#include <hiprand/hiprand.h>

// HIP API error checking
#define HIP_CHECK(err)                                                        \
  do {                                                                        \
    hipError_t err_ = (err);                                                  \
    if (err_ != hipSuccess) {                                                 \
      std::printf("HIP error %d at %s:%d\n", err_, __FILE__, __LINE__);       \
      throw std::runtime_error("HIP error");                                  \
    }                                                                         \
  } while (0)

// hiprand API error checking
#define HIPRAND_CHECK(err)                                                    \
  do {                                                                        \
    hiprandStatus_t err_ = (err);                                             \
    if (err_ != HIPRAND_STATUS_SUCCESS) {                                     \
      std::printf("hiprand error %d at %s:%d\n", err_, __FILE__, __LINE__);   \
      throw std::runtime_error("hiprand error");                              \
    }                                                                         \
  } while (0)

void print_vector(const std::vector<float> &data, size_t n) {
  for (size_t i = data.size()-n; i < data.size(); i++)
    std::printf("%0.6f\n", data[i]);
}

void print_vector(const std::vector<unsigned int> &data, size_t n) {
  for (size_t i = data.size()-n; i < data.size(); i++)
    std::printf("%d\n", data[i]);
}

using data_type = float;

void run_on_device(const int &n, const unsigned long long &offset,
                   const unsigned long long &seed,
                   const hiprandOrdering_t &order, const hiprandRngType_t &rng,
                   hiprandGenerator_t &gen,
                   std::vector<data_type> &h_data) {

  data_type *d_data = nullptr;

  /* C data to device */
  HIP_CHECK(hipMalloc(reinterpret_cast<void **>(&d_data),
                        sizeof(data_type) * h_data.size()));

  /* Create pseudo-random number generator */
  HIPRAND_CHECK(hiprandCreateGenerator(&gen, HIPRAND_RNG_PSEUDO_MRG32K3A));

  /* Set offset */
  HIPRAND_CHECK(hiprandSetGeneratorOffset(gen, offset));

  /* Set ordering */
  HIPRAND_CHECK(hiprandSetGeneratorOrdering(gen, order));

  /* Set seed */
  HIPRAND_CHECK(hiprandSetPseudoRandomGeneratorSeed(gen, seed));

  /* Generate n floats on device */
  HIPRAND_CHECK(hiprandGenerateUniform(gen, d_data, h_data.size()));

  /* Copy data to host */
  HIP_CHECK(hipMemcpy(h_data.data(), d_data,
                        sizeof(data_type) * h_data.size(),
                        hipMemcpyDeviceToHost));

  /* Cleanup */
  HIP_CHECK(hipFree(d_data));
}

void run_on_host(const int &n, const unsigned long long &offset,
                 const unsigned long long &seed, const hiprandOrdering_t &order,
                 const hiprandRngType_t &rng,
                 hiprandGenerator_t &gen, std::vector<data_type> &h_data) {

  /* Create pseudo-random number generator */
  HIPRAND_CHECK(hiprandCreateGeneratorHost(&gen, HIPRAND_RNG_PSEUDO_MRG32K3A));

  /* Set offset */
  HIPRAND_CHECK(hiprandSetGeneratorOffset(gen, offset));

  /* Set ordering */
  HIPRAND_CHECK(hiprandSetGeneratorOrdering(gen, order));

  /* Set seed */
  HIPRAND_CHECK(hiprandSetPseudoRandomGeneratorSeed(gen, seed));

  /* Generate n floats on host */
  HIPRAND_CHECK(hiprandGenerateUniform(gen, h_data.data(), h_data.size()));
}

int main(int argc, char *argv[]) {
  if (argc != 3) {
    printf("Usage: %s <number of pseudorandom numbers to generate> <repeat>\n", argv[0]);
    return 1;
  }
  const int n = atoi(argv[1]);
  const int repeat = atoi(argv[2]);

  hiprandGenerator_t gen = NULL;
  hiprandRngType_t rng = HIPRAND_RNG_PSEUDO_MRG32K3A;
  hiprandOrdering_t order = HIPRAND_ORDERING_PSEUDO_BEST;

  const unsigned long long offset = 0ULL;
  const unsigned long long seed = 1234ULL;

  /* Allocate n floats on host */
  std::vector<data_type> h_data(n, 0);
  std::vector<data_type> d_data(n, -1);

  // warmup
  run_on_host(n, offset, seed, order, rng, gen, h_data);
  run_on_device(n, offset, seed, order, rng, gen, d_data);

  auto start = std::chrono::steady_clock::now();
  for (int i = 0; i < repeat; i++)
    run_on_host(n, offset, seed, order, rng, gen, h_data);
  auto end = std::chrono::steady_clock::now();
  auto time = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  printf("Average execution time on host: %f (us)\n", (time * 1e-3f) / repeat);

#ifdef DEBUG
  printf("Host\n");
  print_vector(h_data, 10);
  printf("=====\n");
#endif

  start = std::chrono::steady_clock::now();
  for (int i = 0; i < repeat; i++)
    run_on_device(n, offset, seed, order, rng, gen, d_data);
  end = std::chrono::steady_clock::now();
  time = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  printf("Average execution time on device: %f (us)\n", (time * 1e-3f) / repeat);

#ifdef DEBUG
  printf("Device\n");
  print_vector(d_data, 10);
  printf("=====\n");
#endif

  /* Cleanup */
  HIPRAND_CHECK(hiprandDestroyGenerator(gen));

  bool ok = true;
  for (int i = 0; i < n; i++) {
    if (std::abs(h_data[i] - d_data[i]) > 1e-3f) {
      ok = false;
      break;
    }
  }
  printf("%s\n", ok ? "PASS" : "FAIL");

  return EXIT_SUCCESS;
}
