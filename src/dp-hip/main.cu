/*
 * Copyright 1993-2010 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

// *********************************************************************
// A simple demo application that implements a
// vector dot product computation between two arrays.
//
// Runs computations with on the GPU device and then checks results
// against basic host CPU/C++ computation.
// *********************************************************************

#include <stdio.h>
#include <stdlib.h>
#include <chrono>
#include <cmath>
#include <hip/hip_runtime.h>
#include <hipcub/hipcub.hpp>
#include <hipblas/hipblas.h>
#include "shrUtils.h"

typedef double Type;

// Forward Declarations
Type DotProductHost(const Type* pfData1, const Type* pfData2, size_t iNumElements);

__global__
void dot_product(const Type *__restrict__ a,
                 const Type *__restrict__ b,
                       Type *__restrict__ d,
                 const size_t n)
{
  size_t iGID = blockIdx.x * blockDim.x + threadIdx.x;
  Type sum = 0;
  for(size_t idx = iGID; idx < n; idx += gridDim.x * blockDim.x) {
    size_t iInOffset = idx * 4;
    sum += a[iInOffset    ] * b[iInOffset    ] +
           a[iInOffset + 1] * b[iInOffset + 1] +
           a[iInOffset + 2] * b[iInOffset + 2] +
           a[iInOffset + 3] * b[iInOffset + 3];
  }

  using BlockReduce = hipcub::BlockReduce<Type, 256>;
  __shared__ typename BlockReduce::TempStorage temp_storage;
  Type aggregate = BlockReduce(temp_storage).Sum(sum);
  if (threadIdx.x == 0) {
    atomicAdd(d, aggregate);
  }
}

int main(int argc, char **argv)
{
  if (argc != 3) {
    printf("Usage: %s <number of elements> <repeat>\n", argv[0]);
    return 1;
  }
  const size_t iNumElements = atol(argv[1]);
  const int iNumIterations = atoi(argv[2]);

  // set and log Global and Local work size dimensions
  int szLocalWorkSize = 256;
  // rounded up to the nearest multiple of the LocalWorkSize
  size_t szGlobalWorkSize = shrRoundUp(szLocalWorkSize, iNumElements);

  printf("Global Work Size \t\t= %zu\nLocal Work Size \t\t= %d\n",
         szGlobalWorkSize, szLocalWorkSize);

  const size_t src_size = szGlobalWorkSize;
  const size_t src_size_bytes = src_size * sizeof(Type);

  const size_t grid_size = shrRoundUp(szLocalWorkSize,
                                      szGlobalWorkSize / (szLocalWorkSize * 4));

  // Allocate and initialize host arrays
  Type* srcA = (Type*) malloc (src_size_bytes);
  Type* srcB = (Type*) malloc (src_size_bytes);
  Type  dst;

  size_t i;
  srand(123);
  for (i = 0; i < iNumElements ; ++i)
  {
    srcA[i] = 1;
    srcB[i] = -1;
  }
  for (i = iNumElements; i < src_size ; ++i) {
    srcA[i] = srcB[i] = 0;
  }

  // Compute and compare results for golden-host and report errors and pass/fail
  Type Golden = DotProductHost (srcA, srcB, iNumElements);

  Type *d_srcA;
  Type *d_srcB;
  Type *d_dst;

  hipMalloc((void**)&d_srcA, src_size_bytes);
  hipMemcpy(d_srcA, srcA, src_size_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_srcB, src_size_bytes);
  hipMemcpy(d_srcB, srcB, src_size_bytes, hipMemcpyHostToDevice);

  hipMalloc((void**)&d_dst, sizeof(Type));

  dim3 grid (grid_size);
  dim3 block (szLocalWorkSize);

  hipDeviceSynchronize();
  auto start = std::chrono::steady_clock::now();

  for (i = 0; i < (size_t)iNumIterations; i++) {
    hipMemset(d_dst, 0, sizeof(Type));
    dot_product<<<grid, block>>>(d_srcA, d_srcB, d_dst, src_size / 4);
  }

  hipDeviceSynchronize();
  auto end = std::chrono::steady_clock::now();
  auto time = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  printf("Average kernel execution time %f (s)\n", (time * 1e-9f) / iNumIterations);

  hipMemcpy(&dst, d_dst, sizeof(Type), hipMemcpyDeviceToHost);
  bool bMatch = std::abs(Golden - dst) < 1e-3f;
  printf("GPU Result %s CPU Result\n\n", bMatch ? "matches" : "DOESN'T match");

  hipblasHandle_t h;
  hipblasCreate(&h);
  hipblasSetPointerMode(h, HIPBLAS_POINTER_MODE_DEVICE);

  start = std::chrono::steady_clock::now();

  for (i = 0; i < (size_t)iNumIterations; i++) {
    hipblasDdot(h, iNumElements, d_srcA, 1, d_srcB, 1, d_dst);
  }

  hipDeviceSynchronize();
  end = std::chrono::steady_clock::now();
  time = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
  printf("Average hipblasDdot execution time %f (s)\n", (time * 1e-9f) / iNumIterations);

  hipMemcpy(&dst, d_dst, sizeof(Type), hipMemcpyDeviceToHost);
  bMatch = std::abs(Golden - dst) < 1e-3f;
  printf("GPU Result %s CPU Result\n", bMatch ? "matches" : "DOESN'T match");

  hipFree(d_dst);
  hipFree(d_srcA);
  hipFree(d_srcB);
  hipblasDestroy(h);

  free(srcA);
  free(srcB);
  return EXIT_SUCCESS;
}

// "Golden" Host processing dot product function for comparison purposes
// *********************************************************************
Type DotProductHost(const Type* pfData1, const Type* pfData2, size_t iNumElements)
{
  Type r = 0;
  for (size_t i = 0; i < iNumElements; i++)
  {
    r += pfData1[i] * pfData2[i];
  }
  return r;
}
