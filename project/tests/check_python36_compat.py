#!/usr/bin/env python3
"""Static Python 3.6 syntax/API guard for target-side OPG runtime modules."""

import ast
import pathlib
import sys


FORBIDDEN_CALL_KEYWORDS = {
    ("subprocess", "run"): {"capture_output", "text"},
    ("subprocess", "Popen"): {"capture_output", "text"},
    ("shutil", "copytree"): {"dirs_exist_ok"},
}
FORBIDDEN_METHOD_KEYWORDS = {
    "unlink": {"missing_ok"},
    "write_text": {"newline"},
}
FORBIDDEN_ATTRIBUTES = {
    "hardlink_to", "is_relative_to", "readlink", "removeprefix",
    "removesuffix", "with_stem",
}
FORBIDDEN_IMPORTS = {"dataclasses", "importlib.resources"}


def dotted_name(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return tuple(reversed(parts))


def check(path):
    source = path.read_text(encoding="utf-8")
    problems = []
    try:
        try:
            tree = ast.parse(source, filename=str(path), feature_version=(3, 6))
        except TypeError:
            # Python 3.6 heeft feature_version nog niet; zijn eigen parser is
            # dan automatisch de relevante syntaxgrens.
            tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        return ["Python 3.6 syntax: {0}".format(exc)]
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in FORBIDDEN_IMPORTS:
                    problems.append("line {0}: import {1} requires newer Python".format(node.lineno, alias.name))
        elif isinstance(node, ast.ImportFrom) and node.module in FORBIDDEN_IMPORTS:
            problems.append("line {0}: import from {1} requires newer Python".format(node.lineno, node.module))
        elif isinstance(node, ast.Attribute) and node.attr in FORBIDDEN_ATTRIBUTES:
            problems.append("line {0}: API {1} is newer than Python 3.6".format(node.lineno, node.attr))
        elif isinstance(node, ast.Call):
            name = dotted_name(node.func)
            forbidden = FORBIDDEN_CALL_KEYWORDS.get(name, set())
            if isinstance(node.func, ast.Attribute):
                forbidden = forbidden | FORBIDDEN_METHOD_KEYWORDS.get(node.func.attr, set())
            used = {keyword.arg for keyword in node.keywords if keyword.arg}
            for keyword in sorted(used & forbidden):
                problems.append("line {0}: keyword {1} is newer than Python 3.6".format(node.lineno, keyword))
    return problems


def main():
    failed = False
    for filename in sys.argv[1:]:
        path = pathlib.Path(filename)
        for problem in check(path):
            failed = True
            print("{0}: {1}".format(path, problem), file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
