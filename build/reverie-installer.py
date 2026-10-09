#!/usr/bin/env python3
"""Install running Reverie alongside Android on internal UFS storage."""

import argparse
from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MIB = 1024**2
GIB = 1024**3
ESP_SIZE, ROOT_MIN, ANDROID_MIN = 1024 * MIB, 16 * GIB, 8 * GIB
RESERVE = ESP_SIZE + ROOT_MIN + 64 * MIB
ESP_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_TYPE = "0fc63daf-8483-4772-8e79-3d69d8477de4"
BTRFS_OPTS = "noatime,compress=zstd:1,discard=async"
SELF = os.path.abspath(sys.argv[0])
RECOVERY = ("To retry from SD, select SD as the boot source in ABL and re-run the installer. "
            "To abandon the internal installation, select UNINSTALL CFW in ABL.")

# Essential Steam runtimes to preserve in base image
PRESERVED_RUNTIMES = (
    "Proton",
    "SteamLinuxRuntime",
    "Steamworks",
    "FEX-Emu",
    "Steam Controller",
)
PRESERVED_MANIFESTS = {
    "appmanifest_228980.acf",   # Steamworks Common Redistributables
    "appmanifest_1493710.acf",  # Proton Experimental
    "appmanifest_3127680.acf",  # FEX
    "appmanifest_4183110.acf",  # Steam Linux Runtime 4.0
    "appmanifest_4185400.acf",  # Steam Linux Runtime 4.0 - Arm64
    "appmanifest_4427310.acf",  # Proton Experimental (ARM64)
    "appmanifest_4628740.acf",  # Proton 11.0 (ARM64)
}


class Error(Exception):
    pass


class Cancelled(Exception):
    pass


class Interrupted(Error):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"operation interrupted by signal {signum}")


def run(*args, capture=False, check=True, input=None, **kwargs):
    args = [str(arg) for arg in args]
    kwargs.setdefault("stdout", subprocess.PIPE if capture else None)
    kwargs.setdefault("stderr", subprocess.PIPE if capture else None)
    if input is not None:
        kwargs["stdin"] = subprocess.PIPE
    child = subprocess.Popen(args, text=True, **kwargs)
    previous, interrupted = {}, []

    def forward(signum, _frame):
        interrupted.append(signum)
        child.send_signal(signum)

    try:
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, forward)
        out, err = child.communicate(input)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    if interrupted:
        raise Interrupted(interrupted[0])
    if check and child.returncode:
        raise Error(f"{shlex.join(args)} failed ({child.returncode})" + (f": {err.strip()}" if err else ""))
    return subprocess.CompletedProcess(args, child.returncode, out, err)


def output(*args):
    return run(*args, capture=True).stdout.strip()


def part_node(device, number):
    return f"{device}{'p' if device[-1].isdigit() else ''}{number}"


def align_up(value):
    return (value + MIB - 1) // MIB * MIB


@dataclass(frozen=True)
class Partition:
    number: int
    start: int
    end: int
    name: str
    type: str
    uuid: str = ""
    attrs: str = ""


