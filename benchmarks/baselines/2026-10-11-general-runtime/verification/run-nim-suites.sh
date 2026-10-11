#!/bin/zsh
# usage: run_matrix.sh TAG — compile+run the Nim suites in parallel, one log each
TAG=$1; T=tmp/perf2/tests; mkdir -p $T/$TAG
export GENE_USER_PACKAGES="$PWD/tmp/perf2/tests/user-packages"
run() { # name, then nim args
  local name=$1; shift
  ( (time nim c -r --path:src --hints:off --warnings:off --nimcache:$T/cache-$name -o:$T/$TAG/$name "$@") > $T/$TAG/$name.log 2>&1; echo "exit=$?" >> $T/$TAG/$name.log ) &
}
run test_all -d:geneScopeReuseTests tests/test_all.nim
run spec_runner tests/spec_runner.nim
run test_vm_orc -d:geneScopeReuseTests tests/test_vm.nim
run test_vm_atomic --mm:atomicArc --threads:on -d:geneScopeReuseTests tests/test_vm.nim
run test_rc -d:geneRcStats tests/test_rc.nim
wait
for f in $T/$TAG/*.log; do echo "== $(basename $f): OK=$(grep -c '\[OK\]' $f) FAILED=$(grep -c '\[FAILED\]' $f) $(grep 'exit=' $f)"; done
