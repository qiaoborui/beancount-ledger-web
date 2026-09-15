# Embedded iOS Beancount runtime

The iOS build embeds these components. Their original licenses and copyright
notices remain applicable. Beancount declares GPL-2.0-only; regex declares
Apache-2.0 AND CNRI-Python. Apache-2.0 and GPL-2.0-only impose incompatible
conditions on distribution of a combined derivative work. This build has an
unresolved redistribution licensing issue: publishing source alone does not
resolve it. Obtain compatible permission or replace the affected dependencies
before redistributing a combined application. Other linked dependencies also
need an audit before distribution. This document changes no repository license.
The current scripts support private local builds and tests. Manual GitHub Actions
builds upload a short-lived private artifact for authorized repository users and
retain a local copy on the owner's Mac. Public IPA release is gated until the
combined-work licensing issue and dependency notice audit are resolved.

* Beancount 3.2.3, copyright Martin Blais and contributors: GPL-2.0-only,
  explicitly declared in pyproject.toml and README.rst.
  Source: https://pypi.org/project/beancount/3.2.3/ . The unmodified source
  archive and its COPYING file are fetched by `scripts/build-beancount-ios.sh`.
* CPython 3.14 from BeeWare Python-Apple-support 3.14-b11: Python Software
  Foundation License and the notices in the bundled Python `LICENSE.txt`.
  Source/build recipes: https://github.com/beeware/Python-Apple-support/tree/3.14-b11 .
  The Python standard-library LICENSE.txt is also copied into the bundle's
  python/app_packages/licenses/CPython.txt. The BeeWare support/build scripts
  use the MIT license, copied as Python-Apple-support.txt. The binary support
  archive also embeds third-party standard-library libraries; its sole license
  file is the CPython license, so a complete audit of those additional notices
  remains required before public redistribution.
* regex 2025.11.3, copyright Matthew Barnett and contributors:
  Apache-2.0 AND CNRI-Python, explicitly declared in PKG-INFO. LICENSE.txt
  assigns CNRI terms to the original code and Apache 2.0 to additions; these
  are cumulative terms, rather than a choice of alternative licenses.
  Source: https://pypi.org/project/regex/2025.11.3/ .
* go-git v5.16.5: Apache-2.0, declared in its LICENSE.
  Source: https://github.com/go-git/go-git/tree/v5.16.5 . The Git storage bridge
  links this dependency through the pinned Go module graph in `server/go.mod`
  and `server/go.sum`. It adds another Apache-2.0 component to the combined
  application; its transitive dependencies also require the full notice audit.

The build pins SHA-256 checksums for all three archives, compiles the canonical
Beancount and regex C extensions into a static XCFramework, and registers both
with CPython before initialization. Validation calls the upstream loader with
HARDCORE_VALIDATIONS, matching bean-check, after local include/plugin policy
checks. Runtime code runs within the application process. Build tools require
Xcode, Python 3, Bison 3.8+, and Flex 2.6.4+ (`brew install bison flex`).

The runtime supports iOS arm64 and simulator arm64/x86_64. Build artifacts live
under ignored `server/.build/beancount-ios/`. Xcode must link BeancountRuntime,
embed and sign Python.xcframework, and run build-beancount-ios-resources.sh as a
post-build phase before the application is signed. Simulator/device smoke tests
must execute the actual interpreter before an IPA is described as validated.

Imported arbitrary Python plugins, plugin configs that evaluate Python, external
include/document paths, encrypted ledger inputs, and imported pickle caches are
outside this runtime's supported ledger format. Validation errors block commits.
