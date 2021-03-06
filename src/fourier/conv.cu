//------ convolutional gridding -------
/*
    Gridding on GPU
	Fucntions:
		1. val_kernel_vec
		2. conv_*d_nputsdriven
		3. partial_3d_conv_sorted
*/

#include <math.h>
#include <cuda.h>
#include <stdio.h>
#include <helper_cuda.h>
//#include <thrust/extrema.h>
#include "conv.h"
#include "common_utils.h"

// __device__ __constant__ double c0[NUM_SEGMENT];
// __device__ __constant__ double c1[NUM_SEGMENT+3];
// __device__ __constant__ double c2[NUM_SEGMENT];
// __device__ __constant__ double c3[NUM_SEGMENT];

void set_ker_eval_lut(PCS *h_c0, PCS *h_c1, PCS *h_c2, PCS *h_c3)
{
    // cudaMemcpyToSymbol(c0, h_c0, NUM_SEGMENT * sizeof(PCS));
    // cudaMemcpyToSymbol(c1, h_c1, NUM_SEGMENT * sizeof(PCS));
    // cudaMemcpyToSymbol(c2, h_c2, NUM_SEGMENT * sizeof(PCS));
    // cudaMemcpyToSymbol(c3, h_c3, NUM_SEGMENT * sizeof(PCS));
    return;
}

static __inline__ __device__ void kervalue_evaluate(PCS &ker, const PCS x, const double kw, const double es_c,
                                                    const double es_beta)
{
    ker = (abs(x) >= kw / 2.0) ? 0.0 : exp(es_beta * (sqrt(1.0 - es_c * x * x)));
}

static __inline__ __device__ void val_kernel_vec(PCS *ker, const PCS x, const double kw, const double es_c,
                                                 const double es_beta)
{
    //get vector of kernel function values
    for (int i = 0; i < kw; i++)
    {
        ker[i] = (abs(x + i) >= kw / 2.0) ? 0.0 : exp(es_beta * (sqrt(1.0 - es_c * (x + i) * (x + i))));
    }
}

static __inline__ __device__ void kervalue_evaluate(PCS &ker, const PCS x, const double kw, const double es_c,
                                                    const double es_beta, int flag)
{
    ker = (abs(x) >= kw / 2.0) ? 0.0 : exp(es_beta * (sqrt(1.0 - es_c * x * x) - flag));
}

static __inline__ __device__ void val_kernel_vec(PCS *ker, const PCS x, const double kw, const double es_c,
                                                 const double es_beta, int flag)
{
    //get vector of kernel function values
    for (int i = 0; i < kw; i++)
    {
        ker[i] = (abs(x + i) >= kw / 2.0) ? 0.0 : exp(es_beta * (sqrt(1.0 - es_c * (x + i) * (x + i)) - flag));
    }
}

__global__ void conv_1d_nputsdriven(PCS *x, CUCPX *c, CUCPX *fw, int M,
                                    const int ns, int nf1, PCS es_c, PCS es_beta, int pirange)
{
    /*
	Input driven convolution
		x - input location, range: [-pi,pi)
		c - complex number
		fw - result
		M - number of nupts
		ns - kernel width
		nf1 - upts after upsampling
		es_ - gridding kernel related factors
		pirange - in pi range or not
	*/

    int xstart, xend; // first grid point for this coordinate
    int ix;
    int outidx;
    PCS ker1[MAX_KERNEL_WIDTH]; // values of kernel function evaluation

    PCS temp1;
    int idx;

    for (idx = blockIdx.x * blockDim.x + threadIdx.x; idx < M; idx += gridDim.x * blockDim.x)
    {

        //value of x, shift and rescale to [0,N) and get the locations
        temp1 = SHIFT_RESCALE(x[idx], nf1, pirange);
        xstart = ceil(temp1 - ns / 2.0);
        xend = floor(temp1 + ns / 2.0);

        PCS x_1 = (PCS)xstart - temp1; // distance from first in range grid point to input coordinate

        val_kernel_vec(ker1, x_1, ns, es_c, es_beta);
        for (int xx = xstart; xx <= xend; xx++)
        {
            ix = xx < 0 ? xx + nf1 : (xx > nf1 - 1 ? xx - nf1 : xx);
            outidx = ix;
            PCS kervalue = ker1[xx - xstart];
            atomicAdd(&fw[outidx].x, c[idx].x * kervalue); //avoid concurrent write
            atomicAdd(&fw[outidx].y, c[idx].y * kervalue);
        }
    }
}

// 2D for w-stacking. 1D + 2D for improved WS will consume more memory
__global__ void conv_2d_nputsdriven(PCS *x, PCS *y, CUCPX *c, CUCPX *fw, int M,
                                    const int ns, int nf1, int nf2, PCS es_c, PCS es_beta, int pirange)
{
    /*
		x, y - range [-pi,pi)
		c - complex number
		fw - result
		M - number of nupts
		ns - kernel width
		nf1, nf2 - upts
		es_ - gridding kernel related factors
		pirange - 1
	*/
    //need to revise
    int xstart, ystart, xend, yend;
    int ix, iy;
    int outidx;
    PCS ker1[MAX_KERNEL_WIDTH];
    PCS ker2[MAX_KERNEL_WIDTH];

    PCS temp1, temp2;
    int idx;

    for (idx = blockIdx.x * blockDim.x + threadIdx.x; idx < M; idx += gridDim.x * blockDim.x)
    {

        //value of x, shift and rescale to [0,N) and get the locations
        temp1 = SHIFT_RESCALE(x[idx], nf1, pirange);
        temp2 = SHIFT_RESCALE(y[idx], nf2, pirange);

        xstart = ceil(temp1 - ns / 2.0);
        ystart = ceil(temp2 - ns / 2.0);
        xend = floor(temp1 + ns / 2.0);
        yend = floor(temp2 + ns / 2.0);

        PCS x_1 = (PCS)xstart - temp1; //cell
        PCS y_1 = (PCS)ystart - temp2;
        val_kernel_vec(ker1, x_1, ns, es_c, es_beta);
        val_kernel_vec(ker2, y_1, ns, es_c, es_beta);
        for (int yy = ystart; yy <= yend; yy++)
        {
            temp1 = ker2[yy - ystart];
            for (int xx = xstart; xx <= xend; xx++)
            {
                ix = xx < 0 ? xx + nf1 : (xx > nf1 - 1 ? xx - nf1 : xx);
                iy = yy < 0 ? yy + nf2 : (yy > nf2 - 1 ? yy - nf2 : yy);
                outidx = ix + iy * nf1;
                temp2 = ker1[xx - xstart];
                PCS kervalue = temp1 * temp2;
                atomicAdd(&fw[outidx].x, c[idx].x * kervalue);
                atomicAdd(&fw[outidx].y, c[idx].y * kervalue);
            }
        }
    }
}

__global__ void conv_3d_nputsdriven(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int M,
                                    const int ns, int nf1, int nf2, int nf3, PCS es_c, PCS es_beta, int pirange)
{
    /*
		x, y, z - range [-pi,pi)
		c - complex number
		fw - result
		M - number of nupts
		ns - kernel width
		nf1, nf2, nf3 - upts
		es_ - gridding kernel related factors
		pirange - 1
	*/

    int idx;
    idx = blockDim.x * blockIdx.x + threadIdx.x;
    int xx, yy, zz, ix, iy, iz;
    unsigned long long int outidx;

    PCS ker1[MAX_KERNEL_WIDTH];
    PCS ker2[MAX_KERNEL_WIDTH];
    PCS ker3[MAX_KERNEL_WIDTH];

    PCS temp1, temp2, temp3;

    // assert(pirange == 1); // check, the x y z should be in range [-pi,pi)

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {

        //value of x, shift and rescale to [0,N) and get the locations
        temp1 = SHIFT_RESCALE(x[idx], nf1, pirange);
        temp2 = SHIFT_RESCALE(y[idx], nf2, pirange);
        temp3 = SHIFT_RESCALE(z[idx], nf3, pirange);

        int xstart = ceil(temp1 - ns / 2.0);
        int ystart = ceil(temp2 - ns / 2.0);
        int zstart = ceil(temp3 - ns / 2.0);
        int xend = floor(temp1 + ns / 2.0);
        int yend = floor(temp2 + ns / 2.0);
        int zend = floor(temp3 + ns / 2.0);

        PCS x1 = (PCS)xstart - temp1;
        PCS y1 = (PCS)ystart - temp2;
        PCS z1 = (PCS)zstart - temp3;

        val_kernel_vec(ker1, x1, ns, es_c, es_beta);
        val_kernel_vec(ker2, y1, ns, es_c, es_beta);
        val_kernel_vec(ker3, z1, ns, es_c, es_beta);

        for (zz = zstart; zz <= zend; zz++)
        {
            temp3 = ker3[zz - zstart];
            for (yy = ystart; yy <= yend; yy++)
            {
                temp2 = ker2[yy - ystart];
                for (xx = xstart; xx <= xend; xx++)
                {
                    //due to the peroid, the index out of range need to be handle
                    ix = xx < 0 ? xx + nf1 : (xx > nf1 - 1 ? xx - nf1 : xx);
                    iy = yy < 0 ? yy + nf2 : (yy > nf2 - 1 ? yy - nf2 : yy);
                    iz = zz < 0 ? zz + nf3 : (zz > nf3 - 1 ? zz - nf3 : zz);
                    outidx = nf1 * nf2;
                    outidx *= iz;
                    outidx += ix + iy * nf1;
                    temp1 = ker1[xx - xstart];
                    PCS kervalue = temp1 * temp2 * temp3;
                    // fw[outidx].x += c[idx].x * kervalue;
                    // fw[outidx].y += c[idx].y * kervalue;
                    // if(outidx==616)printf("%lf,%lf,%lf,%lf\n",x[idx],x1+xx-xstart,y1+yy-ystart,z1+zz-zstart);
                    atomicAdd(&fw[outidx].x, c[idx].x * kervalue);
                    atomicAdd(&fw[outidx].y, c[idx].y * kervalue);
                    //printf("the out id %d kervalue %2.2g\n",outidx,kervalue);
                }
            }
        }
        //if((idx/blockDim.x+1)*blockDim.x<M){ __syncthreads(); }
    }
}

