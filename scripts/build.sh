#!/usr/bin/env bash
# Build Project Chrono from a pinned upstream ref and package the install tree
# as a tarball release asset, plus an acceptance test that consumes the tarball
# exactly the way a downstream CI job would.
#
# Subcommands:
#   build.sh [build]        install deps, clone, compile, stage, sanity-check, package
#   build.sh consume-test   extract the tarball, build+run a hello project against it
#   build.sh notes          print release notes (manifest + consumption snippet) to stdout
#
# Parameters (environment variables):
#   CHRONO_REF      upstream git ref to build          (default: release/9.0)
#   VERSION_LABEL   upstream version label for the tag (default: 9.0.1)
#   RECIPE_REV      recipe revision r1, r2, ...        (default: r1)
#   JOBS            parallel build jobs                (default: 4)
#
# Everything happens in the current working directory: upstream is cloned into
# ./chrono, built in ./build, installed into ./stage/chrono, and packaged as
# ./chrono-<version>-ubuntu24.04-<rev>.tar.zst.
set -euo pipefail

CHRONO_REF="${CHRONO_REF:-release/9.0}"
VERSION_LABEL="${VERSION_LABEL:-9.0.1}"
RECIPE_REV="${RECIPE_REV:-r1}"
JOBS="${JOBS:-4}"

OS_LABEL="ubuntu24.04"
TAG="chrono-${VERSION_LABEL}-${OS_LABEL}-${RECIPE_REV}"
TARBALL="${TAG}.tar.zst"
PREFIX="${PWD}/stage/chrono"
UPSTREAM_URL="https://github.com/projectchrono/chrono.git"

# Chrono 9.x flag names. Upstream 10.x renamed the module switches to
# CH_ENABLE_MODULE_*; use the renamed flags when adding a 10.x build.
CONFIGURE_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_MODULE_VEHICLE=ON
  -DENABLE_MODULE_IRRLICHT=ON
  -DBUILD_DEMOS=OFF
  -DBUILD_TESTING=OFF
  -DBUILD_BENCHMARKING=OFF
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
)

# Build deps; also the runtime deps a consuming machine needs (Irrlicht/GL are
# runtime links, Eigen is header-only at consumer compile time).
DEPS=(
  build-essential cmake git zstd
  libirrlicht-dev libeigen3-dev
  libgl1-mesa-dev libglu1-mesa-dev libxxf86vm-dev libxext-dev libx11-dev
  freeglut3-dev
)

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

install_deps() {
  local sudo_cmd=()
  if [ "$(id -u)" -ne 0 ]; then
    sudo_cmd=(sudo)
  fi
  log "Installing dependencies"
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update
  "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEPS[@]}"
}

