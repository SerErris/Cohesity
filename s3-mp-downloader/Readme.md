# S3 Multi-Process Downloader (s3-mp-download)
A high-performance Python 3 script to download large files from AWS S3 in parallel chunks. It significantly increases download speeds by utilizing multiple CPU cores and network streams.

This tool has been created to increase the download speed for cohesity packages. But it also will work with any other public S3 repository.

## Features

* **Parallel Downloading:** Splits the file into parts and downloads them simultaneously using `multiprocessing`.
* **Public/Anonymous Support:** Download from public buckets (like software distribution repos) without AWS credentials.
* **Visual Progress Bar:** Real-time progress, download speed (MB/s), and total size.
* **Graceful Interruption:** Handles `CTRL+C` (or `q` on Windows) to stop downloads safely.
* **Cleanup:** Optional flag (`--clean`) to automatically remove incomplete files if the download is aborted.
* **Cross-Platform:** Works on Windows, Linux, and macOS (Python 3.13+ compatible).

## Prerequisites

* Python 3.6 or higher (Tested with Python 3.13)
* `boto3` library

### Installation

1. **Clone or download** this script.
2. **Install dependencies**:
   (It is recommended to use `python3 -m pip` to ensure the library is installed for the correct Python version).

   ```bash
   python3 -m pip install boto3
   ```

## Usage

### Basic Syntax

```bash
python3 s3-mp-download.py [S3_URI] [DESTINATION_FILE] [OPTIONS]
```

### Options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-np`, `--num-processes` | Number of parallel download streams. | 4 |
| `-s`, `--split` | Split size (chunk size) in MB. | 64 |
| `--public` | **Important:** Use this for public buckets (no AWS credentials required). | False |
| `--region` | Specify the AWS region (e.g., `us-west-2`). | `us-west-2` |
| `-c`, `--clean` | Delete the incomplete file if the download is aborted. | False |
| `-f`, `--force` | Overwrite the destination file if it already exists. | False |
| `--no-progress` | Disable the progress bar (useful for logs/cron). | False |
| `-q`, `--quiet` | Suppress all output (except errors). | False |

---

## 💡 Guide: How to download from Cohesity Portal

When you copy a download link from the Cohesity support portal (or similar S3-hosted artifact sites), it usually looks like an HTTPS URL. You must convert this to the `s3://` syntax for this tool to work.

### Step 1: Analyze the HTTPS Link

A typical Cohesity download link looks like this:

`https://s3-us-west-2.amazonaws.com/downloads.portal/path/to/file/image.qcow2`

Break it down:
1. **Region:** `s3-us-west-2` → The region is **us-west-2**.
2. **Bucket:** The first part of the path → **downloads.portal**.
3. **Key (Path):** Everything after the bucket → **path/to/file/image.qcow2**.

### Step 2: Construct the Command

Combine the parts into the S3 URI format: `s3://<bucket>/<key>`

**Original URL:**
`https://s3-us-west-2.amazonaws.com/downloads.portal/path/to/file.img`

**Converted URI:**
`s3://downloads.portal/path/to/file.img`

### Step 3: Run the Command

Since Cohesity downloads are public (signed/unsigned), use the `--public` flag and specify the region.

```bash
python3 s3-mp-download.py s3://downloads.portal/path/to/file.img my_image.img --public --region us-west-2 -np 12 -c
```

---

## Examples

**1. Download a Cohesity Image (Public, 12 connections, clean up on abort):**
```bash
python3 s3-mp-download.py s3://downloads.portal/path/to/file/image.qcow2 local_image.qcow2 --public --region us-west-2 -np 12 -c
```

**2. Download from your own private bucket (Requires `~/.aws/credentials`):**
```bash
python3 s3-mp-download.py s3://my-private-backup-bucket/db-dump.sql ./db-dump.sql -np 8
```

**3. Download quietly (for scripts):**
```bash
python3 s3-mp-download.py s3://my-bucket/data.zip data.zip --quiet --no-progress
```

## Troubleshooting

* **`timeout value is too large` (Windows):**
  This script contains a specific fix for Windows multiprocessing timeouts. Ensure you are using the latest version of this script where `result.get()` uses a safe integer value.

* **`Access Denied` / `403 Forbidden`:**
  * If the file is public, did you forget the `--public` flag?
  * If the file is private, have you configured `aws configure`?

* **`ModuleNotFoundError: No module named 'boto3'`:**
  You likely installed boto3 for a different Python version. Run `python3 -m pip install boto3`.

## License
Open Source. Feel free to modify.
