#!/usr/bin/env python3
"""Verify a clean source revision in an isolated, locally cloned checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import platform
import signal
import subprocess
import sys
import tempfile
import tarfile

ROOT = Path(__file__).resolve().parents[1]


class VerificationFailure(RuntimeError):
    pass


def capture(arguments, directory):
    result = subprocess.run(arguments, cwd=directory, capture_output=True, text=True)
    if result.returncode:
        raise VerificationFailure(f"{arguments[0]} failed: {result.stderr.strip()}")
    return result.stdout


def clean_revision(directory):
    status = capture(["git", "status", "--porcelain", "--untracked-files=all"], directory)
    if status:
        raise VerificationFailure("release verification requires clean committed sources:\n" + status)
    modules = capture(["git", "submodule", "status", "--recursive"], directory)
    if any(line.startswith(("-", "+", "U")) for line in modules.splitlines()):
        raise VerificationFailure("initialize submodules at their recorded revisions before verification")
    return {
        "revision": capture(["git", "rev-parse", "HEAD"], directory).strip(),
        "submodules": modules,
    }


def local_submodules(directory):
    result = capture(["git", "config", "--file", ".gitmodules", "--get-regexp",
                      r"submodule\..*\.path$"], directory)
    entries = []
    for line in result.splitlines():
        key, path = line.split(None, 1)
        metadata = capture(["git", "rev-parse", "--absolute-git-dir"], directory / path).strip()
        entries.append((key[:-len(".path")] + ".url", metadata))
    return entries


def run_command(arguments, directory, log, timeout, environment=None):
    """Retain output and terminate the entire owned process group on timeout."""
    with log.open("w") as output:
        try:
            process = subprocess.Popen(list(map(str, arguments)), cwd=directory,
                                       stdout=output, stderr=subprocess.STDOUT,
                                       env=environment, start_new_session=True)
        except OSError as error:
            raise VerificationFailure(f"cannot launch {arguments[0]}: {error}") from error
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            raise VerificationFailure(f"resource limit: {arguments[0]} timed out; see {log}") from error
    if status:
        raise VerificationFailure(f"{arguments[0]} exited {status}; see {log}")


def selected_compiler(bootstrap):
    runs = list(bootstrap.glob("run-*"))
    if len(runs) != 1:
        raise VerificationFailure("expected exactly one fresh bootstrap result")
    result = json.loads((runs[0] / "result.json").read_text())
    if result != {"status": "passed", "stage": "B/C comparison"}:
        raise VerificationFailure("the fresh bootstrap did not pass exact B/C comparison")
    compiler = runs[0] / "C/verona-core"
    if not compiler.is_file():
        raise VerificationFailure("stage C executable is missing")
    return compiler


def verify_archive(archive, required):
    with tarfile.open(archive) as package:
        names = [PurePosixPath(member.name) for member in package.getmembers()]
    if any(name.is_absolute() or ".." in name.parts for name in names):
        raise VerificationFailure("distribution contains a path outside its package root")
    prefixes = {name.parts[0] for name in names if name.parts}
    if len(prefixes) != 1:
        raise VerificationFailure("distribution must have one package root")
    relative = {str(PurePosixPath(*name.parts[1:])) for name in names}
    if not set(required).issubset(relative):
        raise VerificationFailure("distribution is missing required compiler documentation or tooling")
    for name in relative:
        parts = PurePosixPath(name).parts
        if ("build" in parts or "__pycache__" in parts or
                name.endswith((".pyc", ".o", ".a", ".dylib", ".so", ".fasl"))):
            raise VerificationFailure(f"distribution includes a generated artifact: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/compiler-release")
    parser.add_argument("--timeout", type=int, default=7200,
                        help="seconds allowed per verification command (default: 7200)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=args.output)).resolve()
    stage = "preflight"
    report = {"status": "running", "stage": stage, "commands": []}

    def command(label, arguments, directory, environment=None):
        nonlocal stage
        stage = label
        print(label, flush=True)
        log = evidence / (label + ".log")
        report["commands"].append({"stage": label, "arguments": list(map(str, arguments)),
                                   "directory": str(directory), "log": str(log)})
        run_command(arguments, directory, log, args.timeout, environment)

    try:
        if not os.environ.get("VERONA_CL_LLVM"):
            raise VerificationFailure("enter the pinned Nix development shell first")
        if capture(["llvm-config", "--version"], ROOT).split(".")[0] != "23":
            raise VerificationFailure("LLVM 23 is required")
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise VerificationFailure("the native release gate currently requires arm64 Darwin")
        original = clean_revision(ROOT)
        report.update(original)
        report["host"] = {"system": platform.system(), "release": platform.release(),
                          "machine": platform.machine()}
        report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report["toolchain"] = {name: capture([name, "--version"], ROOT).strip()
                               for name in ("clang", "llvm-config", "sbcl")}
        checkout = evidence / "checkout"
        # File-only transports prevent a missing local dependency from silently
        # fetching a different remote source during release validation.
        offline = ["git", "-c", "protocol.allow=never", "-c", "protocol.file.allow=always"]
        command("clone", [*offline, "clone", "--local", "--no-hardlinks", "--no-checkout",
                          ROOT, checkout], ROOT)
        command("revision", ["git", "checkout", "--detach", original["revision"]], checkout)
        # Persist URLs in the isolated repository: Git uses their presence to
        # distinguish initialized submodules in later status checks.
        for key, path in local_submodules(ROOT):
            capture(["git", "config", "--local", key, path], checkout)
        command("submodules", [*offline, "submodule", "update", "--init", "--recursive"],
                checkout)
        if clean_revision(checkout) != original:
            # Submodule branch labels may differ after a detached clone; the
            # indexed revisions, rather than display labels, are authoritative.
            if capture(["git", "rev-parse", "HEAD"], checkout).strip() != original["revision"]:
                raise VerificationFailure("isolated checkout changed the selected revision")
        environment = dict(os.environ, VERONA_CL_LLVM=str(checkout / "vendor/CL-LLVM"),
                           PYTHONDONTWRITEBYTECODE="1")
        command("configure", ["sh", "-c", "autoreconf -fi && ./configure"], checkout, environment)
        command("tests", ["make", "test"], checkout, environment)
        bootstrap = evidence / "bootstrap"
        command("bootstrap", [sys.executable, checkout / "projects/compiler/bootstrap.py",
                              "--bootstrap", checkout / "build/verona", "--output", bootstrap],
                checkout, environment)
        compiler = selected_compiler(bootstrap)
        report["compiler"] = {"path": str(compiler),
                              "sha256": hashlib.sha256(compiler.read_bytes()).hexdigest()}
        command("projects", ["make", "test-self-hosted-projects",
                             "SELF_HOSTED_COMPILER=" + str(compiler),
                             "SELF_HOSTED_PROJECTS_OUTPUT=" + str(evidence / "projects")],
                checkout, environment)
        command("distribution", ["make", "dist"], checkout, environment)
        archives = list(checkout.glob("*.tar.gz"))
        if len(archives) != 1:
            raise VerificationFailure("expected one fresh source distribution")
        archive = archives[0]
        verify_archive(archive, ["docs/compiler-roadmap.org", "docs/self-hosted-project-audit.md",
                                "projects/compiler/README.md", "projects/compiler/verona.build",
                                "projects/compiler/src/core.bigint.vrn",
                                "projects/compiler/tests/compile_time_parity.json",
                                "projects/compiler/tests/compiler_contracts.json",
                                "scripts/verify-compiler-release.py",
                                "scripts/self-hosted-projects.py", "scripts/self-hosted-projects.json"])
        saved = evidence / archive.name
        archive.rename(saved)
        report["distribution"] = {"path": str(saved),
                                  "sha256": hashlib.sha256(saved.read_bytes()).hexdigest()}
        stage = "final-source-check"
        clean_revision(checkout)
        if clean_revision(ROOT) != original:
            raise VerificationFailure("original checkout changed during release verification")
        report.update(status="passed", stage=stage)
    except (VerificationFailure, OSError, ValueError) as error:
        report.update(status="failed", stage=stage, reason=str(error))
        print(f"Release verification stopped at {stage}: {error}", file=sys.stderr)
    finally:
        (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Evidence: {evidence}", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
