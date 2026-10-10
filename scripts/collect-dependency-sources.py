#!/usr/bin/env python3
"""Collect the exact Homebrew sources, recipes and patches used by a Luma app.

Run on the build machine before upgrading its Homebrew dependencies. Downloads
are checked against the installed recipes, never against today's formula version.
Git inputs must pin a full commit. Extra inputs can be supplied with --supplement.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse


RUBY_METADATA = r'''
require "formula"
def source(r)
  {url: r.url, sha256: r.checksum.to_s, mirrors: r.mirrors, specs: r.specs}
end
puts JSON.generate(ARGV.map do |path|
  f = Formulary.factory(Pathname.new(path))
  h = f.to_hash
  {name: f.name, version: f.pkg_version.to_s, license: h["license"],
   source: source(f.stable), dependencies: h["dependencies"],
   build_dependencies: h["build_dependencies"],
   resources: f.resources.map do |r|
     raise "Nested resource patches need explicit collection: #{f.name}/#{r.name}" unless r.patches.empty?
     source(r).merge(name: r.name, version: r.version.to_s)
   end,
   patches: f.stable.patches.map do |p|
     base = {type: p.class.name, strip: p.strip}
     if p.respond_to?(:resource)
       base.merge(source(p.resource))
     elsif p.is_a?(LocalPatch)
       base.merge(file: p.file.to_s)
     else
       base.merge(content: p.contents)
     end
   end}
end)
'''


def run(*args: str | Path, **kwargs) -> str:
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(value: str) -> str:
    result = re.sub(r"[^A-Za-z0-9@._-]", "-", value)
    if result in {"", ".", ".."}:
        raise ValueError(f"Invalid file name: {value!r}")
    return result


def fetch(item: dict, root: Path) -> dict:
    item = dict(item)
    relative = Path(item["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError(f"Source output escapes archive root: {item['path']}")
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    expected = item.get("sha256")
    revision = item.get("specs", {}).get("revision")
    if not expected and not revision:
        raise RuntimeError(f"Source lacks a pinned SHA-256 or Git revision: {item['url']}")
    if path.exists() and expected and sha256(path) == expected:
        item["size"] = path.stat().st_size
        return item
    partial = path.with_name(path.name + ".partial")
    if revision:
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise RuntimeError(f"Git revision must be a full commit: {revision}")
        # Fetch through Git so the commit and tree identities are checked rather
        # than relying on a server-generated archive bearing a commit's name.
        with tempfile.TemporaryDirectory(prefix="luma-source-") as tmp:
            repo = Path(tmp)
            run("git", "init", "--quiet", repo)
            run("git", "-C", repo, "remote", "add", "origin", item["url"])
            run("git", "-C", repo, "fetch", "--quiet", "--depth=1", "origin", revision)
            if run("git", "-C", repo, "rev-parse", "FETCH_HEAD") != revision:
                raise RuntimeError(f"Git revision mismatch: {item['url']}")
            links = [l for l in run("git", "-C", repo, "ls-tree", "-r", revision).splitlines() if l.startswith("160000 ")]
            if links:
                raise RuntimeError(f"Uncollected submodules in {item['url']}: {links}")
            raw = repo / "source.tar"
            run("git", "-C", repo, "archive", "--format=tar", f"--output={raw}", revision)
            with raw.open("rb") as src, partial.open("wb") as dst:
                with gzip.GzipFile(filename="", mode="wb", fileobj=dst, mtime=0) as gz:
                    shutil.copyfileobj(src, gz)
    else:
        errors = []
        for url in [item["url"], *item.get("mirrors", [])]:
            try:
                run("curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "2", "--connect-timeout", "20", "--max-time", "300",
                    "--output", partial, url)
                if sha256(partial) != expected:
                    raise RuntimeError(f"SHA-256 mismatch for {url}")
                break
            except RuntimeError as error:
                errors.append(str(error))
        else:
            raise RuntimeError("; ".join(errors))
    actual = sha256(partial)
    if expected and actual != expected:
        raise RuntimeError(f"SHA-256 mismatch for {item['url']}")
    partial.replace(path)
    item.update(sha256=actual, size=path.stat().st_size)
    print(f"Collected {item['path']} ({item['size'] / 1048576:.1f} MiB)", flush=True)
    return item


def source_entry(package: str, role: str, source: dict) -> dict:
    source = dict(source)
    revision = source.get("specs", {}).get("revision")
    basename = safe_name(Path(urlparse(source["url"]).path).name)
    if revision:
        basename = f"{safe_name(source.get('name', package))}-{revision}.tar.gz"
    source.update(package=package, role=role, path=f"packages/{package}/{role}/{basename}")
    return source


def archive(root: Path, destination: Path) -> None:
    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        return info
    with destination.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w|") as tar:
                tar.add(root, arcname=root.name, filter=normalize)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/release"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--supplement", type=Path, help="Pinned additional sources and local patches as a JSON array")
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*(?:[-a-zA-Z0-9.]*)?", args.version):
        parser.error("Invalid release version")
    thirdparty = args.app / "Contents/Resources/ThirdParty"
    manifest = json.loads((thirdparty / "manifest.json").read_text())
    root = args.output / f"Luma-{args.version}-dependency-sources"
    root.mkdir(parents=True, exist_ok=True)
    cellar = Path(run("brew", "--cellar"))
    formula_paths = []
    for formula in manifest["formulae"]:
        name, version = formula["formula"], formula["version"]
        recipe = cellar / name / version / ".brew" / formula["formula_source"]
        bundled_recipe = thirdparty / name / formula["formula_source"]
        if recipe.read_bytes() != bundled_recipe.read_bytes():
            raise RuntimeError(f"Installed and bundled recipe differ: {name}")
        formula_paths.append(recipe)
        target = root / "packages" / name / "build"
        target.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(recipe, target / recipe.name)
        shutil.copyfile(thirdparty / name / "build-origin.json", target / "build-origin.json")
        sbom = cellar / name / version / "sbom.spdx.json"
        if sbom.is_file():
            shutil.copyfile(sbom, target / "homebrew.spdx.json")
    env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_DEVELOPER="1")
    metadata = json.loads(run("brew", "ruby", "-e", RUBY_METADATA, *formula_paths, env=env))
    supplement = json.loads(args.supplement.read_text()) if args.supplement else []
    entries = []
    for package in metadata:
        name = package["name"]
        entries.append(source_entry(name, "upstream", package["source"]))
        entries.extend(source_entry(name, "resources", resource) for resource in package["resources"])
        for index, patch in enumerate(package["patches"]):
            if patch.get("url"):
                entries.append(source_entry(name, "patches", patch))
            elif patch.get("content"):
                target = root / "packages" / name / "patches" / f"embedded-{index}.patch"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(patch["content"])
            elif patch.get("file"):
                if not any(s.get("package") == name and s.get("original_path") == patch["file"] for s in supplement):
                    raise RuntimeError(f"Supply pinned local patch with --supplement: {name}/{patch['file']}")
            else:
                raise RuntimeError(f"Unsupported patch: {patch}")
    entries.extend(supplement)
    failures = []
    completed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {executor.submit(fetch, entry, root): entry for entry in entries}
        for future in concurrent.futures.as_completed(futures):
            try:
                completed.append(future.result())
            except Exception as error:
                failures.append(str(error))
                print(f"ERROR: {error}", flush=True)
    if failures:
        raise RuntimeError(f"Incomplete source collection ({len(failures)} failures); archive was not produced")
    shutil.copyfile(thirdparty / "manifest.json", root / "binary-manifest.json")
    if args.supplement:
        shutil.copyfile(args.supplement, root / "source-supplement.json")
    (root / "source-manifest.json").write_text(json.dumps({"formulae": metadata, "downloads": sorted(completed, key=lambda i: i["path"])}, indent=2) + "\n")
    (root / "README.txt").write_text(
        "Luma dependency sources\n\n"
        "This archive accompanies the Luma application source release. Each package\n"
        "contains the upstream source archive, the installed Homebrew formula (build\n"
        "recipe, options and inline modifications), and external build resources\n"
        "and patches. source-manifest.json records their origins and checksums.\n"
        "binary-manifest.json maps the packaged dylibs to these package versions.\n\n"
        "Build using the included recipes on macOS with Apple's command-line tools\n"
        "and Homebrew; the formulae name their build dependencies. The Luma source\n"
        "archive contains its Swift source and scripts/build-macos.sh, which links\n"
        "libmpv and relocates and ad-hoc signs the resulting dylib closure.\n"
        "General-purpose compilers and build tools are not included here.\n\n"
        "Third-party sources retain their upstream licenses and notices. The app\n"
        "is distributed under GPL-3.0-or-later. See its LICENSE and third-party\n"
        "notices and each upstream archive for the applicable terms.\n"
    )
    # Reject local usernames/paths in generated text before making a public asset.
    for path in root.rglob("*"):
        if path.is_file() and path.suffix in {".json", ".txt", ".rb", ".patch", ".diff"}:
            if re.search(rb"/Users/[^/\s]+/", path.read_bytes()):
                raise RuntimeError(f"Local user path in release metadata: {path.relative_to(root)}")
    if any(root.rglob("*.partial")):
        raise RuntimeError("Incomplete downloads remain; refusing to archive .partial files")
    checksum_file = root / "SHA256SUMS.txt"
    checksums = [f"{sha256(p)}  {p.relative_to(root)}\n" for p in sorted(root.rglob("*"))
                 if p.is_file() and p != checksum_file]
    checksum_file.write_text("".join(checksums))
    destination = args.output / f"{root.name}.tar.gz"
    temporary_archive = destination.with_name(destination.name + ".partial")
    archive(root, temporary_archive)
    temporary_archive.replace(destination)
    print(f"Created {destination} ({destination.stat().st_size / 1048576:.1f} MiB)")


if __name__ == "__main__":
    main()
