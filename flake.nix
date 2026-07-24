{
	description = "chatscan — search Claude conversation history";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		zig-overlay = {
			url = "github:mitchellh/zig-overlay";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { self, nixpkgs, flake-utils, zig-overlay }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
				zigPkg = zig-overlay.packages.${system}."0.16.0";
				testTarget =
					if system == "x86_64-linux" then "x86_64-linux-musl"
					else if system == "aarch64-linux" then "aarch64-linux-musl"
					else "";
				packageTargetFlag =
					if testTarget == "" then "" else "-Dtarget=${testTarget}";
				sqlite-amalgamation = pkgs.fetchzip {
					url = "https://www.sqlite.org/2024/sqlite-amalgamation-3450300.zip";
					sha256 = "sha256-F50oTmmcPIl0AZJbsWAR3tbNAPV3pQLf+CNITzhmXfI=";
					stripRoot = true;
				};

				# Fixed-output derivation that pre-fetches all Zig URL deps from
				# build.zig.zon (sqlite_vec). Network access only here; the
				# consumer build is fully offline.
				# To recompute: set zigDepsHash = ""; nix build; copy printed hash.
				zigDepsHash = "sha256-pihmKPtmwtp5WjN5e/XJ2yoZWQLWb/0ThD37oYNM7Lo=";

				zigDeps = pkgs.stdenv.mkDerivation {
					pname = "chatscan-zig-deps";
					version = "0.1.0";
					src = ./.;
					nativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
					outputHashMode = "recursive";
					outputHashAlgo = "sha256";
					outputHash = zigDepsHash;
					buildPhase = ''
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$out
						export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						zig build --fetch=all
					'';
					dontInstall = true;
					dontFixup = true;
				};
			in {
				packages.default = pkgs.stdenv.mkDerivation {
					pname = "chatscan";
					version = "0.1.0";

					src = ./.;

					nativeBuildInputs = [ zigPkg ];

					dontConfigure = true;
					dontFixup = true;

					buildPhase = ''
						export HOME=$TMPDIR
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
						cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
						chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

						zig build \
							${packageTargetFlag} \
							-Dcpu=baseline \
							-Doptimize=ReleaseFast \
							--color off
					'';

					installPhase = ''
						mkdir -p $out/bin
						cp zig-out/bin/chatscan $out/bin/
					'';

					meta = with pkgs.lib; {
						description = "Search Claude conversation history with semantic + lexical search";
						license = licenses.mit;
						platforms = platforms.unix;
						mainProgram = "chatscan";
					};
				};

				checks.test = pkgs.stdenv.mkDerivation {
					pname = "chatscan-test";
					version = "0.1.0";
					src = ./.;

					nativeBuildInputs = [ zigPkg pkgs.bash pkgs.jq ];

					dontConfigure = true;
					dontFixup = true;

					buildPhase = ''
						export HOME=$TMPDIR
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						export CHATSCAN_ZIG_TARGET="${testTarget}"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
						cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR"/
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"

						CHATSCAN_IN_NIX_CHECK=1 bash ./test
					'';

					installPhase = ''
						mkdir -p $out
						touch $out/tests-passed
					'';
				};

				devShells.default = pkgs.mkShell {
					packages = [
						zigPkg
						pkgs.jq
						pkgs.ripgrep
					];
					shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
						export NIX_CFLAGS_COMPILE=""
					'';
				};
			}
		);
}
