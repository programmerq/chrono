#!/usr/bin/env bash
# Build Project Chrono from a pinned upstream ref and package the install tree
# as a tarball release asset, plus an acceptance test that consumes the tarball
# exactly the way a downstream CI job would.
#
# Subcommands:
#   build.sh [build]        install deps, clone, compile, stage, sanity-check, package
#   build.sh consume-test   extract the tarball to /opt, build+run a hello project against it
#   build.sh notes          print release notes (manifest + consumption snippet) to stdout
#
# Parameters (environment variables):
#   CHRONO_REF      upstream git ref to build          (default: release/9.0)
#   VERSION_LABEL   upstream version label for the tag (default: 9.0.1)
#   RECIPE_REV      recipe revision r1, r2, ...        (default: r1)
#   JOBS            parallel build jobs                (default: 4)
#
# The build runs in the current working directory: upstream is cloned into
# ./chrono, built in ./build, staged under ./stage, and packaged as
# ./chrono-<version>-ubuntu24.04-<rev>.tar.zst.
#
# Upstream's installed chrono-config.cmake is NOT relocatable: it bakes
# absolute paths (include dirs, library paths, data dirs) derived from
# CMAKE_INSTALL_PREFIX at configure time. The artifact is therefore configured
# for its documented consume location /opt/chrono and staged with DESTDIR;
# consumers must extract the tarball to /opt.
set -euo pipefail

CHRONO_REF="${CHRONO_REF:-release/9.0}"
VERSION_LABEL="${VERSION_LABEL:-9.0.1}"
RECIPE_REV="${RECIPE_REV:-r1}"
JOBS="${JOBS:-4}"

OS_LABEL="ubuntu24.04"
TAG="chrono-${VERSION_LABEL}-${OS_LABEL}-${RECIPE_REV}"
TARBALL="${TAG}.tar.zst"
FINAL_PREFIX="/opt/chrono"
STAGE_ROOT="${PWD}/stage"
STAGED_PREFIX="${STAGE_ROOT}${FINAL_PREFIX}"
UPSTREAM_URL="https://github.com/projectchrono/chrono.git"

# Chrono 9.x uses ENABLE_MODULE_* while 10.x/main uses CH_ENABLE_MODULE_*.
# Pick the right prefix from upstream's source after cloning.
# USE_SIMD=OFF is required for redistribution: upstream's default injects
# -march=native into both the libraries and the exported consumer flags,
# which would make the binaries CPU-specific to the build host.
CONFIGURE_FLAGS_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_DEMOS=OFF
  -DBUILD_TESTING=OFF
  -DBUILD_BENCHMARKING=OFF
  -DUSE_SIMD=OFF
  "-DCMAKE_INSTALL_PREFIX=${FINAL_PREFIX}"
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

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_deps() {
  log "Installing dependencies"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${DEPS[@]}"
}

