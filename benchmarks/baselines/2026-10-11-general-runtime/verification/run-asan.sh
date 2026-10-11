#!/bin/sh
# Build and run the VM and RC suites under AddressSanitizer (recover mode).
T=tmp/perf2/tests
export GENE_USER_PACKAGES="$PWD/tmp/perf2/tests/user-packages"
export ASAN_OPTIONS=detect_leaks=0:halt_on_error=0
for name in test_rc test_vm; do
  extra=""
  [ "$name" = test_vm ] && extra="-d:geneScopeReuseTests"
  nim c -d:geneRcStats -d:useMalloc --debugger:native --passC:-fsanitize=address \
    --passC:-fsanitize-recover=address --passL:-fsanitize=address \
    --passC:-fno-omit-frame-pointer --path:src --hints:off --warnings:off $extra \
    --nimcache:$T/cache-asan-$name -o:$T/asan-$name tests/$name.nim > $T/asan-build-$name.log 2>&1
  echo "build $name exit=$?"
done
$T/asan-test_rc > $T/asan-test_rc.log 2>&1; echo "test_rc exit=$?"
# The env/eval suite's memory-limit fixture needs Nim's allocator counter.
FILTERS=$(grep '^suite "' tests/test_vm.nim | sed 's/^suite "\(.*\)":.*/\1/' | grep -v '^vm — env and eval$' | sed 's/$/::*/')
echo "$FILTERS" | tr '\n' '\0' | xargs -0 $T/asan-test_vm > $T/asan-test_vm.log 2>&1; echo "test_vm exit=$?"
for f in $T/asan-test_rc.log $T/asan-test_vm.log; do
  echo "== $f OK=$(grep -c '\[OK\]' $f) FAILED=$(grep -c '\[FAILED\]' $f) ASAN=$(grep -c 'SUMMARY: AddressSanitizer' $f)"
done
