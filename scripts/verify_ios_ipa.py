#!/usr/bin/env python3
"""Structural release gate for a single thin-arm64 iPhoneOS app IPA.

Uses only the standard library; never extracts or executes archive contents.
Fat binaries, app extensions and other architectures are outside this gate's
release scope. Signature checks establish presence/structure only, NOT trust,
cryptographic validity, provisioning, entitlement compatibility or installability.
Dynamic-library resolution is not checked. Unsigned IPAs are allowed by default.
"""

import argparse
import hashlib
import json
import plistlib
import re
import stat
import struct
import sys
import zipfile
import zlib
from pathlib import Path


class ValidationError(ValueError):
    """The artifact violates this release gate's structural contract."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value),
            "MinimumOSVersion must be a numeric major.minor[.patch] string")
    parts = tuple(int(part) for part in value.split("."))
    require(parts[0] <= 65535 and all(part <= 255 for part in parts[1:]),
            "MinimumOSVersion is outside Mach-O version range")
    return parts + (0,) * (3 - len(parts))


def unpack_version(value):
    return value >> 16, (value >> 8) & 255, value & 255


def inspect_macho(data, minimum):
    require(len(data) >= 32, "Truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<8I", data)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C,
            "Only thin little-endian 64-bit arm64 Mach-O is supported")
    require(filetype == 2, "Main executable is not MH_EXECUTE")
    end = 32 + sizeofcmds
    require(end <= len(data) and ncmds <= sizeofcmds // 8,
            "Mach-O load-command region is out of bounds")
    offset = 32
    build = None
    encryption = None
    signature = None
    for _ in range(ncmds):
        require(offset + 8 <= end, "Truncated Mach-O load command")
        cmd, size = struct.unpack_from("<2I", data, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= end,
                "Invalid Mach-O load-command size")
        if cmd == 0x32:  # LC_BUILD_VERSION
            require(build is None and size >= 24, "Invalid/duplicate LC_BUILD_VERSION")
            platform, minos, sdk, ntools = struct.unpack_from("<4I", data, offset + 8)
            require(size == 24 + ntools * 8, "Invalid LC_BUILD_VERSION tool table")
            require(platform == 2, "Executable is not built for iPhoneOS (platform 2)")
            require(unpack_version(minos) == minimum,
                    "Mach-O minimum OS does not match Info.plist MinimumOSVersion")
            require(unpack_version(sdk) >= minimum, "Mach-O SDK predates minimum OS")
            build = platform
        elif cmd == 0x2C:  # LC_ENCRYPTION_INFO_64
            require(encryption is None and size == 24,
                    "Invalid/duplicate LC_ENCRYPTION_INFO_64")
            cryptoff, cryptsize, cryptid, pad = struct.unpack_from("<4I", data, offset + 8)
            require(cryptoff + cryptsize <= len(data), "Encryption range is out of bounds")
            require(cryptid == 0, "Encrypted executable cannot be used for this release")
            encryption = cryptid
        elif cmd == 0x21:  # LC_ENCRYPTION_INFO belongs to the unsupported 32-bit format.
            raise ValidationError("Unexpected 32-bit encryption command in arm64 executable")
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            require(signature is None and size == 16, "Invalid/duplicate LC_CODE_SIGNATURE")
            start, length = struct.unpack_from("<2I", data, offset + 8)
            require(start >= end and length >= 12 and start + length <= len(data),
                    "Code signature range is empty or out of bounds")
            blob_magic, blob_length, count = struct.unpack_from(
                ">3I", data, start)
            require(blob_magic == 0xFADE0CC0 and 12 <= blob_length <= length,
                    "Invalid embedded code-signature blob magic/length")
            require(count > 0 and 12 + count * 8 <= blob_length,
                    "Invalid embedded code-signature index")
            for index in range(count):
                _, relative = struct.unpack_from(
                    ">2I", data, start + 12 + index * 8)
                require(relative >= 12 + count * 8 and relative + 8 <= blob_length,
                        "Code-signature child offset is out of bounds")
                _, child_length = struct.unpack_from(
                    ">2I", data, start + relative)
                require(child_length >= 8 and relative + child_length <= blob_length,
                        "Code-signature child length is out of bounds")
            signature = True
        offset += size
    require(offset == end, "Mach-O load-command count/size mismatch")
    require(build is not None, "Missing LC_BUILD_VERSION")
    return {"arch": "arm64", "platform": "iPhoneOS", "encrypted": False,
            "signature_present": signature is not None}


def validate_members(archive):
    members = {}
    folded = set()
    for entry in archive.infolist():
        name = entry.filename
        # Treat Windows separators and drive paths as unsafe even on POSIX.
        require(name and "\\" not in entry.orig_filename and "\x00" not in entry.orig_filename
                and not name.startswith("/") and ":" not in name,
                "Unsafe ZIP member path")
        parts = name.rstrip("/").split("/")
        require(all(part not in ("", ".", "..") for part in parts),
                "Unsafe ZIP member path")
        normalized = name.rstrip("/")
        require(normalized.casefold() not in folded, "Duplicate/colliding ZIP member")
        folded.add(normalized.casefold())
        mode = entry.external_attr >> 16
        require(not stat.S_ISLNK(mode), "ZIP symlinks are not supported")
        require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR),
                "Unsupported ZIP member file type")
        require(not entry.flag_bits & 1, "Encrypted ZIP entries are not supported")
        members[name] = entry
    for name in members:
        parts = name.rstrip("/").split("/")
        for depth in range(1, len(parts)):
            parent = members.get("/".join(parts[:depth]))
            require(parent is None or parent.is_dir(), "ZIP file/directory path collision")
    require(archive.testzip() is None, "ZIP CRC verification failed")
    return members


def verify_ipa(path, expected_version=None, expected_bundle_id=None, require_signature=False):
    """Return non-secret metadata, raising ValidationError on a structural failure."""
    path = Path(path)
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        size = stream.tell()
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            members = validate_members(archive)
            apps = {name.split("/")[1] for name in members
                    if name.startswith("Payload/") and len(name.split("/")) >= 3
                    and name.split("/")[1].endswith(".app")}
            require(len(apps) == 1, "Expected exactly one Payload/*.app")
            root = "Payload/" + next(iter(apps)) + "/"
            require(not any(part.lower().endswith(".appex") for name in members
                            for part in name.rstrip("/").split("/")),
                    "App extensions are outside this release gate's scope")
            info_name = root + "Info.plist"
            require(info_name in members and not members[info_name].is_dir(),
                    "Missing app Info.plist")
            try:
                info = plistlib.loads(archive.read(info_name))
            except Exception as exc:
                # Do not echo plist content or credentials into build logs.
                raise ValidationError("Invalid app Info.plist") from exc
            require(isinstance(info, dict), "Info.plist must contain a dictionary")
            for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
                require(isinstance(info.get(key), str) and info[key].strip(),
                        "Missing/invalid " + key)
            require(info.get("CFBundlePackageType") == "APPL", "Bundle package type must be APPL")
            require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
                    "Bundle must support iPhoneOS only")
            families = info.get("UIDeviceFamily")
            require(isinstance(families, list) and all(type(item) is int for item in families)
                    and 1 in families, "UIDeviceFamily must include iPhone (1)")
            minimum = version_tuple(info.get("MinimumOSVersion"))
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and executable not in ("", ".", "..")
                    and not any(char in executable for char in "/\\:\x00"),
                    "CFBundleExecutable must be a basename")
            executable_name = root + executable
            require(executable_name in members and not members[executable_name].is_dir(),
                    "Missing main executable")
            entry = members[executable_name]
            if entry.create_system == 3:
                require((entry.external_attr >> 16) & 0o111,
                        "Unix main executable has no executable mode bits")
            metadata = inspect_macho(archive.read(entry), minimum)
            if metadata["signature_present"]:
                resources = members.get(root + "_CodeSignature/CodeResources")
                require(resources is not None and not resources.is_dir() and resources.file_size > 0,
                        "Signature present but _CodeSignature/CodeResources missing/empty")
            require(not require_signature or metadata["signature_present"],
                    "A code signature is required")
            require(expected_version is None or info["CFBundleShortVersionString"] == expected_version,
                    "Bundle version does not match expected version")
            require(expected_bundle_id is None or info["CFBundleIdentifier"] == expected_bundle_id,
                    "Bundle identifier does not match expected identifier")
            return {"bundle_id": info["CFBundleIdentifier"],
                    "version": info["CFBundleShortVersionString"],
                    "build": info["CFBundleVersion"], "minimum_os": info["MinimumOSVersion"],
                    **metadata, "zip_size": size, "sha256": digest.hexdigest()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-bundle-id")
    parser.add_argument("--require-signature", action="store_true",
                        help="Require signature structure/resources; does NOT verify cryptographic validity")
    args = parser.parse_args(argv)
    try:
        result = verify_ipa(args.path, args.expected_version, args.expected_bundle_id,
                            args.require_signature)
    except (ValidationError, OSError, zipfile.BadZipFile, RuntimeError,
            NotImplementedError, EOFError, zlib.error) as exc:
        message = str(exc) if isinstance(exc, ValidationError) else "Unreadable or corrupt IPA archive"
        print(json.dumps({"error": message}), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
