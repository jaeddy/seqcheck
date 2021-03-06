
version = "0.1.1"

params.config = "/efs/.synapseConfig"
params.syndir = false
params.indir = "${baseDir}/data/reads"
params.skip = false
params.reads = params.syndir ? false : "${params.indir}/*.fastq*"
params.build = false
params.aligner = "hisat2"
params.mapper = "salmon"
params.align_index = params.build ? params.genomes[ params.build ][ params.aligner ] ?: false : false
params.quant_index = params.build ? params.genomes[ params.build ][ params.mapper ] ?: false : false
params.transcriptome = params.build ? params.genomes[ params.build ].transcriptome ?: false : false
params.transcriptome_url = params.build ? params.genomes[ params.build ].transcriptome_url ?: false : false
params.genome = params.build ? params.genomes[ params.build ].genome ?: false : false
params.genome_url = params.build ? params.genomes[ params.build ].genome_url ?: false : false
params.save_reference = true
params.refdir = "${baseDir}/data/reference"
params.outdir = "${baseDir}/results"


log.info "============================================="
log.info "seqcheck : Sequence data sanity check  v${version}"
log.info "============================================="
log.info "Reads            : ${params.reads}"
log.info "Build            : ${params.build}"
log.info "Current home     : $HOME"
log.info "Current path     : $PWD"
log.info "Config path      : ${params.config}"
log.info "Script dir       : $baseDir"
log.info "Working dir      : $workDir"
log.info "Synapse folder?  : ${params.syndir}"
log.info "Input dir        : ${params.indir}"
log.info "Reference dir    : ${params.refdir}"
log.info "Output dir       : ${params.outdir}"
log.info "============================================\n"

log.info "\nPipeline started at\n: $workflow.start"

// Validate inputs
if( !params.build ){
    exit 1, "No reference genome specified."
}
else {
    align_index_file = file(params.align_index)
    if( !align_index_file.exists() ){
        log.info "Align index not found: ${params.align_index}"
        genome_file = file(params.genome)
        if( !genome_file.exists() ){
            log.info "genome FASTA file not found: ${params.genome}"
            if( !params.genome_url){
                exit 1, "No URL to download genome FASTA provided."
            }
            else {
                log.info "...will download from ${params.genome_url}."
                run_download_genome = true
            }
        }
        else {
            log.info "...will build index from ${params.genome}."
            run_download_genome = false
            genome = file(params.genome)
        }
    }
    else {
        run_download_genome = false
        genome = false
        align_index = Channel
            .fromPath("${params.align_index}*")
            .toList()
    }

    quant_index_file = file(params.quant_index)
    if( !quant_index_file.exists() ){
        log.info "Quant index not found: ${params.quant_index}"
        transcriptome_file = file(params.transcriptome)
        if( !transcriptome_file.exists() ){
            log.info "transcriptome FASTA file not found: ${params.transcriptome}"
            if( !params.transcriptome_url){
                exit 1, "No URL to download transcriptome FASTA provided."
            }
            else {
                log.info "...will download from ${params.transcriptome_url}."
                run_download_transcriptome = true
            }
        }
        else {
            log.info "...will build index from ${params.transcriptome}."
            run_download_transcriptome = false
            transcriptome = file(params.transcriptome)
        }
    }
    else {
        run_download_transcriptome = false
        transcriptome = false
        quant_index = Channel
            .fromPath(params.quant_index)
            .toList()
    }
}

// Create channels for Synapse credentials
query_credentials = Channel.fromPath(params.config)
get_credentials = Channel.fromPath(params.config)

/*
 * PREPROCESSING - Download genome
 */
if( run_download_genome ){
    log.info "\nDownloading genome FASTA from Ensembl..."
    process download_genome {
        tag "${params.genome_url}"
        publishDir path: "${params.refdir}/sequence/${params.build}", saveAs: { params.save_reference ? it : null }

        output:
        file "*.{fa,fasta}" into genome

        script:
        """
        curl -O -L ${params.genome_url}
        if [ -f *.tar.gz ]; then
            tar xzf *.tar.gz
        elif [ -f *.gz ]; then
            gzip -d *.gz
        fi
        """
    }
}

/*
 * PREPROCESSING - Download transcriptome
 */
if( run_download_transcriptome ){
    log.info "\nDownloading transcriptome FASTA from Ensembl..."
    process download_transcriptome {
        tag "${params.transcriptome_url}"
        publishDir path: "${params.refdir}/sequence/${params.build}", saveAs: { params.save_reference ? it : null }, mode: 'copy'

        output:
        file "*.{fa,fasta}" into transcriptome

        script:
        """
        curl -O -L ${params.transcriptome_url}
        if [ -f *.tar.gz ]; then
            tar xzf *.tar.gz
        elif [ -f *.gz ]; then
            gzip -d *.gz
        fi
        """
    }
}

