#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <thrust/complex.h>
#include <algorithm>
#include <fstream>
//#include <thrust>
using namespace std;

#include "conv_interp_invoker.h"

#include "cuft.h"
#include "utils.h"

///conv improved WS, method 0 correctness cheak

int main(int argc, char *argv[])
{

    //gpu_method == 0, nupts driven
    int N1, N2, N3;
    PCS sigma = 2.0;
    int M; // input
    if (argc < 4)
    {
        fprintf(stderr,
                "Usage: conv3d\n"
                "Arguments:\n"
                "  method: One of\n"
                "    0: nupts driven, or\n"
                "    1: nupts sorted, or\n"
                "    2: upts driven less atomic operations, or\n"
                "    3: upts driven hive or\n"
                "    6: upts driven efficient memory access, or\n"
                "  N1, N2 : image size.\n"
                "  M: The number of non-uniform points.\n"
                "  tol: NUFFT tolerance (default 1e-6).\n"
                "  kerevalmeth: Kernel evaluation method; one of\n"
                "     0: Exponential of square root (default), or\n"
                "     1: Horner evaluation.\n");
        return 1;
    }
    //no result
    double w;
    int method;
    sscanf(argv[1], "%d", &method);
    sscanf(argv[2], "%lf", &w);
    N1 = (int)w; // so can read 1e6 right!
    sscanf(argv[3], "%lf", &w);
    N2 = (int)w; // so can read 1e6 right!
    sscanf(argv[4], "%lf", &w);
    N3 = (int)w;
    M = N1 * N2 * N3;
    if (argc > 5)
    {
        sscanf(argv[5], "%lf", &w);
        M = (int)w; // so can read 1e6 right!
    }

    PCS tol = 1e-10;
    if (argc > 6)
    {
        sscanf(argv[6], "%lf", &w);
        tol = (PCS)w; // so can read 1e6 right!
    }

    int kerevalmeth = 0;
    if (argc > 7)
    {
        sscanf(argv[7], "%d", &kerevalmeth);
    }

    //int ier;
    PCS *x, *y, *z;
    CPX *c, *fw;
    x = (PCS *)malloc(M * sizeof(PCS)); //Allocates page-locked memory on the host.
    y = (PCS *)malloc(M * sizeof(PCS));
    z = (PCS *)malloc(M * sizeof(PCS));
    c = (CPX *)malloc(M * sizeof(CPX));

    PCS *d_x, *d_y, *d_z;
    CUCPX *d_c;
    checkCudaError(cudaMalloc(&d_x, M * sizeof(PCS)));
    checkCudaError(cudaMalloc(&d_y, M * sizeof(PCS)));
    checkCudaError(cudaMalloc(&d_z, M * sizeof(PCS)));
    checkCudaError(cudaMalloc(&d_c, M * sizeof(CUCPX)));
    //checkCudaError(cudaMalloc(&d_fw,8*nf1*nf2*nf1*sizeof(CUCPX)));

    //generating data
    int nupts_distribute = 0;
    switch (nupts_distribute)
    {
    case 0: //uniform
    {
        for (int i = 0; i < M; i++)
        {
            x[i] = M_PI * randm11();
            y[i] = M_PI * randm11();
            z[i] = M_PI * randm11();
            c[i].real(randm11()); //back to random11()
            c[i].imag(randm11());
        }
    }
    break;
    case 1: // concentrate on a small region
    {
        for (int i = 0; i < M; i++)
        {
            x[i] = M_PI * rand01() / N1 * 16;
            y[i] = M_PI * rand01() / N2 * 16;
            z[i] = M_PI * rand01() / N2 * 16;
            c[i].real(randm11());
            c[i].imag(randm11());
        }
    }
    break;
    default:
        std::cerr << "not valid nupts distr" << std::endl;
        return 1;
    }

    //data transfer
    checkCudaError(cudaMemcpy(d_x, x, M * sizeof(PCS), cudaMemcpyHostToDevice));
    checkCudaError(cudaMemcpy(d_y, y, M * sizeof(PCS), cudaMemcpyHostToDevice));
    checkCudaError(cudaMemcpy(d_z, z, M * sizeof(PCS), cudaMemcpyHostToDevice));
    checkCudaError(cudaMemcpy(d_c, c, M * sizeof(CUCPX), cudaMemcpyHostToDevice));

    CURAFFT_PLAN *h_plan = new CURAFFT_PLAN();
    memset(h_plan, 0, sizeof(CURAFFT_PLAN));

    // opts and copts setting
    h_plan->opts.gpu_conv_only = 1;
    h_plan->opts.gpu_gridder_method = method;
    h_plan->opts.gpu_kerevalmeth = kerevalmeth;
    h_plan->opts.gpu_sort = 0;
    h_plan->opts.upsampfac = sigma;
    h_plan->dim = 3;

    int ier = setup_conv_opts(h_plan->copts, tol, sigma, 1, 1, kerevalmeth); //check the arguements

    if (ier != 0)
        printf("setup_error\n");
    if (kerevalmeth == 1)
        taylor_coefficient_setting(h_plan);

    // plan setting
    int nf1 = (int)N1 * sigma;
    int nf2 = (int)N2 * sigma;
    int nf3 = (int)N3 * sigma;
    ier = setup_plan(nf1, nf2, nf3, M, d_x, d_y, d_z, d_c, h_plan); //cautious the number of plane using N1 N2 to get nf1 nf2

    // printf("the kw is %d\n", h_plan->copts.kw);
    int f_size = nf1 * nf2 * nf3;
    fw = (CPX *)malloc(sizeof(CPX) * f_size);
    // checkCudaError(cudaMalloc(&d_fw, f_size * sizeof(CUCPX)));
    // show_mem_usage();
    h_plan->fw = NULL;
    // checkCudaError(cudaMallocHost(&fw,nf1*nf2*h_plan->num_w*sizeof(CPX))); //malloc after plan setting
    // checkCudaError(cudaMalloc( &h_plan->fw,( nf1*nf2*(nf3)*sizeof(CUCPX) ) ) ); //check

    std::cout << std::scientific << std::setprecision(3); //setprecision not define

    // show_mem_usage();
    cudaEvent_t cuda_start, cuda_end;

    float kernel_time, kernel_time2;

    cudaEventCreate(&cuda_start);
    cudaEventCreate(&cuda_end);

    cudaEventRecord(cuda_start);
    if (h_plan->opts.gpu_gridder_method)
    {
        bin_mapping(h_plan, NULL);
    }
    cudaEventRecord(cuda_end);

    cudaEventSynchronize(cuda_start);
    cudaEventSynchronize(cuda_end);
    cudaEventElapsedTime(&kernel_time2, cuda_start, cuda_end);

    cudaEventRecord(cuda_start);

    // convolution
    curafft_conv(h_plan); //add to include
    cudaEventRecord(cuda_end);

    cudaEventSynchronize(cuda_start);
    cudaEventSynchronize(cuda_end);

    cudaEventElapsedTime(&kernel_time, cuda_start, cuda_end);

    checkCudaError(cudaDeviceSynchronize());

    // int nf3 = h_plan->num_w;
    printf("pre computing time: %.5g s\n", kernel_time2 / 1000.0);
    printf("Conv time time: %.5g s\n", kernel_time / 1000.0);
    printf("[Method %d]  %d NU pts to #%d U pts in %.5g s\n",
           h_plan->opts.gpu_gridder_method, M, nf1 * nf2 * nf3, (kernel_time + kernel_time2) / 1000);

    checkCudaError(cudaMemcpy(fw, h_plan->fw, sizeof(CUCPX) * f_size, cudaMemcpyDeviceToHost));
    curafft_free(h_plan);

    // std::cout << "[result-input]" << std::endl;
    // // ofstream myfile;
    // // myfile.open ("result2.txt");
    // for (int k = 0; k < 1; k++)
    // {
    // 	for (int j = 0; j < nf2; j++)
    // 	{
    // 		for (int i = 0; i < nf1; i++)
    // 		{
    // 			printf(" (%2.3g,%2.3g)", fw[i + j * nf1 + k * nf2 * nf1].real(),
    // 				   fw[i + j * nf1 + k * nf2 * nf1].imag());
    // 			// myfile<<fw[i + j * nf1 + k * nf2 * nf1].real();
    // 			// myfile<<fw[i + j * nf1 + k * nf2 * nf1].imag();
    // 		}
    // 		// myfile<<"\n";
    // 		std::cout << std::endl;
    // 	}
    // 	std::cout << std::endl;
    // 	std::cout << "----------------------------------------------------------------" << std::endl;

    // }
    // std::cout << "----------------------------------------------------------------" << std::endl;
    // myfile.close();
    checkCudaError(cudaDeviceReset());
    free(x);
    free(y);
    free(z);
    free(c);
    free(fw);

    return 0;
}