__global__ void conv_3d_outputdriven(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                     int nf3, PCS es_c, PCS es_beta, int pirange)
{

    unsigned long long int outidx;
    int cur_hive_idx, cur_hive_x, cur_hive_y, cur_hive_z;
    for (int idz = threadIdx.z + blockDim.z * blockIdx.z; idz < nf3; idz += blockDim.z * gridDim.z)
    {
        for (int idy = threadIdx.y + blockDim.y * blockIdx.y; idy < nf2; idy += blockDim.y * gridDim.y)
        {
            for (int idx = threadIdx.x + blockDim.x * blockIdx.x; idx < nf1; idx += blockDim.x * gridDim.x)
            {
                outidx = nf1 * nf2;
                outidx *= idz;
                outidx += idx + idy * nf1;

                for (cur_hive_z = (blockIdx.z - 1); cur_hive_z < 2 + (int)blockIdx.z; cur_hive_z++)
                {
                    for (cur_hive_y = blockIdx.y - 1; cur_hive_y < (int)blockIdx.y + 2; cur_hive_y++)
                    {
                        for (cur_hive_x = blockIdx.x - 1; cur_hive_x < (int)blockIdx.x + 2; cur_hive_x++)
                        {
                            // for(int i=0; i<27; i++){
                            // 	cur_hive_idx = (i / 9 - 1 + blockIdx.z) % gridDim.z * gridDim.y * gridDim.x + (i % 9 / 3 - 1 + blockDim.y) * gridDim.x  + i % 3 - 1 + blockIdx.x;

                            cur_hive_idx = cur_hive_x % gridDim.x + cur_hive_y % gridDim.y * gridDim.x + cur_hive_z % gridDim.z * gridDim.y * gridDim.x;
                            // if(idx==0&&idy==0&&idz==0)printf("++++++%d\n",cur_hive_idx);

                            for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                            {
                                // kernel evaluation
                                PCS ker;
                                PCS kervalue = 1.0;

                                PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                                temp1 = abs(temp1 - idx);
                                //++++ break if not in range
                                if (temp1 > nf1 / 2.0)
                                    temp1 = abs(nf1 - temp1);
                                if (temp1 >= ns / 2.0)
                                    continue;

                                PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                                temp2 = abs(temp2 - idy);
                                if (temp2 > nf2 / 2.0)
                                    temp2 = abs(nf2 - temp2);
                                if (temp2 >= ns / 2.0)
                                    continue;

                                PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);
                                temp3 = abs(temp3 - idz);
                                if (temp3 > nf3 / 2.0)
                                    temp3 = abs(nf3 - temp3);
                                if (temp3 >= ns / 2.0)
                                    continue;

                                ker = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));

                                // kervalue_evaluate(ker, temp, ns, es_c, es_beta);
                                kervalue = kervalue * ker;

                                ker = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));

                                // kervalue_evaluate(ker, temp2, ns, es_c, es_beta);
                                kervalue = kervalue * ker;
                                ker = exp(es_beta * (sqrt(1.0 - es_c * temp3 * temp3)));

                                // kervalue_evaluate(ker, temp3, ns, es_c, es_beta);
                                kervalue = kervalue * ker;

                                fw[outidx].x += c[k].x * kervalue;
                                fw[outidx].y += c[k].y * kervalue;
                            }
                        }
                    }
                }
                // }
            }
        }
    }
}

