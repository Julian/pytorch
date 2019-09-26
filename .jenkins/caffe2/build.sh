#!/bin/bash

set -ex

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# TODO: Migrate all centos jobs to use proper devtoolset
if [[ "$BUILD_ENVIRONMENT" == *py2-cuda9.0-cudnn7-centos7* ]]; then
  # There is a bug in pango packge on Centos7 that causes undefined
  # symbols, upgrading glib2 to >=2.56.1 solves the issue. See
  # https://bugs.centos.org/view.php?id=15495
  sudo yum install -y -q glib2-2.56.1
fi

# CMAKE_ARGS are only passed to 'cmake' and the -Dfoo=bar does not work with
# setup.py, so we build a list of foo=bars and then either convert it to
# -Dfoo=bars or export them before running setup.py
build_args=()
build_to_cmake () {
  cmake_args=()
  for build_arg in $*; do
    cmake_args+=("-D$build_arg")
  done
  echo ${cmake_args[@]}
}


SCCACHE="$(which sccache)"
if [ "$(which gcc)" != "/root/sccache/gcc" ]; then
  # Setup SCCACHE
  ###############################################################################
  # Setup sccache if SCCACHE_BUCKET is set
  if [ -n "${SCCACHE_BUCKET}" ]; then
    mkdir -p ./sccache

    SCCACHE="$(which sccache)"
    if [ -z "${SCCACHE}" ]; then
      echo "Unable to find sccache..."
      exit 1
    fi

    # Setup wrapper scripts
    wrapped="cc c++ gcc g++ x86_64-linux-gnu-gcc"
    if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]]; then
        wrapped="$wrapped nvcc"
    fi
    for compiler in $wrapped; do
      (
        echo "#!/bin/sh"

        # TODO: if/when sccache gains native support for an
        # SCCACHE_DISABLE flag analogous to ccache's CCACHE_DISABLE,
        # this can be removed. Alternatively, this can be removed when
        # https://github.com/pytorch/pytorch/issues/13362 is fixed.
        #
        # NOTE: carefully quoted - we want `which compiler` to be
        # resolved as we execute the script, but SCCACHE_DISABLE and
        # $@ to be evaluated when we execute the script
        echo 'test $SCCACHE_DISABLE && exec '"$(which $compiler)"' "$@"'

        echo "exec $SCCACHE $(which $compiler) \"\$@\""
      ) > "./sccache/$compiler"
      chmod +x "./sccache/$compiler"
    done

    export CACHE_WRAPPER_DIR="$PWD/sccache"

    # CMake must find these wrapper scripts
    export PATH="$CACHE_WRAPPER_DIR:$PATH"
  fi
fi

# Setup ccache if configured to use it (and not sccache)
if [ -z "${SCCACHE}" ] && which ccache > /dev/null; then
  mkdir -p ./ccache
  ln -sf "$(which ccache)" ./ccache/cc
  ln -sf "$(which ccache)" ./ccache/c++
  ln -sf "$(which ccache)" ./ccache/gcc
  ln -sf "$(which ccache)" ./ccache/g++
  ln -sf "$(which ccache)" ./ccache/x86_64-linux-gnu-gcc
  if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]]; then
    ln -sf "$(which ccache)" ./ccache/nvcc
  fi
  export CACHE_WRAPPER_DIR="$PWD/ccache"
  export PATH="$CACHE_WRAPPER_DIR:$PATH"
fi

# sccache will fail for CUDA builds if all cores are used for compiling
if [ -z "$MAX_JOBS" ]; then
  if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]] && [ -n "${SCCACHE}" ]; then
    MAX_JOBS=`expr $(nproc) - 1`
  else
    MAX_JOBS=$(nproc)
  fi
fi

report_compile_cache_stats() {
  if [[ -n "${SCCACHE}" ]]; then
    "$SCCACHE" --show-stats
  elif which ccache > /dev/null; then
    ccache -s
  fi
}


###############################################################################
# Use special scripts for Android and setup builds
###############################################################################
if [[ "${BUILD_ENVIRONMENT}" == *-android* ]]; then
  export ANDROID_NDK=/opt/ndk
  build_args+=("BUILD_BINARY=ON")
  build_args+=("BUILD_TEST=ON")
  build_args+=("USE_OBSERVERS=ON")
  build_args+=("USE_ZSTD=ON")
  "${ROOT_DIR}/scripts/build_android.sh" $(build_to_cmake ${build_args[@]}) "$@"
  exit 0
fi

###############################################################################
# Set parameters
###############################################################################
if [[ "$BUILD_ENVIRONMENT" == *cmake* ]]; then
  build_args+=("BUILD_PYTHON=OFF")
