"""Black-box compiler tests organized by the behavior they exercise."""

from pathlib import Path


def load_tests(loader, tests, pattern):
    package = Path(__file__).resolve().parent
    return loader.discover(
        str(package), pattern or "test_*.py", top_level_dir=str(package.parent)
    )
