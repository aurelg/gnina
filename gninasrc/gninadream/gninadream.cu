#include "../lib/gpu_math.h"
#define CUDA_NUM_THREADS 256
#define CUDA_NUM_BLOCKS 48
#define warpSize 32

// device functions for warp-based reduction using shufl operations
// TODO: should probably just be factored out into gpu_math or gpu_util
template<class T>
__device__   __forceinline__ T warp_sum(T mySum) {
  for (int offset = warpSize >> 1; offset > 0; offset >>= 1)
    mySum += shuffle_down(mySum, offset);
  return mySum;
}

__device__ __forceinline__
bool isNotDiv32(unsigned int val) {
  return val & 31;
}

/* requires blockDim.x <= 1024, blockDim.y == 1 */
template<class T>
__device__   __forceinline__ T block_sum(T mySum) {
  const unsigned int lane = threadIdx.x & 31;
  const unsigned int wid = threadIdx.x >> 5;

  __shared__ T scratch[32];

  mySum = warp_sum(mySum);
  if (lane == 0) scratch[wid] = mySum;
  __syncthreads();

  if (wid == 0) {
    mySum = (threadIdx.x < blockDim.x >> 5) ? scratch[lane] : 0;
    mySum = warp_sum(mySum);
    if (threadIdx.x == 0 && isNotDiv32(blockDim.x))
      mySum += scratch[blockDim.x >> 5];
  }
  return mySum;
}

__global__
void gpu_l2sq(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize) {
  unsigned tidx = blockDim.x * blockIdx.x + threadIdx.x;
  unsigned nthreads = blockDim.x * gridDim.x;
  // optimized grids
  float sum = 0.;
  for (size_t k=tidx; k<gsize; k+=nthreads) {
    float diff = optgrid[k] - screengrid[k];
    float sqdiff = diff * diff;
    sum += sqdiff;
  }
  float total = block_sum<float>(sum);
  if (threadIdx.x == 0)
    atomicAdd(scoregrid, total);
}

void do_gpu_l2sq(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize) {
  unsigned block_multiple = gsize / CUDA_NUM_THREADS;
  unsigned nblocks = block_multiple < CUDA_NUM_BLOCKS ? block_multiple : CUDA_NUM_BLOCKS;
  gpu_l2sq<<<nblocks, CUDA_NUM_THREADS>>>(optgrid, screengrid, scoregrid, gsize);
}

__global__
void gpu_mult(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize) {
  unsigned tidx = blockDim.x * blockIdx.x + threadIdx.x;
  unsigned nthreads = blockDim.x * gridDim.x;
  // optimized grids
  float sum = 0.;
  for (size_t k=tidx; k<gsize; k+=nthreads) {
    float weight = optgrid[k] * screengrid[k];
    sum += weight;
  }
  float total = block_sum<float>(sum);
  if (threadIdx.x == 0)
    atomicAdd(scoregrid, total);
}

void do_gpu_mult(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize) {
  unsigned block_multiple = gsize / CUDA_NUM_THREADS;
  unsigned nblocks = block_multiple < CUDA_NUM_BLOCKS ? block_multiple : CUDA_NUM_BLOCKS;
  gpu_mult<<<nblocks, CUDA_NUM_THREADS>>>(optgrid, screengrid, scoregrid, gsize);
}

__global__
void gpu_thresh(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize, float positive_threshold, float negative_threshold) {
  unsigned tidx = blockDim.x * blockIdx.x + threadIdx.x;
  unsigned nthreads = blockDim.x * gridDim.x;
  // optimized grids
  float sum = 0.;
  for (size_t k=tidx; k<gsize; k+=nthreads) {
    float threshold = optgrid[k] >=0 ? positive_threshold : negative_threshold;
    float sign = optgrid[k] >= 0 ? 1 : -1;
    float magnitude = fabs(optgrid[k]);
    float weight = ((magnitude > threshold) && screengrid[k]) ? 1 : 0;
    sum += sign * weight;
  }
  float total = block_sum<float>(sum);
  if (threadIdx.x == 0)
    atomicAdd(scoregrid, total);
}

void do_gpu_thresh(const float* optgrid, const float* screengrid, float* scoregrid,
    size_t gsize, float positive_threshold, float negative_threshold) {
  unsigned block_multiple = gsize / CUDA_NUM_THREADS;
  unsigned nblocks = block_multiple < CUDA_NUM_BLOCKS ? block_multiple : CUDA_NUM_BLOCKS;
  gpu_thresh<<<nblocks, CUDA_NUM_THREADS>>>(optgrid, screengrid, scoregrid,
      gsize, positive_threshold, negative_threshold);
}