__global__ void conv_3d_outputdriven_t(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                       int nf3, int hivesize_x, int hivesize_y, int hivesize_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange)
{
    /*
		one thread handles t*t elements.
	*/
    unsigned long int idx;
    unsigned long int M = nhive_x; // revise
    M *= nhive_y;
    M *= nhive_z;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        int cur_hive_idx;

        hive_x = idx % nhive_x;
        hive_y = idx / nhive_x % nhive_y;
        hive_z = idx / (nhive_x * nhive_y);

        int bin_x, bin_y, bin_z;
        int cur_hive_x, cur_hive_y, cur_hive_z;

        bin_x = hivesize_x * hive_x;
        bin_y = hivesize_y * hive_y;
        bin_z = hivesize_z * hive_z;

        for (int cur_plane = floor(hive_x - ns / 2.0); cur_plane < ceil(hive_x + ns / 2.0); cur_plane++)
        {
            cur_hive_x = cur_plane;
            for (int j = 0; j < 9; j++)
            {
                cur_hive_x = cur_plane;
                cur_hive_y = hive_y + j % 3 - 1;
                cur_hive_z = hive_z + j / 3 - 1;
                if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                    cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                    cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                    cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;
                cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
                for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                {
                    PCS ker1, ker2, ker3;
                    PCS kervalue = 1.0;

                    PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                    PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                    PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);

                    cur_hive_x = hivesize_x * hivesize_y * hivesize_z;

                    for (int i = 0; i < cur_hive_x; i++)
                    {
                        outidx = nf1 * nf2;
                        outidx *= bin_z + i / hivesize_x / hivesize_y;
                        outidx += bin_x + i % hivesize_x + (bin_y + i / hivesize_x % hivesize_y) * nf1;

                        // distance
                        ker1 = abs(bin_x + i % hivesize_x - temp1);
                        // if(outidx==36&&k==10)printf("....%.3lf %d %.3lf \n",x[k],bin_x + i % hivesize_x,temp1);
                        if (ker1 > nf1 / 2.0)
                            ker1 = abs(nf1 - ker1);
                        if (ker1 >= ns / 2.0)
                            continue;
                        ker2 = abs(bin_y + i / hivesize_x % hivesize_y - temp2);
                        if (ker2 > nf2 / 2.0)
                            ker2 = abs(nf2 - ker2);
                        if (ker2 >= ns / 2.0)
                            continue;
                        ker3 = abs(bin_z + i / hivesize_x / hivesize_y - temp3);
                        if (ker3 > nf3 / 2.0)
                            ker3 = abs(nf3 - ker3);
                        if (ker3 >= ns / 2.0)
                            continue;
                        if (outidx >= (unsigned int)nf1 * nf2 * nf3)
                            continue;

                        ker1 = exp(es_beta * (sqrt(1.0 - es_c * ker1 * ker1)));

                        ker2 = exp(es_beta * (sqrt(1.0 - es_c * ker2 * ker2)));

                        ker3 = exp(es_beta * (sqrt(1.0 - es_c * ker3 * ker3)));
                        kervalue = ker1 * ker2 * ker3;

                        fw[outidx].x += c[k].x * kervalue;
                        fw[outidx].y += c[k].y * kervalue;
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_outputdriven_t2(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                        int nf3, int nz, int hivesize_x, int hivesize_y, int hivesize_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange)
{
    /*
		one thread handles t elements.
	*/
    unsigned long int idx;
    unsigned long int M = nhive_x * hivesize_x;
    M *= nhive_y * hivesize_y;
    M *= (nhive_z - 1) / nz + 1;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        int cur_hive_idx;

        cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        int bin_x, bin_y, bin_z;
        int cur_hive_x, cur_hive_y, cur_hive_z;
        bin_x = hive_x * hivesize_x + threadIdx.x % hivesize_x;
        bin_y = hive_y * hivesize_y + threadIdx.x / hivesize_x % hivesize_y;
        bin_z = hive_z * nz;
        // if(idx==66)printf("%d %d %d \n",bin_x, blockIdx.x, hivesize_x);

        for (int iz = 0; iz < nz; iz++)
        {
            outidx = nf1 * nf2;
            outidx *= bin_z + iz;
            outidx += bin_x + bin_y * nf1;
            // if(idx==264)printf("%lu %d %d %d\n",outidx, bin_x, bin_y, bin_z);
            for (int cur_plane = floor(bin_z + iz - ns / 2.0); cur_plane < ceil(bin_z + iz + ns / 2.0); cur_plane++)
            {
                // if(idx==264)printf("______\n");
                for (int j = 0; j < 9; j++)
                {
                    cur_hive_x = hive_x + j % 3 - 1;
                    cur_hive_y = hive_y + j / 3 - 1;
                    cur_hive_z = cur_plane; // put out of the loop

                    if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                        cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                    if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                        cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                    if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                        cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;
                    cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
                    // if(idx==0&&iz==0)printf("%d ________\n",hive_count[cur_hive_idx+1]-hive_count[cur_hive_idx]);
                    // if(outidx==200)printf("%d\n",cur_hive_idx);
                    for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                    {
                        // PCS ker1, ker2, ker3;
                        PCS kervalue = 1.0;

                        PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                        PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                        PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);

                        // distance
                        temp1 = abs(bin_x - temp1);
                        // if(outidx==36&&k==10)printf("....%.3lf %d %.3lf \n",x[k],bin_x + i % hivesize_x,temp1);
                        if (temp1 > nf1 / 2.0)
                            temp1 = abs(nf1 - temp1);
                        if (temp1 >= ns / 2.0)
                            continue;
                        temp2 = abs(bin_y - temp2);
                        if (temp2 > nf2 / 2.0)
                            temp2 = abs(nf2 - temp2);
                        if (temp2 >= ns / 2.0)
                            continue;
                        temp3 = abs(bin_z + iz - temp3);
                        if (temp3 > nf3 / 2.0)
                            temp3 = abs(nf3 - temp3);
                        if (temp3 >= ns / 2.0)
                            continue;
                        if (outidx >= (unsigned int)nf1 * nf2 * nf3)
                            continue;
                        // if(outidx==588)printf("%.5g %.5g %.5g %d\n",x[k],y[k],z[k],idx);

                        kervalue *= exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));

                        kervalue *= exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));

                        kervalue *= exp(es_beta * (sqrt(1.0 - es_c * temp3 * temp3)));

                        fw[outidx].x += c[k].x * kervalue;
                        fw[outidx].y += c[k].y * kervalue;
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_outputdriven_t1(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                        int nf3, int nz, int hivesize_x, int hivesize_y, int hivesize_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange)
{
    /*
		one thread handles nz elements.
	*/
    unsigned long int idx;
    unsigned long int M = nhive_x * hivesize_x; // revise
    M *= nhive_y * hivesize_y;
    M *= (nhive_z - 1) / nz + 1;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        int cur_hive_idx;

        cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        int bin_x, bin_y, bin_z;
        int cur_hive_x, cur_hive_y, cur_hive_z;
        bin_x = hive_x * hivesize_x + threadIdx.x % hivesize_x;
        bin_y = hive_y * hivesize_y + threadIdx.x / hivesize_x % hivesize_y;
        bin_z = hive_z * nz;

        for (int cur_plane = floor(bin_z - ns / 2.0); cur_plane < ceil(bin_z + nz + ns / 2.0); cur_plane++)
        {
            for (int j = 0; j < 9; j++)
            {
                cur_hive_x = hive_x + j % 3 - 1;
                cur_hive_y = hive_y + j / 3 - 1;
                cur_hive_z = cur_plane;

                if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                    cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                    cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                    cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;
                cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
                // if(idx==6&&cur_plane==2)printf("%d\n",hive_count[cur_hive_idx+1]-hive_count[cur_hive_idx]);
                for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                {
                    // PCS ker1, ker2, ker3;
                    PCS kervalue = 1.0;

                    PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                    PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                    PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);

                    // if(idx==6&&cur_plane==2) printf("%.5lf %.5lf %.5lf %d\n",x[k],y[k],z[k],idx);

                    // reuse the distance x,y distance same, z distance ++
                    // distance
                    temp1 = abs(bin_x - temp1);
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    if (temp1 >= ns / 2.0)
                        continue;
                    temp2 = abs(bin_y - temp2);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;
                    // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%.5lf %.5lf %.5lf\n",x[k],y[k],z[k]);

                    temp1 = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));

                    temp2 = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));

                    for (int i = 0; i < ns + 1; i++)
                    {
                        if (cur_plane - (int)floor(ns / 2.0) + i < bin_z)
                            continue;
                        if (cur_plane - (int)floor(ns / 2.0) + i >= bin_z + nz)
                            break;

                        outidx = nf1 * nf2;
                        outidx *= cur_plane - (int)floor(ns / 2.0) + i;
                        outidx += bin_x + bin_y * nf1;

                        // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%lu %d %d %d----\n",outidx,cur_plane, bin_y, cur_plane - (int)floor(ns/2.0) + i);

                        kervalue = abs(cur_plane - floor(ns / 2.0) + i - temp3);
                        if (kervalue > nf3 / 2.0)
                            kervalue = abs(nf3 - kervalue);
                        if (kervalue >= ns / 2.0)
                            continue;
                        if (outidx >= (unsigned int)nf1 * nf2 * nf3)
                            continue;

                        // if(outidx==9219) printf("%.5lf %.5lf %.5lf %d\n",x[k],y[k],z[k],idx);
                        // if(outidx==9219&&idx==3) printf("%d %d\n",bin_z,bin_z+nz);
                        kervalue = exp(es_beta * (sqrt(1.0 - es_c * kervalue * kervalue)));
                        // if(outidx==577) printf("%.5lf %.5lf %.5lf %d\n",kervalue,temp1,temp2,idx);
                        fw[outidx].x += c[k].x * kervalue * temp1 * temp2;
                        fw[outidx].y += c[k].y * kervalue * temp1 * temp2;
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_outputdriven_t1_taylor(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, PCS *c0, int *hive_count, const int ns, int nf1, int nf2,
                                               int nf3, int nz, int hivesize_x, int hivesize_y, int hivesize_z, int nhive_x, int nhive_y, int nhive_z, int pirange)
{
    /*
		one thread handles t elements.
	*/
    unsigned long int idx;
    unsigned long int M = nhive_x * hivesize_x;
    M *= nhive_y * hivesize_y;
    M *= (nhive_z - 1) / nz + 1;

    double ns_2 = 2 / (double)ns;
    double seg_s = ns_2 * SEG_SIZE;
    double num_s_1 = 1 / (double)SEG_SIZE;
    int seg_idx;
    double dis;
    __shared__ PCS sh_c0[SEG_ORDER_2 * SEG_SIZE];
    for (idx = threadIdx.x; idx < SEG_ORDER_2 * SEG_SIZE; idx += blockDim.x)
    {
        sh_c0[idx] = c0[idx];
    }
    __syncthreads();

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        int cur_hive_idx;

        cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        int bin_x, bin_y, bin_z;
        int cur_hive_x, cur_hive_y, cur_hive_z;
        bin_x = hive_x * hivesize_x + threadIdx.x % hivesize_x;
        bin_y = hive_y * hivesize_y + threadIdx.x / hivesize_x % hivesize_y;
        bin_z = hive_z * nz;

        for (int cur_plane = floor(bin_z - ns / 2.0); cur_plane < ceil(bin_z + nz + ns / 2.0); cur_plane++)
        {
            for (int j = 0; j < 9; j++)
            {
                cur_hive_x = hive_x + j % 3 - 1;
                cur_hive_y = hive_y + j / 3 - 1;
                cur_hive_z = cur_plane;

                if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                    cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                    cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                    cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;
                cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
                // if(idx==6&&cur_plane==2)printf("%d\n",hive_count[cur_hive_idx+1]-hive_count[cur_hive_idx]);
                for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                {
                    // PCS ker1, ker2, ker3;
                    PCS kervalue = 1.0;

                    PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                    PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                    PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);

                    // if(idx==6&&cur_plane==2) printf("%.5lf %.5lf %.5lf %d\n",x[k],y[k],z[k],idx);

                    // reuse the distance x,y distance same, z distance ++
                    // distance
                    temp1 = abs(bin_x - temp1);
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    if (temp1 >= ns / 2.0)
                        continue;
                    temp2 = abs(bin_y - temp2);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;
                    // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%.5lf %.5lf %.5lf\n",x[k],y[k],z[k]);

                    seg_idx = temp1 * seg_s;
                    dis = temp1 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER_2;
                    // seg_idx = (int) temp1*SEG_ORDER;

                    temp1 = sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * (sh_c0[seg_idx + 4] + dis * (sh_c0[seg_idx + 5] + dis * (sh_c0[seg_idx + 6] + dis * (sh_c0[seg_idx + 7] + dis * (sh_c0[seg_idx + 8]))))))));
                    // temp1 =sh_c0[seg_idx] + dis*(sh_c0[seg_idx+1] + dis*(sh_c0[seg_idx+2] + dis*(sh_c0[seg_idx+3]+dis*(sh_c0[seg_idx+4] +dis*(sh_c0[seg_idx+5]+dis*(sh_c0[seg_idx+6]+dis*(sh_c0[seg_idx+7]+dis*(sh_c0[seg_idx+8]+dis*sh_c0[seg_idx+9]))))))));
                    // temp1 =seg_idx + dis*(seg_idx + dis*(seg_idx + dis*(seg_idx+dis*seg_idx)));

                    // temp1 = abs(sh_y[i]-bin_y); // it will be faster just use one variable?
                    // if(temp1>nf2/2.0)temp1 = abs(nf2 - temp1);
                    // if(temp1>=ns/2.0)continue;

                    seg_idx = temp2 * seg_s;
                    dis = temp2 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER_2;
                    // seg_idx = (int) temp2*SEG_ORDER;
                    temp2 = sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * (sh_c0[seg_idx + 4] + dis * (sh_c0[seg_idx + 5] + dis * (sh_c0[seg_idx + 6] + dis * (sh_c0[seg_idx + 7] + dis * (sh_c0[seg_idx + 8]))))))));
                    // temp2 =sh_c0[seg_idx] + dis*(sh_c0[seg_idx+1] + dis*(sh_c0[seg_idx+2] + dis*(sh_c0[seg_idx+3]+dis*(sh_c0[seg_idx+4] +dis*(sh_c0[seg_idx+5]+dis*(sh_c0[seg_idx+6]+dis*(sh_c0[seg_idx+7]+dis*(sh_c0[seg_idx+8]+dis*sh_c0[seg_idx+9]))))))));
                    // temp2 =seg_idx + dis*(seg_idx + dis*(seg_idx + dis*(seg_idx+dis*seg_idx)));

                    // temp1 = exp(es_beta * (sqrt(1.0 - es_c * temp1  * temp1 )));

                    // temp2 = exp(es_beta * (sqrt(1.0 - es_c * temp2  * temp2 )));

                    for (int i = 0; i < ns + 1; i++)
                    {
                        if (cur_plane - (int)floor(ns / 2.0) + i < bin_z)
                            continue;
                        if (cur_plane - (int)floor(ns / 2.0) + i >= bin_z + nz)
                            break;

                        outidx = nf1 * nf2;
                        outidx *= cur_plane - (int)floor(ns / 2.0) + i;
                        outidx += bin_x + bin_y * nf1;

                        // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%lu %d %d %d----\n",outidx,cur_plane, bin_y, cur_plane - (int)floor(ns/2.0) + i);

                        kervalue = abs(cur_plane - floor(ns / 2.0) + i - temp3);
                        if (kervalue > nf3 / 2.0)
                            kervalue = abs(nf3 - kervalue);
                        if (kervalue >= ns / 2.0)
                            continue;
                        if (outidx >= (unsigned int)nf1 * nf2 * nf3)
                            continue;

                        // if(outidx==9219) printf("%.5lf %.5lf %.5lf %d\n",x[k],y[k],z[k],idx);
                        // if(outidx==9219&&idx==3) printf("%d %d\n",bin_z,bin_z+nz);
                        // kervalue = exp(es_beta * (sqrt(1.0 - es_c * kervalue  * kervalue )));
                        seg_idx = kervalue * seg_s;
                        dis = kervalue * ns_2 - num_s_1 * seg_idx;
                        seg_idx *= SEG_ORDER_2;
                        // seg_idx = (int) kervalue*SEG_ORDER;
                        // seg_idx = (int) kervalue;
                        kervalue = sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * (sh_c0[seg_idx + 4] + dis * (sh_c0[seg_idx + 5] + dis * (sh_c0[seg_idx + 6] + dis * (sh_c0[seg_idx + 7] + dis * (sh_c0[seg_idx + 8]))))))));

                        // kervalue =sh_c0[seg_idx] + dis*(sh_c0[seg_idx+1] + dis*(sh_c0[seg_idx+2] + dis*(sh_c0[seg_idx+3]+dis*(sh_c0[seg_idx+4] +dis*(sh_c0[seg_idx+5]+dis*(sh_c0[seg_idx+6]+dis*(sh_c0[seg_idx+7]+dis*(sh_c0[seg_idx+8]+dis*sh_c0[seg_idx+9]))))))));
                        // kervalue =seg_idx + dis*(seg_idx + dis*(seg_idx + dis*(seg_idx+dis*seg_idx)));

                        // if(outidx==577) printf("%.5lf %.5lf %.5lf %d\n",kervalue,temp1,temp3,idx);
                        fw[outidx].x += c[k].x * kervalue * temp1 * temp2;
                        fw[outidx].y += c[k].y * kervalue * temp1 * temp2;
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_outputdriven(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                     int nf3, int nbin_x, int nbin_y, int nbin_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange)
{
    /*
		blocksize = 8*8*8 if change may need to revise
		another method also load intput into shared memroy by multi times

		remove some variable or put to constant memory remove nbin
	*/

    unsigned long int idx;        // one hive by one hive
    unsigned long int M = nbin_x; // the threads are padded
    M *= nbin_y;
    M *= nbin_z;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        // int bin_idx;
        // load to shared memory __synchronize
        // extern __shared__ CUCPX sh_fw[];

        int cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        // bin_idx = threadIdx.x % (nbin_x / hive_x) + threadIdx.x / (nbin_x / hive_x) % (nbin_y / hive_y) + threadIdx.x;
        // idx in hive + hive_x * hivesize_x
        int bin_x = threadIdx.x % (nbin_x / nhive_x) + hive_x * (nbin_x / nhive_x);
        int bin_y = threadIdx.x / (nbin_x / nhive_x) % (nbin_y / nhive_y) + hive_y * (nbin_y / nhive_y);
        int bin_z = threadIdx.x / ((nbin_x / nhive_x) * (nbin_y / nhive_y)) + hive_z * (nbin_z / nhive_z);
        outidx = nf1 * nf2;
        outidx *= bin_z;
        outidx += bin_x + bin_y * nf1;

        int flag = 1;
        int cur_hive_x;
        int cur_hive_y;
        int cur_hive_z;
        // start_hive_idx[1] = cur_hive_idx - nhive_x - 1;
        // start_hive_idx[2] = start_hive_idx[1] + nhive_x*nhive_y;
        // start_hive_idx[0] = start_hive_idx[1] - nhive_x*nhive_y;

        if (bin_x < nf1 && bin_y < nf2 && bin_z < nf3)
        {
            for (int i = 0; i < 3; i++)
            {
                for (int j = 0; j < 9; j++)
                {
                    flag = 1;

                    cur_hive_x = hive_x + j % 3 - 1;
                    cur_hive_y = hive_y + j / 3 - 1;
                    cur_hive_z = hive_z + i - 1;

                    if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                        nhive_x < 3 ? flag = 0 : cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                    if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                        nhive_y < 3 ? flag = 0 : cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                    if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                        nhive_z < 3 ? flag = 0 : cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;
                    // if(outidx==616)printf("%d,%d,%d,%d\n",cur_hive_idx,cur_hive_x,cur_hive_y,cur_hive_z);
                    if (flag == 0)
                        continue; // exceeding the boundart and nf < 3
                    cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
                    // if(outidx==616)printf("%d,%d,%d,%d,%lu\n",cur_hive_idx,cur_hive_x,cur_hive_y,cur_hive_z,idx);

                    //if(cur_hive_idx>=nhive_x*nhive_y*nhive_z||cur_hive_idx<0)printf("%d,%d,%d,%d,%d ",cur_hive_idx, hive_x,hive_y, hive_z,flag);
                    for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                    {
                        // kernel evaluation
                        PCS ker;
                        PCS kervalue = 1.0;

                        PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                        temp1 = abs(temp1 - bin_x);
                        //++++ break if not in range
                        if (temp1 > nf1 / 2.0)
                            temp1 = abs(nf1 - temp1);
                        if (temp1 >= ns / 2.0)
                            continue;

                        PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                        temp2 = abs(temp2 - bin_y);
                        if (temp2 > nf2 / 2.0)
                            temp2 = abs(nf2 - temp2);
                        if (temp2 >= ns / 2.0)
                            continue;

                        PCS temp3 = SHIFT_RESCALE(z[k], nf3, pirange);
                        temp3 = abs(temp3 - bin_z);
                        if (temp3 > nf3 / 2.0)
                            temp3 = abs(nf3 - temp3);
                        if (temp3 >= ns / 2.0)
                            continue;
                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));
                        // if(outidx==575)printf("1st %.12lf, %lf\n",ker,temp1);
                        // if(outidx==4614)printf("%.5lf\n",ker);
                        // kervalue_evaluate(ker, temp, ns, es_c, es_beta);
                        kervalue = kervalue * ker;

                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));
                        // if(outidx==575)printf("2nd %.12lf\n",ker);
                        // if(outidx==577)printf("%.5lf\n",ker);

                        // kervalue_evaluate(ker, temp2, ns, es_c, es_beta);
                        kervalue = kervalue * ker;
                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp3 * temp3)));
                        // if(outidx==577)printf("%.5lf\n",ker);

                        // kervalue_evaluate(ker, temp3, ns, es_c, es_beta);
                        kervalue = kervalue * ker;
                        // if(outidx==616)printf("%lf,%lu,%d,%d,%d\n",x[k],idx,cur_hive_x,cur_hive_y,cur_hive_z);

                        // if(outidx==nf1*nf2-1)printf("%lf,%lf,%lf\n",x[k],temp,kervalue);
                        fw[outidx].x += c[k].x * kervalue;
                        fw[outidx].y += c[k].y * kervalue;
                        // if(outidx==nf1*nf2*nf3-10)printf("%lf\n",kervalue);
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_outputdriven_shared_sparse(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                                   int nf3, int nbin_x, int nbin_y, int nbin_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange)
{
    /*
		blocksize = 8*8*8 if change may need to revise
		another method also load intput into shared memroy by multi times

		remove some variable or put to constant memory remove nbin
	*/

    unsigned long long int idx;   // one hive by one hive
    unsigned long int M = nbin_x; // the threads are padded
    M *= nbin_y;
    M *= nbin_z;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        // int bin_idx;
        // load to shared memory __synchronize
        // extern __shared__ CUCPX sh_fw[];
        __shared__ PCS sh_x[SHARED_SIZE_3D_HIVE];
        __shared__ PCS sh_y[SHARED_SIZE_3D_HIVE];
        __shared__ PCS sh_z[SHARED_SIZE_3D_HIVE];
        __shared__ CUCPX sh_c[SHARED_SIZE_3D_HIVE];
        __shared__ int neighbor_info[27];

        int cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        // bin_idx = threadIdx.x % (nbin_x / hive_x) + threadIdx.x / (nbin_x / hive_x) % (nbin_y / hive_y) + threadIdx.x;
        // idx in hive + hive_x * hivesize_x
        int bin_x = threadIdx.x % (nbin_x / nhive_x) + hive_x * (nbin_x / nhive_x);
        int bin_y = threadIdx.x / (nbin_x / nhive_x) % (nbin_y / nhive_y) + hive_y * (nbin_y / nhive_y);
        int bin_z = threadIdx.x / ((nbin_x / nhive_x) * (nbin_y / nhive_y)) + hive_z * (nbin_z / nhive_z);
        outidx = nf1 * nf2;
        outidx *= bin_z;
        outidx += bin_x + bin_y * nf1;

        int flag = 0; // first bit is for x, y, z later consider this issue

        // start_hive_idx[1] = cur_hive_idx - nhive_x - 1;
        // start_hive_idx[2] = start_hive_idx[1] + nhive_x*nhive_y;
        // start_hive_idx[0] = start_hive_idx[1] - nhive_x*nhive_y;

        if (threadIdx.x < 27)
        { // have a litter improvement
            int cur_hive_x;
            int cur_hive_y;
            int cur_hive_z;

            cur_hive_z = hive_z + threadIdx.x / 9 - 1;
            cur_hive_y = hive_y + threadIdx.x % 9 / 3 - 1;
            cur_hive_x = hive_x + threadIdx.x % 3 - 1;

            // some issues here
            if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
            if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
            if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;

            neighbor_info[threadIdx.x] = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
        }
        __syncthreads();

        // loop from here
        int hive_index = 0;
        while (hive_index < 27)
        {
            if (flag >= 0)
                flag = 0;
            cur_hive_idx = 0; // reuse as start of shared memory
            // load data into shared memroy
            for (; hive_index < 27; hive_index++)
            {
                // if flag = -1, cur_nupt_num changed
                int cur_nupt_num;
                if (flag < 0)
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] + flag * SHARED_SIZE_3D_HIVE;
                else
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] - hive_count[neighbor_info[hive_index]];
                // if(threadIdx.x==0&&blockIdx.x==0)printf("number of point in hive %d: %d\n",hive_index,cur_nupt_num);
                if (cur_hive_idx + cur_nupt_num <= SHARED_SIZE_3D_HIVE)
                {
                    // load to shared mem
                    flag = hive_count[neighbor_info[hive_index]]; //reuse flag
                    for (int j = threadIdx.x; j < cur_nupt_num; j += blockDim.x)
                    {
                        // +++ shift here
                        // sh_x[cur_hive_idx+j] = SHIFT_RESCALE(x[flag+j], nf1, pirange);
                        // sh_y[cur_hive_idx+j] = SHIFT_RESCALE(y[flag+j], nf2, pirange);
                        // sh_z[cur_hive_idx+j] = SHIFT_RESCALE(z[flag+j], nf3, pirange);
                        sh_x[cur_hive_idx + j] = x[flag + j];
                        sh_y[cur_hive_idx + j] = y[flag + j];
                        sh_z[cur_hive_idx + j] = z[flag + j];
                        sh_c[cur_hive_idx + j] = c[flag + j]; // save those shifted stuff
                    }
                    cur_hive_idx += cur_nupt_num;
                }
                else
                {
                    // points in one hive can not load into shared mem
                    if (cur_hive_idx == 0)
                    {
                        // fully occupy the shared mem
                        // printf("1 \n");
                        int start_idx_full = hive_count[neighbor_info[hive_index]] - flag * SHARED_SIZE_3D_HIVE;
                        for (int j = threadIdx.x; j < SHARED_SIZE_3D_HIVE; j += blockDim.x)
                        {
                            // +++ shift here
                            // sh_x[j] = SHIFT_RESCALE(x[start_idx_full+j], nf1, pirange);
                            // sh_y[j] = SHIFT_RESCALE(y[start_idx_full+j], nf2, pirange);
                            // sh_z[j] = SHIFT_RESCALE(z[start_idx_full+j], nf3, pirange);
                            sh_x[j] = x[start_idx_full + j];
                            sh_y[j] = y[start_idx_full + j];
                            sh_z[j] = z[start_idx_full + j];
                            sh_c[j] = c[start_idx_full + j];
                        }
                        cur_hive_idx = SHARED_SIZE_3D_HIVE;
                        // hive_index--;
                        flag--;
                    }
                    // hive_index++;
                    break;
                }
            }
            __syncthreads();

            if (bin_x < nf1 && bin_y < nf2 && bin_z < nf3)
            {
                for (int i = 0; i < cur_hive_idx; i++)
                {

                    // kernel evaluation
                    PCS ker;
                    PCS kervalue = 1.0;

                    PCS temp1 = abs(sh_x[i] - bin_x);
                    //++++ break if not in range
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    if (temp1 >= ns / 2.0)
                        continue;

                    PCS temp2 = abs(sh_y[i] - bin_y);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;

                    PCS temp3 = abs(sh_z[i] - bin_z);
                    if (temp3 > nf3 / 2.0)
                        temp3 = abs(nf3 - temp3);
                    if (temp3 >= ns / 2.0)
                        continue;

                    // if(outidx==0)printf("%lf,%lf,%lf,%lf\n",temp,temp2,temp3,c[k].x);

                    ker = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));
                    // kervalue_evaluate(ker, temp, ns, es_c, es_beta);
                    kervalue = kervalue * ker;
                    ker = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));
                    // kervalue_evaluate(ker, temp2, ns, es_c, es_beta);
                    kervalue = kervalue * ker;
                    ker = exp(es_beta * (sqrt(1.0 - es_c * temp3 * temp3)));
                    // kervalue_evaluate(ker, temp3, ns, es_c, es_beta);
                    kervalue = kervalue * ker;

                    fw[outidx].x += sh_c[i].x * kervalue;
                    fw[outidx].y += sh_c[i].y * kervalue;
                }
            }
            __syncthreads();
        }
    }
}

