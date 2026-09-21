"""Host C ABI checks using CPython >=3.12 headers and a C compiler.

Only the unused iOS static extension registration symbols are stubbed; exports
call the real Python bridge and installed host Beancount. This does not exercise
BRInitialize's Apple bundle layout or Apple native extension linkage.
"""

import ctypes
import json
import os
from pathlib import Path
import shlex
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import unittest
from unittest import mock

import ledger_stream_bridge
from test_ledger_stream_bridge import BASIC


@unittest.skipUnless(sys.version_info >= (3, 12) and shutil.which("cc"),
                     "requires CPython >=3.12 headers and cc")
class NativeStreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        build = Path(cls.temp.name)
        stub = build / "stub.c"
        stub.write_text('#include <Python.h>\n'
                        'PyMODINIT_FUNC PyInit__parser(void) { return NULL; }\n'
                        'PyMODINIT_FUNC PyInit__regex(void) { return NULL; }\n')
        runtime = Path(__file__).resolve().parent
        library = build / "runtime.so"
        flags = ["cc", "-Wall", "-Wextra", "-Werror", "-I" + sysconfig.get_config_var("INCLUDEPY"),
                 "-I" + str(runtime)]
        sources = [str(runtime / "BeancountRuntime.c"), str(stub)]
        libs = ["-L" + sysconfig.get_config_var("LIBDIR"),
                "-Wl,-rpath," + sysconfig.get_config_var("LIBDIR"),
                "-lpython" + sysconfig.get_config_var("LDVERSION")]
        libs += shlex.split(sysconfig.get_config_var("LIBS") or "")
        libs += shlex.split(sysconfig.get_config_var("SYSLIBS") or "")
        subprocess.run(flags + ["-shared", "-fPIC"] + sources + libs + ["-o", str(library)], check=True)
        # CDLL releases the host GIL; production C must acquire it itself.
        cls.lib = ctypes.CDLL(str(library))
        cls.lib.BRExportStream.argtypes = [ctypes.c_char_p] * 4
        cls.lib.BRExportStream.restype = ctypes.c_void_p
        cls.lib.BRFree.argtypes = [ctypes.c_void_p]
        cls.lib.BRFree.restype = None
        for name in ("BRValidate", "BRValidateOnly"):
            function = getattr(cls.lib, name)
            function.argtypes = [ctypes.c_char_p] * 2
            function.restype = ctypes.c_void_p
        # Separate executable really has an uninitialized interpreter.
        main = build / "main.c"
        main.write_text('#include "BeancountRuntime.h"\n#include <stdio.h>\n'
                        'int main(void) { char *s = BRExportStream("/ledger", "main.bean", '
                        '"/derived", "stream.jsonl"); if (!s) return 1; '
                        'puts(s); BRFree(s); BRFree(NULL); return 0; }\n')
        cls.executable = build / "uninitialized"
        subprocess.run(flags + sources + [str(main)] + libs + ["-o", str(cls.executable)], check=True)

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.root = self.base / "ledger"
        self.root.mkdir(mode=0o700)
        self.derived = self.base / "derived"
        self.derived.mkdir(mode=0o700)
        (self.root / "main.bean").write_text(BASIC)
        self.args = [os.fsencode(self.root), b"main.bean", os.fsencode(self.derived), b"spool.jsonl"]

    def decode(self, pointer, *, bounded=True):
        self.assertTrue(pointer)
        try:
            raw = ctypes.string_at(pointer)
            if bounded:
                self.assertLessEqual(len(raw), ledger_stream_bridge.MAX_RESPONSE_BYTES)
                self.assertNotIn(os.fsencode(self.base), raw)
            return json.loads(raw)
        finally:
            self.lib.BRFree(pointer)

    def call(self, args=None):
        return self.decode(self.lib.BRExportStream(*(self.args if args is None else args)))

    def test_response_limit_matches_python(self):
        header = (Path(__file__).resolve().parent / "BeancountRuntime.h").read_text()
        limit = re.search(r"#define BR_EXPORT_STREAM_MAX_RESPONSE_BYTES (\d+)", header)
        self.assertEqual(int(limit[1]), ledger_stream_bridge.MAX_RESPONSE_BYTES)

    def test_real_export_and_exclusive_retry(self):
        result = self.call()
        self.assertTrue(result["ok"])
        self.assertEqual(result["summary"]["directives"], 3)
        spool = self.derived / "spool.jsonl"
        original = spool.read_bytes()
        self.assertFalse(self.call()["ok"])
        self.assertEqual(spool.read_bytes(), original)
        spool.unlink()
        self.assertTrue(self.call()["ok"])

    def test_null_arguments_and_invalid_utf8(self):
        for index in range(4):
            args = self.args.copy()
            args[index] = None
            self.assertEqual(self.call(args)["error"]["code"], "invalid_arguments")
        self.assertEqual(self.call([b"\xff", *self.args[1:]])["error"]["code"], "export_failed")
        self.lib.BRFree(None)

    def test_uninitialized_runtime(self):
        result = subprocess.run([str(self.executable)], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "runtime_unavailable")
        self.assertEqual(result.stderr, "")

    def test_interpreter_failures_are_fixed_public_errors(self):
        with mock.patch.object(ledger_stream_bridge, "export_stream_json",
                               side_effect=RuntimeError("private " + str(self.root))):
            self.assertEqual(self.call(), json.loads(ledger_stream_bridge._EXPORT_FAILED))
        with mock.patch.dict(sys.modules, {"ledger_stream_bridge": None}):
            self.assertEqual(self.call(), json.loads(ledger_stream_bridge._EXPORT_FAILED))
        with mock.patch.object(ledger_stream_bridge, "export_stream_json", None):
            self.assertEqual(self.call(), json.loads(ledger_stream_bridge._EXPORT_FAILED))
        self.assertTrue(self.call()["ok"])

    def test_native_limit_and_result_type_enforced(self):
        for value in (None, 42, b"not text", "", "x" * 1025, "界" * 400,
                      "bad\0value", "\ud800"):
            with self.subTest(value_type=type(value).__name__), \
                    mock.patch.object(ledger_stream_bridge, "export_stream_json", return_value=value):
                self.assertEqual(self.call(), json.loads(ledger_stream_bridge._EXPORT_FAILED))

    def test_existing_validation_entrypoints_still_work(self):
        legacy = self.decode(self.lib.BRValidate(*self.args[:2]), bounded=False)
        validation = self.decode(self.lib.BRValidateOnly(*self.args[:2]), bounded=False)
        self.assertEqual(legacy["errors"], [])
        self.assertEqual(validation["errors"], [])
        self.assertNotEqual(legacy, validation)


if __name__ == "__main__":
    unittest.main()
