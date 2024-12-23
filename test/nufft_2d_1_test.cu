#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <thrust/complex.h>
#include <algorithm>
//#include <thrust>

#include "ragridder_plan.h"
#include "conv_interp_invoker.h"

#include "cuft.h"
#include "deconv.h"
#include "cugridder.h"
#include "precomp.h"
#include "utils.h"

int main(int argc, char *argv[])
{
    /* Input: M, N1, N2, epsilon method
		method - conv method
		M - number of randomly distributed points
		N1, N2 - output size
		epsilon - tolerance
	*/
    int ier = 0;
    if (argc < 4)
    {
        fprintf(stderr,
                "Usage: Nufft 2d, equispaced data to non-equispaced data\n"
                "Arguments:\n"
                "  N1, N2 : image size.\n"
                "  M: The number of randomly distributed points.\n"
                "  epsilon: NUFFT tolerance (default 1e-6).\n"
                "  kerevalmeth: Kernel evaluation method; one of\n"
                "     0: Exponential of square root (default), or\n"
                "  method: One of\n"
                "    0: nupts driven (default),\n");
        return 1;
    }
    int N1, N2;
    PCS sigma = 2.0; // upsampling factor
    int M;

    double inp;
    sscanf(argv[1], "%d", &N1);
    sscanf(argv[2], "%d", &N2);
    sscanf(argv[3], "%d", &M);
    PCS epsilon = 1e-6;
    if (argc > 4)
    {
        sscanf(argv[4], "%lf", &inp);
        epsilon = inp;
    }
    int kerevalmeth = 0;
    if (argc > 5)
        sscanf(argv[5], "%d", &kerevalmeth);
    int method = 0;
    if (argc > 6)
        sscanf(argv[6], "%d", &method);

    //gpu_method == 0, nupts driven

    //int ier;
    PCS *u, *v;
    CPX *c;
    u = (PCS *)malloc(M * sizeof(PCS)); //Allocates page-locked memory on the host.
    v = (PCS *)malloc(M * sizeof(PCS));
    c = (CPX *)malloc(M * sizeof(CPX));
    PCS *d_u, *d_v;
    CUCPX *d_c, *d_fk;
    CUCPX *d_fw;
    checkCudaError(cudaMalloc(&d_u, M * sizeof(PCS)));
    checkCudaError(cudaMalloc(&d_v, M * sizeof(PCS)));
    checkCudaError(cudaMalloc(&d_c, M * sizeof(CUCPX)));

    // generating data
    for (int i = 0; i < M; i++)
    {
        u[i] = randm11() * PI; //xxxxx
        v[i] = randm11() * PI;
        c[i].real(randm11()); // M vis per channel, weight?
        c[i].imag(randm11());
        // wgt[i] = 1;
    }

#ifdef DEBUG
    printf("origial input data...\n");
    for (int i = 0; i < M; i++)
    {
        printf("%.3lf ", u[i]);
    }
    printf("\n");
    for (int i = 0; i < M; i++)
    {
        printf("%.3lf ", c[i].real());
    }
    printf("\n");
#endif

    // Timing begin
    //data transfer
    checkCudaError(cudaMemcpy(d_u, u, M * sizeof(PCS), cudaMemcpyHostToDevice)); //u
    checkCudaError(cudaMemcpy(d_v, v, M * sizeof(PCS), cudaMemcpyHostToDevice)); //v
    checkCudaError(cudaMemcpy(d_c, c, M * sizeof(CUCPX), cudaMemcpyHostToDevice));

    /* ----------Step2: plan setting------------*/
    CURAFFT_PLAN *plan;

    plan = new CURAFFT_PLAN();
    memset(plan, 0, sizeof(CURAFFT_PLAN));

    int direction = 1; //inverse

    // opts and copts setting
    plan->opts.gpu_device_id = 0;
    plan->opts.upsampfac = sigma;
    plan->opts.gpu_sort = 1;
    plan->opts.gpu_binsizex = -1;
    plan->opts.gpu_binsizey = -1;
    plan->opts.gpu_binsizez = -1;
    plan->opts.gpu_kerevalmeth = kerevalmeth;
    plan->opts.gpu_conv_only = 0;
    plan->opts.gpu_gridder_method = method;

    ier = setup_conv_opts(plan->copts, epsilon, sigma, 1, direction, kerevalmeth); //check the arguements

    if (ier != 0)
        printf("setup_error\n");

    // plan setting
    // cuda stream malloc in setup_plan

    int nf1 = get_num_cells(N1, plan->copts);
    int nf2 = get_num_cells(N2, plan->copts);

    plan->dim = 2;
    plan->type = 1;
    setup_plan(nf1, nf2, 1, M, d_u, d_v, NULL, d_c, plan);

    plan->ms = N1;
    plan->mt = N2;
    plan->mu = 1;
    plan->execute_flow = 1;
    int iflag = direction;
    int fftsign = (iflag >= 0) ? 1 : -1;

    plan->iflag = fftsign; //may be useless| conflict with direction
    plan->batchsize = 1;

    plan->copts.direction = direction; // 1 inverse, 0 forward

    fourier_series_appro_invoker(plan->fwkerhalf1, plan->copts, plan->nf1 / 2 + 1, 0);
    fourier_series_appro_invoker(plan->fwkerhalf2, plan->copts, plan->nf2 / 2 + 1, 0);

#ifdef DEBUG
    printf("nf1, nf2 %d %d\n", plan->nf1, plan->nf2);
    printf("copts info printing...\n");
    printf("kw: %d, direction: %d, pirange: %d, upsampfac: %lf, \nbeta: %lf, halfwidth: %lf, c: %lf\n",
           plan->copts.kw,
           plan->copts.direction,
           plan->copts.pirange,
           plan->copts.upsampfac,
           plan->copts.ES_beta,
           plan->copts.ES_halfwidth,
           plan->copts.ES_c);

    PCS *fwkerhalf1 = (PCS *)malloc(sizeof(PCS) * (plan->nf1 / 2 + 1));
    PCS *fwkerhalf2 = (PCS *)malloc(sizeof(PCS) * (plan->nf2 / 2 + 1));

    checkCudaError(cudaMemcpy(fwkerhalf1, plan->fwkerhalf1, (plan->nf1 / 2 + 1) * sizeof(PCS), cudaMemcpyDeviceToHost));

    checkCudaError(cudaMemcpy(fwkerhalf2, plan->fwkerhalf2, (plan->nf2 / 2 + 1) * sizeof(PCS), cudaMemcpyDeviceToHost));

    printf("correction factor print...\n");
    for (int i = 0; i < nf1 / 2 + 1; i++)
    {
        printf("%.3g ", fwkerhalf1[i]);
    }
    printf("\n");

    for (int i = 0; i < nf2 / 2 + 1; i++)
    {
        printf("%.3g ", fwkerhalf2[i]);
    }
    printf("\n");
    // free host fwkerhalf
    free(fwkerhalf1);
    free(fwkerhalf2);
#endif

    // cufft plan setting
    cufftHandle fftplan;
    int n[] = {plan->nf2, plan->nf1};
    int inembed[] = {plan->nf2, plan->nf1};
    int onembed[] = {plan->nf2, plan->nf1};

    // cufftCreate(&fftplan);
    // cufftPlan2d(&fftplan,n[0],n[1],CUFFT_TYPE);
    // the bach size sets as the num of w when memory is sufficent. Alternative way, set as a smaller number when memory is insufficient.
    // and handle this piece by piece
    cufftPlanMany(&fftplan, 2, n, inembed, 1, inembed[0] * inembed[1],
                  onembed, 1, onembed[0] * onembed[1], CUFFT_TYPE, plan->nf3); //need to check and revise (the partial conv will be differnt)
    plan->fftplan = fftplan;

    // set up bin size +++ (for other methods) and related malloc based on gpu method
    // assign memory for index after sorting (can be done in setup_plan)
    // bin sorting (for other methods)

    if (ier == 1)
    {
        printf("errors in gridder setting\n");
        return ier;
    }
    // fw (conv res set)
    checkCudaError(cudaMalloc((void **)&d_fw, sizeof(CUCPX) * nf1 * nf2));
    checkCudaError(cudaMemset(d_fw, 0, sizeof(CUCPX) * nf1 * nf2));
    plan->fw = d_fw;
    // fk malloc and set
    checkCudaError(cudaMalloc((void **)&d_fk, sizeof(CUCPX) * N1 * N2));
    plan->fk = d_fk;

    // calulating result
    curafft_conv(plan);
#ifdef DEBUG
    printf("conv result printing...\n");
    CPX *fw = (CPX *)malloc(sizeof(CPX) * nf1 * nf2);
    PCS temp_res = 0;
    cudaMemcpy(fw, plan->fw, sizeof(CUCPX) * nf1 * nf2, cudaMemcpyDeviceToHost);
    for (int i = 0; i < nf2; i++)
    {
        for (int j = 0; j < nf1; j++)
        {
            printf("%.3g ", fw[i * nf1 + j].real());
            temp_res += fw[i * nf1 + j].real();
        }
        printf("\n");
    }
    printf("fft(0,0) %.3g\n", temp_res);
#endif
    // fft
    CUFFT_EXEC(plan->fftplan, plan->fw, plan->fw, direction);
#ifdef DEBUG
    printf("fft result printing...\n");
    cudaMemcpy(fw, plan->fw, sizeof(CUCPX) * nf1 * nf2, cudaMemcpyDeviceToHost);
    for (int i = 0; i < nf2; i++)
    {
        for (int j = 0; j < nf1; j++)
        {
            printf("%.3g ", fw[i * nf1 + j].real());
        }
        printf("\n");
    }
    free(fw);
#endif

    // deconv
    ier = curafft_deconv(plan);

    CPX *fk = (CPX *)malloc(sizeof(CPX) * N1 * N2);
    checkCudaError(cudaMemcpy(fk, plan->fk, sizeof(CUCPX) * N1 * N2, cudaMemcpyDeviceToHost));

    // result printing
    printf("final result printing...\n");
    for (int i = 0; i < N2; i++)
    {
        for (int j = 0; j < N1; j++)
        {
            printf("%.10lf ", fk[i * N1 + j].real());
        }
        printf("\n");
    }

    printf("ground truth printing...\n");
    CPX *truth = (CPX *)malloc(sizeof(CPX) * N1 * N2);
    CPX Ft = CPX(0, 0), J = IMA * (PCS)iflag;
    for (int i = 0; i < N2; i++)
    {
        for (int j = 0; j < N1; j++)
        {
            for (int k = 0; k < M; ++k)
                Ft += c[k] * exp(J * ((j - N1 / 2) * u[k] + (i - N2 / 2) * v[k])); // crude direct
            truth[i * N1 + j] = Ft;
            printf("%.10lf ", Ft.real());
            Ft.real(0);
            Ft.imag(0);
        }
        printf("\n");
    }

    double max = 0;
    double l2_max = 0;
    double fk_max = 0;
    for (int i = 0; i < M; i++)
    {
        if (abs(fk[i].real()) > fk_max)
            fk_max = abs(fk[i].real());
    }
    printf("fk max %lf\n", fk_max);
    for (int i = 0; i < N1 * N2; i++)
    {
        double temp = abs(truth[i].real() - fk[i].real());
        if (temp > max)
            max = temp;
        if (temp / fk_max > l2_max)
            l2_max = temp / fk_max;
    }
    printf("maximal abs error %.5g, maximal l2 error %.5g\n", max, l2_max);

    //free
    curafft_free(plan);
    free(fk);
    free(u);
    free(v);
    free(c);

    return ier;
}