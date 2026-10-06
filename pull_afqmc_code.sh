#!/bin/bash
set -euo pipefail

REPO=https://github.com/amazon-braket/amazon-braket-examples.git
REF=16cd791da7c3ec7e104851eb3bc502d00be1c1c3  # commit SHA on feature/quantum-monte-carlo
SRC=examples/hybrid_quantum_algorithms/Quantum_Monte_Carlo_Chemistry/afqmc

git fetch --depth 1 "$REPO" "$REF"
rm -rf afqmc && mkdir afqmc
git archive FETCH_HEAD "$SRC" | tar -x --strip-components=4 -C afqmc