"""Check every packaged ELF, APK ZIP alignment, and optional AAB bundle config."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import subprocess
import sys
import zipfile

PAGE_SIZE = 16384
ABI_MACHINES = {"armeabi-v7a": 40, "arm64-v8a": 183, "x86_64": 62}


def elf_segments(stream, size, minimum_alignment=PAGE_SIZE):
    header = stream.read(64)
    if len(header) < 52 or header[:4] != b"\x7fELF":
        raise ValueError("not an ELF library")
    elf_class, byte_order = header[4:6]
    if elf_class not in (1, 2) or byte_order not in (1, 2):
        raise ValueError("unsupported ELF format")
    order = "<" if byte_order == 1 else ">"
    machine = struct.unpack_from(order + "H", header, 18)[0]
    if elf_class == 2:
        if len(header) < 64:
            raise ValueError("truncated ELF header")
        phoff = struct.unpack_from(order + "Q", header, 32)[0]
        entry_size, count = struct.unpack_from(order + "HH", header, 54)
        layout, minimum_header = order + "IIQQQQQQ", 64
    else:
        phoff = struct.unpack_from(order + "I", header, 28)[0]
        entry_size, count = struct.unpack_from(order + "HH", header, 42)
        layout, minimum_header = order + "IIIIIIII", 52
    if not 0 < count < 65535 or entry_size < struct.calcsize(layout):
        raise ValueError("invalid ELF program-header table")
    if phoff < minimum_header or phoff + entry_size * count > size:
        raise ValueError("ELF program-header table is outside the library")
    segments = []
    for index in range(count):
        stream.seek(phoff + entry_size * index)
        raw = stream.read(struct.calcsize(layout))
        if len(raw) != struct.calcsize(layout):
            raise ValueError("truncated ELF program header")
        fields = struct.unpack(layout, raw)
        if fields[0] != 1:  # PT_LOAD, not section alignment.
            continue
        offset, address, filesz, memsz, alignment = (
            (fields[2], fields[3], fields[5], fields[6], fields[7])
            if elf_class == 2
            else (fields[1], fields[2], fields[4], fields[5], fields[7])
        )
        if alignment < minimum_alignment or alignment & (alignment - 1):
            raise ValueError(f"LOAD alignment {alignment} is below the required {minimum_alignment} bytes or is invalid")
        if (address - offset) % alignment:
            raise ValueError("LOAD address and file offset are not congruent")
        if filesz > memsz or offset + filesz > size:
            raise ValueError("LOAD segment is outside the library")
        segments.append(alignment)
    if not segments:
        raise ValueError("ELF contains no LOAD segments")
    return machine, segments


def zip_data_offset(archive, member):
    with archive.open("rb") as stream:
        stream.seek(member.header_offset)
        header = stream.read(30)
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise ValueError("invalid ZIP local header")
    name_length, extra_length = struct.unpack_from("<HH", header, 26)
    return member.header_offset + 30 + name_length + extra_length


def inspect_artifact(path, expected_abis=(), release=False):
    path = Path(path)
    if path.suffix not in (".apk", ".aab"):
        raise ValueError("expected an APK or Android App Bundle")
    libraries, names = [], {}
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            if not member.filename.endswith(".so"):
                continue
            parts = PurePosixPath(member.filename).parts
            abi = parts[-2] if len(parts) > 1 else "unknown"
            # Android's 16 KB runtime gate applies to arm64/x86_64. Keep 32-bit
            # dependencies for older 4 KB devices, but require our Rust core at 16 KB on every ABI.
            required_alignment = 4096 if abi == "armeabi-v7a" and parts[-1] != "libbridge_native.so" else PAGE_SIZE
            try:
                with archive.open(member) as stream:
                    machine, segments = elf_segments(stream, member.file_size, required_alignment)
                if abi in ABI_MACHINES and machine != ABI_MACHINES[abi]:
                    raise ValueError(f"ELF machine {machine} does not match {abi}")
                data_offset = zip_data_offset(path, member)
                stored = member.compress_type == zipfile.ZIP_STORED
                if path.suffix == ".apk" and stored and data_offset % PAGE_SIZE:
                    raise ValueError(f"uncompressed ZIP data offset {data_offset} is not 16 KB aligned")
            except ValueError as error:
                raise ValueError(f"{member.filename}: {error}") from error
            names.setdefault(abi, set()).add(parts[-1])
            libraries.append({
                "path": member.filename,
                "machine": machine,
                "load_alignments": segments,
                "required_load_alignment": required_alignment,
                "zip_stored": stored,
                "zip_data_offset": data_offset,
            })
    if not libraries:
        raise ValueError("artifact contains no native libraries")
    for abi in expected_abis:
        required = {"libbridge_native.so", "libflutter.so"}
        if release:
            required.add("libapp.so")
        missing = required - names.get(abi, set())
        if missing:
            raise ValueError(f"{abi}: missing {', '.join(sorted(missing))}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "artifact": str(path.resolve()),
        "sha256": digest,
        "size_bytes": path.stat().st_size,
        "elf_alignment": "passed",
        "apk_zip_alignment": "passed" if path.suffix == ".apk" else "not_applicable",
        "bundle_alignment": "not_checked" if path.suffix == ".aab" else "not_applicable",
        "device_test": "not_performed",
        "libraries": libraries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--expect-abi", action="append", default=[], choices=ABI_MACHINES)
    parser.add_argument("--release", action="store_true", help="Also require libapp.so for each expected ABI")
    parser.add_argument("--zipalign", type=Path, help="Additionally run the Android SDK verifier")
    parser.add_argument("--bundletool", type=Path, help="Verify AAB PAGE_ALIGNMENT_16K with this official JAR")
    parser.add_argument("--json", type=Path, help="Write a machine-readable verification report")
    args = parser.parse_args()
    report = inspect_artifact(args.artifact, args.expect_abi, args.release)
    if args.zipalign and args.artifact.suffix == ".apk":
        subprocess.run([str(args.zipalign), "-c", "-P", "16", "4", str(args.artifact)], check=True)
        report["zipalign"] = "passed"
    if args.bundletool and args.artifact.suffix == ".aab":
        config = subprocess.check_output([
            "java", "-jar", str(args.bundletool), "dump", "config", f"--bundle={args.artifact}",
        ], text=True, encoding="utf-8")
        if "PAGE_ALIGNMENT_16K" not in config:
            raise ValueError("bundletool did not confirm PAGE_ALIGNMENT_16K")
        report["bundle_alignment"] = "passed"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {args.artifact.name}: {len(report['libraries'])} ELF libraries; SHA-256 {report['sha256']}")
    for library in report["libraries"]:
        scope = " (32-bit / 4 KB devices)" if library["required_load_alignment"] == 4096 else ""
        print(f"  {library['path']}: LOAD >= {min(library['load_alignments'])} bytes{scope}")
    if report["bundle_alignment"] == "not_checked":
        print("AAB packaging alignment NOT CHECKED: supply --bundletool. AAB ZIP offsets are not APK offsets.")
    print("This is a static packaging check, not a device, signing, or store-approval test.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
