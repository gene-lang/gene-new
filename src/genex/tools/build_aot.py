"""Build a Gene-authored native adapter using declared system dependencies."""
from pathlib import Path
import argparse
import os
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]


def build(package, library_name, dependencies, native_sources, link_options=()):
    parser = argparse.ArgumentParser()
    parser.add_argument("--pkg-config-path", action="append", default=[])
    options = parser.parse_args()
    package = Path(package)
    out = package / "build"
    gene = os.environ.get("GENE_EXE", str(ROOT / "bin/gene"))
    cc = os.environ.get("CC", "cc")
    cflags, libs, rpaths = [], [], []
    for dependency in dependencies:
        command = ["nim", "r", "--path:src", "--hints:off",
                   "tools/system_dependency_flags.nim", str(package), dependency]
        for path in options.pkg_config_path:
            command += ["--pkg-config-path", str(Path(path).resolve())]
        flags = subprocess.check_output(command, cwd=ROOT, text=True)
        for line in flags.splitlines():
            kind, flag = line.split("\t", 1)
            target = cflags if kind == "C" else libs
            if flag not in target:
                target.append(flag)
            if kind == "L" and flag.startswith("-L"):
                rpath = "-Wl,-rpath," + flag[2:]
                if rpath not in rpaths:
                    rpaths.append(rpath)
    out.mkdir(parents=True, exist_ok=True)
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        raise SystemExit("this build driver currently supports macOS and Linux")
    library = out / ("lib" + library_name + (".dylib" if system == "Darwin" else ".so"))
    link = ["-undefined", "dynamic_lookup", "-Wl,-install_name," + str(library)] if system == "Darwin" else []
    # Replace the artifact atomically: a running client may still map the old
    # library, and a failed build must leave that usable artifact intact.
    with tempfile.TemporaryDirectory(prefix=".build-", dir=out) as temporary:
        source = Path(temporary) / (library_name + ".c")
        built = Path(temporary) / library.name
        with source.open("w") as output:
            subprocess.run([gene, "compile", "--target", "c", str(package / "src/native.gene")],
                           cwd=ROOT, stdout=output, check=True)
        subprocess.run([cc, "-std=c11", "-O2", "-DGENE_AOT_DYNAMIC_ENTRIES=1",
                        "-shared", "-fPIC", *link, *cflags, str(source),
                        *(str(package / path) for path in native_sources),
                        "-o", str(built), *libs, *rpaths, *link_options], check=True)
        os.replace(source, out / source.name)
        os.replace(built, library)
    print(library)
    return library
