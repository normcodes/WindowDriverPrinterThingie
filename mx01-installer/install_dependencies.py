from __future__ import annotations

import importlib
import os
import sys
import traceback
import zipfile
from pathlib import Path, PurePosixPath


def extract_wheels(wheel_dir: Path, site_packages: Path) -> None:
    site_packages.mkdir(parents=True, exist_ok=True)
    wheels = sorted(wheel_dir.glob("*.whl"))
    if not wheels:
        raise RuntimeError(f"No wheels found in {wheel_dir}")
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as archive:
            for member in archive.infolist():
                name = PurePosixPath(member.filename)
                if name.is_absolute() or ".." in name.parts:
                    raise RuntimeError(f"Unsafe path in dependency wheel {wheel.name}: {member.filename}")
                parts = list(name.parts)
                # Honor the wheel scheme for any data files instead of placing them
                # under the .data staging directory.
                if len(parts) >= 3 and parts[0].endswith(".data"):
                    scheme = parts[1]
                    if scheme not in {"purelib", "platlib"}:
                        continue
                    parts = parts[2:]
                destination = site_packages.joinpath(*parts)
                if member.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(member) as source, destination.open("wb") as target:
                        target.write(source.read())
        print(f"Installed {wheel.name}")


def main() -> None:
    if len(sys.argv) not in {3, 4}:
        raise SystemExit("usage: install_dependencies.py WHEEL_DIR SITE_PACKAGES [ERROR_LOG]")
    wheel_dir, site_packages = map(Path, sys.argv[1:3])
    error_log = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    try:
        if error_log:
            error_log.unlink(missing_ok=True)
        extract_wheels(wheel_dir, site_packages)
        site_packages = site_packages.resolve()
        site_path = str(site_packages)
        normalized_site_path = os.path.normcase(os.path.abspath(site_path))
        if not any(
            os.path.normcase(os.path.abspath(path or os.curdir)) == normalized_site_path
            for path in sys.path
        ):
            sys.path.insert(0, site_path)
        # Python may have cached the initially empty site-packages directory
        # during startup, before the wheels were extracted into it.
        importlib.invalidate_caches()
        bleak_init = site_packages / "bleak" / "__init__.py"
        if not bleak_init.is_file():
            raise RuntimeError(f"Bleak package was not extracted; expected to find {bleak_init}")
        import bleak  # noqa: F401
        import pymupdf  # noqa: F401
        from winrt.windows.devices.bluetooth import BluetoothLEDevice  # noqa: F401
        print("Offline BLE and PDF dependencies are ready.")
    except Exception:
        wheel_names = []
        try:
            wheel_names = sorted(path.name for path in wheel_dir.glob("*.whl"))
        except OSError:
            pass
        bleak_init = site_packages / "bleak" / "__init__.py"
        detail = (
            f"Python executable: {sys.executable}\n"
            f"Wheel directory: {wheel_dir} (exists: {wheel_dir.is_dir()})\n"
            f"Wheel files found: {wheel_names}\n"
            f"Site-packages directory: {site_packages} (exists: {site_packages.is_dir()})\n"
            f"Bleak package file: {bleak_init} (exists: {bleak_init.is_file()})\n"
            f"sys.path: {sys.path!r}\n\n"
            f"{traceback.format_exc()}"
        )
        print(detail, file=sys.stderr)
        if error_log:
            try:
                error_log.parent.mkdir(parents=True, exist_ok=True)
                error_log.write_text(detail, encoding="utf-8")
            except OSError as log_error:
                print(f"Could not save dependency error log at {error_log}: {log_error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
