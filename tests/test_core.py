"""Run the black-box compiler CLI tests with an optional compiler path."""

import sys
import unittest

import compiler_cli
from compiler_cli.support import CompilerTestCase


class CompilerTestLoader(unittest.TestLoader):
    def matching_tests(self, suite, method):
        for test in suite:
            if isinstance(test, unittest.TestSuite):
                yield from self.matching_tests(test, method)
            elif test.id().endswith("." + method):
                yield test

    def loadTestsFromName(self, name, module=None):
        if name == "CoreTests":
            return self.loadTestsFromModule(compiler_cli)
        if name.startswith("CoreTests."):
            method = name.removeprefix("CoreTests.")
            matches = self.suiteClass(
                self.matching_tests(self.loadTestsFromModule(compiler_cli), method)
            )
            if matches.countTestCases():
                return matches
        return super().loadTestsFromName(name)


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if arguments and not arguments[0].startswith("-"):
        CompilerTestCase.configure(arguments.pop(0))
    unittest.main(
        module=compiler_cli,
        argv=[sys.argv[0], *arguments],
        testLoader=CompilerTestLoader(),
    )