__global__ void conv_3d_outputdriven_shared_hive_lut(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, PCS *c0, int *hive_count, const int ns, int nf1, int nf2,
                                                     int nf3, int nbin_x, int nbin_y, int nbin_z, int nhive_x, int nhive_y, int nhive_z, int pirange)
{
    /*
		blocksize = 8*8*8 if change may need to revise
		another method also load intput into shared memroy by multi times

		remove some variable or put to constant memory remove nbin
	*/

    unsigned long int idx;        // one hive by one hive
    unsigned long int M = nbin_x; // the threads are padded
    M *= nbin_y;
    M *= nbin_z;
    double ns_2 = 2 / (double)ns;
    double seg_s = ns_2 * SHARED_SIZE_SEG;
    double num_s_1 = 1 / (double)SHARED_SIZE_SEG;
    __shared__ PCS sh_c0[SHARED_SIZE_SEG * SEG_ORDER];
    for (idx = threadIdx.x; idx < SHARED_SIZE_SEG * SEG_ORDER; idx += blockDim.x)
    {
        sh_c0[idx] = c0[idx];
    }
    __syncthreads();
    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        // int bin_idx;
        // load to shared memory __synchronize
        // extern __shared__ CUCPX sh_fw[];
        __shared__ PCS sh_x[SHARED_SIZE_SEG];
        __shared__ PCS sh_y[SHARED_SIZE_SEG];
        __shared__ PCS sh_z[SHARED_SIZE_SEG];
        __shared__ CUCPX sh_c[SHARED_SIZE_SEG];
        __shared__ int neighbor_info[27];

        int cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        // bin_idx = threadIdx.x % (nbin_x / hive_x) + threadIdx.x / (nbin_x / hive_x) % (nbin_y / hive_y) + threadIdx.x;
        // idx in hive + hive_x * hivesize_x
        int bin_x = threadIdx.x % (nbin_x / nhive_x) + hive_x * (nbin_x / nhive_x);
        int bin_y = threadIdx.x / (nbin_x / nhive_x) % (nbin_y / nhive_y) + hive_y * (nbin_y / nhive_y);
        int bin_z = threadIdx.x / ((nbin_x / nhive_x) * (nbin_y / nhive_y)) + hive_z * (nbin_z / nhive_z);
        outidx = nf1 * nf2;
        outidx *= bin_z;
        outidx += bin_x + bin_y * nf1;

        int flag = 0; // first bit is for x, y, z later consider this issue

        if (threadIdx.x < 27)
        { // have a litter improvement
            int cur_hive_x;
            int cur_hive_y;
            int cur_hive_z;

            cur_hive_z = hive_z + threadIdx.x / 9 - 1;
            cur_hive_y = hive_y + threadIdx.x % 9 / 3 - 1;
            cur_hive_x = hive_x + threadIdx.x % 3 - 1;

            // some issues here if nhive<3 we will not adopt this method
            if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
            if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
            if (cur_hive_z >= nhive_z || cur_hive_z < 0)
                cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0)) * nhive_z;

            neighbor_info[threadIdx.x] = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;
        }
        __syncthreads();

        // loop from here
        int hive_index = 0;
        while (hive_index < 27)
        {
            if (flag >= 0)
                flag = 0;
            cur_hive_idx = 0; // reuse as start of shared memory
            // load data into shared memroy
            for (; hive_index < 27; hive_index++)
            {
                // if flag = -1, cur_nupt_num changed
                int cur_nupt_num;
                if (flag < 0)
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] - hive_count[neighbor_info[hive_index]] + flag * SHARED_SIZE_SEG;
                else
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] - hive_count[neighbor_info[hive_index]];
                // if(threadIdx.x==0&&blockIdx.x==0)printf("number of point in hive %d: %d\n",hive_index,cur_nupt_num);
                if (cur_hive_idx + cur_nupt_num <= SHARED_SIZE_SEG)
                {
                    // load to shared mem
                    int start_idx = hive_count[neighbor_info[hive_index]] - flag * SHARED_SIZE_SEG;
                    for (int j = threadIdx.x; j < cur_nupt_num; j += blockDim.x)
                    {
                        // +++ shift here
                        sh_x[cur_hive_idx + j] = x[start_idx + j];
                        sh_y[cur_hive_idx + j] = y[start_idx + j];
                        sh_z[cur_hive_idx + j] = z[start_idx + j];
                        sh_c[cur_hive_idx + j] = c[start_idx + j]; // save those shifted stuff
                    }
                    cur_hive_idx += cur_nupt_num;
                    flag = 0;
                }
                else
                {
                    // points in one hive can not load into shared mem
                    if (cur_hive_idx == 0)
                    {
                        // fully occupy the shared mem
                        // printf("1 \n");
                        int start_idx_full = hive_count[neighbor_info[hive_index]] - flag * SHARED_SIZE_SEG;
                        for (int j = threadIdx.x; j < SHARED_SIZE_SEG; j += blockDim.x)
                        {
                            // +++ shift here
                            sh_x[j] = x[start_idx_full + j];
                            sh_y[j] = y[start_idx_full + j];
                            sh_z[j] = z[start_idx_full + j];
                            sh_c[j] = c[start_idx_full + j];
                        }
                        cur_hive_idx = SHARED_SIZE_SEG;
                        // hive_index--;
                        flag--;
                    }
                    // hive_index++;
                    break;
                }
            }
            __syncthreads();

            if (bin_x < nf1 && bin_y < nf2 && bin_z < nf3)
            {
                for (int i = 0; i < cur_hive_idx; i++)
                {

                    // kernel evaluation
                    // PCS ker;
                    PCS kervalue = 1.0;

                    PCS temp1 = abs(sh_x[i] - bin_x);
                    //++++ break if not in range
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    // if(outidx==575&&i==491)printf("temp: %.6g\n",temp1);
                    if (temp1 >= ns / 2.0)
                        continue;

                    PCS temp2 = abs(sh_y[i] - bin_y);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;

                    PCS temp3 = abs(sh_z[i] - bin_z);
                    if (temp3 > nf3 / 2.0)
                        temp3 = abs(nf3 - temp3);
                    if (temp3 >= ns / 2.0)
                        continue;

                    int seg_idx = temp1 * seg_s;
                    double dis = temp1 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue = sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    // temp1 = abs(sh_y[i]-bin_y); // it will be faster just use one variable?
                    // if(temp1>nf2/2.0)temp1 = abs(nf2 - temp1);
                    // if(temp1>=ns/2.0)continue;
                    seg_idx = temp2 * seg_s;
                    dis = temp2 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue *= sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    // temp1 = abs(sh_z[i]-bin_z);
                    // if(temp1>nf3/2.0)temp1 = abs(nf3 - temp1);
                    // if(temp1>=ns/2.0)continue;
                    seg_idx = temp3 * seg_s;
                    dis = temp3 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue *= sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    fw[outidx].x += sh_c[i].x * kervalue;
                    fw[outidx].y += sh_c[i].y * kervalue;
                }
            }
            __syncthreads();
        }
    }
}