else
  build_args+=("BUILD_PYTHON=ON")
  build_args+=("PYTHON_EXECUTABLE=${PYTHON}")
fi
if [[ $BUILD_ENVIRONMENT == *mkl* ]]; then
  build_args+=("BLAS=MKL")
  build_args+=("USE_MKLDNN=ON")
fi
build_args+=("BUILD_BINARY=ON")
build_args+=("BUILD_TEST=ON")
build_args+=("INSTALL_TEST=ON")
build_args+=("USE_ZSTD=ON")

if [[ $BUILD_ENVIRONMENT == *cuda* ]]; then
  build_args+=("USE_CUDA=ON")
  build_args+=("USE_NNPACK=OFF")

  # Target only our CI GPU machine's CUDA arch to speed up the build
  build_args+=("TORCH_CUDA_ARCH_LIST=Maxwell")

  # Explicitly set path to NVCC such that the symlink to ccache or sccache is used
  if [ -n "${CACHE_WRAPPER_DIR}" ]; then
    build_args+=("CUDA_NVCC_EXECUTABLE=${CACHE_WRAPPER_DIR}/nvcc")
  fi

  # Ensure FindCUDA.cmake can infer the right path to the CUDA toolkit.
  # Setting PATH to resolve to the right nvcc alone isn't enough.
  # See /usr/share/cmake-3.5/Modules/FindCUDA.cmake, block at line 589.
  export CUDA_PATH="/usr/local/cuda"

  # Ensure the ccache symlink can still find the real nvcc binary.
  export PATH="/usr/local/cuda/bin:$PATH"
fi

if [[ $BUILD_ENVIRONMENT == *caffe2-py3.5-cuda10.1-cudnn7-ubuntu16.04* ]]; then
  # removing http:// duplicate in favor of nvidia-ml.list
  # which is https:// version of the same repo
#  sudo rm -f /etc/apt/sources.list.d/nvidia-machine-learning.list
#  sudo apt-get -qq update
#  sudo apt-get install -y --no-install-recommends python3
#  export ANACONDA_VERSION=3
#  sudo -E ./docker/caffe2/jenkins/common/install_anaconda.sh
#  . /opt/conda/etc/profile.d/conda.sh
#  export PATH=/opt/conda/bin:$PATH
#  LIB_FOLDER="https://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1604/x86_64"
#  declare -a TRT_DEBS
#  TRT_DEBS=("libnvinfer6_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvinfer-dev_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvinfer-plugin6_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvinfer-plugin-dev_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvonnxparsers6_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvonnxparsers-dev_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvparsers6_6.0.1-1+cuda10.1_amd64.deb"
#    "libnvparsers-dev_6.0.1-1+cuda10.1_amd64.deb"
#    "python3-libnvinfer-dev_6.0.1-1+cuda10.1_amd64.deb"
#    "python3-libnvinfer_6.0.1-1+cuda10.1_amd64.deb")
#
#
#  for l in "${TRT_DEBS[@]}"
#  do
#     curl -L -k -o ./$l $LIB_FOLDER/$l
#  done
#  sudo dpkg -i *.deb
#  for l in "${TRT_DEBS[@]}"
#  do
#     rm "$l"
#  done

  curl -L -k -o ./cmake-3.14.6-Linux-x86_64.tar.gz https://github.com/Kitware/CMake/releases/download/v3.14.6/cmake-3.14.6-Linux-x86_64.tar.gz
  tar -xzf cmake-3.14.6-Linux-x86_64.tar.gz
  rm cmake-3.14.6-Linux-x86_64.tar.gz
  export PATH=$(pwd)/cmake-3.14.6-Linux-x86_64/bin/:$PATH

  curl -L -k -o TRT6.tar.gz https://github.com/NVIDIA/TensorRT/archive/v6.0.1.tar.gz
  tar -xzf TRT6.tar.gz
  cd TensorRT-6.0.1
  export TRT_LIB_DIR=/opt/trt6/lib
  export TRT_BIN_DIR=/opt/trt6/bin
  mkdir -p build && cd build
  cmake .. -DTRT_LIB_DIR=$TRT_LIB_DIR/lib -DTRT_BIN_DIR=TRT_BIN_DIR -DCUDA_VERISON=10.1
  make -j$(nproc)
  sudo make install
  cd ../../

  # building OSS release of ONNX parser on top of just installed
  git clone --depth 1 --branch release/6.0 https://github.com/onnx/onnx-tensorrt.git
  cd onnx-tensorrt/
  git submodule update --init --recursive
  cd third_party/onnx
  git checkout v1.5.0
  cd ../../
  mkdir build
  cd build
  cmake ..
  CPLUS_INCLUDE_PATH=/usr/local/cuda/include make -j$(nproc)
  sudo make install
  cd ../../
  rm -rf onnx-tensorrt/

  build_args+=("USE_TENSORRT=ON")
