#!/usr/bin/env python3
# ==============================================================================
# S3 Multi-Process Downloader (s3-mp-download)
# ==============================================================================
#
# DESCRIPTION:
#   Downloads large files from AWS S3 in parallel chunks using multiprocessing.
#   Designed for high-performance downloading over high-bandwidth connections.
#   It splits the source file into logical parts and downloads them concurrently.
#
#   Key Features:
#   - Parallel downloading (multi-part) via multiprocessing.Pool
#   - Supports public (anonymous) buckets and private buckets via standard AWS credentials.
#   - Visual progress bar with speed estimation (MB/s) and total size.
#   - Graceful shutdown on CTRL+C or 'q' key (Windows).
#   - Clean-up option to remove incomplete files on abort.
#   - Compatibility fixes for Windows multiprocessing (Timeout handling).
#
# PREREQUISITES:
#   1. Python 3.6 or higher (Tested on Python 3.13).
#   2. 'boto3' library must be installed:
#      pip install boto3
#   3. Network access to the target S3 bucket.
#   4. AWS Credentials configured (via ~/.aws/credentials or env vars) if accessing private buckets.
#      For public buckets (like software repos), use the --public flag.
#
# LICENSE & WARRANTY DISCLAIMER:
#   This script is provided under the MIT License.
#   ⚠️ Disclaimer:
#   This script is provided as-is, without any warranty of any kind.
#   Use at your own risk. The author(s) are not liable for any loss, data 
#   corruption, or system failure resulting from its use.
#
# EXIT CODES:
#   0 - Success
#   1 - General Error (Invalid arguments, Network error, User interrupt, Permission denied)
#
# USAGE:
#   python3 s3-mp-download.py [S3_URI] [DESTINATION_FILE] [OPTIONS]
#   
#   Example:
#   python3 s3-mp-download.py s3://my-bucket/image.iso ./image.iso -np 8 --public
#
# ==============================================================================
# VERSION: 1.0.0
#
# HISTORY:
#   v1.0.0 - Initial Release of the modernized Python 3 version.
#          - Full Python 3.13 compatibility update.
#          - MIGRATION: Replaced deprecated 'boto' (v2) with 'boto3'.
#          - FEATURE: Added --public flag for anonymous/unsigned requests (e.g. Cohesity portal).
#          - FEATURE: Added --clean flag to auto-remove incomplete files on abort.
#          - FEATURE: implemented multiprocessing Queue for thread-safe progress bar.
#          - FEATURE: Added real-time transfer speed (MB/s) and progress monitoring.
#          - FIX: Solved Windows integer overflow crash by reducing pool.get() timeout to 2M seconds.
#          - FIX: Implemented graceful shutdown handling for KeyboardInterrupt (CTRL+C).
#          - FIX: Added 'q' key listener for graceful stop on Windows.
# ==============================================================================

import argparse
import logging
from math import ceil
from multiprocessing import Pool, Manager
import os
import time
import urllib.parse 
import sys
import threading
import collections

import boto3
import botocore
from botocore import UNSIGNED
from botocore.config import Config

# Windows-specific import for keyboard input monitoring
if os.name == 'nt':
    import msvcrt

# Logger Setup
logger = logging.getLogger("s3-mp-download")

def do_part_download(args):
    """
    Download a part of an S3 object using Range header.
    Runs in a separate worker process.
    """
    bucket_name, key_name, fname, min_byte, max_byte, split, secure, max_tries, current_tries, is_public, region, queue, stop_event = args
    
    # Abort immediately if stop event is set
    if stop_event.is_set():
        return

    # Create Configuration
    config_args = {}
    if is_public:
        config_args['signature_version'] = UNSIGNED
    if region:
        config_args['region_name'] = region
        
    config = Config(**config_args)
    # Create client inside the process (boto3 clients are not thread/process safe across boundaries)
    s3_client = boto3.client('s3', config=config, use_ssl=secure)

    range_header = "bytes=%d-%d" % (min_byte, max_byte)
    
    # Open file handle
    try:
        fd = os.open(fname, os.O_WRONLY)
        os.lseek(fd, min_byte, os.SEEK_SET)
    except OSError as e:
        if stop_event.is_set(): return # File likely deleted during cleanup
        raise e

    try:
        # Buffer size for memory efficiency
        chunk_size = 1024 * 1024 

        resp = s3_client.get_object(Bucket=bucket_name, Key=key_name, Range=range_header)
        stream = resp['Body']
        
        for chunk in stream.iter_chunks(chunk_size=chunk_size):
            # Check if we should abort
            if stop_event.is_set():
                break
                
            if not chunk:
                break
            os.write(fd, chunk)
            
            # Send progress update to main process
            if queue is not None:
                queue.put(len(chunk))

    except Exception as err:
        # No retry if we are stopping anyway
        if stop_event.is_set():
            os.close(fd)
            return

        logger.debug("Retry request %d of max %d times" % (current_tries, max_tries))
        if current_tries > max_tries:
            logger.error(f"Failed to download part: {err}")
            raise err
        else:
            time.sleep(3)
            os.close(fd) 
            # Recursive retry with incremented counter
            new_args = (bucket_name, key_name, fname, min_byte, max_byte, split, secure, max_tries, current_tries + 1, is_public, region, queue, stop_event)
            return do_part_download(new_args)
    
    try:
        os.close(fd)
    except OSError:
        pass

