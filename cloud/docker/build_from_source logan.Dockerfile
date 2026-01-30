FROM ubuntu:24.04

RUN apt-get update 
RUN apt-get install -y git python3 python3-pip

# Compile diamond from source for speed
RUN apt-get install -y cmake g++ make wget libpthread-stubs0-dev zlib1g-dev
# 2.1.11 is newest. Seems to have issues with some fastq files, but singlem always pipes in fasta so should be fine? Doesn't appear to be fine in practice, so downgrading.
ENV DIAMOND_VERSION 2.1.16
RUN cd /tmp && wget http://github.com/bbuchfink/diamond/archive/v$DIAMOND_VERSION.tar.gz
RUN cd /tmp && tar xzf v$DIAMOND_VERSION.tar.gz
RUN cd /tmp/diamond-$DIAMOND_VERSION && mkdir bin
RUN cd /tmp/diamond-$DIAMOND_VERSION/bin && cmake .. && make -j4
RUN cd /tmp/diamond-$DIAMOND_VERSION/bin && cp diamond /usr/local/bin/
RUN rm -rf /tmp/diamond-$DIAMOND_VERSION /tmp/v$DIAMOND_VERSION.tar.gz

# OrfM
RUN cd /tmp && wget https://github.com/wwood/OrfM/releases/download/v0.7.1/orfm-0.7.1.tar.gz
RUN cd /tmp && tar xzf orfm-0.7.1.tar.gz
RUN cd /tmp/orfm-0.7.1 && ./configure && make && cp orfm /usr/local/bin/
RUN rm -rf /tmp/orfm-0.7.1 /tmp/orfm-0.7.1.tar.gz

# hmmer
RUN cd /tmp && wget http://eddylab.org/software/hmmer/hmmer-3.4.tar.gz
RUN cd /tmp && tar xzf hmmer-3.4.tar.gz
RUN cd /tmp/hmmer-3.4 && ./configure && make
#make check && make install
RUN cd /tmp/hmmer-3.4 && make check && make install
RUN rm -rf /tmp/hmmer-3.4 /tmp/hmmer-3.4.tar.gz

# install further deps
RUN apt-get install -y python3-numpy python3-pandas
RUN pip install --no-dependencies --break-system-packages bird_tool_utils argparse-manpage-birdtools extern zenodo_backpack
RUN apt-get install -y python3-requests
RUN apt-get install -y python3-tqdm
# RUN apt-get install -y python3-biopython # Brings kitchen sink, maybe not available on ARM?
RUN pip install --no-dependencies --break-system-packages biopython
RUN apt-get install -y python3-sqlalchemy
# above, the symlink that is created is wrong. But we can just use the pypi version anyway.
# RUN pip install --no-dependencies --break-system-packages kingfisher # Not needed for logan
RUN pip install --no-dependencies --break-system-packages graftm

RUN apt install curl
    
WORKDIR /

# singlem dependencies and data
COPY S5.4.0.GTDB_r226.metapackage_20250331.slim.smpkg /mpkg

# NOTE: The following 2 hashes should be changed in sync. Note that the version must comply with PEP440 otherwise pip will not install it below (but now we aren't using pip?).
ENV SINGLEM_COMMIT 757f62de
ENV SINGLEM_VERSION 0.20.3.post1
RUN rm -rf singlem && git init singlem && cd singlem && git remote add origin https://github.com/wwood/singlem && git fetch origin && git checkout $SINGLEM_COMMIT
# __version__ = {"singlem": "0.18.3", "lyrebird": "0.2.0"}
RUN echo '__version__ = "'$SINGLEM_VERSION.${SINGLEM_COMMIT}'"' >singlem/singlem/version.py
RUN ln -s /singlem/bin/singlem /usr/local/bin/singlem

# Remove bundled singlem packages
RUN rm -rfv singlem/singlem/data singlem/.git singlem/test singlem/appraise_plot.png

## AWS cli
RUN apt install -y curl unzip
RUN cd /tmp && wget "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -O "awscliv2.zip" && unzip awscliv2.zip && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && rm -rf /tmp/awscliv2.zip /tmp/aws

# Test aws s3 copy and context-window in working order
RUN aws s3 cp s3://logan-pub/c/SRR8653040/SRR8653040.contigs.fa.zst . --no-sign-request
RUN apt install -y zstd
RUN python3 /singlem/singlem/main.py pipe --sequences SRR8653040.contigs.fa.zst --no-assign-taxonomy --metapackage /mpkg --archive-otu-table /tmp/a.json --threads 4 --read-chunk-size 200000 --read-chunk-num 1 --context-window 1000
RUN rm /tmp/a.json SRR8653040.contigs.fa.zst

# Dependencies required here so polars doesn't complain "UserWarning: Polars binary is missing!"
RUN pip install --break-system-packages polars

# Clean apt-get files to try to make it smaller
RUN rm -rf /var/lib/apt/lists/*
RUN apt-get clean

# Look for space savings. There are some things e.g. AWS bundles python, and gcc
# probably isn't needed any more, but not worth the effort of debugging

# COPY dust-v0.8.6-x86_64-unknown-linux-gnu/dust /usr/local/bin/dust
# RUN chmod +x /usr/local/bin/dust
# RUN dust -n 60 / && fail

RUN chmod +x /singlem/singlem/main.py
RUN ln -s /singlem/singlem/main.py /usr/bin/singlem
# RUN cd /tmp && python3 /singlem/extras/singlem_an_sra.py --sra-identifier SRR8653040 --metapackage /mpkg

# Attempt to reduce image size
FROM scratch
COPY --from=0 / /
