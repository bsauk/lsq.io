#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <fstream>
#include <sstream>
#include <math.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "CycleTimer.h"

#define NB 4

static inline int updiv(int n, int d) {
  return (n+d-1)/d;
}

__device__ __inline__ int dmin(int a, int b) {
  if(a>b) {
    return b;
  } else {
    return a;
  }
}

// As of 4:41pm on 5/3 I have been debugging for the simplified case with smaller loops. This is just to make sure the basic idea works.
// I believe that up to nextr is correct currently!

__global__ void includGPU(int rows, int cols, double* dA, double* dY, double* dD, double* dR, double* dRHS, double* dSSERR, double* dWeights, int blocks) {
  __shared__ double dXblock[(NB)*NB];
  __shared__ int counter[1];
  
  const int idx = blockIdx.x*blockDim.x+threadIdx.x; // Maps to rows
  const int jdx = blockIdx.y*blockDim.y+threadIdx.y; // Maps to columns
  double vsmall = 2.225e-307;
  int nextr = 0;
  int offset = dmin(NB, cols-threadIdx.y-blockIdx.y*blockDim.y);
  int rowsLeft = dmin(NB, rows-threadIdx.x-blockIdx.x*blockDim.x);
  double w = 0.0, xk = 0.00, di = 0.00, cbar = 0.00, sbar = 0.00, xi = 0.00, tempR = 0.00;
  if(idx >= blockDim.x || jdx > cols) return;
  *counter = 0;
  
  for(int i=threadIdx.x; i<blockDim.x; i+=blockDim.x) { // i<rows
    nextr = *counter;
    //    if(jdx == 0) {
    //      dXblock[threadIdx.x*blockDim.x+threadIdx.y] = 1.0; // Obviously threadIdx.y = 0 but I included for consistency with later
    //      dXblock[threadIdx.x*blockDim.x+threadIdx.y+offset] = dA[i*cols+jdx+offset]; // this is the call to get the nb+1 element into dxblock
    //    } else {
    dXblock[threadIdx.x*blockDim.x+threadIdx.y] = dA[i*cols+jdx];
    
    
    w = dWeights[i];
    __syncthreads();
    
    for(int j=0; j<1; j++) { // j < cols
      di = dD[j];
      if(fabs(w) < vsmall) break;
      for(int k=0; k<threadIdx.x+1; k++) { // k < threadIdx.x+1
	__syncthreads();
	if(j < (blockIdx.y+1)*blockDim.y && j > blockIdx.y*blockDim.y || j==0 && jdx < NB) {
	  xi = dXblock[k*blockDim.x+j]; // Have 32 threads repeat work so they don't sit idle and will all return if need to
	} else {
	  xi = dA[k*cols+j]; // dA does not have a column of 1's so this doesn't work. Workaround, if j==0, xi = 1;
	}
	xk = dXblock[k*blockDim.x+threadIdx.y];
	tempR = dR[nextr+jdx-1];
	__syncthreads();
	if(fabs(xi) < vsmall) {
	  nextr = nextr+cols-j-1;
	} else {
	  w = dWeights[k];
	  cbar = di/(di+w*xi*xi);
	  sbar = w*xi/(di+w*xi*xi);
	  di = di*w*xi*xi;
	  if(jdx > j) {
	    if(idx == k) {
	      dXblock[k*blockDim.x+threadIdx.y] = xk-xi*tempR;
	    }
	    
	    tempR = cbar*tempR+sbar*xk;
	    printf("tempR=%f nextr+jdx-1=%d\n", tempR, nextr+jdx-1);
	    nextr = nextr+cols-j;
	  }
	}
	/*
      }
      dR[nextr-cols+j+jdx] = tempR;
      if(threadIdx.x == rowsLeft && threadIdx.y == 0) *counter = nextr;
      if(idx == 0) {
	xk = dY[i];
	dY[i] = xk-xi*dRHS[i];
	dRHS[i] = cbar*dRHS[i]+sbar*xk;
      }
      dWeights[i] = cbar*w;
      dD[i] = di;
    }
    
  }
  if(jdx==0 && idx==0) {
    for(int i=0; i<rows; i++) {
      dSSERR[0] = dSSERR[0]+dWeights[i]*dY[i]*dY[i];
      //      atomicAdd(dSSERR, dWeights[idx]*dY[idx]*dY[idx]);
      printf("dSSERR = %f\n", dSSERR[0]);
    }
    //      */
      }
    }
  }
} 
  
