#!/usr/bin/env python3
"""Push a conforming Tekton bundle to a plain-HTTP OCI registry (zot).

Why not `tkn bundle push`: it emits a Docker v2 manifest whose layers carry
Tekton media types, and an OCI-native registry rejects that combination (zot
answers 415). The Tekton bundle contract asks for an OCI artifact anyway, so the
manifest is built explicitly here:

  * one layer per Tekton resource, gzip-compressed tar with the YAML inside
  * per-layer annotations dev.tekton.image.{name,kind,apiVersion}
  * OCI image manifest, config blob is empty JSON

Usage: push-bundle.py <registry-host> <repo> <tag> <file.yaml> [more.yaml ...]
Prints the digested reference (repo@sha256:...) on stdout.
"""
import gzip
import hashlib
import io
import json
import sys
import tarfile
import urllib.error
import urllib.request


def request(method, path, data=None, content_type=None, extra_headers=None):
    req = urllib.request.Request(f"http://{REGISTRY}{path}", data=data, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    for key, value in (extra_headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def digest_of(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def put_blob(data: bytes) -> str:
    digest = digest_of(data)
    status, _, _ = request("HEAD", f"/v2/{REPO}/blobs/{digest}")
    if status == 200:
        return digest
    status, _, headers = request("POST", f"/v2/{REPO}/blobs/uploads/")
    assert status in (201, 202), f"start upload failed: {status}"
    location = headers.get("Location") or headers.get("location")
    separator = "&" if "?" in location else "?"
    status, body, _ = request(
        "PUT", f"{location}{separator}digest={digest}", data=data,
        content_type="application/octet-stream",
    )
    assert status in (200, 201), f"blob upload failed: {status} {body[:200]!r}"
    return digest


def top_level_fields(path: str) -> dict:
    """Read apiVersion/kind and metadata.name without a YAML library.

    The published manifests are flat and well-formed, and staying dependency-free
    keeps the publisher task on a stock python image.
    """
    fields: dict = {}
    section = None
    with open(path) as handle:
        for line in handle:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key, _, value = line.partition(":")
            value = value.strip().strip("'\"")
            if line[0].isspace():
                if section:
                    fields.setdefault(section, {})[key.strip()] = value
            else:
                section = key.strip()
                fields[section] = {"": value}
    return fields


def layer_from(path: str) -> dict:
    with open(path, "rb") as handle:
        raw = handle.read()

    fields = top_level_fields(path)
    name = fields["metadata"]["name"]
    kind = fields["kind"][""].lower()
    api_version = fields["apiVersion"][""]

    buffer = io.BytesIO()
    # mtime=0: a reproducible digest, so the digest the platform approves is the
    # digest it published (and a re-publish of unchanged content is a no-op).
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed_stream:
        with tarfile.open(fileobj=compressed_stream, mode="w") as archive:
            info = tarfile.TarInfo(name=path.split("/")[-1])
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
    compressed = buffer.getvalue()

    return {
        "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
        "digest": put_blob(compressed),
        "size": len(compressed),
        "annotations": {
            "dev.tekton.image.name": name,
            "dev.tekton.image.kind": kind,
            "dev.tekton.image.apiVersion": api_version,
        },
    }


REGISTRY, REPO, TAG = sys.argv[1], sys.argv[2], sys.argv[3]
FILES = sys.argv[4:]
assert FILES, "no resource files given"

config = json.dumps({}).encode()
manifest = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": put_blob(config),
        "size": len(config),
    },
    "layers": [layer_from(path) for path in FILES],
}

payload = json.dumps(manifest).encode()
status, body, _ = request(
    "PUT", f"/v2/{REPO}/manifests/{TAG}", data=payload,
    content_type="application/vnd.oci.image.manifest.v1+json",
)
assert status in (200, 201), f"manifest push failed: {status} {body[:300]!r}"
pushed = digest_of(payload)
print(f"{REGISTRY}/{REPO}@{pushed}")
