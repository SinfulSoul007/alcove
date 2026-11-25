"""Inspect owned arm64 images and remove reviewed developer load metadata.

This module never loads an image or edits executable/data sections. Its input is
the separately authenticated source-built engine, not arbitrary installed code.
"""
import hashlib
import struct

ENVIRONMENT = 0x27
APPROVED_ENVIRONMENT = {'DYLD_FRAMEWORK_PATH', 'DYLD_LIBRARY_PATH'}
DYLIB_COMMANDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command_string(raw, minimum):
    require(len(raw) >= minimum, 'Truncated load command string')
    offset = struct.unpack_from('<I', raw, 8)[0]
    require(minimum <= offset < len(raw), 'Invalid load command string offset')
    end = raw.find(b'\0', offset)
    require(end >= 0, 'Unterminated load command string')
    try:
        return raw[offset:end].decode('utf-8', errors='strict')
    except UnicodeDecodeError as error:
        raise ValueError('Invalid load command string encoding') from error


def inspect_image(data):
    require(len(data) >= 32, 'Expected a complete thin arm64 image')
    header = struct.unpack_from('<8I', data)
    require(header[0] == 0xFEEDFACF and header[1] == 0x0100000C,
            'Only thin little-endian arm64 images are approved')
    count, size = header[4:6]
    require(0 < count <= 4096 and count * 8 <= size <= min(4*1024*1024, len(data)-32),
            'Invalid load command inventory')
    end, cursor = 32 + size, 32
    commands, sections, environment, dependencies, rpaths, builds = [], [], [], [], [], []
    identity = None
    for _ in range(count):
        require(cursor + 8 <= end, 'Truncated load command table')
        kind, length = struct.unpack_from('<II', data, cursor)
        require(length >= 8 and length % 8 == 0 and cursor + length <= end,
                'Invalid load command size')
        raw = data[cursor:cursor+length]
        commands.append((kind, raw))
        if kind == 0x19:  # segment_command_64, followed by section_64 records
            require(length >= 72, 'Truncated segment load command')
            segment = struct.unpack_from('<II16sQQQQiiII', raw)
            file_offset, file_size, number = segment[5], segment[6], segment[9]
            require(number <= 4096 and length == 72 + number * 80,
                    'Invalid segment load command sections')
            require(file_offset + file_size <= len(data), 'Segment content exceeds image')
            for index in range(number):
                section = struct.unpack_from('<16s16sQQIIIIIIII', raw, 72 + index*80)
                section_size, offset, flags = section[3], section[4], section[8]
                stored = flags & 0xFF not in {1, 0xC, 0x12}
                if stored and section_size:
                    require(offset >= end and offset >= file_offset and
                            offset + section_size <= file_offset + file_size,
                            'Invalid section content range')
                sections.append({'name': section[0].split(b'\0')[0].decode('ascii'),
                                 'segment': section[1].split(b'\0')[0].decode('ascii'),
                                 'offset': offset, 'size': section_size, 'stored': stored,
                                 'sha256': digest(memoryview(data)[offset:offset+section_size]) if stored else None})
        elif kind in DYLIB_COMMANDS:
            name = command_string(raw, 24)
            if kind == 0xD:
                require(identity is None, 'Duplicate library identity load command')
                identity = name
            else:
                dependencies.append(name)
        elif kind == 0x8000001C:
            rpaths.append(command_string(raw, 12))
        elif kind == ENVIRONMENT:
            environment.append(command_string(raw, 12))
        elif kind == 0x32:
            require(length >= 24, 'Truncated platform load command')
            platform, minimum, sdk, tools = struct.unpack_from('<4I', raw, 8)
            require(length == 24 + tools*8, 'Invalid platform load command tools')
            builds.append({'platform': platform, 'minimum': minimum, 'sdk': sdk})
        cursor += length
    require(cursor == end, 'Invalid load command count or table size')
    require(len(builds) == 1, 'Expected exactly one platform load command')
    return {'header': header, 'tableEnd': end, '_commands': commands,
            'identity': identity, 'dependencies': dependencies, 'rpaths': rpaths,
            'environment': environment, 'platform': builds[0], 'sections': sections}


def approved_environment(values):
    for value in values:
        name, separator, _ = value.partition('=')
        require(separator and name in APPROVED_ENVIRONMENT,
                'Unapproved developer environment load command')


def remove_developer_environment(data):
    image = inspect_image(data)
    approved_environment(image['environment'])
    if not image['environment']:
        return data
    kept = [raw for kind, raw in image['_commands'] if kind != ENVIRONMENT]
    table = b''.join(kept)
    output = bytearray(data)
    struct.pack_into('<II', output, 16, len(kept), len(table))
    output[32:image['tableEnd']] = table + bytes(image['tableEnd'] - 32 - len(table))
    return bytes(output)


def verify_derivation(before, after, allowed_changes):
    require(allowed_changes == {'removeDeveloperEnvironment': True},
            'Unsupported metadata derivation policy')
    original, derived = inspect_image(before), inspect_image(after)
    require(len(before) == len(after), 'Image content length changed')
    require(original['sections'] == derived['sections'], 'Executable/data section content changed')
    require(original['platform'] == derived['platform'], 'Platform load command changed')
    require(before[:16] == after[:16] and before[24:32] == after[24:32], 'Image header identity changed')
    approved_environment(original['environment'])
    require(not derived['environment'], 'Developer environment load commands remain')
    kept = [item for item in original['_commands'] if item[0] != ENVIRONMENT]
    require(kept == derived['_commands'], 'Unapproved load command change')
    old_end, new_end = original['tableEnd'], derived['tableEnd']
    require(new_end <= old_end and after[new_end:old_end] == bytes(old_end-new_end),
            'Removed load command space is not zeroed')
    require(before[old_end:] == after[old_end:], 'Image content outside load commands changed')
    return {'inputSHA256': digest(before), 'outputSHA256': digest(after),
            'removedEnvironmentCommands': len(original['environment']),
            'sectionCount': len(original['sections']), 'sectionBytesAndOffsetsUnchanged': True}
