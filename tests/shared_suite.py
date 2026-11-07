"""Explicit shared expectations for the evaluator and full-value native protocol."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


class SuiteFailure(RuntimeError):
    pass


def execute(command, directory, label, timeout=30):
    try:
        result = subprocess.run(list(map(str, command)), capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        (directory / f"{label}.json").write_text(json.dumps({
            "command": list(map(str, command)), "outcome": "resource-limit",
            "stdout": str(error.stdout or ""), "stderr": str(error.stderr or "")}))
        raise SuiteFailure(f"{label}: resource-limit: host timeout") from error
    except OSError as error:
        (directory / f"{label}.json").write_text(json.dumps({
            "command": list(map(str, command)), "outcome": "tool-failure", "error": str(error)}))
        raise SuiteFailure(f"{label}: tool failure: {error}") from error
    (directory / f"{label}.json").write_text(json.dumps({
        "command": list(map(str, command)), "status": result.returncode,
        "stdout": result.stdout, "stderr": result.stderr}, indent=2) + "\n")
    return result


def require(condition, label, result):
    if not condition:
        raise SuiteFailure(f"{label}: unexpected outcome (status {result.returncode}): "
                           f"stdout={result.stdout!r}, stderr={result.stderr!r}")


def expect_failure(result, expected, source, label):
    status = 2 if expected["failure"] == "analysis" else 70
    line, column = expected["location"]
    require(result.returncode == status and not result.stdout
            and expected["diagnostic"] in result.stderr
            and f"{source}:{line}:{column}:" in result.stderr, label, result)


def run_suite(compiler, output):
    compiler = Path(compiler).resolve()
    output = Path(output)
    # A fresh directory prevents a previous binary from satisfying a failed build.
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((Path(__file__).parent / "shared/fixtures.json").read_text())
    if manifest["version"] != 1:
        raise SuiteFailure("unsupported fixture version")
    for fixture in manifest["fixtures"]:
        name = fixture["name"]
        directory = output / name
        directory.mkdir()
        source = (directory / "input.vrn").resolve()
        source.write_text(fixture["source"])
        for filename, content in fixture.get("modules", {}).items():
            module = directory / filename
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_text(content)
        if fixture["entry"] != "main" or fixture["arguments"]:
            raise SuiteFailure(f"{name}: CLI currently supports only main()")
        expected = fixture["expected"]
        evaluated = execute([compiler, "eval", source], directory, "eval")
        if "failure" in expected:
            expect_failure(evaluated, expected, source, name + "/eval")
        else:
            require(evaluated.returncode == 0 and not evaluated.stderr
                    and evaluated.stdout == expected.get("encoding", expected.get("value")) + "\n", name + "/eval", evaluated)
        if "failure" not in expected or expected["failure"] != "analysis":
            emitted = execute([compiler, "emit-llvm", source], directory, "emit-llvm")
            require(emitted.returncode == 0, name + "/emit-llvm", emitted)
            (directory / "program.ll").write_text(emitted.stdout)
        for level in ("-O0", "-O2"):
            label = level[1:]
            binary = directory / label
            compiled = execute([compiler, "compile-report", source, "-o", binary, level],
                               directory, label + "-compile")
            if expected.get("failure") == "analysis":
                expect_failure(compiled, expected, source, name + "/compile")
                require(not binary.exists(), name + "/stale-output", compiled)
                continue
            require(compiled.returncode == 0 and binary.is_file(), name + "/compile", compiled)
            native = execute([binary.resolve()], directory, label + "-native", timeout=10)
            if "failure" in expected:
                expect_failure(native, expected, source, name + "/native")
            else:
                require(native.returncode == 0 and not native.stderr
                        and native.stdout == expected.get("encoding", "i64:" + expected.get("value", "")) + "\n",
                        name + "/native", native)
    return len(manifest["fixtures"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.output:
            count = run_suite(args.compiler, args.output)
        else:
            with tempfile.TemporaryDirectory(prefix="verona-shared-") as temporary:
                count = run_suite(args.compiler, Path(temporary) / "results")
        print(f"{count} shared fixtures passed through evaluator and native paths")
    except SuiteFailure as error:
        parser.exit(1, f"shared suite failed: {error}\n")


if __name__ == "__main__":
    main()
