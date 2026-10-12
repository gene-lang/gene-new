"""Build a Gene-authored native adapter using declared system dependencies."""
from pathlib import Path
import argparse
import os
import platform
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]


def native_environment(cc):
    """Select a linkable macOS SDK for the actual native compiler.

    config.nims can fix the SDK inside a Nim child, but cannot export that
    environment back to this bootstrap driver or its later C compiler.
    Keep explicit SDK choices and working defaults unchanged.
    """
    environment = dict(os.environ)
    if platform.system() != "Darwin" or environment.get("SDKROOT"):
        return environment
    with tempfile.TemporaryDirectory(prefix="gene-sdk-probe-") as temporary:
        def probe(env):
            return subprocess.run(
                [cc, "-x", "c", "-", "-o", str(Path(temporary) / "probe")],
                input="int main(void) { return 0; }\n", text=True,
                capture_output=True, env=env, timeout=30)

        default = probe(environment)
        if default.returncode == 0:
            return environment
        selected = subprocess.run(["xcrun", "--show-sdk-path"],
                                  capture_output=True, text=True,
                                  env=environment, timeout=30)
        candidates = []
        if selected.returncode == 0 and selected.stdout.strip():
            directory = Path(selected.stdout.strip()).parent
            for sdk in directory.glob("MacOSX*.sdk"):
                version = re.fullmatch(r"MacOSX(\d+(?:\.\d+)*)\.sdk", sdk.name)
                if version and sdk.is_dir():
                    candidates.append((tuple(map(int, version[1].split("."))), sdk))
        seen = set()
        for _, sdk in sorted(candidates, reverse=True):
            resolved = sdk.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            candidate = {**environment, "SDKROOT": str(sdk)}
            if probe(candidate).returncode == 0:
                print(f"genex: using SDKROOT={sdk} ({cc}'s default SDK did not link)",
                      file=sys.stderr)
                return candidate
    raise SystemExit(
        f"genex: {cc} could not link with the default or any installed macOS SDK. "
        "Select a compatible toolchain with CC/SDKROOT.\n" + default.stderr.strip())


def build(package, library_name, dependencies, native_sources, link_options=()):
    parser = argparse.ArgumentParser()
    parser.add_argument("--pkg-config-path", action="append", default=[])
    options = parser.parse_args()
    package = Path(package)
    out = package / "build"
    gene = os.environ.get("GENE_EXE", str(ROOT / "bin/gene"))
    cc = os.environ.get("CC", "cc")
    environment = native_environment(cc)
    cflags, libs, rpaths = [], [], []
    for dependency in dependencies:
        command = ["nim", "r", "--path:src", "--hints:off",
                   "tools/system_dependency_flags.nim", str(package), dependency]
        for path in options.pkg_config_path:
            command += ["--pkg-config-path", str(Path(path).resolve())]
        flags = subprocess.check_output(command, cwd=ROOT, text=True, env=environment)
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
                           cwd=ROOT, stdout=output, check=True, env=environment)
        subprocess.run([cc, "-std=c11", "-O2", "-DGENE_AOT_DYNAMIC_ENTRIES=1",
                        "-shared", "-fPIC", *link, *cflags, str(source),
                        *(str(package / path) for path in native_sources),
                        "-o", str(built), *libs, *rpaths, *link_options],
                       check=True, env=environment)
        os.replace(source, out / source.name)
        os.replace(built, library)
    print(library)
    return library
