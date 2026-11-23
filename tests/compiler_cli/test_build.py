"""Manifest builds and versioned package resolution."""

import os
import subprocess
import sys
from pathlib import Path

from .support import CompilerTestCase


class BuildTests(CompilerTestCase):
    def build_project(self, manifest, target="app", output="output directory", *options, env=None):
        (self.root / "verona.build").write_text(manifest)
        return subprocess.run([str(self.compiler), "build", target, str(output), *map(str, options)],
                              cwd=self.root, capture_output=True, text=True, timeout=60, env=env)

    def test_manifest_executable_and_defaults(self):
        (self.root / "main.vrn").write_text('(%function main () i32 42)')
        result = self.build_project('(executable app (root main))', output="nested output/inner")
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.root / "nested output/inner/app"
        self.assertEqual(Path(result.stdout.strip()), binary)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 42)
        for level in ("0", "+01", "2", "3", "-0"):
            result = self.build_project(f'(executable app (root main) (target native) (version "0.2.0") (optimize {level}))')
            self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "blocked").write_text("file")
        result = self.build_project('(executable app (root main))', output="blocked/child")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot create output directory", result.stderr)

    def test_manifest_paths_features_and_imports(self):
        first = self.root / "first source"
        second = self.root / "second source"
        first.mkdir(); second.mkdir()
        (first / "main.vrn").write_text("""
(import dep)
#+cli (%function first () i32 (dep:value))
#-cli (%function first () i32 0)
#+package (%function main () i32 (first))
#-package (%function main () i32 1)
""")
        (first / "dep.vrn").write_text('#+package (%function value () i32 42) #-package (%function value () i32 0) (export value)')
        (second / "dep.vrn").write_text('(%function value () i32 99)(export value)')
        manifest = '(executable app (root main) (module-path "first source") (module-path "second source") (features PACKAGE))'
        result = self.build_project(manifest, "app", "out", "--feature", "CLI")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "out/app")], timeout=10).returncode, 42)
        result = self.build_project(manifest, "app", "out")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "out/app")], timeout=10).returncode, 0)

    def test_manifest_library_kinds_and_relative_link_paths(self):
        source = '(%function add ((a i32) (b i32)) i32 (+ a b))(native-export add "manifest_add")'
        (self.root / "api.vrn").write_text(source)
        (self.root / "main.vrn").write_text('(%external-function add "manifest_add" (i32 i32) i32)(%function main () i32 (add 20 22))')
        manifest = """
(static-library archive (root api))
(shared-library dynamic (root api) (optimize 2))
(executable app (root main) (library-path "native output") (library "archive"))
"""
        for name, extension in (("archive", "a"), ("dynamic", "dylib" if sys.platform == "darwin" else "so")):
            result = self.build_project(manifest, name, "native output")
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = self.root / f"native output/lib{name}.{extension}"
            self.assertEqual(Path(result.stdout.strip()), artifact)
            self.assertTrue(artifact.exists())
            self.assertTrue(artifact.with_suffix(".h").exists())
        result = self.build_project(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "output directory/app")], timeout=10).returncode, 42)

    def test_verona_package_libraries_use_separate_source_and_artifact_roots(self):
        source_root = self.root / "package sources"
        library_root = self.root / "package artifacts"
        package_source = source_root / "answer-1.2.0" / "src"
        package_artifact = library_root / "answer-1.2.0"
        package_source.mkdir(parents=True)
        package_artifact.mkdir(parents=True)
        (package_source / "answer.vrn").write_text("""
(%external-function answer "package_answer" () i64)
(%export answer)
""")
        implementation = self.root / "package-implementation.vrn"
        implementation.write_text("""
(%function answer () i64 42)
(native-export answer "package_answer")
""")
        static = package_artifact / "libanswer.a"
        shared = package_artifact / ("libanswer.dylib" if sys.platform == "darwin" else "libanswer.so")
        for kind, artifact in (("static-library", static), ("shared-library", shared)):
            built = subprocess.run(
                [str(self.compiler), "compile", str(implementation), "--emit", kind, "-o", str(artifact)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
        (self.root / "main.vrn").write_text("""
(%import answer)
(%function main () i64 (answer:answer))
""")
        environment = dict(
            os.environ,
            VERONA_SOURCE_DIR=str(source_root),
            VERONA_LIBRARY_DIR=str(library_root),
        )
        manifest = """(executable app
  (root main)
  (module-path ".")
  (library answer
    (version "1.2.0")
    (link static)))
"""
        result = self.build_project(manifest, output="manifest output", env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "manifest output/app")], timeout=10).returncode, 42)
        dynamic_manifest = manifest.replace('(link static)', '(link dynamic)')
        result = self.build_project(dynamic_manifest, output="dynamic manifest output", env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "dynamic manifest output/app")], timeout=10).returncode, 42)
        binary = self.root / "cli package"
        result = subprocess.run(
            [str(self.compiler), "compile", str(self.root / "main.vrn"), "--library", "dynamic",
             str(source_root / "answer-1.2.0"), "-o", str(binary)],
            env=environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 42)

    def test_static_library_package_import_does_not_require_artifact(self):
        source_root = self.root / "package sources"
        library_root = self.root / "package artifacts"
        dependency = source_root / "dep" / "src"
        dependency.mkdir(parents=True)
        library_root.mkdir()
        (dependency / "dep.vrn").write_text('(%export value)(%function value () i64 42)')
        (self.root / "client.vrn").write_text('(%import dep)(%export get)(%function get () i64 (dep:value))')
        environment = dict(os.environ, VERONA_SOURCE_DIR=str(source_root), VERONA_LIBRARY_DIR=str(library_root))
        manifest = '''(static-library client
  (root client)
  (module-path ".")
  (library dep (link static)))
'''
        result = self.build_project(manifest, "client", "out", env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "out/libclient.a").exists())
        self.assertFalse((library_root / "dep").exists())

    def test_package_roots_are_required_and_versions_are_exact(self):
        source_root = self.root / "package sources"
        library_root = self.root / "package artifacts"
        (source_root / "answer-1.2.0" / "src").mkdir(parents=True)
        (library_root / "answer-1.2.0").mkdir(parents=True)
        (source_root / "answer-1.2.0" / "src" / "answer.vrn").write_text('(%export answer)(%function answer () i64 42)')
        (self.root / "main.vrn").write_text('(%import answer)(%function main () i64 (answer:answer))')
        manifest = '''(executable app
  (root main)
  (module-path ".")
  (library answer (version "2.0.0") (link static)))
'''
        valid_environment = dict(os.environ, VERONA_SOURCE_DIR=str(source_root), VERONA_LIBRARY_DIR=str(library_root))
        result = self.build_project(manifest, env=valid_environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Verona package source root", result.stderr)
        valid_manifest = manifest.replace('"2.0.0"', '"1.2.0"')
        for variable, message in (("VERONA_SOURCE_DIR", "VERONA_SOURCE_DIR"),
                                  ("VERONA_LIBRARY_DIR", "VERONA_LIBRARY_DIR")):
            for invalid in ("", "relative", str(self.root / "missing-root")):
                with self.subTest(variable=variable, value=invalid):
                    environment = dict(valid_environment, **{variable: invalid})
                    result = self.build_project(valid_manifest, env=environment)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)

    def test_manifest_validation_and_no_evaluation(self):
        (self.root / "main.vrn").write_text('(%function main () i32 42)')
        valid = '(executable app (root main))'
        cases = (
            ('(executable app)', "requires exactly one root"),
            ('(executable app (root main) (root main))', "duplicate build option"),
            (valid + valid, "duplicate build target"),
            ('(executable app (root main) (mystery 1))', "unknown build option"),
            ('(executable app (root main) (module-path src))', "requires a data string"),
            ('(executable app (root main) (features))', "at least one feature"),
            ('(executable app (root main) (features 1))', "build name"),
            ('(executable app (root main) (features a) (features b))', "duplicate build option"),
            ('(executable app (root main) (version ""))', "non-empty single-line"),
            ('(executable app (root main) (version "a\\nb"))', "non-empty single-line"),
            ('(executable app (root main) (version "a") (version "b"))', "duplicate build option"),
            ('(executable app (root main) (optimize 0) (optimize 1))', "duplicate build option"),
            ('(executable app (root main) (optimize 4))', "integer from 0 through 3"),
            ('(executable app (root main) (optimize -1))', "integer from 0 through 3"),
            ('(executable app (root main) (optimize 1.0))', "integer from 0 through 3"),
            ('(executable app (root main) (target 1))', "native or a target-triple"),
            ('(executable app (root main) (target native) (target native))', "duplicate build option"),
            ('(executable app (root bad..module))', "dotted module"),
            ('(object app (root main))', "unknown top-level build form"),
            ("(compiler:state-set! 'side-effect 1)" + valid, "unknown top-level build form"),
            (valid + '(executable unselected (root main) (unknown 1))', "unknown build option"),
        )
        for manifest, message in cases:
            with self.subTest(manifest=manifest):
                result = self.build_project(manifest)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertIn("verona.build:", result.stderr)
                self.assertFalse((self.root / "output directory").exists())
        result = self.build_project(valid, "missing")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown build target", result.stderr)
        (self.root / "verona.build").unlink()
        result = subprocess.run([str(self.compiler), "build", "app", "out"], cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot find verona.build", result.stderr)
        for options in (("--feature",), ("--feature", ""), ("--unknown", "x")):
            result = self.build_project(valid, "app", "out", *options)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)

    def test_manifest_target_features_and_link_policy(self):
        (self.root / "api.vrn").write_text('#+x86_64 (%function value () i64 42) #-x86_64 (%function value () i64 0) (native-export value)')
        manifest = '(static-library api (root api) (target "x86_64-unknown-linux-gnu"))'
        result = self.build_project(manifest, "api", "out")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "out/libapi.a").exists())
        manifest = '(shared-library api (root api) (target "x86_64-unknown-linux-gnu") (framework "Foundation"))'
        result = self.build_project(manifest, "api", "bad-out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("frameworks are supported only on Darwin", result.stderr)
