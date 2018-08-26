#! /usr/bin/env nix-shell
#! nix-shell -i bash -p git haskellPackages.cabal2nix nix-prefetch-git jq

# This script generates the nix derivation for elm-format intended for nixpkgs:
# https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/compilers/elm/packages/elm-format.nix

# To use this script, update the FLAVOR to the most recent flavor of elm-format
# and then run:
#
# $ ./generate_derivation.sh > elm-format.sh
#
# This might take a bit of time if the dependencies are not already in the nix
# store. If you already have all the dependencies installed, feel free to remove
# them from the shebang to speed up the process.

FLAVOR="0.19"

REV="$(git rev-parse HEAD)"
VERSION="$(git describe --abbrev=8)"
ROOTDIR="$(git rev-parse --show-toplevel)"
SHA="$(nix-prefetch-git --url "$ROOTDIR" --rev "$REV" --quiet --no-deepClone | jq .sha256)"

PATCH=$(cat <<END
  src = fetchgit {
    url = "http://github.com/avh4/elm-format";
    sha256 = $SHA;
    rev = "$REV";
  };

  doHaddock = false;
  jailbreak = true;
  postInstall = ''
    ln -s \$out/bin/elm-format-$FLAVOR \$out/bin/elm-format
  '';
  postPatch = ''
    sed -i "s|desc <-.*||" ./Setup.hs
    sed -i "s|gitDescribe = .*|gitDescribe = \\\\\\\\\"$VERSION\\\\\\\\\"\"|" ./Setup.hs
  '';
END
)

# quoteSubst from https://stackoverflow.com/a/29613573
quoteSubst() {
  IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g' <<<"$1")
  printf %s "${REPLY%$'\n'}"
}

cabal2nix "$ROOTDIR" |
  sed "s#^{ mkDerivation#{ mkDerivation, fetchgit#" |
  sed "s#\\s*src = .*;#$(quoteSubst "$PATCH")#"
