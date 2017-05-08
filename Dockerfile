# Base Image
FROM biocontainers/biocontainers:latest

# Metadata
LABEL base.image="biocontainers:latest"
LABEL version="2"
LABEL software="seqcheck-deps"
LABEL software.version="0.1"
LABEL description="dependencies for mini-pipeline to sanity check new sequencing data on Synapse"
LABEL website="https://github.com/jaeddy/seqcheck"
LABEL documentation="https://github.com/jaeddy/seqcheck"
LABEL license="https://github.com/jaeddy/seqcheck"
LABEL tags="Genomics"

# Maintainer
MAINTAINER James Eddy <james.a.eddy@gmail.com>

RUN conda config --add channels conda-forge && \
    conda config --add channels defaults && \
    conda config --add channels r && \
    conda config --add channels bioconda
RUN conda install fastqc=0.11.5 hisat2=2.0.5 salmon=0.8.2 multiqc=0.9.1
RUN pip install synapseclient==1.6.2
