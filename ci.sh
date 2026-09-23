#!/usr/bin/env bash
set -e

echo "📦 Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq p7zip-full qbittorrent-nox python3 python3-pip curl

echo "🐍 Installing Python libraries..."
pip3 install --no-cache-dir --break-system-packages requests qbittorrent-api natsort

echo "⚙️ Configuring qBittorrent headless daemon..."
mkdir -p ~/.config/qBittorrent downloads torrents

cat << 'EOF' > ~/.config/qBittorrent/qBittorrent.conf
[LegalNotice]
Accepted=true

[Preferences]
Downloads\SavePath=downloads
WebUI\Address=127.0.0.1
WebUI\Port=8080
WebUI\LocalHostAuth=false
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\UseUPnP=false
BitTorrent\Session\MaxActiveDownloads=16
BitTorrent\Session\MaxActiveTorrents=32
BitTorrent\Session\MaxActiveUploads=0
BitTorrent\Session\GlobalDLLimit=0
BitTorrent\Session\Port=6881
EOF

echo "🚀 Starting qBittorrent daemon..."
qbittorrent-nox --daemon

echo "🧲 Processing links with qBittorrent..."
python3 - << 'EOF'
import time
import os
import requests
import asyncio
from urllib.parse import urlparse
from qbittorrentapi import Client

qb = Client(host='127.0.0.1', port=8080)

# Wait for qBittorrent WebUI to initialize
for _ in range(15):
    try:
        qb.app_version()
        print("✅ Connected to qBittorrent WebUI.")
        break
    except Exception:
        time.sleep(1)
else:
    print("❌ Failed to connect to qBittorrent daemon.")
    exit(1)

# Fetch best trackers
try:
    tracker_res = requests.get("https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt", timeout=5)
    if tracker_res.status_code == 200:
        trackers = "\n".join([line.strip() for line in tracker_res.text.splitlines() if line.strip()])
    else:
        trackers = ""
except Exception:
    trackers = ""

link_url = "https://pink-script-snap.lovable.app/api/public/page/0e01cfaf-128c-477f-bff1-9dee23822d97.txt"

try:
    ks = requests.get(link_url, timeout=10).text
    if "STOP.ALL.TORRENTS" in ks:
        print("🛑 Global kill switch active.")
        exit(0)

    direct_links = []
    
    for i, link in enumerate(ks.splitlines()):
        link = link.strip()
        if not link or link.startswith('#') or link.endswith(' NO'):
            continue
            
        if link.startswith('magnet:') or link.endswith('.torrent'):
            print(f"📥 Adding to qBittorrent: {link[:60]}...", flush=True)
            qb.torrents_add(
                urls=link,
                save_path=os.path.abspath("downloads"),
                category="ci_download"
            )
        elif link.startswith('http'):
            direct_links.append(link)

    # Process direct HTTP links fallback
    if direct_links:
        print(f"🔗 Processing {len(direct_links)} direct HTTP links...", flush=True)
        for dlink in direct_links:
            filename = os.path.basename(urlparse(dlink).path) or f"direct_{time.time()}.dat"
            target_path = os.path.join("downloads", filename)
            print(f"📥 Downloading direct link: {filename}", flush=True)
            with requests.get(dlink, stream=True, timeout=30) as r:
                r.raise_for_status()
                with open(target_path, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        f.write(chunk)

    # Monitor qBittorrent downloads
    print("⏳ Waiting for torrent downloads to complete...", flush=True)
    stuck_counter = 0
    
    while True:
        torrents = qb.torrents_info(category="ci_download")
        if not torrents and not direct_links:
            print("ℹ️ No active torrent downloads found.")
            break

        all_completed = True
        for t in torrents:
            progress = t.progress * 100
            print(f"📊 [{t.state}] {t.name[:30]}: {progress:.1f}% @ {t.dlspeed / 1024 / 1024:.2f} MB/s", flush=True)
            
            if t.state not in ['completed', 'pausedUP', 'uploading', 'stalledUP']:
                all_completed = False

        if all_completed and len(torrents) > 0:
            print("🎉 All torrent downloads finished successfully!")
            break
            
        time.sleep(10)

except Exception as e:
    print(f"❌ Error during download process: {e}")
    exit(1)
EOF

echo "📦 Running Smart Zipping Rules..."
python3 - << 'EOF'
import os, shutil, subprocess, re
from collections import defaultdict
from natsort import natsorted

folder = "downloads"
video_ext = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v')
media_ext = video_ext + ('.srt', '.ass', '.vtt', '.sub')
max_bytes = 10000 * 1024 * 1024

def get_dir_size(p):
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fn in os.walk(p) for f in fn)

