#!/usr/bin/env python3
"""Author a small, unencrypted BD-J disc using Plozz's original test clips."""
from pathlib import Path
import shutil
import struct


def u16(value: int) -> bytes:
    return struct.pack(">H", value)


def u32(value: int) -> bytes:
    return struct.pack(">I", value)


def section(data: bytes) -> bytes:
    return u32(len(data)) + data


def app_string(value: str) -> bytes:
    data = value.encode("ascii")
    if len(data) > 255:
        raise ValueError("BDJO application string exceeds 255 bytes")
    return bytes([len(data)]) + data + (b"\0" if len(data) % 2 == 0 else b"")


def index() -> bytes:
    # BD-J interactive object, referencing BDJO/00000.bdjo.
    title = u32(2 << 30) + u16(3 << 14) + b"00000\0"
    application = section(b"\x00\x51" + bytes(32))
    titles = section(title + title + u16(1) + title)
    return b"INDX0200" + u32(78) + u32(0) + bytes(24) + application + titles


def bdjo() -> bytes:
    terminal = section(b"*****" + b"\x20" + bytes(4))
    cache = section(b"\x01\0" + b"\x01" + b"00000eng" + bytes(3))
    playlists = section(u32(2 << 21) + b"00001\0" + b"00002\0")
    descriptor = u16(1 << 12) + u16(1) + b"\x01\0\0\0"
    descriptor += b"\x01\x10" + u16(0)
    descriptor += app_string("") + u16(0)
    descriptor += app_string("00000") + app_string("")
    descriptor += app_string("org.plozz.disclab.MenuXlet") + b"\0\0"
    app = b"\x01\x10" + u32(0x504C4F5A) + u16(1)
    app += b"\0\0" + u32(len(descriptor) + 4) + bytes(4) + descriptor
    applications = section(b"\x01\0" + app)
    sections = [terminal, cache, playlists, applications, bytes(4), u16(0)]
    offset = 48
    addresses = []
    for data in sections:
        addresses.append(offset)
        offset += len(data)
    return b"BDJO0200" + b"".join(u32(x) for x in addresses) + bytes(16) + b"".join(sections)


def stream_entry(pid: int, attributes: bytes) -> bytes:
    return b"\x03\x01" + u16(pid) + bytes([len(attributes)]) + attributes


def playlist(clip: str, audio_pids=(0x1100,)) -> bytes:
    streams = bytes(2) + bytes([1, len(audio_pids)]) + bytes(10)
    streams += stream_entry(0x1011, b"\x1b\x51")
    for pid in audio_pids:
        streams += stream_entry(pid, b"\x81\x31eng")
    item = clip.encode("ascii") + b"M2TS" + u16(1) + b"\0"
    item += u32(0) + u32(8 * 45000) + bytes(8) + b"\x80\0\0\0"
    item += u16(len(streams)) + streams
    body = section(u16(0) + u16(1) + u16(0) + u16(len(item)) + item)
    marks = section(u16(1) + struct.pack(">BBHIHI", 0, 1, 0, 0, 0xFFFF, 0))
    application = section(b"\0\x01\0\0" + bytes(8) + b"\x80\0")
    return (b"MPLS0200" + u32(64) + u32(64 + len(body)) + u32(0) +
            bytes(20) + application + bytes(6) + body + marks)


