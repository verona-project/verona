#!/usr/bin/env python3
"""Integration tests for the verona-project command-line tool."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


EXECUTABLE = Path(sys.argv[1] if len(sys.argv) == 2 else "build/verona-project").resolve()


def invoke(root, *arguments):
    environment = os.environ.copy()
    environment.pop("VERONA_SOURCE_DIR", None)
    environment.pop("VERONA_LIBRARY_DIR", None)
    if root is not None:
        environment["VERONA_SOURCE_DIR"] = str(root)
    return subprocess.run(
        [str(EXECUTABLE), *arguments], env=environment, text=True, capture_output=True
    )


def assert_result(result, status, output, error=""):
    assert result.returncode == status, result
    assert result.stdout == output, result.stdout
    assert result.stderr == error, result.stderr


def write_manifest(root, directory, contents):
    path = root / directory / "verona.build"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)


def test_inventory(root):
    for name in ("base-1.1.0", "base-1.2.0"):
        (root / name).mkdir()
    (root / "ordinary-file").write_text("ignored")
    (root / "alias-1.1.0").symlink_to("base-1.1.0")
    (root / "broken").symlink_to("missing")
    assert_result(
        invoke(root, "libraries"), 0, "alias: 1.1.0\nbase: 1.1.0, 1.2.0\n"
    )


def test_grouped_versions(root):
    for name in (
        "my-library-2.0.0", "base-2.0.0", "base-extra-1.0.0",
        "base-1.0.0-rc.1", "base-1.0.0+local", "base-1.0.0",
        "my-library-1.0.0", "unversioned", "base", "tool-2",
    ):
        (root / name).mkdir()
    assert_result(
        invoke(root, "libraries"), 0,
        "base: (unversioned), 1.0.0, 1.0.0+local, 1.0.0-rc.1, 2.0.0\n"
        "base-extra: 1.0.0\nmy-library: 1.0.0, 2.0.0\n"
        "tool-2: (unversioned)\nunversioned: (unversioned)\n",
    )


def test_manifest_fallback(root):
    write_manifest(root, "base", '(static-library base (root base) (version "1.1.0"))\n')
    write_manifest(root, "my-library", '(shared-library my-library (version "2.0.0-rc.1+local") (root main))')
    write_manifest(root, "base-1.2.0", '(static-library base (version "9.9.9") (root base))')
    assert_result(
        invoke(root, "libraries"), 0, "base: 1.1.0*, 1.2.0\nmy-library: 2.0.0-rc.1+local*\n"
    )


def test_missing_manifest_version(root):
    write_manifest(root, "absent", "(static-library absent (root main))")
    write_manifest(root, "other", '(static-library different (version "1.0.0") (root main))')
    write_manifest(root, "empty", '(static-library empty (version "") (root main))')
    write_manifest(root, "invalid", "(static-library invalid (version 123) (root main))")
    write_manifest(root, "unterminated", '(static-library unterminated (version "1.0.0')
    write_manifest(root, "nested", '(static-library nested (features (version "9.9.9")) (root main))')
    assert_result(
        invoke(root, "libraries"), 0,
        "absent: (unversioned)\nempty: (unversioned)\ninvalid: (unversioned)\n"
        "nested: (unversioned)\nother: (unversioned)\nunterminated: (unversioned)\n",
    )


def test_repeated_version(root):
    (root / "base-1.1.0").mkdir()
    write_manifest(root, "base", '(static-library base (version "1.1.0") (root base))')
    assert_result(invoke(root, "libraries"), 0, "base: 1.1.0*\n")


def test_empty_directory(root):
    assert_result(invoke(root, "libraries"), 0, "")


def test_invalid_roots():
    for root in (None, "", "relative", "/nonexistent-verona-source-directory"):
        result = invoke(root, "libraries")
        assert result.returncode != 0
        assert result.stdout == ""
        assert "VERONA_SOURCE_DIR" in result.stderr
    with tempfile.NamedTemporaryFile() as file:
        result = invoke(file.name, "libraries")
        assert result.returncode != 0
        assert result.stdout == ""
        assert "VERONA_SOURCE_DIR" in result.stderr


def test_command_errors():
    result = invoke(None, "libraries", "extra")
    assert result.returncode != 0 and result.stdout == ""
    assert "extra arguments" in result.stderr
    result = invoke(None, "--help")
    assert_result(result, 0, result.stdout)
    assert "libraries" in result.stdout and result.stderr == ""


def test_new_project(root):
    result = subprocess.run(
        [str(EXECUTABLE), "new", "example"], cwd=root, text=True, capture_output=True
    )
    assert_result(result, 0, "Created example\n")
    assert (root / "example" / "verona.build").is_file()


def main():
    assert EXECUTABLE.is_file(), f"missing executable: {EXECUTABLE}"
    cases = (
        test_inventory, test_grouped_versions, test_manifest_fallback,
        test_missing_manifest_version, test_repeated_version, test_empty_directory,
        test_new_project,
    )
    for case in cases:
        with tempfile.TemporaryDirectory(prefix="verona-project-") as directory:
            case(Path(directory))
    test_invalid_roots()
    test_command_errors()


if __name__ == "__main__":
    main()