def gen_byte_ranges(size, num_parts):
    """
    Generator to calculate start and end bytes for each part.
    """
    part_size = int(ceil(1. * size / num_parts))
    for i in range(num_parts):
        start = part_size * i
        end = min(part_size * (i + 1) - 1, size - 1)
        yield (start, end)

def format_bytes(size):
    """
    Helper to format bytes into human readable string.
    """
    power = 2**10
    n = 0
    power_labels = {0 : '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size > power:
        size /= power
        n += 1
    return f"{size:.2f} {power_labels.get(n, '')}B"

def progress_monitor(queue, total_size, stop_event):
    """
    Runs in a separate thread in the main process.
    Updates the progress bar and checks for keyboard input (Windows 'q').
    """
    downloaded = 0
    dq = collections.deque(maxlen=20) 
    
    # Hide cursor
    sys.stderr.write("\033[?25l")

    while not stop_event.is_set():
        # Empty the queue to update counter
        while not queue.empty():
            try:
                chunk_len = queue.get_nowait()
                downloaded += chunk_len
            except:
                break
        
        # Windows 'q' key check
        if os.name == 'nt':
            if msvcrt.kbhit():
                key = msvcrt.getwch()
                if key.lower() == 'q':
                    sys.stderr.write("\nKey 'q' detected. Stopping...\n")
                    stop_event.set()
                    break

        # Speed calculation (Moving Average)
        current_time = time.time()
        dq.append((current_time, downloaded))
        old_time, old_bytes = dq[0]
        
        time_diff = current_time - old_time
        bytes_diff = downloaded - old_bytes
        speed = bytes_diff / time_diff if time_diff > 0 else 0
        
        percent = (downloaded / total_size) * 100 if total_size > 0 else 0
        
        bar_len = 30
        filled_len = int(bar_len * percent // 100)
        bar = '=' * filled_len + '-' * (bar_len - filled_len)
        
        # Update line
        sys.stderr.write(f"\r[{bar}] {percent:5.1f}% | {format_bytes(downloaded)} / {format_bytes(total_size)} | {format_bytes(speed)}/s   ")
        sys.stderr.flush()
        
        # Check if done
        if downloaded >= total_size and total_size > 0:
            break

        time.sleep(0.1)

    # Show cursor again
    sys.stderr.write("\033[?25h\n")

def main(src, dest, num_processes=2, split=32, force=False, verbose=False, quiet=False, secure=True, max_tries=5, public=False, region=None, show_progress=True, clean=False):

    # Parse URL
    split_rs = urllib.parse.urlsplit(src)
    if split_rs.scheme != "s3":
        raise ValueError("'%s' is not an S3 url" % src)

    if os.path.isdir(dest):
        filename = split_rs.path.split('/')[-1]
        dest = os.path.join(dest, filename)

    if os.path.exists(dest):
        if force:
            os.remove(dest)
        else:
            raise ValueError("Destination file '%s' exists, specify -f to overwrite" % dest)

    # Config Setup
    config_args = {}
    if public: config_args['signature_version'] = UNSIGNED
    if region: config_args['region_name'] = region
    config = Config(**config_args)
    s3 = boto3.client('s3', config=config, use_ssl=secure)
    
    bucket_name = split_rs.netloc
    key_name = split_rs.path.lstrip('/')

    if not quiet:
        logger.info(f"Source: s3://{bucket_name}/{key_name}")
        logger.info(f"Dest:   {dest}")
        if clean: logger.info("Clean:  Enabled (file will be removed on abort)")

    try:
        head = s3.head_object(Bucket=bucket_name, Key=key_name)
        size = int(head['ContentLength'])
        if not quiet: logger.info("Size:   %s" % format_bytes(size))
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            raise ValueError("'%s' does not exist." % src)
        elif e.response['Error']['Code'] == "403":
             raise ValueError("Access Denied. If this is a public file, try --public")
        else:
            raise e

    if size < 1024 * 1024:
        logger.info("Downloading small file (<1MB)...")
        s3.download_file(bucket_name, key_name, dest)
        logger.info("Done.")
        return

    # Create empty file
    fd = os.open(dest, os.O_CREAT | os.O_WRONLY)
    os.close(fd)

    # Calculations
    size_mb = size / 1024 / 1024
    if split == 0: split = 32
    num_parts = int(ceil(size_mb / split))
    if num_parts < 1: num_parts = 1

    if not quiet and not show_progress:
        logger.info(f"Splitting into {num_parts} parts using {num_processes} processes")

    # Manager Setup
    manager = Manager()
    queue = manager.Queue() if show_progress else None
    stop_event = manager.Event() # Global Stop Signal
    
    monitor_thread = None
    if show_progress:
        monitor_thread = threading.Thread(target=progress_monitor, args=(queue, size, stop_event))
        monitor_thread.start()

    def arg_iterator(num_parts):
        for min_byte, max_byte in gen_byte_ranges(size, num_parts):
            yield (bucket_name, key_name, dest, min_byte, max_byte, split, secure, max_tries, 0, public, region, queue, stop_event)

    pool = None
    try:
        t1 = time.time()
        pool = Pool(processes=num_processes)
        
        # map_async is crucial to keep the main thread responsive to KeyboardInterrupt
        result = pool.map_async(do_part_download, arg_iterator(num_parts))
        
        # Wait for completion
        # NOTE: Timeout set to ~23 days to prevent Windows OverflowError on 32-bit int
        result.get(2000000) 

        pool.close()
        pool.join()
        
        # Check if stopped by 'q'
        if stop_event.is_set():
            raise KeyboardInterrupt("Stopped by user via 'q'")

        if show_progress:
            stop_event.set() 
            monitor_thread.join()

        t2 = time.time() - t1
        speed = (size / 1024 / 1024) / t2 if t2 > 0 else 0
        if not quiet:
            logger.info("Finished in %0.2fs (Avg: %0.2f MB/s)" % (t2, speed))

    except KeyboardInterrupt:
        logger.warning("\nDownload aborted by user!")
        stop_event.set() 
        
        if pool:
            pool.terminate() 
            pool.join()
        
        if show_progress and monitor_thread:
            monitor_thread.join()

        if clean:
            logger.warning(f"Cleaning up: removing '{dest}'...")
            try:
                if os.path.exists(dest):
                    os.remove(dest)
            except Exception as e:
                logger.error(f"Could not remove file: {e}")
        else:
            logger.warning(f"Incomplete file kept: '{dest}' (use --clean to auto-delete)")
            
        sys.exit(1)
        
    except Exception as err:
        stop_event.set()
        if pool:
            pool.terminate()
        logger.error(err)
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download a file from S3 in parallel", prog="s3-mp-download")
    parser.add_argument("src", help="The S3 key to download (s3://bucket/key)")
    parser.add_argument("dest", help="The destination file")
    parser.add_argument("-np", "--num-processes", help="Number of processors to use", type=int, default=4)
    parser.add_argument("-s", "--split", help="Split size, in Mb", type=int, default=64)
    parser.add_argument("-f", "--force", help="Overwrite an existing file", action="store_true")
    parser.add_argument("-c", "--clean", help="Delete incomplete file on abort", action="store_true")
    parser.add_argument("--insecure", dest='secure', help="Use HTTP for connection", default=True, action="store_false")
    parser.add_argument("--public", help="Download anonymously (no AWS credentials)", action="store_true")
    parser.add_argument("--region", help="AWS Region (e.g. us-west-2)", default="us-west-2")
    parser.add_argument("-t", "--max-tries", help="Max allowed retries", type=int, default=5)
    parser.add_argument("-v", "--verbose", help="Be more verbose", default=False, action="store_true")
    parser.add_argument("-q", "--quiet", help="Be less verbose", default=False, action="store_true")
    parser.add_argument("--no-progress", dest='show_progress', help="Disable progress bar", default=True, action="store_false")

    args = parser.parse_args()
    arg_dict = vars(args)
    
    logging.basicConfig(level=logging.INFO, format='%(message)s')
    
    if arg_dict['quiet']:
        logger.setLevel(logging.WARNING)
    elif arg_dict['verbose']:
        logger.setLevel(logging.DEBUG)
        
    main(**arg_dict)
