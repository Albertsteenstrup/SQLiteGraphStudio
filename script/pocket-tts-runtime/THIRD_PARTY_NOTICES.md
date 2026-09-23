# Pocket TTS runtime notices

The app's speech worker uses Kyutai Pocket TTS 3.1.0, distributed under the MIT License. The
English model and Alba voice are separate assets under CC BY 4.0; the app downloads them only
after an explicit install action and retains the upstream attribution and license links in its
speech settings.

The bundled CPython 3.12.13 runtime is built from Astral's `python-build-standalone` distribution.
That project is MPL-2.0 and the CPython components retain their PSF license. The distribution's
`python/LICENSE.txt` and any license files in the installed package metadata are retained in the
runtime tree.

All Python packages are pinned in `requirements.lock` with SHA-256 artifact hashes. The release
builder installs only wheels and retains each package's `.dist-info` metadata and license files in
`python/lib/python3.12/site-packages`. The runtime manifest records the Python distribution URL and
archive SHA-256 used to prepare each architecture. These notices identify the upstream software
and model terms; inspect the package metadata included with the built runtime for the complete
license text and attribution of each transitive dependency.
