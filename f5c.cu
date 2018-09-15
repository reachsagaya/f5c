#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "error.h"
#include "f5c.h"
#include "f5cmisc.cuh"
#include "f5cmisc.h"

#define CUDA_DEBUG 1
#define BLOCK_LEN 8



void align_cuda(core_t* core, db_t* db) {
    int32_t i;
    int32_t n_bam_rec = db->n_bam_rec;

    /**allocate and copy input arrays for cuda*/

    char* read;        //flattened reads sequences
    int32_t* read_ptr; //index pointer for flattedned "reads"
    int32_t* read_len;
    int64_t sum_read_len;
    //get the total size and create the pointers
    int32_t* read_ptr_host = (int32_t*)malloc(sizeof(int32_t) * n_bam_rec);
    MALLOC_CHK(read_ptr_host);
    sum_read_len = 0;

    //read sequences : needflattening
    for (i = 0; i < n_bam_rec; i++) {
        read_ptr_host[i] = sum_read_len;
        sum_read_len += (db->read_len[i] + 1); //with null term
    }
    //form the temporary flattened array on host
    char* read_host = (char*)malloc(sizeof(char) * sum_read_len);
    MALLOC_CHK(read_host);
    for (i = 0; i < n_bam_rec; i++) {
        int32_t idx = read_ptr_host[i];
        strcpy(&read_host[idx], db->read[i]);
    }

    //copy to the gpu
    print_size("read_ptr array",n_bam_rec * sizeof(int32_t));
    cudaMalloc((void**)&read_ptr, n_bam_rec * sizeof(int32_t));
    CUDA_CHK();
    cudaMemcpy(read_ptr, read_ptr_host, n_bam_rec * sizeof(int32_t),
               cudaMemcpyHostToDevice);
    CUDA_CHK();
    print_size("read array",sum_read_len * sizeof(char));
    cudaMalloc((void**)&read, sum_read_len * sizeof(char)); //with null char
    CUDA_CHK();
    cudaMemcpy(read, read_host, sum_read_len * sizeof(char),
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    //read length : already linear hence direct copy
    print_size("read_lens",n_bam_rec * sizeof(int32_t));
    cudaMalloc((void**)&read_len, n_bam_rec * sizeof(int32_t));
    CUDA_CHK();
    cudaMemcpy(read_len, db->read_len, n_bam_rec * sizeof(int32_t),
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    //now the events : need flattening

    int32_t* n_events;
    event_t* event_table;
    int32_t* event_ptr;
    int64_t sum_n_events;

    //num events : need flattening
    //get the total size and create the pointers
    int32_t* n_events_host = (int32_t*)malloc(sizeof(int32_t) * n_bam_rec);
    MALLOC_CHK(n_events_host);
    int32_t* event_ptr_host = (int32_t*)malloc(sizeof(int32_t) * n_bam_rec);
    MALLOC_CHK(event_ptr_host);

    sum_n_events = 0;
    for (i = 0; i < n_bam_rec; i++) {
        n_events_host[i] = db->et[i].n;
        event_ptr_host[i] = sum_n_events;
        sum_n_events += db->et[i].n;
    }

    //n_events copy
    print_size("n_events",n_bam_rec * sizeof(int32_t));
    cudaMalloc((void**)&n_events, n_bam_rec * sizeof(int32_t));
    CUDA_CHK();
    cudaMemcpy(n_events, n_events_host, n_bam_rec * sizeof(int32_t),
               cudaMemcpyHostToDevice);
    CUDA_CHK();
    //event ptr copy
    print_size("event ptr",n_bam_rec * sizeof(int32_t));
    cudaMalloc((void**)&event_ptr, n_bam_rec * sizeof(int32_t));
    CUDA_CHK();
    cudaMemcpy(event_ptr, event_ptr_host, n_bam_rec * sizeof(int32_t),
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    //event table flatten
    //form the temporary flattened array on host
    event_t* event_table_host =
        (event_t*)malloc(sizeof(event_t) * sum_n_events);
    MALLOC_CHK(event_table_host);
    for (i = 0; i < n_bam_rec; i++) {
        int32_t idx = event_ptr_host[i];
        memcpy(&event_table_host[idx], db->et[i].event,
               sizeof(event_t) * db->et[i].n);
    }

    print_size("event table",sum_n_events * sizeof(event_t));
    cudaMalloc((void**)&event_table, sum_n_events * sizeof(event_t));
    CUDA_CHK();
    cudaMemcpy(event_table, event_table_host, sizeof(event_t) * sum_n_events,
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    //model : already linear
    model_t* model;
    cudaMalloc((void**)&model,
               NUM_KMER * sizeof(model_t)); //todo : constant memory
    CUDA_CHK();
    cudaMemcpy(model, core->model, NUM_KMER * sizeof(model_t),
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    //scalings : already linear
    scalings_t* scalings;
    print_size("Scalings",n_bam_rec * sizeof(scalings_t));
    cudaMalloc((void**)&scalings, n_bam_rec * sizeof(scalings_t));
    CUDA_CHK();
    cudaMemcpy(scalings, db->scalings, sizeof(scalings_t) * n_bam_rec,
               cudaMemcpyHostToDevice);
    CUDA_CHK();

    /**allocate output arrays for cuda**/
    AlignedPair* event_align_pairs;
    int32_t* n_event_align_pairs;
    print_size("event align pairs",2 * sum_n_events *sizeof(AlignedPair));
    cudaMalloc((void**)&event_align_pairs,
               2 * sum_n_events *
                   sizeof(AlignedPair)); //todo : need better huristic
    CUDA_CHK();
    print_size("n_event_align_pairs",n_bam_rec * sizeof(int32_t));
    cudaMalloc((void**)&n_event_align_pairs, n_bam_rec * sizeof(int32_t));
    CUDA_CHK();

    //scratch arrays

    size_t sum_n_bands = sum_n_events + sum_read_len; //todo : can be optimised

    size_t *kmer_ranks;
    float *bands;
    uint8_t *trace;
    EventKmerPair* band_lower_left;

    print_size("kmer ranks",sizeof(size_t) * sum_read_len);
    cudaMalloc((void**)&kmer_ranks,sizeof(size_t) * sum_read_len); //todo : optimise by the sum of n_kmers
    CUDA_CHK();
    print_size("bands",sizeof(float) * sum_n_bands * ALN_BANDWIDTH);
    cudaMalloc((void**)&bands,sizeof(float) * sum_n_bands * ALN_BANDWIDTH);
    CUDA_CHK();
    print_size("trace",sizeof(uint8_t) * sum_n_bands * ALN_BANDWIDTH);
    cudaMalloc((void**)&trace, sizeof(uint8_t) * sum_n_bands * ALN_BANDWIDTH);
    CUDA_CHK();
    print_size("band_lower_left",sizeof(EventKmerPair)* sum_n_bands);
    cudaMalloc((void**)&band_lower_left, sizeof(EventKmerPair)* sum_n_bands);
    CUDA_CHK();

    //cuda kernel configuraion parameters
    dim3 grid((db->n_bam_rec + BLOCK_LEN - 1) / BLOCK_LEN);
    dim3 block(BLOCK_LEN);

    // cudaDeviceSetLimit(cudaLimitMallocHeapSize, 512 * 1024 * 1024);
    // CUDA_CHK();

    align_kernel<<<grid, block>>>(event_align_pairs, n_event_align_pairs, read,
                                  read_len, read_ptr, event_table, n_events,
                                  event_ptr, model, scalings, n_bam_rec, kmer_ranks,bands,trace,band_lower_left );

    //fprintf(stderr,"readlen %d,n_events %d\n",db->read_len[i],n_event_align_pairs);

#ifdef CUDA_DEBUG

    cudaDeviceSynchronize();
    //todo : print a message to detect the launch timed out
    if (cudaGetLastError() == cudaErrorLaunchTimeout) {
        ERROR("%s", "The kernel timed out. You have to first disable the cuda "
                    "time out.");
        fprintf(
            stderr,
            "On Ubuntu do the following\nOpen the file /etc/X11/xorg.conf\nYou "
            "will have a section about your NVIDIA device. Add the following "
            "line to it.\nOption \"Interactive\" \"0\"\nIf you do not have a "
            "section about your NVIDIA device in /etc/X11/xorg.conf or you do "
            "not have a file named /etc/X11/xorg.conf, run the command sudo "
            "nvidia-xconfig to generate a xorg.conf file and do as above.\n\n");
    }
    CUDA_CHK();
#endif

    //copyback ans
    cudaMemcpy(db->n_event_align_pairs, n_event_align_pairs,
               n_bam_rec * sizeof(int32_t), cudaMemcpyDeviceToHost);
    CUDA_CHK();
    AlignedPair* event_align_pairs_host =
        (AlignedPair*)malloc(2 * sum_n_events * sizeof(AlignedPair));
    MALLOC_CHK(event_align_pairs_host);
    cudaMemcpy(event_align_pairs_host, event_align_pairs,
               2 * sum_n_events * sizeof(AlignedPair), cudaMemcpyDeviceToHost);
    CUDA_CHK();
    //copy back
    for (i = 0; i < n_bam_rec; i++) {
        int32_t idx = event_ptr_host[i];
        memcpy(db->event_align_pairs[i], &event_align_pairs_host[idx * 2],
               sizeof(AlignedPair) * db->n_event_align_pairs[i]);
    }

    //free the temp arrays on host
    free(read_host);
    free(read_ptr_host);
    free(n_events_host);
    free(event_ptr_host);
    free(event_table_host);
    free(event_align_pairs_host);
    cudaFree(read_ptr);
    cudaFree(read); //with null char
    cudaFree(read_len);
    cudaFree(n_events);
    cudaFree(event_ptr);
    cudaFree(event_table);
    cudaFree(model); //constant memory
    cudaFree(scalings);
    cudaFree(event_align_pairs);
    cudaFree(n_event_align_pairs);
    cudaFree(kmer_ranks);
    cudaFree(bands);
    cudaFree(trace);
    cudaFree(band_lower_left);


}
