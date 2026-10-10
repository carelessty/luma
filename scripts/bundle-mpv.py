#!/usr/bin/env python3
"""Relocate the executable's non-system dylib closure into a macOS app.

Only files referenced by Mach-O load commands are copied. The app uses libmpv's
OpenGL render API; optional mpv command-line tools, scripts and Vulkan drivers
are deliberately not installed or invoked. No library is copied from IINA.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path


def run(*args: str | Path) -> str:
    result = subprocess.run([str(arg) for arg in args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def system_library(name: str) -> bool:
    return name.startswith(("/System/Library/", "/usr/lib/", "/Library/Apple/System/Library/"))


def load_commands(binary: Path) -> tuple[list[str], list[str], list[str]]:
    # Parse load commands rather than otool -L so LC_ID_DYLIB is never mistaken
    # for a dependency and weak/re-exported dependencies receive the same checks.
    output = run("otool", "-l", binary)
    dependencies, rpaths, minimums = [], [], []
    command = ""
    for line in output.splitlines():
        text = line.strip()
        if text.startswith("cmd "):
            command = text.split(None, 1)[1]
        elif text.startswith("name ") and command in {
            "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"
        }:
            dependencies.append(text[5:].rsplit(" (offset ", 1)[0])
        elif text.startswith("path ") and command == "LC_RPATH":
            rpaths.append(text[5:].rsplit(" (offset ", 1)[0])
        elif text.startswith("minos ") and command == "LC_BUILD_VERSION":
            minimums.append(text.split()[1])
        elif text.startswith("version ") and command == "LC_VERSION_MIN_MACOSX":
            minimums.append(text.split()[1])
    return list(dict.fromkeys(dependencies)), list(dict.fromkeys(rpaths)), minimums


def version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in (value.split(".") + ["0", "0"])[:3])


def expanded(value: str, loader: Path, executable: Path) -> Path:
    return Path(value.replace("@loader_path", str(loader.parent)).replace("@executable_path", str(executable.parent)))


def resolve(name: str, loader: Path, executable: Path, rpaths: list[str]) -> Path:
    if name.startswith("@rpath/"):
        candidates = [expanded(path, loader, executable) / name[len("@rpath/"):] for path in rpaths]
    else:
        candidates = [expanded(name, loader, executable)]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError(f"Cannot resolve dependency {name!r} of {loader.name}")


def keg_for(library: Path) -> Path | None:
    for parent in library.parents:
        if (parent / "INSTALL_RECEIPT.json").is_file():
            return parent
    return None


def notices(kegs: set[Path], destination: Path) -> list[dict]:
    records = []
    for keg in sorted(kegs):
        formula = keg.parent.name
        target = destination / formula
        target.mkdir(parents=True, exist_ok=True)
        receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
        formula_source = next(iter(sorted((keg / ".brew").glob("*.rb"))), None)
        source_text = formula_source.read_text() if formula_source else ""
        if formula_source:
            shutil.copyfile(formula_source, target / formula_source.name)
        licenses = []
        for candidate in keg.rglob("*"):
            if not candidate.is_file() or candidate.is_symlink():
                continue
            # Homebrew bottles carry upstream notices at their root or in doc.
            named_notice = re.match(r"^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|AUTHORS)(?:[._-].*)?$", candidate.name, re.I)
            root_spdx = candidate.parent == keg and re.match(r"^(?:A?GPL|LGPL|BSD|MIT|Apache|MPL|ISC)[-_.].*\.txt$", candidate.name, re.I)
            if not named_notice and not root_spdx:
                continue
            relative = candidate.relative_to(keg)
            if len(relative.parts) > 1 and relative.parts[0] not in {"share", "lib"}:
                continue
            copy = target / relative
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate, copy)
            licenses.append(str(relative))
        license_lines = re.findall(r"^\s*license\s+(.+)$", source_text, flags=re.M)
        # Keep build provenance without recording a user's local cache paths.
        record = {
            "formula": formula,
            "version": keg.name,
            "tap": receipt.get("source", {}).get("tap"),
            "poured_from_bottle": receipt.get("poured_from_bottle"),
            "built_on": receipt.get("built_on"),
            "license_declarations": license_lines,
            "license_files": licenses,
            "formula_source": formula_source.name if formula_source else None,
        }
        (target / "build-origin.json").write_text(json.dumps(record, indent=2) + "\n")
        records.append(record)
    return records


def bundle(app: Path) -> None:
    executable = app / "Contents/MacOS/Luma"
    frameworks = app / "Contents/Frameworks"
    third_party = app / "Contents/Resources/ThirdParty"
    if not executable.is_file():
        raise RuntimeError(f"Missing Luma executable: {executable}")
    frameworks.mkdir(parents=True, exist_ok=True)
    third_party.mkdir(parents=True, exist_ok=True)
    executable_commands = load_commands(executable)
    nodes: dict[Path, tuple[list[tuple[str, Path]], list[str], list[str]]] = {}
    names: dict[str, Path] = {}
    pending = [(executable, executable_commands[1])]
    while pending:
        binary, inherited_rpaths = pending.pop()
        if binary in nodes:
            continue
        dependencies, rpaths, minimums = load_commands(binary)
        all_rpaths = [str(expanded(path, binary, executable)) for path in rpaths] + inherited_rpaths
        edges = []
        for name in dependencies:
            if system_library(name):
                continue
            resolved = resolve(name, binary, executable, all_rpaths)
            previous = names.get(resolved.name)
            if previous is not None and previous != resolved:
                raise RuntimeError(f"Dependency name collision: {previous} and {resolved}")
            names[resolved.name] = resolved
            edges.append((name, resolved))
            pending.append((resolved, all_rpaths))
        nodes[binary] = (edges, rpaths, minimums)
    if not any(path.name.startswith("libmpv.") for path in nodes):
        raise RuntimeError("Luma is not linked to libmpv; refusing an incomplete package")

    architectures = set(run("lipo", "-archs", executable).split())
    for original in nodes:
        if original == executable:
            continue
        if not architectures.issubset(set(run("lipo", "-archs", original).split())):
            raise RuntimeError(f"Architecture mismatch in {original.name}")
        shutil.copyfile(original, frameworks / original.name)
        (frameworks / original.name).chmod(0o755)

    for original, (edges, rpaths, _) in nodes.items():
        copied = executable if original == executable else frameworks / original.name
        arguments = ["install_name_tool"]
        if original != executable:
            arguments += ["-id", f"@rpath/{original.name}"]
        for old_name, dependency in edges:
            prefix = "@rpath" if original == executable else "@loader_path"
            arguments += ["-change", old_name, f"{prefix}/{dependency.name}"]
        for rpath in rpaths:
            if not rpath.startswith(("@loader_path", "@executable_path")):
                arguments += ["-delete_rpath", rpath]
        if original == executable and "@executable_path/../Frameworks" not in rpaths:
            arguments += ["-add_rpath", "@executable_path/../Frameworks"]
        if len(arguments) > 1:
            run(*arguments, copied)

    # Refuse an app that still relies on Homebrew or a developer's checkout.
    for binary in [executable, *sorted(frameworks.iterdir())]:
        dependencies, rpaths, _ = load_commands(binary)
        for name in dependencies:
            if system_library(name):
                continue
            resolved = resolve(name, binary, executable, rpaths + ["@executable_path/../Frameworks"])
            if not resolved.is_relative_to(frameworks):
                raise RuntimeError(f"Unbundled dependency in {binary.name}: {name}")
        if any(path.startswith("/") and not system_library(path + "/") for path in rpaths):
            raise RuntimeError(f"Unrelocated rpath in {binary.name}")

    plist_path = app / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    minimums = [info.get("LSMinimumSystemVersion", "13.0")]
    minimums += [minimum for _, _, values in nodes.values() for minimum in values]
    minimum = max(minimums, key=version)
    info["LSMinimumSystemVersion"] = minimum
    plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))

    records = notices({keg for path in nodes if (keg := keg_for(path)) is not None}, third_party)
    manifest = {
        "source": "Homebrew formulae and installed bottles; no IINA binaries",
        "minimum_macos": minimum,
        "architectures": sorted(architectures),
        "libraries": [
            {"file": original.name, "source_sha256": hashlib.sha256(original.read_bytes()).hexdigest(),
             "formula": keg_for(original).parent.name if keg_for(original) else None}
            for original in sorted(nodes) if original != executable
        ],
        "formulae": records,
    }
    (third_party / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copyfile(Path(__file__).parent.parent / "macos/ThirdPartyNotices.md", third_party / "README.md")
    shutil.copyfile(Path(__file__).parent.parent / "macos/Homebrew-LICENSE.txt", third_party / "Homebrew-LICENSE.txt")
    for binary in sorted(frameworks.iterdir()):
        run("codesign", "--force", "--sign", "-", binary)
        run("codesign", "--verify", "--strict", binary)
    size = sum(path.stat().st_size for path in frameworks.iterdir()) / 1024 / 1024
    print(f"Bundled {len(nodes) - 1} libraries ({size:.1f} MiB); minimum macOS {minimum}; {', '.join(sorted(architectures))}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    bundle(arguments.app.resolve())
