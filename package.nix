# package.nix
#
# info:
#   - update-lock.sh will regenerate:
#       pyproject.toml
#       uv.lock
#       make sure you manage these files with git in case
#       we need to go back
#   - myCustomOverrides.nix
#       Useful place to force particular nixpkgs versions
#       of packages such as: torch pyside6 shiboken6 etc.
#
# Usage:
#   nix run                            # Desktop app (Tauri)
#   nix build                          # Python serve environment
#   nix build . --override-input strata.package.nix.backend cuda  # CUDA engine
#   nix build . --override-input strata.package.nix.backend rocm   # ROCm engine
#   nix develop                        # Dev shell with locked Python env
#
# Variants via .override (nixpkgs pattern):
#   strata = pkgs.callPackage ./package.nix {};
#   strata-cuda = strata.override { backend = "cuda"; };
#
# so everything must be self-contained.

{ pkgs
, backend ? "cuda"
, cudaArch ? "60"
}:

let
  inherit (pkgs) lib;

  projectName = "strata";

  # Allow unfree packages (CUDA toolkit)
  pkgs' = import pkgs.path {
    inherit (pkgs) system;
    config.allowUnfree = true;
    config.cudaSupport = true;
  };

  # -- pyproject-nix ecosystem ----------------------------------------------
  pyproject-nix = import (pkgs'.fetchgit {
    url = "https://github.com/pyproject-nix/pyproject.nix.git";
    rev = "ddc400a6883b042646d0940e65971bb7f7e96107";
    sha256 = "sha256-vcCAvhtA7hG+/gOge29hYHy7I/dLkIsr5nLx4sFEQic=";
  }) { inherit lib; };

  uv2nix = import (pkgs'.fetchgit {
    url = "https://github.com/pyproject-nix/uv2nix.git";
    rev = "a541fda20d6784d88789cfcb221638b7c25a23dd";
    sha256 = "sha256-PeENT3Fu7a7YrX5zIHjdxai8GzPcxpKn+nQsgByhwNo=";
  }) { inherit pyproject-nix lib; };

  pyproject-build-systems = import (pkgs'.fetchgit {
    url = "https://github.com/pyproject-nix/build-system-pkgs.git";
    rev = "953d35d03a51dbecaf3feb3fb679eb63e90ebeb4";
    sha256 = "sha256-pyru9MpuXRiyq0Bd4q0nHpL4T6HCuZT4B+alcgAYE4A=";
  }) { inherit pyproject-nix uv2nix lib; };

  # python312: numpy==2.5.3 only ships wheels up to cp312
  python = pkgs'.python312;

  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = ./nix;
  };

  uvLockedOverlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  myCustomOverrides = import ./nix/myCustomOverrides.nix {
    pkgs = pkgs';
    inherit python;
  };

  pythonSet = (pkgs'.callPackage pyproject-nix.build.packages {
    inherit python;
  }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      uvLockedOverlay
      myCustomOverrides
    ]
  );

  appPythonEnv = pythonSet.mkVirtualEnv
    "${projectName}-env"
    workspace.deps.default;

  # -- Desktop app (Tauri) --------------------------------------------------
  # Builds the Tauri desktop app and outputs a runnable package.
  # On Linux: produces a directory with the GTK binary and a launcher.
  # On macOS: produces an .app bundle.

  desktopPkg = let
    nodejs = pkgs.nodejs_24;

    # Host frontend: builds the React/Vite UI
    hostDist = pkgs.buildNpmPackage {
      pname = "strata-host";
      version = "0.2.14";
      src = ./apps/host;
      npmDeps = pkgs.fetchNpmDeps {
        src = ./apps/host;
        hash = "sha256-Y64w7UCnm3ZOhabqLkITsbC8n0HqzGZmY4cOkV67U+M=";
      };

      buildPhase = "npm run build";

      installPhase = "cp -r dist $out";
    };

    # Tauri app: Rust build that packages the frontend + Rust binary
    tauriSrc = pkgs.rustPlatform.buildRustPackage {
      pname = "strata-desktop-src";
      version = "0.2.14";
      src = ./apps/desktop/src-tauri;
      doCheck = false;  # placeholder server triggers test failure

      # Use cargo vendor to fetch deps into Nix store
      # (enabled by default as of nixpkgs 25.05)
      cargoLock = {
        lockFile = ./apps/desktop/src-tauri/Cargo.lock;
      };

      # Rust toolchain + pkg-config for GTK/WebKit detection
      nativeBuildInputs = [
        pkgs.cargo
        pkgs.rustc
        pkgs.rustfmt
        pkgs.pkg-config
        pkgs.makeWrapper
      ];

      # Linux: GTK + WebKitGTK for the window
      # macOS: Cocoa + WebKit
      buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
        pkgs.gtk3
        pkgs.webkitgtk_4_1
        pkgs.libnotify
        pkgs.libappindicator
        pkgs.libayatana-appindicator
        pkgs.nss
        pkgs.nspr
        pkgs.alsa-lib
        pkgs.atk
        pkgs.brotli
        pkgs.cups
        pkgs.dbus
        pkgs.expat
        pkgs.fontconfig
        pkgs.freetype
        pkgs.glib
        pkgs.harfbuzz
        pkgs.json_c
        pkgs.libdrm
        pkgs.libepoxy
        pkgs.libglvnd
        pkgs.libjpeg
        pkgs.libpng
        pkgs.libwebp
        pkgs.libxkbcommon
        pkgs.openssl
        pkgs.zlib
        pkgs.zstd
      ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
        pkgs.cocoa
        pkgs.webkitgtk
      ];

      # Tauri needs to find the host dist at the path it expects
      # tauri.conf.json says: "frontendDist": "../../host/dist"
      # We create a symlink and patch the config
      # Also create placeholder dirs for resources that don't exist in source
      buildPhase = ''
        # Create a parent directory structure so ../../host works
        mkdir -p ../host
        ln -sf ${hostDist} ../host/dist
        cp ${./apps/host/package.json} ../host/package.json
        # Use the real host server
        cp -r ${./apps/host/server}/. ../host/server/

        # Create placeholder dirs for other Tauri bundle resources
        mkdir -p resources/node resources/control resources/harness resources/engine-bundle

        # Provide a Node.js binary for the host server
        cp ${nodejs}/bin/node resources/node/node

        sed -i 's|"../../host/dist"|"../host/dist"|' tauri.conf.json
        sed -i 's|"../../host/server"|"../host/server"|' tauri.conf.json
        sed -i 's|"../../host/package.json"|"../host/package.json"|' tauri.conf.json

        # Build for development (faster, no stripping)
        export CARGO_PROFILE_RELEASE_STRIP=false
        export CARGO_PROFILE_RELEASE_LTO=false
        cargo build --release
      '';

      installPhase = ''
        mkdir -p $out
        cp -r target/release $out/
      '';
    };

  in pkgs.stdenv.mkDerivation {
    pname = "strata-desktop";
    version = "0.2.14";
    src = tauriSrc;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      mkdir -p $out/bin

      if [[ ${pkgs.stdenv.system} == x86_64-linux || ${pkgs.stdenv.system} == aarch64-linux ]]; then
        # Linux: wrap the binary with all the GTK/WebKit libs on the path
        makeWrapper ${tauriSrc}/release/strata-desktop $out/bin/strata-desktop
      else
        # macOS: create .app bundle
        mkdir -p $out/Strata.app/Contents/MacOS
        cp ${tauriSrc}/release/strata-desktop $out/Strata.app/Contents/MacOS/Strata

        # Info.plist - use printf to avoid heredoc issues
        printf '%s\n' \
          '<?xml version="1.0" encoding="UTF-8"?>' \
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
          '<plist version="1.0">' \
          '<dict>' \
          '  <key>CFBundleName</key><string>Strata</string>' \
          '  <key>CFBundleIdentifier</key><string>ai.strata.desktop</string>' \
          '  <key>CFBundleVersion</key><string>0.2.14</string>' \
          '  <key>CFBundleShortVersionString</key><string>0.2.14</string>' \
          '  <key>CFBundleExecutable</key><string>Strata</string>' \
          '  <key>CFBundlePackageType</key><string>APPL</string>' \
          '  <key>CFBundleIconFile</key><string>Icon</string>' \
          '</dict>' \
          '</plist>' \
          > $out/Strata.app/Contents/Info.plist
      fi
    '';

    meta = with lib; {
      description = "Strata desktop app (Tauri)";
      platforms = platforms.unix;
    };
  };

  # -- Engine builder -------------------------------------------------------
  # mkEngine { backend, ... } → derivation
  #   backend = "cuda" | "rocm" | "cpu"
  #
  # Uses the .override / .overrideAttrs variant pattern (see nix/PackageVariants.md).
  mkEngine =
    { backend
#     , cudaArch ? "120"
    , cudaArch ? "60"
    , extraCmakeFlags ? [ ]
    }@args:
    let
      isCuda = backend == "cuda";
      isRocm = backend == "rocm";
      isCpu  = backend == "cpu";

      # GCC 14 for CUDA (nvcc rejects GCC > 14)
      stdenv = if isCuda then pkgs'.gcc14Stdenv else pkgs'.stdenv;

      # CUDA toolkit (12.9)
      cudaToolkit = pkgs'.cudaPackages_12_9.cudatoolkit;
      nvcc        = pkgs'.cudaPackages_12_9.cuda_nvcc;

      # ROCm toolkit
      rocmRuntime = pkgs'.rocmPackages.rocm-runtime;
      rocblas     = pkgs'.rocmPackages.rocblas;
      hipRuntime  = pkgs'.rocmPackages.clr;

      # Common build tools
      cmake' = pkgs'.cmake;
      ninja' = pkgs'.ninja;

      # Backend-specific inputs
      nativeBuildInputs = [
        cmake'
        ninja'
        pkgs'.makeWrapper
      ] ++ lib.optionals isCuda [ nvcc ];

      buildInputs =
        lib.optionals isCuda [
          cudaToolkit
          pkgs'.cudaPackages_12_9.libcublas
        ]
        ++ lib.optionals isRocm [
          rocmRuntime
          hipRuntime
          rocblas
          pkgs'.rocmPackages.miopen
        ];

      # CMake flags per backend
      # enableParallelBuilding = false;
      # buildPhase = "cmake --build $cmakeBuildDir -- -j 16";
      cmakeFlags = [
        "-DSTRATA_BUILD_TESTS=OFF"
        "-DSTRATA_ENABLE_SYCL=OFF"
        "-DSTRATA_BUILD_SPLIT=OFF"
      ]
      ++ lib.optionals isCuda [
        "-DSTRATA_ENABLE_CUDA=ON"
        "-DCMAKE_CUDA_ARCHITECTURES=${cudaArch}"
        # Pascal/Volta (sm_60/70, e.g. Tesla P100) is refused by the CUDA backend
        # unless this is set; see cmake/backends/cuda.cmake.
        "-DSTRATA_EXPERIMENTAL_SM60=ON"
      ]
      ++ lib.optionals isRocm [
        "-DSTRATA_ENABLE_HIP=ON"
        "-DCMAKE_HIP_ARCHITECTURES=gfx1100"
      ];

      pname = "strata-engine";
      version = "0.1.59.1";

    in
    stdenv.mkDerivation (rec {
      pname = "strata-engine";
      version = "0.1.59.1";
      src = ./.;

      inherit nativeBuildInputs buildInputs cmakeFlags;

      # Environment variables the build scripts expect
      env = lib.optionalAttrs isCuda {
        CUDA_HOME = "${cudaToolkit}";
        CUDA_PATH = "${cudaToolkit}";
        # CUDAHOSTCXX = "${pkgs'.stdenv.cc}/bin/c++";
        CUDAHOSTCXX = "${pkgs'.gcc14}/bin/g++";
      } // lib.optionalAttrs isRocm {
        ROCM_PATH = "${rocmRuntime}";
        HIP_PATH = "${hipRuntime}";
      };

      installPhase = ''
        mkdir -p $out/bin

        # GPU engine (strata) — only built when a backend is on
        ${lib.optionalString (isCuda || isRocm) ''
          cp strata $out/bin/
          [ -f libstrata_kq.so ] && cp libstrata_kq.so $out/bin/ || true
        ''}

        # CPU-only CLI tools (built in every configuration)
        cp strata-gguf $out/bin/
        cp strata-dequant $out/bin/
        cp strata-plan $out/bin/
      '';

      meta = with lib; {
        description = "Strata engine — ${backend} backend";
        platforms = platforms.linux;
        maintainers = [];
      };
    });

  # -- CUDA paths for setup.py engine compilation --------------------------
  # The Nix CUDA split means nvcc lives in cuda_nvcc but headers/libs are in cudatoolkit.
  # setup.py computes toolkit root from nvcc location, so we need to override it.
  cudaBuildEnv = let
    cudaToolkit = pkgs'.cudaPackages_12_9.cudatoolkit;
    nvcc        = pkgs'.cudaPackages_12_9.cuda_nvcc;
    gcc14       = pkgs'.gcc14;
  in {
    # Point STRATA_NVCC to the actual nvcc (not the symlink in merged toolkit)
    STRATA_NVCC = "${nvcc}/bin/nvcc";
    # CUDA_PATH to the merged toolkit (has headers + libs)
    CUDA_PATH = "${cudaToolkit}";
    CUDA_HOME = "${cudaToolkit}";
    CUDA_TOOLKIT_ROOT_DIR = "${cudaToolkit}";
    # GCC 14 (nvcc rejects GCC > 14)
    CC = "${gcc14}/bin/gcc";
    CXX = "${gcc14}/bin/g++";
    CUDAHOSTCXX = "${gcc14}/bin/g++";
    # Add nvcc bin to PATH so cmake finds it
    PATH = "${nvcc}/bin:${cudaToolkit}/bin";
  };

  # -- Python serve environment ---------------------------------------------
  # Still available for `nix build` or development.
  servePkg = pkgs'.stdenv.mkDerivation (rec {
    pname = "strata";
    version = "0.1.59.1";
    src = ./.;
    mainProgram = "${pname}";

    nativeBuildInputs = [
      appPythonEnv
      pkgs'.makeWrapper
      pkgs'.cudaPackages_12_9.cudatoolkit  # headers + libs for engine build
      pkgs'.cudaPackages_12_9.cuda_nvcc    # nvcc compiler
      pkgs'.gcc14                          # host compiler (nvcc rejects GCC > 14)
    ];

    # CUDA environment for setup.py engine compilation
    # The Nix CUDA split: nvcc is in cuda_nvcc, headers/libs in cudatoolkit
    env = {
      STRATA_NVCC = "${pkgs'.cudaPackages_12_9.cuda_nvcc}/bin/nvcc";
      CUDA_PATH = "${pkgs'.cudaPackages_12_9.cudatoolkit}";
      CUDA_HOME = "${pkgs'.cudaPackages_12_9.cudatoolkit}";
      CUDA_TOOLKIT_ROOT_DIR = "${pkgs'.cudaPackages_12_9.cudatoolkit}";
      CC = "${pkgs'.gcc14}/bin/gcc";
      CXX = "${pkgs'.gcc14}/bin/g++";
      CUDAHOSTCXX = "${pkgs'.gcc14}/bin/g++";
    };

    installPhase = ''
      export HOME=$TMPDIR

      mkdir -p $out/bin
      mkdir -p $out/share/${pname}

      mkdir -p $out/bin/${pname}-env
      for f in ${appPythonEnv}/bin/*; do
        ln -s "$f" "$out/bin/${pname}-env/"
      done

      mkdir -p $out/share/${pname}
      tar -cf - -C ${./serve} . | tar -xf - -C $out/share/${pname}/
      chmod -R u+w $out/share/${pname}

      # Copy setup.py and requirements files for setup command
      cp -f ${./setup.py} $out/share/${pname}/setup.py
      cp -f ${./requirements.bak.txt} $out/share/${pname}/requirements.bak.txt

      cat > $out/bin/${pname} <<'LAUNCHER'
      #!@BASH@
      exec @OUT@/bin/@NAME@-env/python3 @OUT@/share/@NAME@/server.py "$@"
      LAUNCHER
      sed -i 's|@BASH@|@BASHVAL@|' $out/bin/${pname}
      sed -i "s|@BASHVAL@|${pkgs'.bash}/bin/bash|" $out/bin/${pname}
      sed -i "s|@OUT@|$out|g" $out/bin/${pname}
      sed -i "s|@NAME@|${pname}|g" $out/bin/${pname}
      chmod +x $out/bin/${pname}

      # Create setup wrapper (injects CUDA env vars for engine compilation)
      cat > $out/bin/${pname}-setup <<LAUNCHER
      #!@BASH@
      export STRATA_NVCC="${pkgs'.cudaPackages_12_9.cuda_nvcc}/bin/nvcc"
      export CUDA_PATH="${pkgs'.cudaPackages_12_9.cudatoolkit}"
      export CUDA_HOME="${pkgs'.cudaPackages_12_9.cudatoolkit}"
      export CUDA_TOOLKIT_ROOT_DIR="${pkgs'.cudaPackages_12_9.cudatoolkit}"
      export CC="${pkgs'.gcc14}/bin/gcc"
      export CXX="${pkgs'.gcc14}/bin/g++"
      export CUDAHOSTCXX="${pkgs'.gcc14}/bin/g++"
      export PATH="${pkgs'.cudaPackages_12_9.cuda_nvcc}/bin:${pkgs'.cudaPackages_12_9.cudatoolkit}/bin:$PATH"
      exec @OUT@/bin/@NAME@-env/python3 @OUT@/share/@NAME@/setup.py "$@"
      LAUNCHER
      sed -i 's|@BASH@|@BASHVAL@|' $out/bin/${pname}-setup
      sed -i "s|@BASHVAL@|${pkgs'.bash}/bin/bash|" $out/bin/${pname}-setup
      sed -i "s|@OUT@|$out|g" $out/bin/${pname}-setup
      sed -i "s|@NAME@|${pname}|g" $out/bin/${pname}-setup
      chmod +x $out/bin/${pname}-setup
    '';

    meta = with lib; {
      description = "Strata - Python server environment (uv2nix locked)";
      platforms = platforms.all;
    };
  });

  # -- Engine variants ------------------------------------------------------
  engine-cpu = mkEngine { backend = "cpu"; };
  engine-cuda = mkEngine { backend = "cuda"; inherit cudaArch; };
  engine-rocm = mkEngine { backend = "rocm"; };

in

# Default: Desktop app (Tauri) for `nix run`
# Other packages available: servePkg, engine-cpu, engine-cuda, engine-rocm
{
  default = desktopPkg;
  inherit desktopPkg servePkg engine-cpu engine-cuda engine-rocm;
}