def clip_info(packet_count: int, audio_pids=(0x1100,)) -> bytes:
    clip = section(bytes(2) + b"\x01\x01" + u32(0) + u32(1200000) +
                   u32(packet_count) + bytes(128) + u16(0))
    sequence = section(b"\0\x01" + u32(0) + b"\x01\0" +
                       u16(0x1011) + u32(0) + u32(0) + u32(8 * 45000))
    streams = u16(0x1011) + b"\x03\x1b\x51\x30"
    for pid in audio_pids:
        streams += u16(pid) + b"\x05\x81\x31eng"
    program = section(b"\0\x01" + u32(0) + u16(0x100) + bytes([1 + len(audio_pids), 0]) + streams)
    sequence_offset = 40 + len(clip)
    program_offset = sequence_offset + len(sequence)
    cpi_offset = program_offset + len(program)
    # One real access point at the first packet. These short clips only test
    # startup; arbitrary seeking requires an index of the other keyframes.
    entry = (0x1011 << 80) | (1 << 66) | (1 << 50) | (1 << 32) | 14
    cpi = section(u16(1) + b"\0\x01" + entry.to_bytes(12, "big") +
                  u32(12) + u32(0) + u32(0) + u32(0x80000000))
    return (b"HDMV0200" + u32(sequence_offset) + u32(program_offset) +
            u32(cpi_offset) + u32(cpi_offset + len(cpi)) + u32(0) + bytes(12) +
            clip + sequence + program + cpi + u32(0))


def create_hdmv_metadata(destination: Path, source_clips: Path) -> None:
    """Two original eight-second playlists: first play and a looping top menu."""
    destination.mkdir(parents=True, exist_ok=False)
    for folder in ("PLAYLIST", "CLIPINF"):
        (destination / "BDMV" / folder).mkdir(parents=True)

    def title(number):
        return u32(1 << 30) + u16(0) + u16(number) + bytes(4)

    application = section(b"\x00\x51" + bytes(32))
    titles = section(title(0) + title(1) + u16(1) + title(1))
    (destination / "BDMV/index.bdmv").write_bytes(
        b"INDX0200" + u32(78) + u32(0) + bytes(24) + application + titles)
    objects = bytes(4) + u16(2)
    for number in (1, 2):
        commands = u32(0x22800000) + u32(number) + u32(0)
        commands += u32(0x21810000) + u32(0) + u32(0)
        objects += u16(0) + u16(2) + commands
    (destination / "BDMV/MovieObject.bdmv").write_bytes(b"MOBJ0200" + bytes(32) + section(objects))
    for clip in ("00001", "00002"):
        size = (source_clips / f"{clip}.m2ts").stat().st_size
        if not size or size % 192:
            raise ValueError("Expected complete original M2TS clips")
        (destination / f"BDMV/PLAYLIST/{clip}.mpls").write_bytes(playlist(clip))
        (destination / f"BDMV/CLIPINF/{clip}.clpi").write_bytes(clip_info(size // 192))

    multi_audio = source_clips / "00004.m2ts"
    if multi_audio.exists():
        size = multi_audio.stat().st_size
        if not size or size % 192:
            raise ValueError("Expected a complete original multi-audio M2TS clip")
        (destination / "audio-selection.mpls").write_bytes(playlist("00004", (0x1101, 0x1100)))
        (destination / "BDMV/CLIPINF/00004.clpi").write_bytes(clip_info(size // 192, (0x1100, 0x1101)))


def create(destination: Path, source_clips: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    for name in ("PLAYLIST", "STREAM", "CLIPINF", "BDJO", "JAR", "AUXDATA"):
        (destination / "BDMV" / name).mkdir(parents=True)
    (destination / "CERTIFICATE").mkdir()
    # A deterministic, original disc identifier; no encryption keys or certificates.
    (destination / "CERTIFICATE/id.bdmv").write_bytes(
        b"BDID0200" + bytes(32) + bytes.fromhex("504c4f5a5a444953434c41423030303031") + bytes(4))
    (destination / "BDMV/index.bdmv").write_bytes(index())
    (destination / "BDMV/BDJO/00000.bdjo").write_bytes(bdjo())
    for clip in ("00001", "00002"):
        source = source_clips / f"{clip}.m2ts"
        size = source.stat().st_size
        if size == 0 or size % 192:
            raise ValueError(f"{source.name}: expected complete 192-byte M2TS packets")
        shutil.copyfile(source, destination / f"BDMV/STREAM/{clip}.m2ts")
        (destination / f"BDMV/PLAYLIST/{clip}.mpls").write_bytes(playlist(clip))
        (destination / f"BDMV/CLIPINF/{clip}.clpi").write_bytes(clip_info(size // 192))
