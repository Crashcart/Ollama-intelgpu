#!/usr/bin/env python3
"""
File Catalog — large-file browser with external-drive offload.

Scans DATA_DIR for files above MIN_SIZE_MB and lets you move them to a
mounted external drive with automatic symlinks back, so all paths keep
working.  Useful for offloading model weights (.gguf / .safetensors) to
a large external disk without reconfiguring Ollama.

Environment:
  DATA_DIR     — directory to scan          (default: /data)
  DRIVES_DIR   — where drives are mounted   (default: /drives)
  MIN_SIZE_MB  — minimum file size to list  (default: 100)

Routes:
  GET  /api/files          → list large files with size / symlink info
  GET  /api/drives         → list usable mount points under DRIVES_DIR
  POST /api/file/move      → move file to drive + create symlink
  POST /api/file/restore   → move file back from drive + remove symlink
  GET  /                   → static HTML UI
"""

import os
import shutil
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

DATA_DIR   = Path(os.environ.get("DATA_DIR",  "/data"))
DRIVES_DIR = Path(os.environ.get("DRIVES_DIR", "/drives"))
MIN_SIZE_B = int(os.environ.get("MIN_SIZE_MB", "100")) * 1024 * 1024

# Extensions commonly associated with large AI/data files
LARGE_EXTS = {
    ".gguf", ".bin", ".safetensors", ".pt", ".pth", ".onnx",
    ".db", ".sqlite", ".sqlite3",
    ".tar", ".gz", ".zip", ".zst", ".7z",
    ".iso", ".img",
}

app = FastAPI(title="File Catalog", docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def human_size(b: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def file_info(path: Path) -> dict:
    is_link = path.is_symlink()
    link_target: Optional[str] = None
    on_drive = False

    if is_link:
        try:
            target = Path(os.readlink(path))
            if not target.is_absolute():
                target = (path.parent / target).resolve()
            link_target = str(target)
            # Check if symlink points into DRIVES_DIR
            try:
                target.relative_to(DRIVES_DIR)
                on_drive = True
            except ValueError:
                pass
        except OSError:
            pass

    try:
        stat = path.stat()          # follows symlinks
        size_b = stat.st_size
    except OSError:
        size_b = 0

    rel = str(path.relative_to(DATA_DIR))
    ext = path.suffix.lower()

    return {
        "path":        rel,
        "abs":         str(path),
        "size_b":      size_b,
        "size_human":  human_size(size_b),
        "ext":         ext,
        "is_symlink":  is_link,
        "link_target": link_target,
        "on_drive":    on_drive,
        "mtime":       int(path.lstat().st_mtime),
    }


def scan() -> list[dict]:
    results = []
    try:
        for root, dirs, files in os.walk(DATA_DIR, followlinks=False):
            # Skip directories that are themselves symlinks (already offloaded trees)
            dirs[:] = [d for d in dirs
                       if not Path(root, d).is_symlink()]
            for fname in files:
                p = Path(root, fname)
                try:
                    lstat = p.lstat()
                except OSError:
                    continue

                # Always include symlinks that point to DRIVES_DIR regardless of size
                if p.is_symlink():
                    try:
                        target = Path(os.readlink(p))
                        if not target.is_absolute():
                            target = (p.parent / target).resolve()
                        target.relative_to(DRIVES_DIR)   # raises if not under DRIVES_DIR
                        results.append(file_info(p))
                        continue
                    except (ValueError, OSError):
                        pass

                # Include large files (by extension or raw size)
                size = lstat.st_size
                if size >= MIN_SIZE_B or p.suffix.lower() in LARGE_EXTS:
                    if size >= MIN_SIZE_B // 10:   # skip tiny files that match ext
                        results.append(file_info(p))
    except PermissionError:
        pass

    results.sort(key=lambda x: x["size_b"], reverse=True)
    return results


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class MoveRequest(BaseModel):
    path: str       # relative path within DATA_DIR
    drive: str      # drive name (subdirectory of DRIVES_DIR)

class RestoreRequest(BaseModel):
    path: str       # relative path within DATA_DIR (which is currently a symlink)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

@app.get("/api/files")
def list_files():
    return {"files": scan(), "data_dir": str(DATA_DIR), "min_size_mb": MIN_SIZE_B // 1024 // 1024}


@app.get("/api/drives")
def list_drives():
    drives = []
    if DRIVES_DIR.exists():
        for entry in sorted(DRIVES_DIR.iterdir()):
            if not entry.is_dir():
                continue
            try:
                usage = shutil.disk_usage(entry)
                drives.append({
                    "name":       entry.name,
                    "path":       str(entry),
                    "total_b":    usage.total,
                    "used_b":     usage.used,
                    "free_b":     usage.free,
                    "total_human": human_size(usage.total),
                    "free_human":  human_size(usage.free),
                })
            except OSError:
                continue
    return {"drives": drives, "drives_dir": str(DRIVES_DIR)}


@app.post("/api/file/move")
def move_file(req: MoveRequest):
    src = (DATA_DIR / req.path).resolve()

    # Safety: must be inside DATA_DIR
    try:
        src.relative_to(DATA_DIR.resolve())
    except ValueError:
        raise HTTPException(400, "Path escapes DATA_DIR")

    if not src.exists():
        raise HTTPException(404, "File not found")
    if src.is_symlink():
        raise HTTPException(409, "File is already a symlink — restore it first")

    drive_root = DRIVES_DIR / req.drive
    if not drive_root.is_dir():
        raise HTTPException(404, f"Drive '{req.drive}' not found under {DRIVES_DIR}")

    # Mirror the DATA_DIR subdirectory structure on the drive
    rel = src.relative_to(DATA_DIR.resolve())
    dst = drive_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)

    if dst.exists():
        raise HTTPException(409, f"Destination already exists: {dst}")

    try:
        shutil.move(str(src), str(dst))
        src.symlink_to(dst)
    except Exception as e:
        # Attempt rollback
        if dst.exists() and not src.exists():
            try:
                shutil.move(str(dst), str(src))
            except Exception:
                pass
        raise HTTPException(500, str(e))

    return {
        "moved":   str(rel),
        "from":    str(src),
        "to":      str(dst),
        "symlink": str(src),
    }


@app.post("/api/file/restore")
def restore_file(req: RestoreRequest):
    link = (DATA_DIR / req.path).resolve()

    try:
        link.relative_to(DATA_DIR.resolve())
    except ValueError:
        raise HTTPException(400, "Path escapes DATA_DIR")

    # Must be a symlink pointing into DRIVES_DIR
    lpath = DATA_DIR / req.path
    if not lpath.is_symlink():
        raise HTTPException(409, "File is not a symlink")

    target = Path(os.readlink(lpath))
    if not target.is_absolute():
        target = (lpath.parent / target).resolve()

    try:
        target.relative_to(DRIVES_DIR.resolve())
    except ValueError:
        raise HTTPException(409, "Symlink does not point into DRIVES_DIR — refusing")

    if not target.exists():
        raise HTTPException(404, f"Drive file missing: {target}")

    try:
        lpath.unlink()
        shutil.move(str(target), str(lpath))
    except Exception as e:
        # Attempt rollback
        if not lpath.exists() and target.exists():
            try:
                lpath.symlink_to(target)
            except Exception:
                pass
        raise HTTPException(500, str(e))

    return {
        "restored": req.path,
        "from":     str(target),
        "to":       str(lpath),
    }


# Static UI — mount last
app.mount("/", StaticFiles(directory="static", html=True), name="static")
