"""Canonical Beancount validation inside the application process.

The shipped parser and plugins are trusted application code. Imported ledgers
are data: preflight every parsed include before invoking loader transformations.
"""
import glob
import json
import os
from pathlib import Path

from beancount import loader
from beancount.core import data
from beancount.ops import validation
from beancount.parser import parser


ALLOWED_PLUGINS = frozenset({
    "beancount.plugins.auto_accounts",
    "beancount.plugins.check_closing",
    "beancount.plugins.check_drained",
    "beancount.plugins.close_tree",
    "beancount.plugins.coherent_cost",
    "beancount.plugins.implicit_prices",
    "beancount.plugins.leafonly",
    "beancount.plugins.noduplicates",
    "beancount.plugins.nounused",
    "beancount.plugins.onecommodity",
    "beancount.plugins.sellgains",
    "beancount.plugins.unique_prices",
})


def _confined(root, path):
    candidate = Path(os.path.abspath(path))
    if not candidate.is_relative_to(root):
        raise ValueError("账本引用超出本地目录")
    current = root
    for part in candidate.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("账本引用包含符号链接")
    if not candidate.resolve().is_relative_to(root):
        raise ValueError("账本引用超出本地目录")
    return candidate


def _preflight(root, entry):
    pending, seen = [entry], set()
    while pending:
        filename = _confined(root, pending.pop())
        if filename in seen:
            continue
        seen.add(filename)
        if len(seen) > 10000:
            raise ValueError("账本引用文件数量超过限制")
        if filename.suffix.lower() in {".gpg", ".asc"}:
            raise ValueError("请先解密账本再导入")
        entries, errors, options = parser.parse_file(str(filename))
        # Parser errors are returned by the canonical full load below; options
        # recovered by the parser still receive the same policy checks.
        if options.get("insert_pythonpath"):
            raise ValueError("本地账本仅支持应用内置插件，需移除 insert_pythonpath")
        for name, config in options.get("plugin", []):
            if name not in ALLOWED_PLUGINS:
                raise ValueError("本地账本暂不支持插件：" + name)
        for directory in options.get("documents", []):
            _confined(root, filename.parent / directory)
        for item in entries:
            if isinstance(item, data.Document):
                _confined(root, filename.parent / item.filename)
        for include in options.get("include", []):
            pattern = _confined(root, filename.parent / include)
            # Check each glob result before the loader can open it.
            pending.extend(_confined(root, path) for path in glob.glob(str(pattern)))


def validate_json(workspace, entry_file="main.bean"):
    try:
        root = Path(workspace).resolve(strict=True)
        if not root.is_dir() or Path(entry_file).is_absolute():
            raise ValueError("账本入口路径无效")
        entry = _confined(root, root / entry_file)
        _preflight(root, entry)
        # The uncached entry point avoids loading or removing any imported
        # pickle cache. This is the same loader pipeline used by bean-check.
        _, errors, _ = loader._uncached_load_file(
            str(entry), None, validation.HARDCORE_VALIDATIONS, None
        )
        result = []
        for error in errors:
            source = error.source or {}
            filename = source.get("filename", "")
            if filename and Path(filename).is_relative_to(root):
                filename = str(Path(filename).relative_to(root))
            result.append({"message": error.message, "filename": filename,
                           "lineno": source.get("lineno", 0)})
        return json.dumps({"errors": result}, ensure_ascii=False)
    except Exception as error:
        return json.dumps({"errors": [{"message": str(error)}]}, ensure_ascii=False)
