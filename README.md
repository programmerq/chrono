# chrono — prebuilt Project Chrono binaries

Prebuilt Linux binaries of [Project Chrono](https://github.com/projectchrono/chrono), the C++
multibody physics engine, published as tarball assets on this repository's
[GitHub Releases](https://github.com/programmerq/chrono/releases).

This is an independent build/publish pipeline, not affiliated with or endorsed by Project
Chrono, and not a fork: no Chrono source lives here. Upstream is cloned at a pinned ref at
build time, compiled, and only the packaged result is published. The binaries are
redistributed under upstream's BSD-3-Clause license; a copy is included in every tarball.

Why this exists: upstream ships Linux as source-only — there is no binary C++ distribution
that includes the Vehicle and Irrlicht modules. Downstream C++ projects that link those
modules pay a 20–40 minute source build in their CI; a pinned binary release removes that.
Upstream releases roughly yearly, so a published artifact stays current a long time.

## Consuming a release

The exact steps a CI job runs:

```bash
curl -fsSL -o chrono.tar.zst \
  https://github.com/programmerq/chrono/releases/download/chrono-9.0.1-ubuntu24.04-r1/chrono-9.0.1-ubuntu24.04-r1.tar.zst
sudo tar -I zstd -xf chrono.tar.zst -C /opt
export Chrono_DIR=/opt/chrono/lib/cmake/Chrono   # authoritative path: cmake_config_dir in BUILD_MANIFEST.txt
export LD_LIBRARY_PATH=/opt/chrono/lib:${LD_LIBRARY_PATH:-}
# then: find_package(Chrono CONFIG REQUIRED COMPONENTS Vehicle Irrlicht)
```

The tarball **must be extracted to `/opt`** (yielding `/opt/chrono`): upstream's installed
`chrono-config.cmake` is not relocatable — it bakes absolute include, library, and data
paths derived from the configured install prefix, so the binaries are built for exactly
that location.

Each tarball contains an install tree:

```
chrono/
  BUILD_MANIFEST.txt     # what was built, from what, with what — including the CMake config dir
  LICENSE                # upstream's BSD-3-Clause license
  include/chrono/...
  lib/                   # libChronoEngine*.so + the CMake package-config dir
  share/chrono/data/...  # runtime data files (vehicle JSON etc.)
```

### Runtime requirements on the consuming machine

- An Ubuntu-24.04-compatible glibc/libstdc++ (>= the versions recorded in
  `BUILD_MANIFEST.txt` inside the tarball).
- Packages:
  `libirrlicht-dev libeigen3-dev libgl1-mesa-dev libglu1-mesa-dev libxxf86vm-dev libxext-dev libx11-dev freeglut3-dev`
  (Irrlicht and GL are runtime links; Eigen is compile-time and header-only for consumers).

### ABI note

C++ binaries are toolchain-bound. These are built on Ubuntu 24.04 with its stock gcc;
consumers should check `BUILD_MANIFEST.txt` inside the tarball for the exact compiler and
libstdc++ symbol versions. A consumer on an older or different base needs its own
OS-labelled release, not this one.

The libraries are built with `USE_SIMD=OFF`: upstream's default injects `-march=native`,
which would tie the binaries to the build machine's CPU. These binaries run on any x86-64
host (at a modest single-core performance cost versus a native-tuned source build).

## Tag scheme

```
chrono-<version>-ubuntu24.04-<rev>        e.g. chrono-9.0.1-ubuntu24.04-r1
```

- `<version>` — upstream Chrono version label.
- `ubuntu24.04` — the OS the binaries were built on. Part of the name because C++ binaries
  are ABI-bound to the build OS/toolchain; a consumer on a different base gets its own
  OS-labelled build, never a silently reused one.
- `<rev>` — recipe revision (`r1`, `r2`, …): bumped when the build recipe changes for the
  same upstream version.

**Releases are immutable.** An existing tag or asset is never overwritten or re-uploaded;
a changed recipe is published as a new `<rev>`.

## Publishing (maintainers)

Two paths, both ending in the same pipeline — build via
[`scripts/build.sh`](scripts/build.sh), prove the tarball is usable by compiling, linking,
and running a minimal consumer project against the extracted artifact, and only then
create the release:

- **Manual:** Actions → **publish** → *Run workflow*, with inputs
  `chrono_ref` / `version_label` / `recipe_rev`. Use this for recipe-revision bumps
  (`r2`, `r3`, …) and for refs that aren't plain upstream release tags.
- **Automatic:** the **check-upstream** workflow runs weekly (Mondays 06:17 UTC), on
  every push to `main`, and on manual dispatch. It compares upstream's release tags
  (from `9.0.1` up) against
  the `chrono-*-ubuntu24.04-*` tags already published here and builds every missing
  version in the supported series at `r1`. A missing version *outside* the supported
  series (e.g. a new major like 10.x, which renamed the CMake module flags) produces a
  workflow warning instead of a doomed build — update `scripts/build.sh` for it, then
  widen `SUPPORTED` in
  [`.github/workflows/check-upstream.yml`](.github/workflows/check-upstream.yml).

`scripts/build.sh` is runnable locally on Ubuntu 24.04 the same way
(`build`, then `consume-test`, then `notes`).
