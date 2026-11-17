#!/usr/bin/env bash
# Fetches the libraries the contracts need into lib/ (they are not stored in git). Pinned versions.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib
clone() { # dir url commit
  if [ ! -d "lib/$1" ]; then
    git clone --quiet "$2" "lib/$1"
    git -C "lib/$1" checkout --quiet "$3"
  fi
}
clone forge-std https://github.com/foundry-rs/forge-std.git master
clone openzeppelin-contracts https://github.com/OpenZeppelin/openzeppelin-contracts.git 69c8def5f222ff96f2b5beff05dfba996368aa79
clone solmate https://github.com/transmissions11/solmate.git 89365b880c4f3c786bdd453d4b8e8fe410344a69
clone v4-periphery https://github.com/Uniswap/v4-periphery.git c6e4754dab11bd38c6f08ac51c3c868569e93d64
git -C lib/v4-periphery submodule update --init --quiet lib/v4-core lib/permit2
echo "libraries ready"
