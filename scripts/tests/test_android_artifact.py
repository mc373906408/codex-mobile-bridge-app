import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_android_artifact import elf_segments, inspect_artifact


def elf(bits=64, alignment=16384, address=0, machine=None, byte_order="<"):
    header_size, ph_size = (64, 56) if bits == 64 else (52, 32)
    size = header_size + ph_size
    machine = machine if machine is not None else (183 if bits == 64 else 40)
    identification = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1 if byte_order == "<" else 2, 1]) + bytes(9)
    if bits == 64:
        header = struct.pack(byte_order + "16sHHIQQQIHHHHHH", identification, 3, machine, 1,
                             0, header_size, 0, 0, header_size, ph_size, 1, 0, 0, 0)
        segment = struct.pack(byte_order + "IIQQQQQQ", 1, 5, 0, address, address, size, size, alignment)
    else:
        header = struct.pack(byte_order + "16sHHIIIIIHHHHHH", identification, 3, machine, 1,
                             0, header_size, 0, 0, header_size, ph_size, 1, 0, 0, 0)
        segment = struct.pack(byte_order + "IIIIIIII", 1, 0, address, address, size, size, 5, alignment)
    return header + segment


def add_library(archive, name, content, aligned=True, compressed=False):
    member = zipfile.ZipInfo(name)
    member.compress_type = zipfile.ZIP_DEFLATED if compressed else zipfile.ZIP_STORED
    if aligned and not compressed:
        offset = archive.fp.tell() + 30 + len(name.encode("utf-8"))
        padding = (16384 - offset % 16384) % 16384
        if 0 < padding < 4:
            padding += 16384
        if padding:
            member.extra = struct.pack("<HH", 0xCAFE, padding - 4) + bytes(padding - 4)
    archive.writestr(member, content)


class ElfTests(unittest.TestCase):
    def test_32_and_64_bit_load_headers(self):
        for bits in (32, 64):
            for order in ("<", ">"):
                with self.subTest(bits=bits, order=order):
                    data = elf(bits=bits, byte_order=order)
                    machine, segments = elf_segments(io.BytesIO(data), len(data))
                    self.assertEqual(machine, 40 if bits == 32 else 183)
                    self.assertEqual(segments, [16384])

    def test_rejects_small_and_non_power_of_two_alignment(self):
        for alignment in (0, 4096, 8192, 24576):
            with self.subTest(alignment=alignment), self.assertRaisesRegex(ValueError, "alignment"):
                data = elf(alignment=alignment)
                elf_segments(io.BytesIO(data), len(data))

    def test_rejects_incongruent_address(self):
        data = elf(address=4096)
        with self.assertRaisesRegex(ValueError, "congruent"):
            elf_segments(io.BytesIO(data), len(data))

    def test_rejects_truncated_headers_and_segments(self):
        for data in (b"not ELF", elf()[:55], elf()[:-1]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                elf_segments(io.BytesIO(data), len(data))

    def test_rejects_missing_load_segments(self):
        data = bytearray(elf())
        struct.pack_into("<I", data, 64, 2)
        with self.assertRaisesRegex(ValueError, "no LOAD"):
            elf_segments(io.BytesIO(data), len(data))


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "synthetic.apk"

    def test_checks_all_libraries_not_only_rust(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/arm64-v8a/libbridge_native.so", elf())
            add_library(archive, "lib/arm64-v8a/libthird_party.so", elf(alignment=4096))
        with self.assertRaisesRegex(ValueError, "libthird_party.so"):
            inspect_artifact(self.path)

    def test_checks_zip_local_header_alignment(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/arm64-v8a/libbridge_native.so", elf(), aligned=False)
        with self.assertRaisesRegex(ValueError, "ZIP data offset"):
            inspect_artifact(self.path)

    def test_release_requires_flutter_and_app_in_each_expected_abi(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            for name in ("libbridge_native.so", "libflutter.so", "libapp.so"):
                add_library(archive, "lib/arm64-v8a/" + name, elf())
        report = inspect_artifact(self.path, ["arm64-v8a"], release=True)
        self.assertEqual(report["elf_alignment"], "passed")
        self.assertEqual(report["apk_zip_alignment"], "passed")
        self.assertEqual(len(report["libraries"]), 3)
        with self.assertRaisesRegex(ValueError, "x86_64: missing"):
            inspect_artifact(self.path, ["arm64-v8a", "x86_64"], release=True)

    def test_rejects_wrong_machine_for_abi(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/x86_64/libbridge_native.so", elf())
        with self.assertRaisesRegex(ValueError, "does not match"):
            inspect_artifact(self.path)

    def test_compressed_libraries_still_need_elf_alignment(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/arm64-v8a/libbridge_native.so", elf(), compressed=True)
        self.assertEqual(inspect_artifact(self.path)["elf_alignment"], "passed")

    def test_aab_offsets_are_not_mistaken_for_apk_offsets(self):
        path = self.path.with_suffix(".aab")
        with zipfile.ZipFile(path, "w") as archive:
            add_library(archive, "base/lib/arm64-v8a/libbridge_native.so", elf(), aligned=False)
        report = inspect_artifact(path)
        self.assertEqual(report["apk_zip_alignment"], "not_applicable")
        self.assertEqual(report["bundle_alignment"], "not_checked")

    def test_legacy_arm32_dependency_is_explicitly_scoped_to_4kb_devices(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/armeabi-v7a/libbarhopper_v3.so", elf(bits=32, alignment=4096))
        report = inspect_artifact(self.path)
        self.assertEqual(report["libraries"][0]["required_load_alignment"], 4096)

    def test_rust_core_still_requires_16kb_for_arm32(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            add_library(archive, "lib/armeabi-v7a/libbridge_native.so", elf(bits=32, alignment=4096))
        with self.assertRaisesRegex(ValueError, "required 16384"):
            inspect_artifact(self.path)

    def test_rejects_empty_artifact(self):
        with zipfile.ZipFile(self.path, "w"):
            pass
        with self.assertRaisesRegex(ValueError, "no native"):
            inspect_artifact(self.path)


if __name__ == "__main__":
    unittest.main()
