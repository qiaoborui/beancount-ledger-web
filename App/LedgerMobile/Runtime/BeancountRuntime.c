#include "BeancountRuntime.h"
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

PyMODINIT_FUNC PyInit__parser(void);
PyMODINIT_FUNC PyInit__regex(void);

static char *python_error(void) {
    PyObject *error = PyErr_GetRaisedException();
    PyObject *description = error ? PyObject_Str(error) : NULL;
    const char *utf8 = description ? PyUnicode_AsUTF8(description) : NULL;
    char *result = strdup(utf8 ? utf8 : "Embedded Python runtime failed");
    Py_XDECREF(description);
    Py_XDECREF(error);
    PyErr_Clear();
    return result;
}

char *BRInitialize(const char *bundle_path) {
    if (Py_IsInitialized()) return NULL;
    if (PyImport_AppendInittab("beancount.parser._parser", PyInit__parser) < 0 ||
        PyImport_AppendInittab("regex._regex", PyInit__regex) < 0)
        return strdup("Unable to register native Beancount modules");
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    const char *suffixes[] = {"/python/lib/python3.14", "/python/lib/python3.14/lib-dynload", "/python/app_packages"};
    PyStatus status = PyStatus_Ok();
    for (size_t i = 0; i < 3; i++) {
        char *path = malloc(strlen(bundle_path) + strlen(suffixes[i]) + 1);
        if (!path) { PyConfig_Clear(&config); return strdup("Insufficient memory"); }
        strcpy(path, bundle_path);
        strcat(path, suffixes[i]);
        wchar_t *wide = Py_DecodeLocale(path, NULL);
        free(path);
        if (!wide) { PyConfig_Clear(&config); return strdup("Invalid runtime path"); }
        status = PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
        if (PyStatus_Exception(status)) break;
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    char *result = PyStatus_Exception(status) ? strdup(status.err_msg ? status.err_msg : "Python initialization failed") : NULL;
    PyConfig_Clear(&config);
    if (!result) PyEval_SaveThread();
    return result;
}

static char *validate(const char *workspace_path, const char *entry_file, const char *function_name) {
    if (!Py_IsInitialized()) return strdup("{\"errors\":[{\"message\":\"Python runtime is unavailable\"}]}");
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("ledger_validator");
    PyObject *function = module ? PyObject_GetAttrString(module, function_name) : NULL;
    PyObject *result = function ? PyObject_CallFunction(function, "ss", workspace_path, entry_file) : NULL;
    const char *utf8 = result ? PyUnicode_AsUTF8(result) : NULL;
    char *output = utf8 ? strdup(utf8) : NULL;
    if (!output) {
        char *error = python_error();
        // JSON-escape interpreter failures through the standard library.
        PyObject *json = PyImport_ImportModule("json");
        PyObject *encoded = json ? PyObject_CallMethod(json, "dumps", "s", error) : NULL;
        const char *escaped = encoded ? PyUnicode_AsUTF8(encoded) : NULL;
        if (escaped) {
            size_t size = strlen(escaped) + 40;
            output = malloc(size);
            if (output) snprintf(output, size, "{\"errors\":[{\"message\":%s}]}", escaped);
        }
        free(error);
        Py_XDECREF(encoded);
        Py_XDECREF(json);
    }
    Py_XDECREF(result);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyErr_Clear();
    PyGILState_Release(state);
    return output;
}

char *BRValidate(const char *workspace_path, const char *entry_file) {
    return validate(workspace_path, entry_file, "validate_json");
}

char *BRValidateOnly(const char *workspace_path, const char *entry_file) {
    return validate(workspace_path, entry_file, "validate_only_json");
}

char *BRExportStream(const char *workspace_path, const char *entry_file,
                     const char *derived_directory, const char *spool_name) {
    // Unlike validation, this boundary never formats interpreter exceptions.
    const char *failed = "{\"ok\":false,\"error\":{\"code\":\"export_failed\",\"message\":\"Bounded stream export failed\"}}";
    if (!workspace_path || !entry_file || !derived_directory || !spool_name)
        return strdup("{\"ok\":false,\"error\":{\"code\":\"invalid_arguments\",\"message\":\"Invalid stream export arguments\"}}");
    if (!Py_IsInitialized())
        return strdup("{\"ok\":false,\"error\":{\"code\":\"runtime_unavailable\",\"message\":\"Python runtime is unavailable\"}}");
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("ledger_stream_bridge");
    PyObject *function = module ? PyObject_GetAttrString(module, "export_stream_json") : NULL;
    PyObject *result = function ? PyObject_CallFunction(function, "ssss", workspace_path,
                                                       entry_file, derived_directory, spool_name) : NULL;
    char *output = NULL;
    // Check character count before UTF-8 conversion, then byte count before copy.
    if (result && PyUnicode_Check(result) && PyUnicode_GetLength(result) > 0 &&
        PyUnicode_GetLength(result) <= BR_EXPORT_STREAM_MAX_RESPONSE_BYTES) {
        Py_ssize_t size = 0;
        const char *utf8 = PyUnicode_AsUTF8AndSize(result, &size);
        if (utf8 && size > 0 && size <= BR_EXPORT_STREAM_MAX_RESPONSE_BYTES &&
            !memchr(utf8, '\0', (size_t)size)) {
            output = malloc((size_t)size + 1);
            if (output) memcpy(output, utf8, (size_t)size + 1);
        }
    }
    Py_XDECREF(result);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyErr_Clear();
    PyGILState_Release(state);
    return output ? output : strdup(failed);
}

void BRFree(char *value) { free(value); }
