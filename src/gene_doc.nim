## `gene-doc` — the documentation builder (design §7, Q36).
##
## Built as its own executable, like `gene-fmt` and `gene-lsp`, because the
## builder is a third engine beside the compiler and the VM: it reads source
## and follows module resolution, and it never compiles a body or runs a form.
## Keeping it out of `gene` is what keeps `bin/gene` free of the builder, and
## keeping the builder out of the VM is what lets it document a module that
## does not compile or whose dependencies are absent.

import tools/docs/cli

runDocCli()