void gpu_lsq(double* A, double* weights, double* y, int rows, int cols, int nbest, int max_size, double** ress, int** lopt, double* bound) {
  /*
  int nvar = cols-1, nobs = 0, r_dim = cols*(cols-1)/2, max_cdim = max_size*(max_size+1)/2;
  double sserr[1], rss[cols], rhs[cols], work[cols], tol[cols], D[cols], r[r_dim];
  double sterr[max_size];
  int vorder[cols], row_ptr[cols], ifault[1], list[4], ier[1];

  bool lindep[cols], tol_set[1], rss_set[1];
  double vsmall = 2.225e-307, total_sumsq;
  double eps = 1e-14;
    
  sserr[0] = 0.0;
  tol_set[0] = false;
  rss_set[0] = false;

  for(int i=0; i<cols; i++) {
    vorder[i] = i;
  }
  row_ptr[0] = 0;
  for(int i=1; i<cols-1; i++) {
    row_ptr[i] = row_ptr[i-1]+cols-i; 
  }
  row_ptr[cols-1] = 0;
  */
  int r_dim = cols*(cols-1)/2;
  double* dA = NULL;
  double* dY = NULL;
  double* dD = NULL; // cols
  double* dR = NULL; //r_dim
  double* dRHS = NULL; //cols
  double* dSSERR = NULL; // cols
  double* dWeights = NULL; //rows
  cudaMalloc((void **)&dA, rows*(cols+1)*sizeof(double));
  cudaMalloc((void **)&dY, rows*sizeof(double));
  cudaMalloc((void **)&dD, cols*sizeof(double));
  cudaMalloc((void **)&dR, r_dim*sizeof(double));
  cudaMalloc((void **)&dRHS, cols*sizeof(double));
  cudaMalloc((void **)&dSSERR, sizeof(double));
  cudaMalloc((void **)&dWeights, rows*sizeof(double));

  cudaMemcpy(dA, A, rows*(cols+1)*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(dY, y, rows*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy(dWeights, weights, rows*sizeof(double), cudaMemcpyHostToDevice); // May want to consider just assuming 1 for now if this takes too long :/.
  
  cudaMemset(dD, 0.00, cols*sizeof(double));
  cudaMemset(dR, 0.00, r_dim*sizeof(double));
  cudaMemset(dRHS, 0.00, cols*sizeof(double));
  cudaMemset(dSSERR, 0.00, sizeof(double));

  dim3 threadsPerBlock(NB,NB);
  dim3 blocks(updiv(rows, NB), updiv(cols, NB));
  includGPU<<<blocks, threadsPerBlock>>>(rows, cols, dA, dY, dD, dR, dRHS, dSSERR, dWeights, blocks.x); 
  cudaDeviceSynchronize();
  /****************************************************************
  // This part gets translated into CUDA device code.
  for(int i=0; i<rows; i++) {
    xrow[0] = 1.0;
    for(int j=1; j<cols; j++) {
      xrow[j] = A[i*cols+j-1];
    }
    includ(weights[i], xrow, y[i], cols, D, r, rhs, sserr);
  }
  *****************************************************************/
  //  std::cout << "sserr = " << sserr[0] << std::endl;
  /*
  nobs = rows;
  sing(lindep, ifault, cols, D, tol_set, r, tol, row_ptr, rhs, sserr, work);
  if(ifault[0] == 0) {
    std::cout << "QR-factorization is not singular" << std::endl;
  } else {
    for(int i=0; i<nvar; i++) {
      if(lindep[i]) 
	std::cout << vorder[i] << " is exactly linearly related to earlier variables" << std::endl;
    }
  }
  ss(cols, sserr, rss, rss_set, D, rhs);
  
  // Set tolerances and test for singularities
  tolset(cols, work, r, tol, tol_set);
  sing(lindep, ier, cols, D, tol_set, r, tol, row_ptr, rhs, sserr, work);
  if(ier[0] != 0) {
    std::cout << ier[0] << " singularities detected in predictor variables" << std::endl;
    std::cout << "These variables are linearly related to earlier ones:" << std::endl;
    for(int i=0; i<cols; i++) {
      if(lindep[i]) {
	for(int j=0; j<nvar; j++) {
	  if(lindep[j]) {
	    std::cout << vorder[j] << std::endl;
	  }
	}
	break;
      }
    }
  }
  // Not sure if these three need to be called again here...
  tolset(cols, work, r, tol, tol_set);
  sing(lindep, ier, cols, D, tol_set, r, tol, row_ptr, rhs, sserr, work);
  ss(cols, sserr, rss, rss_set, D, rhs);
  
  for(int i=0; i<max_size; i++) {
    report(i, rss[i], max_size, bound, nbest, ress, vorder, lopt);
  }
  
  total_sumsq = rss[0];
  int first = 1;
  int last = cols;

  // The next part is that I will need to implement the different subset selection techniques, pick a few
  // Forward selection
  double startForwrd = CycleTimer::currentSeconds();
  forwrd(first, last, ifault, cols, max_size, D, rhs, r, nbest, rss, bound, ress, vorder, lopt, rss_set, sserr, row_ptr, tol);
  double endForwrd = CycleTimer::currentSeconds();
  std::cout << "Forwrd took " << 1000.f*(endForwrd-startForwrd) << std::endl;
  /*
  for(int i=first; i<max_size; i++) {
    std::cout << "Best subsets found of " << i << " variables" << std::endl;
    std::cout << "     R.S.S.          Variable numbers" << std::endl;
    int pos = (i*i+i)/2;
    for(int j=0; j<nbest; j++) {
      std::cout << ress[i][j] << "    ";
      for(int k=pos; k<pos+i+1; k++) {
	std::cout << lopt[j][k] << "   ";
      }
      std::cout << std::endl;
    }
  }
  */
}