__global__ void partial_conv_3d_outputdriven(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                             int nf3, int nf3_total, int nbin_x, int nbin_y, int nbin_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta, int pirange,
                                             int init_shift, int up_shift, int c_shift, int down_shift)
{
    /*
		blocksize = 8*8*8 if change may need to revise
		another method also load intput into shared memroy by multi times

		remove some variable or put to constant memory remove nbin
	*/

    unsigned long int idx;        // one hive by one hive
    unsigned long int M = nbin_x; // the threads are padded
    M *= nbin_y;
    M *= nbin_z;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        // int bin_idx;
        // load to shared memory __synchronize
        // extern __shared__ CUCPX sh_fw[];

        int cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        // bin_idx = threadIdx.x % (nbin_x / hive_x) + threadIdx.x / (nbin_x / hive_x) % (nbin_y / hive_y) + threadIdx.x;
        // idx in hive + hive_x * hivesize_x
        int bin_x = threadIdx.x % (nbin_x / nhive_x) + hive_x * (nbin_x / nhive_x);
        int bin_y = threadIdx.x / (nbin_x / nhive_x) % (nbin_y / nhive_y) + hive_y * (nbin_y / nhive_y);
        int bin_z = threadIdx.x / ((nbin_x / nhive_x) * (nbin_y / nhive_y)) + hive_z * (nbin_z / nhive_z);
        outidx = nf1 * nf2;
        outidx *= bin_z;
        outidx += bin_x + bin_y * nf1;

        int flag = 1;
        int cur_hive_x;
        int cur_hive_y;
        int cur_hive_z;
        // start_hive_idx[1] = cur_hive_idx - nhive_x - 1;
        // start_hive_idx[2] = start_hive_idx[1] + nhive_x*nhive_y;
        // start_hive_idx[0] = start_hive_idx[1] - nhive_x*nhive_y;

        if (bin_x < nf1 && bin_y < nf2 && bin_z < nf3)
        {
            for (int i = 0; i < 3; i++)
            {
                for (int j = 0; j < 9; j++)
                {
                    flag = 1;

                    cur_hive_x = hive_x + j % 3 - 1;
                    cur_hive_y = hive_y + j / 3 - 1;
                    cur_hive_z = hive_z + i - 1;

                    if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                        nhive_x < 3 ? flag = 0 : cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                    if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                        nhive_y < 3 ? flag = 0 : cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                    // if(cur_hive_z >= nhive_z || cur_hive_z < 0) nhive_z<3? flag=0: cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0))*nhive_z;
                    // if(outidx==616)printf("%d,%d,%d,%d\n",cur_hive_idx,cur_hive_x,cur_hive_y,cur_hive_z);
                    if (flag == 0)
                        continue; // exceeding the boundart and nf < 3
                    if (cur_hive_z == nhive_z)
                    {
                        // calculate cur_hive_idx
                        cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + down_shift;
                    }
                    else if (cur_hive_z < 0)
                    {
                        cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + up_shift;
                    }
                    else
                        cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y + c_shift;
                    // if(outidx==616)printf("%d,%d,%d,%d,%lu\n",cur_hive_idx,cur_hive_x,cur_hive_y,cur_hive_z,idx);

                    //if(cur_hive_idx>=nhive_x*nhive_y*nhive_z||cur_hive_idx<0)printf("%d,%d,%d,%d,%d ",cur_hive_idx, hive_x,hive_y, hive_z,flag);
                    for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                    {
                        // kernel evaluation
                        // if(k==91444&&blockIdx.x==3)printf("%d %d %d\n",bin_x,bin_y,bin_z);
                        PCS ker;
                        PCS kervalue = 1.0;
                        PCS temp1 = x[k]; //save
                        temp1 = abs(temp1 - bin_x);
                        //++++ break if not in range
                        if (temp1 > nf1 / 2.0)
                            temp1 = abs(nf1 - temp1);
                        if (temp1 >= ns / 2.0)
                            continue;
                        // if(k==91444&&blockIdx.x==3&&bin_x==31&&bin_y==4&&bin_z==2)printf("temp1 %lf\n",temp1);

                        PCS temp2 = y[k];
                        temp2 = abs(temp2 - bin_y);
                        if (temp2 > nf2 / 2.0)
                            temp2 = abs(nf2 - temp2);
                        if (temp2 >= ns / 2.0)
                            continue;
                        // if(k==91444&&blockIdx.x==3&&bin_x==31&&bin_y==4&&bin_z==2)printf("temp1 %lf\n",temp2);

                        PCS temp3 = z[k]; // +++
                        temp3 = abs(temp3 - bin_z - init_shift);
                        if (temp3 > nf3_total / 2.0)
                            temp3 = abs(nf3_total - temp3);
                        if (temp3 >= ns / 2.0)
                            continue;
                        // if(k==91444&&blockIdx.x==3&&bin_x==31&&bin_y==4&&bin_z==2)printf("temp1 %lf\n",temp3);
                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));
                        // if(outidx==575)printf("1st %.12lf, %lf\n",ker,temp1);

                        // kervalue_evaluate(ker, temp, ns, es_c, es_beta);
                        kervalue = kervalue * ker;

                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));
                        // if(outidx==575)printf("2nd %.12lf\n",ker);

                        // kervalue_evaluate(ker, temp2, ns, es_c, es_beta);
                        kervalue = kervalue * ker;
                        ker = exp(es_beta * (sqrt(1.0 - es_c * temp3 * temp3)));

                        // kervalue_evaluate(ker, temp3, ns, es_c, es_beta);
                        kervalue = kervalue * ker;
                        // if(outidx==616)printf("%lf,%lu,%d,%d,%d\n",x[k],idx,cur_hive_x,cur_hive_y,cur_hive_z);
                        // if(k==91444)printf("%d, %lf %d\n",cur_hive_idx,x[k],bin_x);
                        // if(outidx==nf1*nf2-1)printf("%lf,%lf,%lf\n",x[k],temp,kervalue);
                        fw[outidx].x += c[k].x * kervalue;
                        fw[outidx].y += c[k].y * kervalue;
                        // if(outidx==nf1*nf2*nf3-10)printf("%lf\n",kervalue);
                    }
                }
            }
        }
    }
}

