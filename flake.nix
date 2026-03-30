{
  description = "WurstScript development environment for Tever";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      jre = pkgs.jdk11_headless;
      wurstHome = "$HOME/.wurst";

      # WurstSetup.jar (grill CLI)
      wurstSetupJar = pkgs.fetchurl {
        url = "https://github.com/wurstscript/WurstSetup/releases/download/nightly-master/WurstSetup.jar";
        hash = "sha256-YZl9o7aWx6l9PucZGg4Nf8J/eD/92SFPm7pmtbSGtoo=";
      };

      # Compiler wrapper — uses jars from ~/.wurst/ (installed by grill/extension)
      wurstscript = pkgs.writeShellScriptBin "wurstscript" ''
        WURST_CP="${wurstHome}/wurstscript.jar:${wurstHome}/*"
        exec ${jre}/bin/java -cp "$WURST_CP" de.peeeq.wurstio.Main "$@"
      '';

      # Wrapper: grill (WurstSetup CLI)
      grill = pkgs.writeShellScriptBin "grill" ''
        exec ${jre}/bin/java -Djava.awt.headless=true -jar ${wurstSetupJar} "$@"
      '';

      # Shared build logic
      buildMapScript = pkgs.writeShellScript "wurst-build-map" ''
        set -euo pipefail
        unset DISPLAY
        export JAVA_TOOL_OPTIONS="-Xms1g -Xmx2g"
        PROJECT_DIR="''${1:-$(pwd)}"
        cd "$PROJECT_DIR"

        # Clean previous build output
        rm -f _build/*.w3x

        echo "Building map..."
        WURST_CP="${wurstHome}/wurstscript.jar:${wurstHome}/*"
        ${jre}/bin/java -cp "$WURST_CP" de.peeeq.wurstio.Main \
          -runcompiletimefunctions -injectobjects -stacktraces -noExtractMapScript \
          -noPJass -build -opt \
          -workspaceroot "$PROJECT_DIR" \
          -inputmap "$PROJECT_DIR/Teve_Reborn_Revamp_Latest.w3x" \
          -lib "$PROJECT_DIR/_build/dependencies/TeveR_StdLib" \
          "$PROJECT_DIR/lib/common.j" "$PROJECT_DIR/lib/blizzard.j" "$PROJECT_DIR/wurst"

        # Find the newest .w3x in _build/
        MAP=$(find _build -maxdepth 1 -name '*.w3x' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -z "$MAP" ]; then
          echo "ERROR: No .w3x found in _build/ after build"
          exit 1
        fi

        MAP_NAME=$(basename "$MAP")
        MAP_SIZE=$(du -h "$MAP" | cut -f1)
        echo "Built: $MAP_NAME ($MAP_SIZE)"
      '';

      # Build map only (for CI/agents to verify the build works)
      buildMap = pkgs.writeShellScriptBin "wurst-build" ''
        exec ${buildMapScript} "''${1:-$(pwd)}"
      '';

      # Run wurst tests (compiletime tests via grill)
      testMap = pkgs.writeShellScriptBin "wurst-test" ''
        set -euo pipefail
        unset DISPLAY
        export JAVA_TOOL_OPTIONS="-Xms1g -Xmx2g"
        PROJECT_DIR="''${1:-$(pwd)}"
        cd "$PROJECT_DIR"
        echo "Running WurstScript tests..."
        ${grill}/bin/grill test
      '';

      # Build map and copy to NFS share for laptop
      nfsShareDir = "/home/daniel/shared";
      deployMap = pkgs.writeShellScriptBin "wurst-deploy" ''
        ${buildMapScript} "''${1:-$(pwd)}"

        PROJECT_DIR="''${1:-$(pwd)}"
        cd "$PROJECT_DIR"
        MAP=$(find _build -maxdepth 1 -name '*.w3x' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
        DEST="${nfsShareDir}/$(basename "$MAP")"
        cp "$MAP" "$DEST"
        echo "Deployed: $DEST"
      '';

      # CI: get latest release version
      getLatestVersion = pkgs.writeShellScriptBin "ci-get-version" ''
        set -euo pipefail
        ${pkgs.glab}/bin/glab auth login -t "$GLAB_TOKEN"
        ${pkgs.glab}/bin/glab release list > releases
        cat releases
        # Extract first version-like tag (X.Y.Z) from output, ignoring headers
        VERSION=$(${pkgs.gnugrep}/bin/grep -oP '\d+\.\d+\.\d+' releases | head -1)
        echo "Detected version: $VERSION"
        echo "$VERSION" > version
      '';

      # CI: protect mapfile with KryptProtect (Wine)
      wine = pkgs.wineWow64Packages.stable;
      protectMap = pkgs.writeShellScriptBin "ci-protect-map" ''
        set -euo pipefail
        export WINEPREFIX="''${HOME}/.wine-kp"
        export WINEDEBUG=-all
        unset DISPLAY

        cd lib/kryptprotect/latest

        # Inject wine + coreutils/awk into PATH for runTeveR.sh
        export PATH="${wine}/bin:${pkgs.gawk}/bin:$PATH"
        # Run with bash explicitly (NixOS has no /bin/bash)
        bash runTeveR.sh

        # runTeveR.sh outputs to repo root (../../../) — relocate to _build/
        cd ../../..
        mv Reborn*_KPed.w3x _build/
        MAPFILE=$(ls _build/Reborn*_KPed.w3x | head -1)
        echo "$MAPFILE" > _build/mapfilename

        echo "Protection was successful!"
      '';

      # CI: create GitLab release
      createRelease = pkgs.writeShellScriptBin "ci-create-release" ''
        set -euo pipefail
        VERSION=$(cat version)
        MAPFILENAME=$(cat _build/mapfilename)
        echo "Creating release $VERSION..."
        ${pkgs.gitlab-release-cli}/bin/release-cli create \
          --name "''${VERSION}_branch_''${CI_COMMIT_BRANCH}" \
          --tag-name "$VERSION" \
          --description "''${CI_COMMIT_MESSAGE}" \
          --ref "''${CI_COMMIT_SHA}" \
          create-from-file --file "$MAPFILENAME"
      '';

    in
    {
      packages.${system} = {
        wurst-build = buildMap;
        wurst-test = testMap;
        wurst-deploy = deployMap;
        ci-get-version = getLatestVersion;
        ci-protect-map = protectMap;
        ci-create-release = createRelease;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ jre wurstscript grill buildMap testMap deployMap ];

        shellHook = ''
          # Set up ~/.wurst grill wrapper for VSCode extension
          mkdir -p ${wurstHome}
          cat > ${wurstHome}/grill <<'GRILL'
#!/usr/bin/env bash
exec ${jre}/bin/java -Djava.awt.headless=true -jar ${wurstSetupJar} "$@"
GRILL
          chmod +x ${wurstHome}/grill

          echo "WurstScript dev environment loaded."
          echo "  wurstscript  - Wurst compiler (uses ~/.wurst/ jars)"
          echo "  grill        - Wurst package manager"
          echo "  wurst-test   - Run WurstScript tests"
          echo "  wurst-build  - Build map only (for CI/agents)"
          echo "  wurst-deploy - Build + deploy to NFS share (${nfsShareDir})"
        '';
      };
    };
}
