"""Bound native masked PNGs to MCP image blocks, without duplicate base64 text."""
from __future__ import annotations

import base64
import binascii
import json
import hashlib
import math
import struct
import zlib

MAX_PNG_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_IMAGE_PIXELS = 12000000


def _png_dimensions(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Native image is not a PNG")
    offset, dimensions, ended, pixel_data = 8, None, False, False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Native PNG is truncated")
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        if end > len(data):
            raise ValueError("Native PNG chunk is truncated")
        body = data[offset + 8:offset + 8 + size]
        expected = struct.unpack(">I", data[end - 4:end])[0]
        if zlib.crc32(kind + body) & 0xffffffff != expected:
            raise ValueError("Native PNG checksum mismatch")
        if dimensions is None:
            if kind != b"IHDR" or size != 13:
                raise ValueError("Native PNG lacks its first IHDR")
            dimensions = struct.unpack(">II", body[:8])
        elif kind == b"IHDR":
            raise ValueError("Native PNG has multiple IHDR chunks")
        if kind == b"IDAT":
            pixel_data = True
        if kind == b"IEND":
            if size or end != len(data):
                raise ValueError("Native PNG has invalid trailing data")
            ended = True
            break
        offset = end
    if not ended or not pixel_data or dimensions is None or any(x <= 0 or x > 16384 for x in dimensions) or dimensions[0] * dimensions[1] > MAX_IMAGE_PIXELS:
        raise ValueError("Native PNG dimensions/completion are invalid")
    return dimensions


def _validate_image(image, parent):
    if not isinstance(image, dict) or image.get("mime_type") != "image/png":
        raise ValueError("Native image MIME must be image/png")
    encoded = image.get("data")
    if not isinstance(encoded, str) or not encoded or len(encoded) > ((MAX_PNG_BYTES + 2) // 3) * 4:
        raise ValueError("Native image base64 size is invalid")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Native image base64 is invalid") from error
    if not data or len(data) > MAX_PNG_BYTES or base64.b64encode(data).decode("ascii") != encoded:
        raise ValueError("Native image encoding/size is invalid")
    width, height = _png_dimensions(data)
    if type(image.get("width")) is not int or type(image.get("height")) is not int or (image["width"], image["height"]) != (width, height):
        raise ValueError("Native PNG dimensions do not match image metadata")
    snapshot = parent.get("snapshot_id")
    if not isinstance(snapshot, str) or not snapshot or image.get("snapshot_id") != snapshot:
        raise ValueError("Native image snapshot binding mismatch")
    if type(parent.get("target_pid")) is not int or parent["target_pid"] <= 0 or not isinstance(parent.get("window_frame"), dict):
        raise ValueError("Native image lacks target PID/window binding")
    if image.get("masked") is not True:
        raise ValueError("Native image is not declared masked")
    if "window_frame" in image and image["window_frame"] != parent["window_frame"]:
        raise ValueError("Native image window binding mismatch")
    if "read_only_background" in parent and image.get("read_only_background") != parent["read_only_background"]:
        raise ValueError("Native image background binding mismatch")
    for field in ("target_pid", "window_id", "display_topology_signature", "frame_complete_serial"):
        if field in image and image[field] != parent.get(field):
            raise ValueError("Native image target/topology/frame binding mismatch")
    if image.get("downsampled") is True:
        original = {"width": image.get("original_width"), "height": image.get("original_height")}
        if any(type(value) is not int or value <= 0 for value in original.values()) or original != parent.get("pixel_size"):
            raise ValueError("Native downsampled image lacks original frame-size binding")
        if width > original["width"] or height > original["height"] or (width, height) == (original["width"], original["height"]) or image.get("ocr_frame_unchanged") is not True:
            raise ValueError("Native downsampled image changed OCR frame or did not shrink")
    elif "pixel_size" in parent and parent["pixel_size"] != {"width": width, "height": height}:
        raise ValueError("Native image pixel dimensions do not match the frame")
    for field in ("pixel_to_point_scale_x", "pixel_to_point_scale_y"):
        if field in image and (type(image[field]) not in (int, float) or not math.isfinite(image[field]) or image[field] <= 0):
            raise ValueError("Native image scale metadata is invalid")
    return {"type": "image", "data": encoded, "mimeType": "image/png"}, len(data)


def mcp_content(response):
    """Copy metadata, strip binary data, and emit only validated native images.

    A bad image never leaks its payload in error text. Preserve native action
    evidence even when image delivery fails, and never encourage replay.
    """
    images, errors = [], []
    def visit(value):
        if isinstance(value, list):
            return [visit(row) for row in value]
        if not isinstance(value, dict):
            return value
        result = {}
        for key, item in value.items():
            if key == "image":
                # Only metadata fields from the native image contract enter text.
                metadata = {k: v for k, v in item.items() if k in {"mime_type", "width", "height", "snapshot_id", "masked", "byte_count", "pixel_to_point_scale_x", "pixel_to_point_scale_y", "window_frame", "source", "read_only_background", "target_pid", "window_id", "display_topology_signature", "frame_complete_serial", "downsampled", "original_width", "original_height", "ocr_frame_unchanged", "resampling_method"}} if isinstance(item, dict) else {}
                try:
                    block, count = _validate_image(item, value)
                    images.append(block)
                    metadata.update(byte_count=count, sha256=hashlib.sha256(base64.b64decode(block["data"])).hexdigest(), mcp_content_index=len(images))
                except ValueError as error:
                    errors.append(str(error))
                    metadata.update(delivery_failed=True)
                result[key] = metadata
            else:
                result[key] = visit(item)
        return result
    metadata = visit(response)
    if errors:
        # No arbitrary image bytes, debug paths or native fields are copied into
        # this diagnostic. The original native result remains reviewable.
        metadata.update(image_delivery_failed=True, image_delivery_errors=errors, automatic_replay_allowed=False)
        images = []
    text = json.dumps(metadata, ensure_ascii=False)
    blocks = [{"type": "text", "text": text}, *images]
    if len(json.dumps(blocks, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE_BYTES:
        # Keep response output bounded, even for a batch of valid frames.
        metadata.update(image_delivery_failed=True, image_delivery_errors=["MCP image response exceeds 8 MiB"], automatic_replay_allowed=False)
        blocks = [{"type": "text", "text": json.dumps(metadata, ensure_ascii=False)}]
        errors.append("response_size")
    return {"content": blocks, "isError": not response.get("ok", False) or bool(errors)}