__global__ void partial_conv_3d_outputdriven_t1(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int *hive_count, const int ns, int nf1, int nf2,
                                                int nf3, int nf3_total, int nz, int hivesize_x, int hivesize_y, int hivesize_z, int nhive_x, int nhive_y, int nhive_z, PCS es_c, PCS es_beta,
                                                int pirange, int init_shift, int up_shift, int c_shift, int down_shift)
{
    /*
		one thread handles t elements.
	*/
    unsigned long int idx;
    unsigned long int M = nhive_x * hivesize_x; // revise
    M *= nhive_y * hivesize_y;
    M *= (nhive_z - 1) / nz + 1;

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        int cur_hive_idx;

        cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        int bin_x, bin_y, bin_z;
        int cur_hive_x, cur_hive_y, cur_hive_z;
        bin_x = hive_x * hivesize_x + threadIdx.x % hivesize_x;
        bin_y = hive_y * hivesize_y + threadIdx.x / hivesize_x % hivesize_y;
        bin_z = hive_z * nz;

        for (int cur_plane = floor(bin_z - ns / 2.0); cur_plane < ceil(min(bin_z + nz, nf3 - 1) + ns / 2.0); cur_plane++)
        {

            for (int j = 0; j < 9; j++)
            {
                cur_hive_x = hive_x + j % 3 - 1;
                cur_hive_y = hive_y + j / 3 - 1;
                cur_hive_z = cur_plane;

                if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                    cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
                if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                    cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
                // if(cur_hive_z >= nhive_z || cur_hive_z < 0) cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0))*nhive_z;
                // cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y;

                if (cur_hive_z >= nhive_z)
                {
                    // calculate cur_hive_idx
                    cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + down_shift + (cur_hive_z - nhive_z) * nhive_x * nhive_y;
                }
                else if (cur_hive_z < 0)
                {
                    cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + up_shift + (ceil(ns / 2.0) + cur_hive_z) * nhive_x * nhive_y; // 8 + cur_hive_z, save -8 - -1
                }
                else
                    cur_hive_idx = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y + c_shift;
                // if(idx==335)printf("%d, %d\n",cur_hive_idx,c_shift);

                // if(idx==6&&cur_plane==2)printf("%d\n",hive_count[cur_hive_idx+1]-hive_count[cur_hive_idx]);
                for (int k = hive_count[cur_hive_idx]; k < hive_count[cur_hive_idx + 1]; k++)
                {
                    // PCS ker1, ker2, ker3;
                    PCS kervalue = 1.0;

                    PCS temp1 = SHIFT_RESCALE(x[k], nf1, pirange); //save
                    PCS temp2 = SHIFT_RESCALE(y[k], nf2, pirange);
                    PCS temp3 = SHIFT_RESCALE(z[k], nf3_total, pirange);

                    // if(floor(x[k])==2054&&floor(y[k])==1034&&floor(z[k])==13)printf("%d %d %d\n",bin_x,bin_y,bin_z);
                    // if(idx==0) printf("%.5lf %.5lf %.5lf %d %d\n",x[k],y[k],z[k],cur_hive_idx,k);

                    // reuse the distance x,y distance same, z distance ++
                    // distance
                    temp1 = abs(bin_x - temp1);
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    if (temp1 >= ns / 2.0)
                        continue;
                    temp2 = abs(bin_y - temp2);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;
                    // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%.5lf %.5lf %.5lf\n",x[k],y[k],z[k]);
                    // if(idx==335)printf("%d %d\n",cur_hive_idx,k);
                    // if(idx==335&&k==510)printf("%.5lf %.5lf %.5lf\n",x[k],y[k],z[k]);
                    temp1 = exp(es_beta * (sqrt(1.0 - es_c * temp1 * temp1)));

                    temp2 = exp(es_beta * (sqrt(1.0 - es_c * temp2 * temp2)));

                    for (int i = 0; i < ns + 1; i++)
                    {
                        if (cur_plane - (int)floor(ns / 2.0) + i < bin_z)
                            continue;
                        if (cur_plane - (int)floor(ns / 2.0) + i >= bin_z + nz)
                            break;

                        outidx = nf1 * nf2;
                        outidx *= cur_plane - (int)floor(ns / 2.0) + i;
                        outidx += bin_x + bin_y * nf1;
                        // if(idx==335&&k==510)printf("%.5lf %.5lf %.5lf %lu %d %d\n",x[k],y[k],z[k],outidx,cur_plane - (int)floor(ns/2.0) + i,bin_z);

                        // if(idx==1&& cur_plane <= bin_z+ns/2.0)printf("%lu %d %d %d----\n",outidx,cur_plane, bin_y, cur_plane - (int)floor(ns/2.0) + i);

                        kervalue = abs(cur_plane - floor(ns / 2.0) + i - temp3 + init_shift);
                        if (kervalue > nf3_total / 2.0)
                            kervalue = abs(nf3_total - kervalue);
                        if (kervalue >= ns / 2.0)
                            continue;
                        if (outidx >= (unsigned int)nf1 * nf2 * nf3)
                            continue;
                        // if(outidx==0)printf("%lf,%lf,%lf \n",x[k],y[k],z[k]);
                        // if(outidx==9219) printf("%.5lf %.5lf %.5lf %d\n",x[k],y[k],z[k],idx);
                        // if(outidx==9219&&idx==3) printf("%d %d\n",bin_z,bin_z+nz);
                        kervalue = exp(es_beta * (sqrt(1.0 - es_c * kervalue * kervalue)));
                        // if(outidx==577) printf("%.5lf %.5lf %.5lf %d\n",kervalue,temp1,temp2,idx);
                        fw[outidx].x += c[k].x * kervalue * temp1 * temp2;
                        fw[outidx].y += c[k].y * kervalue * temp1 * temp2;

                        // if(outidx==13920)printf("%.5g \n",fw[outidx].x);
                    }
                }
            }
        }
    }
}