fi

if [[ $BUILD_ENVIRONMENT == *rocm* ]]; then
  build_args+=("USE_ROCM=ON")
  # This is needed to enable ImageInput operator in resnet50_trainer
  build_args+=("USE_OPENCV=ON")
  # This is needed to read datasets from https://download.caffe2.ai/databases/resnet_trainer.zip
  build_args+=("USE_LMDB=ON")
  # When hcc runs out of memory, it silently exits without stopping
  # the build process, leaving undefined symbols in the shared lib
  # which will cause undefined symbol errors when later running
  # tests. Setting MAX_JOBS to smaller number to make CI less flaky.
  export MAX_JOBS=4

  ########## HIPIFY Caffe2 operators
  ${PYTHON} "${ROOT_DIR}/tools/amd_build/build_amd.py"
fi

# building bundled nccl in this config triggers a bug in nvlink. For
# more, see https://github.com/pytorch/pytorch/issues/14486
if [[ "${BUILD_ENVIRONMENT}" == *-cuda8*-cudnn7* ]]; then
    build_args+=("USE_SYSTEM_NCCL=ON")
fi

# Try to include Redis support for Linux builds
if [ "$(uname)" == "Linux" ]; then
  build_args+=("USE_REDIS=ON")
fi

# Use a speciallized onnx namespace in CI to catch hardcoded onnx namespace
build_args+=("ONNX_NAMESPACE=ONNX_NAMESPACE_FOR_C2_CI")

###############################################################################
# Configure and make
###############################################################################

if [[ "$BUILD_ENVIRONMENT" == *cmake* ]]; then
  # cmake-only non-setup.py build, to test cpp only bits. This installs into
  # /usr/local/caffe2 and installs no Python tests
  build_args+=("CMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}")

  # Run cmake from ./build_caffe2 directory so it doesn't conflict with
  # standard PyTorch build directory. Eventually these won't need to
  # be separate.
  rm -rf build_caffe2
  mkdir build_caffe2
  cd ./build_caffe2

  # We test the presence of cmake3 (for platforms like Centos and Ubuntu 14.04)
  # and use that if so.
  if [[ -x "$(command -v cmake3)" ]]; then
      CMAKE_BINARY=cmake3
  else
      CMAKE_BINARY=cmake
  fi

  # Configure
  ${CMAKE_BINARY} "${ROOT_DIR}" $(build_to_cmake ${build_args[@]}) "$@"

  # Build
  if [ "$(uname)" == "Linux" ]; then
    make "-j${MAX_JOBS}" install
  else
    echo "Don't know how to build on $(uname)"
    exit 1
  fi

  # This is to save test binaries for testing
  mv "$INSTALL_PREFIX/test/" "$INSTALL_PREFIX/cpp_test/"

  ls -lah $INSTALL_PREFIX

else
  # Python build. Uses setup.py to install into site-packages
  build_args+=("USE_LEVELDB=ON")
  build_args+=("USE_LMDB=ON")
  build_args+=("USE_OPENCV=ON")
  build_args+=("BUILD_TEST=ON")
  # These flags preserve the flags that were used before this refactor (blame
  # me)
  build_args+=("USE_GLOG=ON")
  build_args+=("USE_GFLAGS=ON")
  build_args+=("USE_FBGEMM=OFF")
  build_args+=("USE_MKLDNN=OFF")
  build_args+=("USE_DISTRIBUTED=ON")
  for build_arg in "${build_args[@]}"; do
    export $build_arg
  done

  # sccache will be stuck if  all cores are used for compiling
  # see https://github.com/pytorch/pytorch/pull/7361
  if [[ -n "${SCCACHE}" && $BUILD_ENVIRONMENT != *rocm* ]]; then
    export MAX_JOBS=`expr $(nproc) - 1`
  fi

  $PYTHON setup.py install --user

  report_compile_cache_stats
fi

###############################################################################
# Install ONNX
###############################################################################

# Install ONNX into a local directory
pip install --user -b /tmp/pip_install_onnx "file://${ROOT_DIR}/third_party/onnx#egg=onnx"

if [[ $BUILD_ENVIRONMENT == *rocm* ]]; then
  # runtime compilation of MIOpen kernels manages to crash sccache - hence undo the wrapping
  bash tools/amd_build/unwrap_clang.sh
fi

report_compile_cache_stats
