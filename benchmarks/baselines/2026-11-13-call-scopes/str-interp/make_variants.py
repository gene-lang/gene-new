"""Write the kernel-file variants used to trace str_interp's layout sensitivity.

usage: make_variants.py KERNELS_GENE OUT_DIR

  kNN.gene       NN extra Str constants (32-byte-class buffers, allocated at compile time)
  control.gene   400 boxed Ints (one 32-byte-class cell each) before it, n = 2 M
  lonehole.gene  the same, with one of them in a full chunk released first
  holes.gene     40 strings with every other one released (same-chunk holes)
  solid.gene     the same 40 strings, none released
"""
import sys
src = open(sys.argv[1]).read(); out = sys.argv[2]
line = '(set t (now)) (report "str_interp_500k" t (bench_str 500000))'
assert src.count(line) == 1
big = line.replace('500000', '2000000')
def write(name, text): open(f'{out}/{name}.gene', 'w').write(text)
for k in [0, 1, 2, 3, 4, 6, 8, 12]:
    # No `$` before `{t}`: a plain 16-character Str constant, so each pad is one
    # more constant allocated when the file is compiled.
    pads = ''.join(f'(var pad_{i} $"pad-number-{i}-{{t}}")\n' for i in range(k))
    write(f'k{k:02d}', src.replace(line, pads + line))
fill = '(var lone_fill [])\n(repeat i in 400 (lone_fill .push (+ 140737488355328 i)))\n'
write('control', src.replace(line, fill + big))
write('lonehole', src.replace(line, fill + '(set lone_fill/10 nil)\n' + big))
forty = ('(var hole_all [])\n(repeat i in 40 (hole_all .push $"hole-number-${i}"))\n'
         '(var hole_kept [])\n'
         '(repeat i in 40 (if (== (// i 2) 0) (hole_kept .push hole_all/%i) nil))\n')
write('solid', src.replace(line, forty + big))
write('holes', src.replace(line, forty + '(set hole_all nil)\n' + big))
