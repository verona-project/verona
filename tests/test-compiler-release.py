"""Release verification boundaries; no LLVM or native compiler is required."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import time
import unittest

SPEC = importlib.util.spec_from_file_location(
    "compiler_release", Path(__file__).resolve().parents[1] / "scripts/verify-compiler-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="verona-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def git(self, directory, *arguments):
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", *arguments], cwd=directory,
            stderr=subprocess.STDOUT, text=True).strip()

    def repository(self, name):
        directory = self.root / name
        directory.mkdir()
        self.git(directory, "init")
        self.git(directory, "config", "user.name", "Release Test")
        self.git(directory, "config", "user.email", "release-test@example.invalid")
        (directory / "source.txt").write_text("selected source\n")
        self.git(directory, "add", "source.txt")
        self.git(directory, "commit", "--no-gpg-sign", "-m", "Create fixture")
        return directory

    def test_clean_revision_and_dirty_source(self):
        directory = self.repository("source")
        selected = release.clean_revision(directory)
        self.assertEqual(selected["revision"], self.git(directory, "rev-parse", "HEAD"))
        (directory / "untracked.vrn").write_text("new source")
        with self.assertRaisesRegex(release.VerificationFailure, "clean committed"):
            release.clean_revision(directory)
        (directory / "untracked.vrn").unlink()
        (directory / "source.txt").write_text("edited source")
        with self.assertRaisesRegex(release.VerificationFailure, "clean committed"):
            release.clean_revision(directory)

    def test_local_submodule_sources_and_dirty_dependency(self):
        directory = self.repository("source")
        library = self.repository("library")
        self.git(directory, "-c", "protocol.file.allow=always", "submodule", "add",
                 str(library), "dependency")
        self.git(directory, "commit", "--no-gpg-sign", "-m", "Record dependency")
        release.clean_revision(directory)
        entries = release.local_submodules(directory)
        self.assertEqual(entries[0][0], "submodule.dependency.url")
        self.assertTrue(Path(entries[0][1]).is_dir())
        (directory / "dependency/source.txt").write_text("changed dependency")
        with self.assertRaisesRegex(release.VerificationFailure, "clean committed"):
            release.clean_revision(directory)

    def test_failed_command_retains_diagnostics(self):
        log = self.root / "failure.log"
        with self.assertRaisesRegex(release.VerificationFailure, "exited 7"):
            release.run_command([sys.executable, "-c",
                                 "import sys; print('output'); print('diagnostic', file=sys.stderr); sys.exit(7)"],
                                self.root, log, 5)
        self.assertIn("output", log.read_text())
        self.assertIn("diagnostic", log.read_text())

    def test_missing_command_is_a_tool_failure(self):
        with self.assertRaisesRegex(release.VerificationFailure, "cannot launch"):
            release.run_command([self.root / "missing-tool"], self.root,
                                self.root / "missing.log", 5)

    def test_timeout_stops_descendants(self):
        marker = self.root / "child-survived"
        child = f"import time; from pathlib import Path; time.sleep(1); Path({str(marker)!r}).write_text('alive')"
        parent = ("import subprocess, sys, time; "
                  f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
                  "print('started', flush=True); time.sleep(20)")
        log = self.root / "timeout.log"
        with self.assertRaisesRegex(release.VerificationFailure, "resource limit"):
            release.run_command([sys.executable, "-c", parent], self.root, log, 0.5)
        time.sleep(1.1)
        self.assertIn("started", log.read_text())
        self.assertFalse(marker.exists())

    def test_selects_only_the_fresh_successful_stage_c(self):
        bootstrap = self.root / "bootstrap"
        stage = bootstrap / "run-current"
        (stage / "C").mkdir(parents=True)
        compiler = stage / "C/verona-core"
        compiler.write_bytes(b"fresh compiler")
        result = stage / "result.json"
        result.write_text(json.dumps({"status": "failed", "stage": "C/build"}))
        with self.assertRaisesRegex(release.VerificationFailure, "did not pass"):
            release.selected_compiler(bootstrap)
        result.write_text(json.dumps({"status": "passed", "stage": "B/C comparison"}))
        self.assertEqual(release.selected_compiler(bootstrap), compiler)
        (bootstrap / "run-stale").mkdir()
        with self.assertRaisesRegex(release.VerificationFailure, "exactly one fresh"):
            release.selected_compiler(bootstrap)

    def test_distribution_requires_docs_and_excludes_generated_output(self):
        archive = self.root / "source.tar.gz"

        def package(names):
            with tarfile.open(archive, "w:gz") as output:
                for name in names:
                    entry = tarfile.TarInfo(name)
                    entry.size = 1
                    output.addfile(entry, io.BytesIO(b"x"))

        package(["verona/docs/compiler-roadmap.org"])
        release.verify_archive(archive, ["docs/compiler-roadmap.org"])
        with self.assertRaisesRegex(release.VerificationFailure, "missing"):
            release.verify_archive(archive, ["scripts/missing.py"])
        for path in ("build/verona", "projects/compiler/tests/__pycache__/test.pyc", "libexample.a"):
            package(["verona/docs/compiler-roadmap.org", "verona/" + path])
            with self.assertRaisesRegex(release.VerificationFailure, "generated artifact"):
                release.verify_archive(archive, ["docs/compiler-roadmap.org"])


if __name__ == "__main__":
    unittest.main()