__global__ void partial_conv_3d_outputdriven_shared_hive_lut(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, PCS *c0, int *hive_count, const int ns, int nf1, int nf2,
                                                             int nf3, int nf3_total, int nbin_x, int nbin_y, int nbin_z, int nhive_x, int nhive_y, int nhive_z, int pirange, int init_shift, int up_shift, int c_shift, int down_shift)
{
    /*
		blocksize = 8*8*8 if change may need to revise
		another method also load intput into shared memroy by multi times

		remove some variable or put to constant memory remove nbin
	*/

    unsigned long int idx;        // one hive by one hive
    unsigned long int M = nbin_x; // the threads are padded
    M *= nbin_y;
    M *= nbin_z;
    double ns_2 = 2 / (double)ns;
    double seg_s = ns_2 * SHARED_SIZE_SEG;
    double num_s_1 = 1 / (double)SHARED_SIZE_SEG;
    __shared__ PCS sh_c0[SHARED_SIZE_SEG * SEG_ORDER];
    for (idx = threadIdx.x; idx < SHARED_SIZE_SEG * SEG_ORDER; idx += blockDim.x)
    {
        sh_c0[idx] = c0[idx];
    }
    __syncthreads();
    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {
        int hive_x, hive_y, hive_z;
        unsigned long long int outidx;
        // int bin_idx;
        // load to shared memory __synchronize
        // extern __shared__ CUCPX sh_fw[];
        __shared__ PCS sh_x[SHARED_SIZE_SEG];
        __shared__ PCS sh_y[SHARED_SIZE_SEG];
        __shared__ PCS sh_z[SHARED_SIZE_SEG];
        __shared__ CUCPX sh_c[SHARED_SIZE_SEG];
        __shared__ int neighbor_info[27];

        int cur_hive_idx = blockIdx.x; // current hive idx
        hive_x = cur_hive_idx % nhive_x;
        hive_y = cur_hive_idx / nhive_x % nhive_y;
        hive_z = cur_hive_idx / (nhive_x * nhive_y);

        // bin_idx = threadIdx.x % (nbin_x / hive_x) + threadIdx.x / (nbin_x / hive_x) % (nbin_y / hive_y) + threadIdx.x;
        // idx in hive + hive_x * hivesize_x
        int bin_x = threadIdx.x % (nbin_x / nhive_x) + hive_x * (nbin_x / nhive_x);
        int bin_y = threadIdx.x / (nbin_x / nhive_x) % (nbin_y / nhive_y) + hive_y * (nbin_y / nhive_y);
        int bin_z = threadIdx.x / ((nbin_x / nhive_x) * (nbin_y / nhive_y)) + hive_z * (nbin_z / nhive_z);
        outidx = nf1 * nf2;
        outidx *= bin_z;
        outidx += bin_x + bin_y * nf1;

        int flag = 0; // first bit is for x, y, z later consider this issue

        if (threadIdx.x < 27)
        { // have a litter improvement
            int cur_hive_x;
            int cur_hive_y;
            int cur_hive_z;

            cur_hive_z = hive_z + threadIdx.x / 9 - 1;
            cur_hive_y = hive_y + threadIdx.x % 9 / 3 - 1;
            cur_hive_x = hive_x + threadIdx.x % 3 - 1;

            // some issues here if nhive<3 we will not adopt this method
            if (cur_hive_x >= nhive_x || cur_hive_x < 0)
                cur_hive_x -= ((cur_hive_x > 0) - (cur_hive_x < 0)) * nhive_x;
            if (cur_hive_y >= nhive_y || cur_hive_y < 0)
                cur_hive_y -= ((cur_hive_y > 0) - (cur_hive_y < 0)) * nhive_y;
            // if(cur_hive_z >= nhive_z || cur_hive_z < 0)  cur_hive_z -= ((cur_hive_z > 0) - (cur_hive_z < 0))*nhive_z;
            if (cur_hive_z >= nhive_z)
            {
                neighbor_info[threadIdx.x] = cur_hive_x + cur_hive_y * nhive_x + down_shift;
            }
            else if (cur_hive_z < 0)
            {
                neighbor_info[threadIdx.x] = cur_hive_x + cur_hive_y * nhive_x + up_shift;
            }
            else
                neighbor_info[threadIdx.x] = cur_hive_x + cur_hive_y * nhive_x + cur_hive_z * nhive_x * nhive_y + c_shift;
        }
        __syncthreads();

        // loop from here
        int hive_index = 0;
        while (hive_index < 27)
        {
            if (flag >= 0)
                flag = 0;
            cur_hive_idx = 0; // reuse as start of shared memory
            // load data into shared memroy
            for (; hive_index < 27; hive_index++)
            {
                // if flag = -1, cur_nupt_num changed
                int cur_nupt_num;
                if (flag < 0)
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] - hive_count[neighbor_info[hive_index]] + flag * SHARED_SIZE_SEG;
                else
                    cur_nupt_num = hive_count[neighbor_info[hive_index] + 1] - hive_count[neighbor_info[hive_index]];
                // if(threadIdx.x==315&&blockIdx.x==523779)printf("num %d %d\n",cur_nupt_num);
                // if(threadIdx.x==0&&blockIdx.x==0)printf("number of point in hive %d: %d\n",hive_index,cur_nupt_num);
                if (cur_hive_idx + cur_nupt_num <= SHARED_SIZE_SEG)
                {
                    // load to shared mem
                    int start_idx = hive_count[neighbor_info[hive_index]] - flag * SHARED_SIZE_SEG; //reuse flag
                    for (int j = threadIdx.x; j < cur_nupt_num; j += blockDim.x)
                    {
                        // +++ shift here
                        sh_x[cur_hive_idx + j] = x[start_idx + j];
                        sh_y[cur_hive_idx + j] = y[start_idx + j];
                        sh_z[cur_hive_idx + j] = z[start_idx + j];
                        sh_c[cur_hive_idx + j] = c[start_idx + j]; // save those shifted stuff
                    }
                    cur_hive_idx += cur_nupt_num;
                    flag = 0;
                }
                else
                {
                    // points in one hive can not load into shared mem
                    if (cur_hive_idx == 0)
                    {
                        // fully occupy the shared mem
                        int start_idx_full = hive_count[neighbor_info[hive_index]] - flag * SHARED_SIZE_SEG;
                        for (int j = threadIdx.x; j < SHARED_SIZE_SEG; j += blockDim.x)
                        {
                            // +++ shift here
                            sh_x[j] = x[start_idx_full + j];
                            sh_y[j] = y[start_idx_full + j];
                            sh_z[j] = z[start_idx_full + j];
                            sh_c[j] = c[start_idx_full + j];
                        }
                        cur_hive_idx = SHARED_SIZE_SEG;
                        // hive_index--;
                        flag--;
                    }
                    // hive_index++;
                    break;
                }
            }
            __syncthreads();

            if (bin_x < nf1 && bin_y < nf2 && bin_z < nf3)
            {
                for (int i = 0; i < cur_hive_idx; i++)
                {

                    // kernel evaluation
                    // PCS ker;
                    PCS kervalue = 1.0;

                    PCS temp1 = abs(sh_x[i] - bin_x);
                    //++++ break if not in range
                    if (temp1 > nf1 / 2.0)
                        temp1 = abs(nf1 - temp1);
                    // if(outidx==575&&i==491)printf("temp: %.6g\n",temp1);
                    if (temp1 >= ns / 2.0)
                        continue;

                    PCS temp2 = abs(sh_y[i] - bin_y);
                    if (temp2 > nf2 / 2.0)
                        temp2 = abs(nf2 - temp2);
                    if (temp2 >= ns / 2.0)
                        continue;

                    PCS temp3 = abs(sh_z[i] - bin_z - init_shift);
                    if (temp3 > nf3_total / 2.0)
                        temp3 = abs(nf3_total - temp3);
                    if (temp3 >= ns / 2.0)
                        continue;

                    // if(outidx==nf1*nf2*16+21)printf("temp: %lf, %lf, %lf, %d %d %d\n",sh_x[i],sh_y[i],sh_z[i], hive_x,hive_y,hive_z);

                    int seg_idx = temp1 * seg_s;
                    double dis = temp1 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue = sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    // temp1 = abs(sh_y[i]-bin_y); // it will be faster just use one variable?
                    // if(temp1>nf2/2.0)temp1 = abs(nf2 - temp1);
                    // if(temp1>=ns/2.0)continue;
                    seg_idx = temp2 * seg_s;
                    dis = temp2 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue *= sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    // temp1 = abs(sh_z[i]-bin_z);
                    // if(temp1>nf3/2.0)temp1 = abs(nf3 - temp1);
                    // if(temp1>=ns/2.0)continue;
                    seg_idx = temp3 * seg_s;
                    dis = temp3 * ns_2 - num_s_1 * seg_idx;
                    seg_idx *= SEG_ORDER;
                    kervalue *= sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));

                    fw[outidx].x += sh_c[i].x * kervalue;
                    fw[outidx].y += sh_c[i].y * kervalue;
                }
            }
            __syncthreads();
        }
    }
}