@dataclass(frozen=True)
class Table:
    device: str
    sector_size: int
    first: int
    last: int
    disk_id: str
    parts: tuple
    entry_count: int = 128
    unused: tuple = ()

    @classmethod
    def parse(cls, device, data):
        try:
            t = data["partitiontable"]
            sector = t["sectorsize"]
            if (t["label"] != "gpt" or t["unit"] != "sectors" or t["device"] != device
                    or type(sector) is not int or sector not in (512, 4096)):
                raise ValueError("expected a GPT disk with 512 or 4096 byte sectors")
            first, last = t["firstlba"], t["lastlba"]
            if type(first) is not int or type(last) is not int or not 0 < first < last:
                raise ValueError("invalid usable disk bounds")
            count = t.get("table-length", 128)
            if not re.fullmatch(r"[1-9][0-9]*", str(count)) or int(count) > 2**32 - 1:
                raise ValueError("invalid GPT entry count")
            count = int(count)
            parts, unused = [], []
            for p in t["partitions"]:
                node = p["node"]
                match = re.fullmatch(re.escape(device) + ("p" if device[-1].isdigit() else "") + r"([1-9][0-9]*)", node)
                if not match or int(match[1]) > count:
                    raise ValueError("invalid partition number")
                if p["type"] == "00000000-0000-0000-0000-000000000000":
                    unused.append(int(match[1]))
                    continue
                if type(p["start"]) is not int or type(p["size"]) is not int or p["size"] <= 0:
                    raise ValueError("invalid partition extent or device node")
                if not isinstance(p.get("name", ""), str):
                    raise ValueError("invalid partition name")
                parts.append(Partition(int(match[1]), p["start"], p["start"] + p["size"],
                                       p.get("name", ""), p["type"].lower(), p["uuid"].lower(), p.get("attrs", "")))
            ordered = sorted(parts, key=lambda p: p.start)
            if (len({p.number for p in parts} | set(unused)) != len(parts) + len(unused)
                    or any(p.start < first or p.end > last + 1 for p in parts)
                    or any(a.end > b.start for a, b in zip(ordered, ordered[1:]))):
                raise ValueError("overlapping or out-of-bounds partitions")
            return cls(device, sector, first, last, t["id"].lower(), tuple(sorted(parts, key=lambda p: p.number)), count, tuple(sorted(unused)))
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            raise Error(f"Could not validate the partition table: {error}") from error

    def layout(self):
        userdata = [p for p in self.parts if p.name == "userdata"]
        if len(userdata) != 1:
            raise Error("Expected exactly one Android userdata partition")
        userdata = userdata[0]
        tail = tuple(sorted((p for p in self.parts if p.start >= userdata.end), key=lambda p: p.start))
        return userdata, tail

    def info(self):
        userdata, tail = self.layout()
        android_gib = (userdata.end - userdata.start) * self.sector_size // GIB
        if tail:
            return dict(mode="occupied", partition_names=", ".join(
                            f"{part_node(self.device, p.number)} ({p.name or 'unnamed'})" for p in tail),
                        android_gib=android_gib, linux_gib=sum(p.end - p.start for p in tail) * self.sector_size // GIB)
        maximum = ((userdata.end * self.sector_size // MIB * MIB)
                   - align_up(userdata.start * self.sector_size) - RESERVE) // GIB
        if maximum < ANDROID_MIN // GIB:
            return dict(mode="toosmall", needed_gib=RESERVE // GIB, android_current_gib=android_gib)
        return dict(mode="fresh", android_min_gib=ANDROID_MIN // GIB, android_max_gib=maximum,
                    android_current_gib=android_gib)


def read_table(device):
    try:
        return Table.parse(device, json.loads(output("sfdisk", "--json", device)))
    except ValueError as error:
        raise Error(f"Invalid partition table output: {error}") from error


def table_fingerprint(table):
    ident = os.stat(table.device).st_rdev
    diskseq = (Path("/sys/dev/block") / f"{os.major(ident)}:{os.minor(ident)}" / "diskseq").read_text().strip()
    data = dict(table=asdict(table), device_id=ident, disk_sequence=diskseq)
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


@dataclass(frozen=True)
class Plan:
    table: Table
    operation: str
    userdata: Partition
    userdata_end: int
    remove: tuple
    create: tuple

    @classmethod
    def make(cls, table, userdata_gib=None):
        userdata, tail = table.layout()
        sector = table.sector_size
        end = max(p.end for p in (userdata, *tail))
        if tail:
            if userdata_gib is not None:
                raise Error("--userdata-gib only applies to a fresh install")
            operation, ud_end = "replace", userdata.end
            start = align_up(ud_end * sector) // sector
        else:
            info = table.info()
            if info["mode"] == "toosmall":
                raise Error("Not enough space for Android and Reverie")
            if type(userdata_gib) is not int or not info["android_min_gib"] <= userdata_gib <= info["android_max_gib"]:
                raise Error(f"Android size must be {info['android_min_gib']}..{info['android_max_gib']} GiB")
            operation = "fresh"
            ud_end = (align_up(userdata.start * sector) + userdata_gib * GIB) // sector
            start = ud_end
        end = end * sector // MIB * MIB // sector
        if (end - start) * sector < ESP_SIZE + ROOT_MIN:
            raise Error("Space after userdata is too small; use UNINSTALL CFW in ABL, then install with a smaller Android size")
        used = {p.number for p in table.parts if p not in tail}
        preferred = [userdata.number + offset for offset in (1, 2)]
        free = [number for number in range(1, table.entry_count + 1) if number not in used]
        numbers = preferred if all(number in free for number in preferred) else free[:2]
        if len(numbers) != 2:
            raise Error("Not enough free GPT partition slots")
        esp_end = start + ESP_SIZE // sector
        create = (Partition(numbers[0], start, esp_end, "REVERIE", ESP_TYPE),
                  Partition(numbers[1], esp_end, end, "rootfs", LINUX_TYPE))
        return cls(table, operation, userdata, ud_end, tail, create)

    def describe(self):
        if self.operation == "replace":
            names = ", ".join(f"{part_node(self.table.device, p.number)} ({p.name or 'unnamed'})" for p in self.remove)
            return (f"Erase partitions after Android userdata on {self.table.device} ({names}) and install Reverie?\n"
                    f"Android user data will remain untouched.")
        size = (self.userdata_end - self.userdata.start) * self.table.sector_size // GIB
        return f"Install Reverie and resize Android to {size} GiB?\nAll Android user data will be erased."

    def script(self):
        table = self.table
        lines = ["label: gpt", f"label-id: {table.disk_id}", "unit: sectors",
                 f"first-lba: {table.first}", f"last-lba: {table.last}",
                 f"sector-size: {table.sector_size}", f"table-length: {table.entry_count}"]
        parts = [replace(p, end=self.userdata_end) if p == self.userdata else p
                 for p in table.parts if p not in self.remove] + list(self.create)
        for p in sorted(parts, key=lambda p: p.number):
            name = re.sub(r'["\\\x00-\x1f]', lambda m: f"\\x{ord(m[0]):02x}", p.name)
            fields = [f"start={p.start}", f"size={p.end - p.start}", f"type={p.type}",
                      f'name="{name}"']
            if p.uuid:
                fields.append("uuid=" + p.uuid)
            if p.attrs:
                fields.append("attrs=" + json.dumps(p.attrs))
            lines.append(part_node(table.device, p.number) + ": " + ", ".join(fields))
        return "\n".join(lines) + "\n"

    def write(self):
        run("sfdisk", "--no-reread", "--no-tell-kernel", "--wipe=never", "--wipe-partitions=never",
            self.table.device, input=self.script())

    def verify(self, actual):
        expected = {p.number: p for p in self.table.parts if p not in self.remove}
        expected[self.userdata.number] = replace(self.userdata, end=self.userdata_end)
        new = {p.number: p for p in self.create}
        if ((actual.device, actual.sector_size, actual.first, actual.last, actual.disk_id, actual.entry_count)
                != (self.table.device, self.table.sector_size, self.table.first, self.table.last, self.table.disk_id, self.table.entry_count)
                or actual.unused or {p.number for p in actual.parts} != expected.keys() | new.keys()):
            raise Error("Partition table does not match the installation plan")
        for p in actual.parts:
            wanted = new.get(p.number)
            if (wanted and replace(p, uuid="", attrs="") != wanted) or (not wanted and p != expected[p.number]):
                raise Error(f"Partition {p.number} does not match the installation plan")


def discover_device(override=None):
    if override:
        device = str(Path(override).resolve(strict=True))
    else:
        disks = json.loads(output("lsblk", "--json", "--paths", "--output", "NAME,TYPE,PARTLABEL"))["blockdevices"]
        candidates = [d["name"] for d in disks if d["type"] == "disk"
                      and any(p.get("partlabel") == "userdata" for p in d.get("children", []))]
        if len(candidates) != 1:
            raise Error("Could not uniquely identify internal storage; specify --device")
        device = candidates[0]
    if not Path(device).is_block_device() or output("lsblk", "-dnro", "TYPE", device) != "disk":
        raise Error(f"{device} is not a whole block device")
    return device


def refuse_boot_disk(device):
    mount = "/sysroot" if Path("/sysroot").is_mount() else "/"
    source = output("findmnt", "--noheadings", "--output", "SOURCE", "--target", mount).split("[", 1)[0]
    if not Path(source).is_block_device():
        raise Error("Cannot determine the boot disk; refusing to modify internal storage")
    ancestors = output("lsblk", "--inverse", "--noheadings", "--raw", "--output", "MAJ:MIN", source).splitlines()
    ident = os.stat(device).st_rdev
    if not ancestors or f"{os.major(ident)}:{os.minor(ident)}" in ancestors:
        raise Error("Refusing to modify the disk the running system booted from")


def require_idle(plan):
    parts = list(plan.remove)
    if plan.operation != "replace":
        parts.append(plan.userdata)
    mounted = {line.split()[2] for path in ("/proc/1/mountinfo", "/proc/self/mountinfo")
               for line in Path(path).read_text().splitlines()}
    swaps = {os.stat(line.split()[0]).st_rdev for line in Path("/proc/swaps").read_text().splitlines()[1:]}
    for p in parts:
        node = part_node(plan.table.device, p.number)
        try:
            ident = os.stat(node).st_rdev
        except FileNotFoundError:
            continue
        key = f"{os.major(ident)}:{os.minor(ident)}"
        if key in mounted or ident in swaps or any((Path("/sys/dev/block") / key / "holders").iterdir()):
            raise Error(f"{node} is in use; unmount it before continuing")


def find_source_kernel(exclude_nodes=()):
    candidates = [
        Path("/run/reverie-installer-src-esp/KERNEL"),
        Path("/boot/efi/KERNEL"),
        Path("/esp/KERNEL"),
    ]
    # Scan all user media mountpoints dynamically
    media_dir = Path("/run/media")
    if media_dir.is_dir():
        for p in media_dir.glob("*/*/KERNEL"):
            candidates.append(p)

    for p in candidates:
        try:
            if p.is_file() and p.stat().st_size > 5 * 1024 * 1024:
                return p
        except Exception:
            pass

    devices = []
    # 1. Inspect the boot device of current rootfs
    try:
        root_dev = subprocess.run(["findmnt", "-no", "SOURCE", "/"], capture_output=True, text=True).stdout.strip()
        if root_dev:
            pk = subprocess.run(["lsblk", "-no", "PKNAME", root_dev], capture_output=True, text=True).stdout.strip()
            if pk:
                parent = f"/dev/{pk}"
                p1 = f"{parent}p1" if parent[-1].isdigit() else f"{parent}1"
                if p1 not in devices:
                    devices.append(p1)
    except Exception:
        pass

    # 2. Search blkid safely for boot labels
    for lbl in ["LABEL=REVERIE", "LABEL_FATBOOT=REVERIE", "LABEL=ARMADA"]:
        try:
            res = subprocess.run(["blkid", "-t", lbl, "-o", "device"], capture_output=True, text=True)
            if res.returncode == 0:
                for line in res.stdout.splitlines():
                    d = line.strip()
                    if d and d not in devices:
                        devices.append(d)
        except Exception:
            pass

    # 3. Search all vfat partitions
    try:
        res = subprocess.run(["blkid", "-t", "TYPE=vfat", "-o", "device"], capture_output=True, text=True)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                d = line.strip()
                if d and d not in devices:
                    devices.append(d)
    except Exception:
        pass

    mnt = Path("/run/reverie-installer-src-esp")
    mnt.mkdir(parents=True, exist_ok=True)
    exclude_set = set(str(e) for e in exclude_nodes)

    for dev in devices:
        if dev in exclude_set:
            continue
        try:
            subprocess.run(["umount", str(mnt)], capture_output=True)
            res = subprocess.run(["mount", "-o", "ro", dev, str(mnt)], capture_output=True)
            if res.returncode == 0:
                k = mnt / "KERNEL"
                if k.is_file() and k.stat().st_size > 5 * 1024 * 1024:
                    return k
                subprocess.run(["umount", str(mnt)], capture_output=True)
        except Exception:
            subprocess.run(["umount", str(mnt)], capture_output=True)

    raise Error("Could not find bootable /KERNEL image on SD card or mounted partitions")



class Installation:
    def __init__(self, plan):
        self.plan = plan
        self.changed = False
        self.mounts = []
        self.work = None

    def mount(self, source, target, options=None):
        target.mkdir(parents=True, exist_ok=True)
        self.mounts.append(target)
        try:
            run("mount", *(["-o", options] if options else []), source, target)
        except BaseException:
            if not target.is_mount():
                self.mounts.remove(target)
            raise

    def close(self):
        failed = False
        for target in reversed(self.mounts):
            try:
                run("umount", target)
            except Exception as error:
                failed = True
                print(f"ERROR: cleanup unmount {target}: {error}", file=sys.stderr)
        if self.work and not failed:
            shutil.rmtree(self.work, ignore_errors=True)
        if failed:
            raise Error("Could not unmount all installation targets; do not remove storage")

    def partition(self):
        plan = self.plan
        refuse_boot_disk(plan.table.device)
        if read_table(plan.table.device) != plan.table:
            raise Error("Partition table changed unexpectedly; please restart")
        require_idle(plan)
        self.changed = True
        plan.write()
        run("partprobe", plan.table.device)
        run("udevadm", "settle")
        plan.verify(read_table(plan.table.device))
        if plan.operation != "replace":
            run("dd", "if=/dev/zero", f"of={part_node(plan.table.device, plan.userdata.number)}",
                "bs=1M", "count=8", "conv=fsync", "status=none")

    def deploy(self):
        plan = self.plan
        esp_node = part_node(plan.table.device, plan.create[0].number)
        root_node = part_node(plan.table.device, plan.create[1].number)

        self.work = Path(tempfile.mkdtemp(prefix="reverie-install.", dir="/run"))
        target = self.work / "target"
        target.mkdir(parents=True, exist_ok=True)
        esp_dir = self.work / "esp"
        esp_dir.mkdir(parents=True, exist_ok=True)

        print(f"Formatting {esp_node} as VFAT (REVERIE ESP)...", flush=True)
        run("mkfs.vfat", "-F", "32", "-n", "REVERIE", esp_node)

        print(f"Formatting {root_node} as Btrfs (rootfs)...", flush=True)
        run("mkfs.btrfs", "-f", "-L", "rootfs", root_node)

        print("Mounting internal ESP partition...", flush=True)
        self.mount(esp_node, esp_dir)

        print("Locating boot image (/KERNEL)...", flush=True)
        kernel_src = find_source_kernel(exclude_nodes=[esp_node])
        print(f"Copying {kernel_src} -> {esp_dir / 'KERNEL'}...", flush=True)
        shutil.copy2(kernel_src, esp_dir / "KERNEL")
        run("sync")

        # Clean up source ESP mount if mounted
        subprocess.run(["umount", "/run/reverie-installer-src-esp"], capture_output=True)

        print("Unmounting internal ESP...", flush=True)
        run("umount", esp_dir)
        self.mounts.remove(esp_dir)

        print("Mounting internal rootfs...", flush=True)
        self.mount(root_node, target, BTRFS_OPTS)

        # Check for pre-packaged clean base image archive
        base_archive = None
        archive_candidates = [
            Path("/opt/reverie/reverie-base.tar.zst"),
        ]
        media_dir = Path("/run/media")
        if media_dir.is_dir():
            for p in media_dir.glob("*/*/reverie-base.tar.zst"):
                archive_candidates.append(p)

        for archive_path in archive_candidates:
            if archive_path.is_file():
                base_archive = archive_path
                break

        if base_archive:
            print(f"Extracting clean base image from {base_archive}...", flush=True)
            run("tar", "-I", "zstd", "-xpf", str(base_archive), "-C", str(target))
        else:
            print("Deploying clean base system (excluding game downloads and caches)...", flush=True)
            exclude_args = [
                "--exclude=/dev/*",
                "--exclude=/proc/*",
                "--exclude=/sys/*",
                "--exclude=/tmp/*",
                "--exclude=/run/*",
                "--exclude=/mnt/*",
                "--exclude=/media/*",
                "--exclude=/lost+found",
                "--exclude=/swapfile",
                "--exclude=/boot/efi*",
                "--exclude=/esp*",
                "--exclude=.armada-installer*.log",
                "--exclude=reverie-installer*.log",
                # Exclude installer itself and its desktop shortcuts from internal target
                "--exclude=home/steamos/.local/bin/reverie-installer",
                "--exclude=home/steamos/Desktop/reverie-installer.desktop",
                "--exclude=home/steamos/.local/share/applications/reverie-installer.desktop",
                "--exclude=usr/share/applications/reverie-installer.desktop",
                "--exclude=usr/libexec/reverie*",
                "--exclude=usr/bin/reverie-installer",
                "--exclude=etc/sudoers.d/reverie*",
                # Strictly exclude all non-runtime games and downloading caches
                "--exclude=home/steamos/.local/share/Steam/steamapps/downloading/*",
                "--exclude=home/steamos/.local/share/Steam/steamapps/temp/*",
                "--exclude=home/steamos/.local/share/Steam/steamapps/shadercache/*",
                "--exclude=home/steamos/.cache/*",
                "--exclude=home/steamos/Downloads/*",
                # Exclude runtime system logs and journals from internal target
                "--exclude=/var/log/journal/*",
                "--exclude=/var/log/*.log",
                "--exclude=/var/log/*.txt",
                "--exclude=/var/log/reverie*",
            ]

            # Exclude game directories inside steamapps/common, preserving only runtimes
            games_dir = Path("/home/steamos/.local/share/Steam/steamapps/common")
            if games_dir.is_dir():
                for game_entry in games_dir.iterdir():
                    if game_entry.is_dir():
                        name = game_entry.name
                        if not any(name.startswith(p) for p in PRESERVED_RUNTIMES):
                            exclude_args.append(f"--exclude={game_entry.relative_to('/')}")

            # Exclude game manifests (.acf) that do not belong to system runtimes
            manifests_dir = Path("/home/steamos/.local/share/Steam/steamapps")
            if manifests_dir.is_dir():
                for item in manifests_dir.glob("appmanifest_*.acf"):
                    if item.name not in PRESERVED_MANIFESTS:
                        exclude_args.append(f"--exclude={item.relative_to('/')}")

            rsync_cmd = ["rsync", "-aHAX", *exclude_args, "/", f"{target}/"]
            run(*rsync_cmd)

        # Ensure essential mount point directories exist
        (target / "boot/efi").mkdir(parents=True, exist_ok=True)
        (target / "esp").mkdir(parents=True, exist_ok=True)

        # Ensure installer files never remain on internal installation
        for p in [
            target / "home/steamos/.local/bin/reverie-installer",
            target / "home/steamos/Desktop/reverie-installer.desktop",
            target / "home/steamos/.local/share/applications/reverie-installer.desktop",
            target / "usr/share/applications/reverie-installer.desktop",
            target / "usr/bin/reverie-installer",
            target / "etc/sudoers.d/reverie",
        ]:
            if p.is_file() or p.is_symlink():
                p.unlink(missing_ok=True)
        shutil.rmtree(target / "usr/libexec/reverie", ignore_errors=True)

        # Clean fstab of target
        fstab_path = target / "etc/fstab"
        if fstab_path.exists():
            print("Configuring target fstab...", flush=True)
            lines = [l for l in fstab_path.read_text().splitlines() if not l.strip().startswith("/dev/mmcblk")]
            fstab_path.write_text("\n".join(lines) + "\n")

        print("Syncing data to internal storage...", flush=True)
        run("sync")
        print("Reverie deployed successfully!", flush=True)

    def recovery(self):
        android = " Android userdata and earlier partitions are unchanged." if self.plan.operation == "replace" else ""
        return "Internal storage was modified." + android + " Do not boot internal storage. " + RECOVERY


@contextmanager
def operation(plan):
    job = Installation(plan)
    failure = None
    try:
        yield job
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            job.close()
        except Exception as error:
            if failure is None:
                failure = error
                raise
        finally:
            if failure is not None and job.changed:
                print("ERROR: " + job.recovery(), file=sys.stderr)


@contextmanager
def inhibit_sleep():
    child = subprocess.Popen(["systemd-inhibit", "--what=sleep:idle:shutdown", "--who=Reverie Installer",
                              "--why=installer operation in progress", "--mode=block", sys.executable, "-c",
                              "import time; print('ready', flush=True); time.sleep(2147483647)"],
                             stdout=subprocess.PIPE, start_new_session=True)
    try:
        if not select.select([child.stdout], [], [], 10)[0] or child.stdout.readline() != b"ready\n":
            raise Error("Could not inhibit sleep and shutdown; installation was not started")
        yield
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
        child.wait()
        child.stdout.close()


def choose_android_size(minimum, maximum, total):
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gio, Gtk

    selected = []
    app = Adw.Application(application_id="org.reverie.Installer.Size", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def activate(application):
        window = Adw.MessageDialog(application=application, title="Reverie Installer", heading="Reverie Installer")
        window.set_default_size(520, -1)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.append(Gtk.Label(label="Choose how to split internal storage", wrap=True))
        sizes = Gtk.Label()
        box.append(sizes)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        minus, plus = Gtk.Button(), Gtk.Button()
        slider = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, minimum, max(maximum, minimum+1), 1)
        slider.set_draw_value(False)
        slider.set_digits(0)
        slider.set_round_digits(0)
        slider.set_hexpand(True)
        slider.set_value(min(maximum, max(minimum, 32)))
        slider.set_sensitive(maximum > minimum)
        for button, icon, tooltip in ((minus, "list-remove-symbolic", "Decrease Android storage by 1 GiB"),
                                      (plus, "list-add-symbolic", "Increase Android storage by 1 GiB")):
            button.set_child(Gtk.Image(icon_name=icon, pixel_size=16))
            button.set_size_request(56, 56)
            button.set_tooltip_text(tooltip)
            button.update_property([Gtk.AccessibleProperty.LABEL], [tooltip])
        for widget in (minus, slider, plus):
            row.append(widget)
        box.append(row)

        def changed(*_):
            value = max(minimum, min(maximum, round(slider.get_value())))
            sizes.set_text(f"Android: {value} GiB       Reverie: {total-value} GiB")
            minus.set_sensitive(value > minimum)
            plus.set_sensitive(value < maximum)

        slider.connect("value-changed", changed)
        minus.connect("clicked", lambda _: slider.set_value(max(minimum, slider.get_value()-1)))
        plus.connect("clicked", lambda _: slider.set_value(min(maximum, slider.get_value()+1)))
        changed()
        window.set_extra_child(box)
        window.add_response("cancel", "Cancel")
        window.add_response("continue", "Continue")
        window.set_default_response("continue")
        window.set_close_response("cancel")

        def respond(dialog, response):
            if response == "continue":
                selected.append(max(minimum, min(maximum, round(slider.get_value()))))
            dialog.destroy()

        window.connect("response", respond)
        window.present()

    app.connect("activate", activate)
    app.run([])
    if not selected:
        raise Cancelled()
    return selected[0]


class Gui:
    def __init__(self, device):
        self.command = ["sudo", SELF, *(["--device", device] if device else [])]

    def dialog(self, kind, text, *options):
        return run("zenity", "--" + kind, "--title=Reverie Installer", "--width=500", "--text=" + html.escape(text),
                   *options, capture=True, check=False)

    def confirm(self, text, label):
        if self.dialog("question", text, "--ok-label=" + label, "--cancel-label=Cancel").returncode:
            raise Cancelled()

    def progress(self, command):
        fd, name = tempfile.mkstemp(prefix="reverie-installer.", suffix=".log",
                                    dir="/run" if os.geteuid() == 0 else f"/run/user/{os.getuid()}")
        with os.fdopen(fd, "w") as stream:
            progress = subprocess.Popen(["zenity", "--progress", "--pulsate", "--auto-close", "--no-cancel",
                                         "--title=Reverie Installer", "--text=Installing Reverie to internal storage…\nWorking, do not power off."], stdin=subprocess.PIPE, text=True)
            try:
                progress.stdin.write("0\n")
                progress.stdin.flush()
                result = run(*self.command, *command, "--assume-yes", stdout=stream, stderr=subprocess.STDOUT, check=False)
            finally:
                try:
                    progress.stdin.close()
                except BrokenPipeError:
                    pass
                progress.wait()
        if result.returncode:
            with open(name, "rb") as log:
                log.seek(max(0, os.fstat(log.fileno()).st_size - 4096))
                recent = "\n".join(log.read().decode(errors="replace").splitlines()[-12:])
            raise Error(f"Operation failed.\n\n{recent}\n\nFull log: {name}\n\n" + RECOVERY)

    def start(self):
        info = json.loads(output(*self.command, "detect", "--json"))
        self.command = ["sudo", SELF, "--device", info["device"]]
        mode = info["mode"]
        if mode == "toosmall":
            raise Error(f"Internal storage is too small. Reverie needs about {info['needed_gib']} GiB alongside Android.")
        
        if mode == "fresh":
            self.confirm("Install Reverie alongside Android?\n\nInstalling Reverie will factory-reset Android and erase all Android user data.", "Continue")
            minimum, maximum = info["android_min_gib"], info["android_max_gib"]
            gib = choose_android_size(minimum, maximum, info["android_current_gib"])
            self.confirm(f"Resize Android to {gib} GiB and install Reverie? All Android user data will be erased.", "Install")
            command = ["install", "--userdata-gib", str(gib)]
        elif mode == "occupied":
            self.confirm("Replace the existing Linux installation?\n\n"
                         "Internal storage already has space in use alongside Android. Installing Reverie will replace everything in that space.\n\n"
                         "All data in that space will be erased. Android and its user data will be kept.\n\n"
                         f"Partitions to erase: {info['partition_names']}",
                         "Replace with Reverie")
            command = ["install"]
        else:
            raise Error("Unknown internal storage layout")

        self.progress(command)
        if self.dialog("question", "Installation complete.\n\nPower off, remove the SD card, then power on to boot Reverie from internal storage.",
                       "--ok-label=Power off", "--cancel-label=Close").returncode == 0:
            run("sudo", "systemctl", "poweroff")


def execute(args):
    if os.geteuid() != 0:
        raise Error("This command must run as root")
    device = discover_device(args.device)
    table = read_table(device)
    if args.command == "detect":
        info = table.info()
        info.update(device=device, table_fingerprint=table_fingerprint(table))
        print(json.dumps(info) if args.json else "\n".join(f"{k}={v}" for k, v in info.items()))
        return
    refuse_boot_disk(device)
    with open("/run/reverie-installer.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Error("Another installation is already running") from error
        size = getattr(args, "userdata_gib", None)
        if args.command == "install" and table.info()["mode"] == "fresh" and size is None:
            if args.assume_yes:
                raise Error("Specify --userdata-gib for an unattended fresh install")
            info = table.info()
            try:
                size = int(input(f"New Android size in GiB ({info['android_min_gib']}..{info['android_max_gib']}): "))
            except ValueError as error:
                raise Error("Android size must be an integer") from error
        plan = Plan.make(table, size)
        print(plan.describe(), flush=True)
        if not args.assume_yes and input("Proceed? [y/N]: ").strip().lower() not in ("y", "yes"):
            raise Cancelled()
        require_idle(plan)
        with inhibit_sleep():
            with operation(plan) as job:
                job.partition()
                job.deploy()
                os.sync()
        print("Install complete. Power off, remove the SD card, then power on.", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog="To uninstall, select UNINSTALL CFW in ABL.")
    parser.add_argument("--device", default=os.environ.get("REVERIE_INTERNAL_DEVICE"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("gui", help="desktop graphical installer")
    commands.add_parser("detect", help="inspect internal storage without changing it").add_argument("--json", action="store_true")
    install = commands.add_parser("install", help="install Reverie to internal storage")
    install.add_argument("--userdata-gib", type=int)
    install.add_argument("-y", "--assume-yes", action="store_true")
    args = parser.parse_args(argv)

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)
    try:
        if args.command == "gui":
            Gui(args.device).start()
        else:
            execute(args)
        return 0
    except Cancelled:
        print("Aborted.")
        return 0
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if args.command == "gui":
            Gui(args.device).dialog("error", str(error))
        return 128 + error.signum if isinstance(error, Interrupted) else 1


if __name__ == "__main__":
    sys.exit(main())
