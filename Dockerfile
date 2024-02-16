FROM ubuntu:jammy-20230804 AS unsquashed_rocm_gfx1012_pytorch

# Add needle tools
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
RUN apt update && \
    apt full-upgrade -y && \
    apt install -y build-essential curl git git-lfs sudo libjpeg-dev libpng-dev \
        ccache ffmpeg libavdevice-dev libavfilter-dev libavformat-dev libavcodec-dev libavutil-dev repo && \
    apt-get install -y --no-install-recommends dpkg-dev gcc gnupg libbluetooth-dev libbz2-dev libc6-dev \
        libdb-dev libexpat1-dev libffi-dev libgdbm-dev liblzma-dev libncursesw5-dev libreadline-dev \
        libsqlite3-dev libssl-dev make tk-dev uuid-dev wget xz-utils zlib1g-dev

# Install new python
RUN wget -O python.tar.xz "https://www.python.org/ftp/python/3.12.2/Python-3.12.2.tar.xz" && \
    mkdir -p /usr/src/python && \
    tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz && rm python.tar.xz

RUN dpkg-buildflags --get LDFLAGS
WORKDIR /usr/src/python
RUN ./configure \
    --enable-loadable-sqlite-extensions \
    --enable-optimizations \
    --enable-option-checking=fatal \
    --enable-shared \
    --with-lto \
    --with-system-expat \
    --without-ensurepip && \
    nproc="$(nproc)" && \
    EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)" && \
    LDFLAGS="$(dpkg-buildflags --get LDFLAGS)" && \
    LDFLAGS="${LDFLAGS:--Wl},--strip-all" && \
    make -j "$nproc" \
        "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
        "LDFLAGS=${LDFLAGS:-}" \
        "PROFILE_TASK=${PROFILE_TASK:-}" && \
    rm python && \
    make -j "$nproc" \
        "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
        "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
        "PROFILE_TASK=${PROFILE_TASK:-}" \
        python && \
    make install && \
    cd / && rm -rf /usr/src/python

RUN set -eux; \
    for src in idle3 pydoc3 python3 python3-config; do \
        dst="$(echo "$src" | tr -d 3)"; \
        [ -s "/usr/local/bin/$src" ]; \
        [ ! -e "/usr/local/bin/$dst" ]; \
        ln -svT "$src" "/usr/local/bin/$dst"; \
    done

# Totally replace system python with new one
RUN rm -rf /usr/bin/python /usr/bin/python3 /usr/bin/python3-config /usr/bin/python-config /usr/bin/pydoc3 /usr/bin/pydoc && \
    ln -s /usr/local/bin/python /usr/bin/python && \
    ln -s /usr/local/bin/python3 /usr/bin/python3 && \
    ln -s /usr/local/bin/python3-config /usr/bin/python3-config && \
    ln -s /usr/local/bin/python-config /usr/bin/python-config && \
    ln -s /usr/local/bin/pydoc3 /usr/bin/pydoc3 && \
    ln -s /usr/local/bin/pydoc /usr/bin/pydoc

RUN python3 --version
RUN python --version

# Install new pip
ENV PYTHON_PIP_VERSION 24.0
ENV PYTHON_GET_PIP_URL https://github.com/pypa/get-pip/raw/dbf0c85f76fb6e1ab42aa672ffca6f0a675d9ee4/public/get-pip.py
RUN wget -O get-pip.py "$PYTHON_GET_PIP_URL" && \
    python get-pip.py \
        --disable-pip-version-check \
        --no-cache-dir \
        --no-compile \
        "pip==$PYTHON_PIP_VERSION" && \
    rm -f get-pip.py

# Totally replace system pip with new one
RUN rm -rf /usr/bin/pip /usr/bin/pip3 && \
    ln -s /usr/local/bin/pip /usr/bin/pip && \
    ln -s /usr/local/bin/pip3 /usr/bin/pip3

RUN pip --version

# Add groups and user
RUN groupadd -g 105 render && \
    useradd --create-home -G render,video --shell /bin/bash jenkins && \
    echo "jenkins ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/jenkins

USER jenkins
WORKDIR /home/jenkins

# Clone ROCm using repo
RUN mkdir -p /home/jenkins/ROCm/
WORKDIR /home/jenkins/ROCm/
RUN repo init -u https://github.com/RadeonOpenCompute/ROCm.git -b roc-5.4.x && \
    repo sync

# Get needle version of cmake
WORKDIR /home/jenkins/
RUN curl https://cmake.org/files/v3.18/cmake-3.18.6-Linux-x86_64.tar.gz | tar xz