/*
 * PREPROCESSING - Build align index
 */
if( genome ){
    if( params.aligner == "hisat2" ){
        log.info "\nBuilding HISAT2 index from genome FASTA..."
        process make_hisat2_index {
            tag genome
            publishDir path: "${params.refdir}/indexes/hisat2/${params.build}", saveAs: { params.save_reference ? it : null }, mode: 'copy'

            input:
            file genome from genome

            output:
            file "${params.build}.*.ht2" into align_index

            script:
            """
            mkdir ${params.build}
            hisat2-build \
                -p ${task.cpus} \
                $genome \
                ${params.build}
            """
        }
    }
}

/*
 * PREPROCESSING - Build quant index
 */
if( transcriptome ){
    if( params.mapper == "salmon" ){
        log.info "\nBuilding Salmon index from transcriptome FASTA..."
        process make_salmon_index {
            tag transcriptome
            publishDir path: "${params.refdir}/indexes/salmon", saveAs: { params.save_reference ? it : null }, mode: 'copy'

            input:
            file transcriptome from transcriptome

            output:
            file "${params.build}" into quant_index

            script:
            """
            mkdir ${params.build}
            salmon index \
                -p ${task.cpus} \
                -t ${transcriptome} \
                -i ${params.build}
            """
        }
    }
}

/*
 * STEP 0 - Download FASTQs from Synapse
 */
if( params.syndir ){
    log.info "\nRetrieving Synapse IDs for FASTQs in entity '${params.syndir}'..."
    process locate_fastqs {
        tag params.syndir

        input:
        file config from query_credentials

        output:
        stdout query_result

        script:
        """
        synapse --c ${config} -s query "select id,name from file where parentId=='${params.syndir}'"
        """
    }

    /*
     * Split Synapse IDs and create channel
     */
    query_result
        .splitCsv(sep: '\t', header: true)
        .into { fastq_entities }

    /*
     * Download FASTQs and create channels for input read files
     */
    log.info "\nDownloading individual FASTQ files..."
    process download_fastq {
        tag "${syn_id} -> ${reads}"
        publishDir "${params.indir}", overwrite: true, mode: 'copy'

        input:
        file config from get_credentials
        val fastq_entity from fastq_entities

        output:
        file reads into read_files_fastqc, read_files_quant, read_files_align

        script:
        syn_id = fastq_entity['file.id']
        reads = "${fastq_entity['file.name']}"
        """
        synapse --c ${config} -s get ${syn_id}
        """
    }
}
else {
    /*
     * Create channels for input read files
     */
    pattern = "${params.indir}/*.fastq*"
    Channel
        .fromPath( pattern )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${pattern}" }
        .into { read_files_fastqc; read_files_quant; read_files_align }
}

/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$reads"
    publishDir "${params.outdir}/fastqc", overwrite: true

    input:
    file(reads) from read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads -o .
    """
}

/*
 * STEP 2 - align
 */
if( params.aligner == "hisat2" && !params.skip ){
    process hisat2_align {
        tag "$reads"
        publishDir "${params.outdir}/align"

        input:
        file reads from read_files_align
        file index from align_index.first()

        output:
        file "${prefix}.txt" into align_results

        script:
        index_base = index[0].toString() - ~/.\d.ht2/
        prefix = reads.toString() - ~/(\.fq)?(\.fastq)?(\.gz)?$/
        """
        hisat2 \
            -x ${index_base} \
            -U ${reads} \
            -p ${task.cpus} \
            1> /dev/null \
            2> ${prefix}.txt
        """
    }
}

/*
 * STEP 3 - quantify
 */
if( params.mapper == "salmon" && !params.skip ){
    process salmon_quant {
        tag "$reads"
        publishDir "${params.outdir}/quant"

        input:
        file reads from read_files_quant
        file index from quant_index.first()

        output:
        file "${prefix}" into quant_results

        script:
        prefix = reads.toString() - ~/(\.fq)?(\.fastq)?(\.gz)?$/
        """
        salmon quant \
            -i ${index} -l U \
            -r ${reads} \
            -p ${task.cpus} \
            -o ${prefix}
        """
    }
}

/*
 * STEP 4 - MultiQC
 */
if( !params.skip ){
process multiqc {
    tag "all samples"
    publishDir "${params.outdir}/multiqc", mode: 'copy'

    input:
    file ('fastqc/*') from fastqc_results.flatten().toList()
    file ('align/*') from align_results.flatten().toList()
    file ('quant/*') from quant_results.flatten().toList()

    output:
    file "*multiqc_report.html"
    file "*multiqc_data"

    script:
    """
    multiqc -f .
    """
}
}

workflow.onComplete {
    log.info "\nPipeline completed at: ${workflow.complete} (in ${workflow.duration})"
    log.info "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
}