def create_7z_group(group_name, file_paths, base_dir, max_bytes_limit):
    group_dir = os.path.join(base_dir, group_name)
    os.makedirs(group_dir, exist_ok=True)
    
    files_to_move = list(file_paths)
    for p in file_paths:
        base_stem = os.path.splitext(p)[0]
        for sub_ext in ('.srt', '.ass', '.vtt', '.sub'):
            sub_file = base_stem + sub_ext
            if os.path.exists(sub_file) and sub_file not in files_to_move:
                files_to_move.append(sub_file)

    for p in files_to_move:
        dst = os.path.join(group_dir, os.path.basename(p))
        if p != dst and not os.path.exists(dst):
            shutil.move(p, dst)
    
    folder_size = get_dir_size(group_dir)
    zip_name = f"{group_name}.zip"
    orig = os.getcwd()
    os.chdir(base_dir)
    cmd = ["7z", "a", "-bb0", "-mx0", "-mmt=on", zip_name, group_name]
    if folder_size > max_bytes_limit:
        cmd.insert(2, "-v5900m")
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    os.chdir(orig)
    shutil.rmtree(group_dir)

# 1. Zip directories containing more than 3 nested videos
for item in natsorted(os.listdir(folder)):
    item_path = os.path.join(folder, item)
    if os.path.isdir(item_path):
        vids = natsorted([
            os.path.join(r, f) for r, _, files in os.walk(item_path)
            for f in files if f.lower().endswith(video_ext)
        ])
        if len(vids) > 3:
            print(f"📦 Zipping folder: {item}", flush=True)
            folder_size = get_dir_size(item_path)
            orig = os.getcwd()
            os.chdir(folder)
            zip_name = f"{item}.zip"
            cmd = ["7z", "a", "-bb0", "-mx0", "-mmt=on", zip_name, item]
            if folder_size > max_bytes:
                cmd.insert(2, "-v5900m")
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            os.chdir(orig)
            shutil.rmtree(item_path)

# 2. Collect loose videos
all_videos = []
for r, _, files in os.walk(folder):
    for f in files:
        if f.lower().endswith(video_ext):
            all_videos.append(os.path.join(r, f))

all_videos = natsorted(all_videos)
series_regex = re.compile(r'(?i)(?:^(.*?)[.\s_-]+)?S(\d{1,2})(?:[EX\-]|\b)')

series_groups = defaultdict(list)
movies_and_loose = []
short_series_pool = []

for vid_path in all_videos:
    vid_name = os.path.basename(vid_path)
    parent_name = os.path.basename(os.path.dirname(vid_path))
    match = series_regex.search(vid_name) or series_regex.search(parent_name)
    
    if match:
        raw_title = match.group(1) or "Season"
        s_num = match.group(2)
        group_key = f"{raw_title.strip('. -_').lower()}_S{s_num}"
        series_groups[group_key].append(vid_path)
    else:
        movies_and_loose.append(vid_path)