# Clone script to build ROCm
WORKDIR /home/jenkins/
RUN git clone https://github.com/xuhuisheng/rocm-build.git
WORKDIR /home/jenkins/rocm-build
RUN git checkout 59b87dc62972c1ad32a8862e9ea6b5921c1f33a0 && \
    chmod a+x /home/jenkins/rocm-build/*.sh && \
    chmod a+x /home/jenkins/rocm-build/navi14/*.sh && \
    sed -i "s@sudo @@g" /home/jenkins/rocm-build/install-dependency.sh

# Add fixed patch for ROCm rocsparse
COPY ./25.rocsparse-gfx10-1.patch /home/jenkins/rocm-build/patch/25.rocsparse-gfx10-1.patch

# Apply custom patch for ROCm rccl
COPY rccl.patch /home/jenkins/rocm-build/patch/rccl.patch
WORKDIR /home/jenkins/ROCm/rccl
RUN git apply /home/jenkins/rocm-build/patch/rccl.patch
WORKDIR /home/jenkins/rocm-build

# Set correct environments
ENV ROCM_INSTALL_DIR=/opt/rocm
ENV ROCM_MAJOR_VERSION=5
ENV ROCM_MINOR_VERSION=4
ENV ROCM_PATCH_VERSION=3
ENV ROCM_LIBPATCH_VERSION=50403
ENV CPACK_DEBIAN_PACKAGE_RELEASE=72~20.04
ENV ROCM_PKGTYPE=DEB
ENV ROCM_GIT_DIR=/home/jenkins/ROCm
ENV ROCM_BUILD_DIR=/home/jenkins/rocm-build/build
ENV ROCM_PATCH_DIR=/home/jenkins/rocm-build/patch
ENV AMDGPU_TARGETS="gfx1012"
ENV CMAKE_DIR=/home/jenkins/cmake-3.18.6-Linux-x86_64
ENV PATH=$ROCM_INSTALL_DIR/bin:$ROCM_INSTALL_DIR/llvm/bin:$ROCM_INSTALL_DIR/hip/bin:$CMAKE_DIR/bin:$PATH

USER root

# Install dependencies
RUN /home/jenkins/rocm-build/install-dependency.sh

# Install rocm-dev packages that already have partial support
RUN mkdir --parents --mode=0755 /etc/apt/keyrings && \
    curl https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null && \
    echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/5.4.3 jammy main' | tee /etc/apt/sources.list.d/rocm.list && \
    printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600' | tee /etc/apt/preferences.d/rocm-pin-600 && \
    apt update && \
    apt full-upgrade -y && \
    apt install -y rocm-dev rocprim hipblas miopen-hip hipfft hipsparse hipcub hipfort hipsolver rocthrust

USER jenkins

# Re-build some ROCm components
RUN /home/jenkins/rocm-build/navi14/22.rocblas.sh && \
    /home/jenkins/rocm-build/21.rocfft.sh && \
    /home/jenkins/rocm-build/24.rocrand.sh && \
    /home/jenkins/rocm-build/navi14/25.rocsparse.sh && \
    /home/jenkins/rocm-build/28.rccl.sh

WORKDIR /home/jenkins/

# Clone PyTorch
RUN git clone --depth 1 --branch v2.2.0 --recursive https://github.com/pytorch/pytorch.git
WORKDIR /home/jenkins/pytorch
# RUN git submodule sync && \
#     git submodule update --init --recursive

# Build PyTorch
ENV PYTORCH_ROCM_ARCH=gfx1012
ENV USE_ROCM=1
ENV ROCM_PATH="/opt/rocm-5.4.3"
RUN pip install -r requirements.txt && \
    python3 tools/amd_build/build_amd.py && \
    python3 setup.py install --user

# Clone and build PyTorch Vision
WORKDIR /home/jenkins
RUN git clone --depth 1 --branch v0.17.0 https://github.com/pytorch/vision.git
WORKDIR /home/jenkins/vision
RUN python3 setup.py install --user

# Clone and build PyTorch audio
WORKDIR /home/jenkins
RUN git clone --depth 1 --branch v2.2.0 https://github.com/pytorch/audio.git
WORKDIR /home/jenkins/audio
ENV USE_FFMPEG=1
RUN pip install -r requirements.txt && \
    python3 setup.py install --user

# Clone PyTorch examples (to test)
WORKDIR /home/jenkins/
RUN git clone https://github.com/pytorch/examples.git
RUN cp -r /home/jenkins/examples/mnist /home/jenkins

# Clean sources
RUN rm -rf /home/jenkins/audio /home/jenkins/vision /home/jenkins/pytorch /home/jenkins/examples/ \
    /home/jenkins/ROCm/ /home/jenkins/cmake-3.18.6-Linux-x86_64 /home/jenkins/rocm-build

FROM scratch AS rocm_gfx1012_pytorch

COPY --from=unsquashed_rocm_gfx1012_pytorch / /

USER jenkins
WORKDIR /home/jenkins/mnist
# Run Mnist test
ENTRYPOINT [ "python", "main.py" ]
# ENTRYPOINT [ "tail", "-f", "/dev/null" ]