__global__ void fisrt_hive_plane_nupt(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, int M,
                                      const int ns, int nf1, int nf2, int nf3, PCS es_c, PCS es_beta, int flag, int pirange)
{
    /*
		x, y, z - range [-pi,pi)
		c - complex number
		fw - result
		M - number of nupts
		ns - kernel width
		nf1, nf2, nf3 - upts
		es_ - gridding kernel related factors
		pirange - 1
	*/

    int idx;
    idx = blockDim.x * blockIdx.x + threadIdx.x;
    int xx, yy, ix, iy;
    unsigned long long int outidx;

    PCS ker1[MAX_KERNEL_WIDTH];
    PCS ker2[MAX_KERNEL_WIDTH];
    PCS ker3;

    PCS temp1, temp2, temp3;

    // assert(pirange == 1); // check, the x y z should be in range [-pi,pi)

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {

        //value of x, shift and rescale to [0,N) and get the locations
        temp1 = SHIFT_RESCALE(x[idx], nf1, pirange);
        temp2 = SHIFT_RESCALE(y[idx], nf2, pirange);
        temp3 = SHIFT_RESCALE(z[idx], nf3, pirange);

        int bin_x = floor(temp1);
        int bin_y = floor(temp2);
        int bin_z = floor(temp3);

        int xstart = ceil(temp1 - ns / 2.0);
        int ystart = ceil(temp2 - ns / 2.0);
        int xend = floor(temp1 + ns / 2.0);
        int yend = floor(temp2 + ns / 2.0);

        PCS x1 = (PCS)xstart - temp1;
        PCS y1 = (PCS)ystart - temp2;

        val_kernel_vec(ker1, x1, ns, es_c, es_beta, flag);
        val_kernel_vec(ker2, y1, ns, es_c, es_beta, flag);
        if (bin_z >= nf3 - ns / 2.0)
        {
            for (int ii = ns / 2; ii > 0; ii--)
            {
                int out_z = bin_z + ii - nf3;
                if (out_z < 0)
                    break;
                kervalue_evaluate(ker3, abs(nf3 - temp3 + out_z), ns, es_c, es_beta, flag);
                for (yy = ystart; yy <= yend; yy++)
                {
                    temp2 = ker2[yy - ystart];
                    for (xx = xstart; xx <= xend; xx++)
                    {
                        //due to the peroid, the index out of range need to be handle
                        ix = xx < 0 ? xx + nf1 : (xx > nf1 - 1 ? xx - nf1 : xx);
                        iy = yy < 0 ? yy + nf2 : (yy > nf2 - 1 ? yy - nf2 : yy);
                        outidx = nf1 * nf2;
                        outidx *= out_z;
                        outidx += ix + iy * nf1;
                        temp1 = ker1[xx - xstart];
                        PCS kervalue = temp1 * temp2 * ker3;
                        atomicAdd(&fw[outidx].x, c[idx].x * kervalue);
                        atomicAdd(&fw[outidx].y, c[idx].y * kervalue);
                    }
                }
            }
        }
    }
}

__global__ void conv_3d_nputsdriven_taylor(PCS *x, PCS *y, PCS *z, CUCPX *c, CUCPX *fw, PCS *c0, int M,
                                           const int ns, int nf1, int nf2, int nf3, int pirange)
{
    /*
		x, y, z - range [-pi,pi)
		c - complex number
		fw - result
		M - number of nupts
		ns - kernel width
		nf1, nf2, nf3 - upts
		es_ - gridding kernel related factors
		pirange - 1
	*/

    int idx;
    idx = blockDim.x * blockIdx.x + threadIdx.x;
    int xx, yy, zz, ix, iy, iz;
    unsigned long long int outidx;

    PCS ker1[MAX_KERNEL_WIDTH];
    PCS ker2[MAX_KERNEL_WIDTH];
    PCS ker3[MAX_KERNEL_WIDTH];

    PCS temp1, temp2, temp3;

    double ns_2 = 2 / (double)ns;
    double seg_s = ns_2 * SHARED_SIZE_SEG;
    double num_s_1 = 1 / (double)SHARED_SIZE_SEG;
    __shared__ PCS sh_c0[SHARED_SIZE_SEG * SEG_ORDER];
    for (idx = threadIdx.x; idx < SHARED_SIZE_SEG * SEG_ORDER; idx += blockDim.x)
    {
        sh_c0[idx] = c0[idx];
    }
    __syncthreads();

    // assert(pirange == 1); // check, the x y z should be in range [-pi,pi)

    for (idx = blockDim.x * blockIdx.x + threadIdx.x; idx < M; idx += blockDim.x * gridDim.x)
    {

        //value of x, shift and rescale to [0,N) and get the locations
        temp1 = SHIFT_RESCALE(x[idx], nf1, pirange);
        temp2 = SHIFT_RESCALE(y[idx], nf2, pirange);
        temp3 = SHIFT_RESCALE(z[idx], nf3, pirange);

        int xstart = ceil(temp1 - ns / 2.0);
        int ystart = ceil(temp2 - ns / 2.0);
        int zstart = ceil(temp3 - ns / 2.0);
        int xend = floor(temp1 + ns / 2.0);
        int yend = floor(temp2 + ns / 2.0);
        int zend = floor(temp3 + ns / 2.0);

        PCS x1 = (PCS)xstart - temp1;
        PCS y1 = (PCS)ystart - temp2;
        PCS z1 = (PCS)zstart - temp3;

        for (int i = 0; i < ns; i++)
        {
            int seg_idx = abs(x1 + i) * seg_s;
            double dis = abs(x1 + i) * ns_2 - num_s_1 * seg_idx;
            seg_idx *= SEG_ORDER;
            ker1[i] = (abs(x1 + i) >= ns / 2.0) ? 0.0 : sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));
            seg_idx = abs(y1 + i) * seg_s;
            dis = abs(y1 + i) * ns_2 - num_s_1 * seg_idx;
            seg_idx *= SEG_ORDER;
            dis = abs(y1 + i);
            ker2[i] = (abs(y1 + i) >= ns / 2.0) ? 0.0 : sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));
            seg_idx = abs(y1 + i) * seg_s;
            dis = abs(y1 + i) * ns_2 - num_s_1 * seg_idx;
            seg_idx *= SEG_ORDER;
            ker2[i] = (abs(z1 + i) >= ns / 2.0) ? 0.0 : sh_c0[seg_idx] + dis * (sh_c0[seg_idx + 1] + dis * (sh_c0[seg_idx + 2] + dis * (sh_c0[seg_idx + 3] + dis * sh_c0[seg_idx + 4])));
        }

        // val_kernel_vec(ker1, x1, ns, es_c, es_beta);
        // val_kernel_vec(ker2, y1, ns, es_c, es_beta);
        // val_kernel_vec(ker3, z1, ns, es_c, es_beta);

        for (zz = zstart; zz <= zend; zz++)
        {
            temp3 = ker3[zz - zstart];
            for (yy = ystart; yy <= yend; yy++)
            {
                temp2 = ker2[yy - ystart];
                for (xx = xstart; xx <= xend; xx++)
                {
                    //due to the peroid, the index out of range need to be handle
                    ix = xx < 0 ? xx + nf1 : (xx > nf1 - 1 ? xx - nf1 : xx);
                    iy = yy < 0 ? yy + nf2 : (yy > nf2 - 1 ? yy - nf2 : yy);
                    iz = zz < 0 ? zz + nf3 : (zz > nf3 - 1 ? zz - nf3 : zz);
                    outidx = nf1 * nf2;
                    outidx *= iz;
                    outidx += ix + iy * nf1;
                    temp1 = ker1[xx - xstart];
                    PCS kervalue = temp1 * temp2 * temp3;
                    // fw[outidx].x += c[idx].x * kervalue;
                    // fw[outidx].y += c[idx].y * kervalue;
                    // if(outidx==616)printf("%lf,%lf,%lf,%lf\n",x[idx],x1+xx-xstart,y1+yy-ystart,z1+zz-zstart);
                    atomicAdd(&fw[outidx].x, c[idx].x * kervalue);
                    atomicAdd(&fw[outidx].y, c[idx].y * kervalue);
                    //printf("the out id %d kervalue %2.2g\n",outidx,kervalue);
                }
            }
        }
        //if((idx/blockDim.x+1)*blockDim.x<M){ __syncthreads(); }
    }
}