cmd_build() {
  install_deps

  log "Fetching ${UPSTREAM_URL} @ ${CHRONO_REF}"
  rm -rf chrono build stage
  git clone --depth 1 --branch "${CHRONO_REF}" "${UPSTREAM_URL}" chrono
  local upstream_sha
  upstream_sha=$(git -C chrono rev-parse HEAD)

  log "Configuring"
  cmake -S chrono -B build "${CONFIGURE_FLAGS[@]}"

  log "Building (${JOBS} jobs)"
  cmake --build build -j"${JOBS}"

  log "Installing into ${PREFIX}"
  cmake --install build

  log "Copying upstream license (required for binary redistribution)"
  install -m 644 chrono/LICENSE "${PREFIX}/LICENSE"

  log "Sanity-checking the staged install tree"
  # CMake package config: locate it, don't assume its path.
  local config_files config_dir_rel
  mapfile -t config_files < <(find "${PREFIX}" -name 'chrono-config.cmake' -o -name 'ChronoConfig.cmake')
  [ "${#config_files[@]}" -eq 1 ] ||
    die "expected exactly one Chrono CMake package config under ${PREFIX}, found ${#config_files[@]}: ${config_files[*]:-none}"
  config_dir_rel=$(dirname "${config_files[0]#"${PREFIX}"/}")

  # Core libraries.
  local engine_lib libdir
  engine_lib=$(find "${PREFIX}" -name 'libChronoEngine.so' -print -quit)
  [ -n "${engine_lib}" ] || die "libChronoEngine.so not found under ${PREFIX}"
  libdir=$(dirname "${engine_lib}")
  local lib
  for lib in libChronoEngine_vehicle.so libChronoEngine_irrlicht.so; do
    [ -e "${libdir}/${lib}" ] || die "${lib} not found in ${libdir}"
  done

  # Vehicle-models library (name may vary between versions: confirm and record).
  local models_libs
  models_libs=$(cd "${libdir}" && ls libChronoModels_vehicle*.so* 2>/dev/null || true)
  [ -n "${models_libs}" ] || die "vehicle-models library (libChronoModels_vehicle*.so) not found in ${libdir}"

  # Runtime data tree (vehicle JSON etc.).
  local data_dir="${PREFIX}/share/chrono/data"
  [ -d "${data_dir}" ] || die "data tree not found at ${data_dir}"
  find "${data_dir}/vehicle" -name '*.json' -print -quit 2>/dev/null | grep -q . ||
    die "no vehicle JSON data found under ${data_dir}/vehicle"

  log "Writing BUILD_MANIFEST.txt"
  local libstdcxx build_glibcxx artifact_glibcxx
  libstdcxx=$(g++ -print-file-name=libstdc++.so.6)
  build_glibcxx=$(strings -a "${libstdcxx}" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' | sort -uV | tail -n1)
  artifact_glibcxx=$(objdump -T "${libdir}"/libChrono*.so* | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' | sort -uV | tail -n1)
  cat > "${PREFIX}/BUILD_MANIFEST.txt" <<EOF
tag=${TAG}
version_label=${VERSION_LABEL}
chrono_ref=${CHRONO_REF}
upstream_url=${UPSTREAM_URL}
upstream_sha=${upstream_sha}
os=ubuntu-24.04
gcc_version=$(gcc -dumpfullversion)
build_libstdcxx_max_glibcxx=${build_glibcxx}
artifact_required_max_glibcxx=${artifact_glibcxx}
enabled_modules=VEHICLE,IRRLICHT
configure_flags=${CONFIGURE_FLAGS[*]}
recipe_rev=${RECIPE_REV}
build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cmake_config_dir=${config_dir_rel}
chrono_libraries=$(cd "${libdir}" && ls libChrono*.so* | tr '\n' ' ')
EOF
  cat "${PREFIX}/BUILD_MANIFEST.txt"

  log "Packaging ${TARBALL}"
  rm -f "${TARBALL}"
  tar -C stage -I 'zstd -19 -T0' -cf "${TARBALL}" chrono
  log "Done: ${TARBALL} ($(du -h "${TARBALL}" | cut -f1))"
}

cmd_consume_test() {
  [ -f "${TARBALL}" ] || die "${TARBALL} not found — run 'build.sh build' first"
  install_deps

  log "Extracting ${TARBALL} into a scratch prefix"
  rm -rf consume-test
  mkdir -p consume-test
  tar -C consume-test -I zstd -xf "${TARBALL}"
  local prefix="${PWD}/consume-test/chrono"

  local config_dir_rel
  config_dir_rel=$(sed -n 's/^cmake_config_dir=//p' "${prefix}/BUILD_MANIFEST.txt")
  [ -n "${config_dir_rel}" ] || die "cmake_config_dir missing from BUILD_MANIFEST.txt"
  local chrono_dir="${prefix}/${config_dir_rel}"

  log "Generating hello project"
  mkdir -p consume-test/hello
  cat > consume-test/hello/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.18)
project(chrono_consume_test CXX)
find_package(Chrono CONFIG REQUIRED COMPONENTS Vehicle Irrlicht)
include_directories(${CHRONO_INCLUDE_DIRS})
add_executable(hello main.cpp)
set_target_properties(hello PROPERTIES
    COMPILE_FLAGS "${CHRONO_CXX_FLAGS}"
    LINK_FLAGS "${CHRONO_LINKER_FLAGS}")
target_link_libraries(hello ${CHRONO_LIBRARIES})
EOF
  cat > consume-test/hello/main.cpp <<'EOF'
#include <cstdio>

#include "chrono/physics/ChSystemSMC.h"
#include "chrono_irrlicht/ChVisualSystemIrrlicht.h"
#include "chrono_vehicle/ChVehicleModelData.h"

int main() {
    chrono::ChSystemSMC sys;
    for (int i = 0; i < 10; i++)
        sys.DoStepDynamics(1e-3);

    // Touch the Vehicle and Irrlicht modules so their libraries must link.
    chrono::vehicle::SetDataPath("data/vehicle/");
    std::printf("vehicle data path: %s\n", chrono::vehicle::GetDataPath().c_str());
    chrono::irrlicht::ChVisualSystemIrrlicht vis;  // no Initialize(): headless-safe

    std::printf("consume-test OK: t=%f\n", sys.GetChTime());
    return 0;
}
EOF

  log "Configuring hello project (Chrono_DIR=${chrono_dir})"
  cmake -S consume-test/hello -B consume-test/hello/build \
    -DCMAKE_BUILD_TYPE=Release "-DChrono_DIR=${chrono_dir}"

  log "Building hello project"
  cmake --build consume-test/hello/build -j"${JOBS}"

  log "Running hello project"
  local libdir
  libdir=$(dirname "$(find "${prefix}" -name 'libChronoEngine.so' -print -quit)")
  LD_LIBRARY_PATH="${libdir}" ./consume-test/hello/build/hello

  log "Consume-test passed"
}

cmd_notes() {
  local manifest="${PREFIX}/BUILD_MANIFEST.txt"
  [ -f "${manifest}" ] || die "${manifest} not found — run 'build.sh build' first"
  local repo="${GITHUB_REPOSITORY:-programmerq/chrono}"
  local config_dir_rel
  config_dir_rel=$(sed -n 's/^cmake_config_dir=//p' "${manifest}")

  cat <<EOF
Prebuilt [Project Chrono](https://github.com/projectchrono/chrono) ${VERSION_LABEL} binaries for Ubuntu 24.04, with the Vehicle and Irrlicht modules. Redistributed under upstream's BSD-3-Clause license (copy included in the tarball). Releases are immutable: this tag will never be overwritten; recipe changes get a new revision suffix.

## Consumption

\`\`\`bash
curl -fsSL -o chrono.tar.zst \\
  https://github.com/${repo}/releases/download/${TAG}/${TAG}.tar.zst
sudo tar -I zstd -xf chrono.tar.zst -C /opt
export Chrono_DIR=/opt/chrono/${config_dir_rel}
# then: find_package(Chrono CONFIG REQUIRED COMPONENTS Vehicle Irrlicht)
\`\`\`

Runtime requirements on the consuming machine: an Ubuntu-24.04-compatible glibc/libstdc++ (>= the versions in BUILD_MANIFEST.txt), plus:
\`libirrlicht-dev libeigen3-dev libgl1-mesa-dev libglu1-mesa-dev libxxf86vm-dev libxext-dev libx11-dev freeglut3-dev\`

Binaries are toolchain-bound (ABI): check BUILD_MANIFEST.txt inside the tarball before linking against them on a different base image.

## BUILD_MANIFEST.txt

\`\`\`
$(cat "${manifest}")
\`\`\`
EOF
}

case "${1:-build}" in
  build)        cmd_build ;;
  consume-test) cmd_consume_test ;;
  notes)        cmd_notes ;;
  *)            die "unknown subcommand: $1 (expected: build | consume-test | notes)" ;;
esac