# 3. Handle TV series
for group_key in natsorted(series_groups.keys()):
    vids = natsorted(series_groups[group_key])
    if len(vids) > 3:
        first_stem = os.path.splitext(os.path.basename(vids[0]))[0]
        create_7z_group(first_stem, vids, folder, max_bytes)
    else:
        short_series_pool.extend(vids)

# 4. Bundle remaining short series
if len(short_series_pool) > 3:
    first_stem = os.path.splitext(os.path.basename(short_series_pool[0]))[0]
    create_7z_group(f"Batch_{first_stem}", short_series_pool, folder, max_bytes)
else:
    movies_and_loose.extend(short_series_pool)

# 5. Clean up directory structure
for r, dirs, files in os.walk(folder, topdown=False):
    if r == folder: continue
    for f in natsorted(files):
        if f.lower().endswith(media_ext):
            src = os.path.join(r, f)
            dst = os.path.join(folder, f)
            if not os.path.exists(dst): 
                shutil.move(src, dst)
    shutil.rmtree(r, ignore_errors=True)
EOF

echo "📤 Uploading files to Filemirage..."
python3 - << 'EOF'
import os
import subprocess
import requests
import time
import fcntl
from concurrent.futures import ThreadPoolExecutor
from natsort import natsorted

FILEMIRAGE_API_TOKEN = '9QQH-DGES-CWQZ-FXNV'
FOLDER_PATH = 'downloads'

try:
    srv_res = requests.get("https://filemirage.com/api/servers", timeout=10).json()
    SERVER = srv_res['data']['server']
except Exception as e:
    print(f"Failed to fetch Filemirage server: {e}")
    exit(1)

def upload_single_file(file_path):
    filename = os.path.basename(file_path)
    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
    print(f"⬆️ [START] Uploading: {filename} ({file_size_mb:.2f} MB)", flush=True)
    
    curl_cmd = [
        "curl", "-X", "POST",
        f"{SERVER}/upload.php",
        "-H", f"Authorization: Bearer {FILEMIRAGE_API_TOKEN}",
        "-F", f"file=@{file_path}",
        "--max-time", "3600"
    ]
    
    proc = subprocess.Popen(curl_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    fd = proc.stderr.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    
    last_print_time = time.time()
    buffer = b""
    
    while proc.poll() is None:
        try:
            chunk = proc.stderr.read(1024)
            if chunk:
                buffer += chunk
                if b'\r' in buffer or b'\n' in buffer:
                    lines = buffer.replace(b'\r', b'\n').split(b'\n')
                    buffer = lines[-1]
                    valid_lines = [L.decode('utf-8', errors='ignore').strip() for L in lines[:-1] if L.strip()]
                    if valid_lines:
                        last_line = valid_lines[-1]
                        if time.time() - last_print_time >= 30:
                            print(f"📤 Progress [{filename[:25]}]: {last_line}", flush=True)
                            last_print_time = time.time()
        except Exception:
            pass
        time.sleep(0.5)
        
    stdout, stderr = proc.communicate()
    if proc.returncode == 0:
        print(f"✅ Finished uploading {filename}: {stdout.decode('utf-8', errors='ignore').strip()}", flush=True)
    else:
        err_msg = stderr.decode('utf-8', errors='ignore').strip() if stderr else 'Unknown error'
        print(f"❌ Curl Error uploading {filename}: {err_msg}", flush=True)

if os.path.exists(FOLDER_PATH):
    upload_queue = []
    for root, dirs, files in os.walk(FOLDER_PATH):
        for filename in files:
            if not any(ext in filename for ext in [".!qB", ".part", ".aria2"]):
                upload_queue.append(os.path.join(root, filename))
    
    upload_queue = natsorted(upload_queue)
    
    if upload_queue:
        print(f"🚀 Launching 4 parallel upload workers for {len(upload_queue)} files...", flush=True)
        with ThreadPoolExecutor(max_workers=4) as executor:
            executor.map(upload_single_file, upload_queue)
EOF

echo "✨ Execution completed!"
