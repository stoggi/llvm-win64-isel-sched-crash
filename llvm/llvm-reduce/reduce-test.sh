#!/bin/bash
# llvm-reduce interestingness test: llc must hit the specific assertion, so
# the reduction cannot drift onto a different crash. Needs an llc built with
# -DLLVM_ENABLE_ASSERTIONS=ON (without the fix) and `not` from an LLVM build.
#
#   LLC=/path/to/llc NOT=/path/to/not \
#     llvm-reduce -j 20 --test=./reduce-test.sh king-cape.bc -o king-cape.reduced.bc
"${NOT:-not}" --crash "${LLC:-llc}" "$1" -o /dev/null 2> "$1.err" || exit 1
grep -q "getMinimalPhysRegClass" "$1.err"