cmd_build() {
  install_deps

  log "Fetching ${UPSTREAM_URL} @ ${CHRONO_REF}"
  rm -rf chrono build stage
  rm -f "${TARBALL}"
  git clone --depth 1 --branch "${CHRONO_REF}" "${UPSTREAM_URL}" chrono
  local upstream_sha
  upstream_sha=$(git -C chrono rev-parse HEAD)

  # The tag asserts VERSION_LABEL; if upstream has a tag by that name it must
  # point at exactly what we are building, or the label would be a lie.
  local tag_sha
  tag_sha=$(git ls-remote "${UPSTREAM_URL}" "refs/tags/${VERSION_LABEL}" "refs/tags/${VERSION_LABEL}^{}" | tail -n1 | cut -f1)
  if [ -n "${tag_sha}" ] && [ "${tag_sha}" != "${upstream_sha}" ]; then
    die "upstream tag ${VERSION_LABEL} points at ${tag_sha}, but ${CHRONO_REF} is at ${upstream_sha}; build the tag itself or fix VERSION_LABEL"
  fi
  [ -n "${tag_sha}" ] || log "note: upstream has no tag '${VERSION_LABEL}'; trusting the operator-provided version label"

  local module_prefix
  if grep -q 'option(CH_ENABLE_MODULE_VEHICLE' chrono/CMakeLists.txt; then
    module_prefix="CH_ENABLE_MODULE"
  elif grep -q 'option(ENABLE_MODULE_VEHICLE' chrono/CMakeLists.txt; then
    module_prefix="ENABLE_MODULE"
  else
    die "could not detect Chrono module flag prefix in chrono/CMakeLists.txt"
  fi

  local configure_flags=(
    "${CONFIGURE_FLAGS_COMMON[@]}"
    "-D${module_prefix}_VEHICLE=ON"
    "-D${module_prefix}_IRRLICHT=ON"
  )

  log "Configuring"
  cmake -S chrono -B build "${configure_flags[@]}"

  log "Building (${JOBS} jobs)"
  cmake --build build -j"${JOBS}"

  log "Staging into ${STAGED_PREFIX} (DESTDIR install for prefix ${FINAL_PREFIX})"
  DESTDIR="${STAGE_ROOT}" cmake --install build

  log "Copying upstream license (required for binary redistribution)"
  install -m 644 chrono/LICENSE "${STAGED_PREFIX}/LICENSE"

  log "Sanity-checking the staged install tree"
  # CMake package config: locate it, don't assume its path.
  local config_files config_dir_rel
  mapfile -t config_files < <(find "${STAGED_PREFIX}" -name 'chrono-config.cmake' -o -name 'ChronoConfig.cmake')
  [ "${#config_files[@]}" -eq 1 ] ||
    die "expected exactly one Chrono CMake package config under ${STAGED_PREFIX}, found ${#config_files[@]}: ${config_files[*]:-none}"
  config_dir_rel=$(dirname "${config_files[0]#"${STAGED_PREFIX}"/}")

  # The config must reference the final prefix, never the staging directory.
  grep -q "${FINAL_PREFIX}/include" "${config_files[0]}" ||
    die "package config does not reference ${FINAL_PREFIX} — install prefix handling changed upstream?"
  ! grep -q "${STAGE_ROOT}" "${config_files[0]}" ||
    die "package config leaks the staging path ${STAGE_ROOT} — artifact would be unusable on consumer machines"

  # Core libraries.
  local engine_lib libdir
  engine_lib=$(find "${STAGED_PREFIX}" -name 'libChronoEngine.so' -print -quit)
  [ -n "${engine_lib}" ] || die "libChronoEngine.so not found under ${STAGED_PREFIX}"
  libdir=$(dirname "${engine_lib}")
  local lib
  for lib in libChronoEngine_vehicle.so libChronoEngine_irrlicht.so; do
    [ -e "${libdir}/${lib}" ] || die "${lib} not found in ${libdir}"
  done

  # Vehicle-models library (name may vary between versions: confirm and record).
  local models_libs
  models_libs=$(cd "${libdir}" && ls libChronoModels_vehicle*.so* 2>/dev/null || true)
  [ -n "${models_libs}" ] || die "vehicle-models library (libChronoModels_vehicle*.so) not found in ${libdir}"

  # No CPU-specific code: the artifact must run on any x86-64 host.
  ! grep -q 'march=native' "${config_files[0]}" ||
    die "package config still propagates -march=native — USE_SIMD=OFF did not take effect"

  # Runtime data tree (vehicle JSON etc.).
  local data_dir="${STAGED_PREFIX}/share/chrono/data"
  [ -d "${data_dir}" ] || die "data tree not found at ${data_dir}"
  find "${data_dir}/vehicle" -name '*.json' -print -quit 2>/dev/null | grep -q . ||
    die "no vehicle JSON data found under ${data_dir}/vehicle"

  log "Writing BUILD_MANIFEST.txt"
  local libstdcxx build_glibcxx artifact_glibcxx
  libstdcxx=$(g++ -print-file-name=libstdc++.so.6)
  [ -e "${libstdcxx}" ] || die "could not locate the build libstdc++ (g++ returned '${libstdcxx}')"
  build_glibcxx=$(strings -a "${libstdcxx}" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' | sort -uV | tail -n1) ||
    die "failed to read GLIBCXX symbol versions from ${libstdcxx}"
  artifact_glibcxx=$(objdump -T "${libdir}"/libChrono*.so* | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' | sort -uV | tail -n1) ||
    die "failed to read GLIBCXX requirements from the built libraries"
  cat > "${STAGED_PREFIX}/BUILD_MANIFEST.txt" <<EOF
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
simd_baseline=generic x86-64 (USE_SIMD=OFF, no -march flags)
configure_flags=${configure_flags[*]}
recipe_rev=${RECIPE_REV}
build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
install_prefix=${FINAL_PREFIX}
cmake_config_dir=${config_dir_rel}
chrono_libraries=$(cd "${libdir}" && ls libChrono*.so* | tr '\n' ' ')
EOF
  cat "${STAGED_PREFIX}/BUILD_MANIFEST.txt"

  log "Packaging ${TARBALL}"
  rm -f "${TARBALL}"
  tar -C "${STAGE_ROOT}/opt" -I 'zstd -19 -T0' -cf "${TARBALL}" chrono
  log "Done: ${TARBALL} ($(du -h "${TARBALL}" | cut -f1))"
}

cmd_consume_test() {
  [ -f "${TARBALL}" ] || die "${TARBALL} not found — run 'build.sh build' first"
  install_deps

  log "Extracting ${TARBALL} to /opt (the location baked into the package config)"
  if [ -e "${FINAL_PREFIX}" ]; then
    # Only ever remove a tree that a previous run of this pipeline put there.
    [ -f "${FINAL_PREFIX}/BUILD_MANIFEST.txt" ] ||
      die "${FINAL_PREFIX} exists and is not a previous consume-test extract; remove it manually"
    as_root rm -rf "${FINAL_PREFIX}"
  fi
  as_root tar -C /opt -I zstd -xf "${TARBALL}"

  local config_dir_rel
  config_dir_rel=$(sed -n 's/^cmake_config_dir=//p' "${FINAL_PREFIX}/BUILD_MANIFEST.txt")
  [ -n "${config_dir_rel}" ] || die "cmake_config_dir missing from BUILD_MANIFEST.txt"
  local chrono_dir="${FINAL_PREFIX}/${config_dir_rel}"

  log "Generating hello project"
  rm -rf consume-test
  mkdir -p consume-test/hello
  # Mirrors upstream's template_project/CMakeLists.txt consumer pattern.
  cat > consume-test/hello/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.18)
project(chrono_consume_test)
find_package(Chrono CONFIG REQUIRED COMPONENTS Vehicle Irrlicht)
set(CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD ${CHRONO_CXX_STANDARD})
include_directories(${CHRONO_INCLUDE_DIRS})
add_executable(hello main.cpp)
target_compile_definitions(hello PUBLIC "CHRONO_DATA_DIR=\"${CHRONO_DATA_DIR}\"")
target_compile_options(hello PUBLIC ${CHRONO_CXX_FLAGS})
target_link_options(hello PUBLIC ${CHRONO_LINKER_FLAGS})
target_link_libraries(hello ${CHRONO_LIBRARIES})
EOF
  cat > consume-test/hello/main.cpp <<'EOF'
#include <cstdio>
#include <filesystem>
#include <string>

#include "chrono/physics/ChSystemSMC.h"
#include "chrono_irrlicht/ChVisualSystemIrrlicht.h"
#include "chrono_vehicle/ChVehicleModelData.h"

int main() {
    chrono::ChSystemSMC sys;
    for (int i = 0; i < 10; i++)
        sys.DoStepDynamics(1e-3);
    if (sys.GetChTime() <= 0) {
        std::printf("FAIL: simulation did not advance\n");
        return 1;
    }

    // The data tree must exist at the path baked into the package config.
    const std::string data_dir = CHRONO_DATA_DIR;
    if (!std::filesystem::is_directory(data_dir) ||
        !std::filesystem::is_directory(data_dir + "vehicle")) {
        std::printf("FAIL: data tree missing at %s\n", data_dir.c_str());
        return 1;
    }

    // Touch the Vehicle and Irrlicht modules so their libraries must link.
    chrono::vehicle::SetDataPath(data_dir + "vehicle/");
    std::printf("vehicle data path: %s\n", chrono::vehicle::GetDataPath().c_str());
    chrono::irrlicht::ChVisualSystemIrrlicht vis;  // constructed, never Initialize()d: headless-safe

    std::printf("consume-test OK: t=%f data=%s\n", sys.GetChTime(), data_dir.c_str());
    return 0;
}
EOF

  log "Configuring hello project (Chrono_DIR=${chrono_dir})"
  cmake -S consume-test/hello -B consume-test/hello/build \
    -DCMAKE_BUILD_TYPE=Release "-DChrono_DIR=${chrono_dir}"

  log "Building hello project"
  cmake --build consume-test/hello/build -j"${JOBS}"

  log "Running hello project"
  LD_LIBRARY_PATH="${FINAL_PREFIX}/lib" ./consume-test/hello/build/hello

  log "Consume-test passed"
}

cmd_notes() {
  local manifest="${STAGED_PREFIX}/BUILD_MANIFEST.txt"
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
sudo tar -I zstd -xf chrono.tar.zst -C /opt   # must be /opt: absolute paths are baked into the CMake config
export Chrono_DIR=${FINAL_PREFIX}/${config_dir_rel}
export LD_LIBRARY_PATH=${FINAL_PREFIX}/lib:\${LD_LIBRARY_PATH:-}
# then: find_package(Chrono CONFIG REQUIRED COMPONENTS Vehicle Irrlicht)
\`\`\`

Runtime requirements on the consuming machine: an Ubuntu-24.04-compatible glibc/libstdc++ (>= the versions in BUILD_MANIFEST.txt), plus:
\`libirrlicht-dev libeigen3-dev libgl1-mesa-dev libglu1-mesa-dev libxxf86vm-dev libxext-dev libx11-dev freeglut3-dev\`

Binaries are toolchain-bound (ABI): check BUILD_MANIFEST.txt inside the tarball before linking against them on a different base image. Built with USE_SIMD=OFF (no -march=native), so they run on any x86-64 host.

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
