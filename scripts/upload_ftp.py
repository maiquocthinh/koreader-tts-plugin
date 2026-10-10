#!/usr/bin/env python3
"""
Upload packaged plugin from dist/koreader_tts.koplugin to device via FTP.
Usage:
    python scripts/upload_ftp.py [host] [port] [remote_path]
"""

import os
import sys
import ftplib

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.47"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2121
REMOTE_BASE = sys.argv[3] if len(sys.argv) > 3 else "/koreader/plugins/koreader_tts.koplugin"
LOCAL_SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dist", "koreader_tts.koplugin")

if not os.path.isdir(LOCAL_SRC):
    print(f"[-] ERROR: Local source folder not found at '{LOCAL_SRC}'")
    print("    Please run 'make package' first.")
    sys.exit(1)

print(f"=== Connecting to FTP server ftp://{HOST}:{PORT} ===")
ftp = ftplib.FTP()
try:
    ftp.connect(HOST, PORT, timeout=30)
    ftp.login()
except Exception as e:
    print(f"[-] FTP Connection failed: {e}")
    sys.exit(1)

def ensure_remote_dir(path):
    parts = [p for p in path.split("/") if p]
    cur = ""
    for p in parts:
        cur += "/" + p
        try:
            ftp.mkd(cur)
        except Exception:
            pass

ensure_remote_dir(REMOTE_BASE)

total_files = 0
total_bytes = 0

for root, dirs, files in os.walk(LOCAL_SRC):
    rel_dir = os.path.relpath(root, LOCAL_SRC).replace("\\", "/")
    remote_dir = REMOTE_BASE if rel_dir == "." else f"{REMOTE_BASE}/{rel_dir}"
    ensure_remote_dir(remote_dir)

    for fname in files:
        local_file = os.path.join(root, fname)
        remote_file = f"{remote_dir}/{fname}"
        size = os.path.getsize(local_file)
        print(f"  + Uploading {fname:<25} ({size / 1024:6.1f} KB) -> {remote_file}")
        with open(local_file, "rb") as f:
            ftp.storbinary(f"STOR {remote_file}", f, blocksize=65536)
        total_files += 1
        total_bytes += size

ftp.quit()
print(f"\n[+] UPLOAD SUCCESSFUL: {total_files} files ({total_bytes / (1024*1024):.2f} MB) installed to {REMOTE_BASE}/")
print("[+] Restart KOReader on your device to load the plugin.")
