#!/usr/bin/env python3
"""Optional local QEMU VMs. Trusted Linux images; no provider-policy bypass."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from process_identity import identity, read_record


class VMError(Exception):
    def __init__(self, message, code=8):
        super().__init__(message)
        self.code = code


def name(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', value):
        raise VMError('Name must be 1-64 ASCII letters/digits/dot/underscore/hyphen, starting with a letter or digit.', 6)
    return value


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def private_dir(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or (hasattr(os, 'getuid') and path.stat().st_uid != os.getuid()):
        raise VMError(f'Untrusted state directory: {path}', 9)
    path.chmod(0o700)
    return path


def write_json(path, data):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(data, file, indent=2)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    if path.is_symlink() or path.stat().st_mode & 0o022:
        raise VMError(f'Untrusted writable/symlink state file: {path}', 9)
    if hasattr(os, 'getuid') and path.stat().st_uid != os.getuid():
        raise VMError(f'Untrusted state file owner: {path}', 9)
    return json.loads(path.read_text())


def run(argv, timeout=120):
    try:
        result = subprocess.run([str(x) for x in argv], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise VMError(f'Required program is unavailable: {argv[0]}', 3) from exc
    except subprocess.TimeoutExpired as exc:
        raise VMError(f'Operation timed out after {timeout}s: {argv[0]}') from exc
    if result.returncode:
        raise VMError(f'{argv[0]} failed (exit {result.returncode}): {result.stderr[-1500:]}')
    return result.stdout


def tool(binary):
    resolved = shutil.which(binary)
    if not resolved:
        raise VMError(f'{binary} is not installed; optional CyberVM is unavailable.', 3)
    return str(Path(resolved).resolve())


def capabilities():
    linux = sys.platform.startswith('linux')
    qemu = shutil.which('qemu-system-x86_64')
    kvm = linux and os.access('/dev/kvm', os.R_OK | os.W_OK) and platform.machine() in ('x86_64', 'amd64')
    seed = shutil.which('cloud-localds') or shutil.which('genisoimage') or shutil.which('mkisofs')
    return {'schema_version': 1, 'platform': sys.platform, 'qemu_x86_64': qemu,
            'qemu_img': shutil.which('qemu-img'), 'kvm_device_accessible': kvm,
            'acceleration': 'KVM_CANDIDATE' if qemu and kvm else 'TCG_SOFTWARE' if qemu and linux else 'UNAVAILABLE',
            'cloud_init_seed_builder': seed, 'managed_vm_platform': 'linux',
            'supported_guest_architecture': 'x86_64',
            'note': 'KVM accessibility is a capability hint; VM start verifies whether QEMU accepts it. Provider lifecycle remains authoritative.'}


class Manager:
    def __init__(self, root=None):
        default = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'cybervps/cybervm'
        self.root = Path(root or os.environ.get('CYBERVM_HOME', default)).expanduser().resolve()
        self.vms = self.root / 'vms'
        self.images = self.root / 'images'

    def directory(self, value):
        return self.vms / name(value)

    @contextlib.contextmanager
    def locked(self):
        if not sys.platform.startswith('linux'):
            raise VMError('Managed CyberVM requires Linux. Native Windows QEMU control is not implemented.', 3)
        import fcntl
        private_dir(self.root)
        private_dir(self.vms)
        private_dir(self.images)
        lockpath = self.root / '.lock'
        fd = os.open(lockpath, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise VMError('Another CyberVM mutation is running. Retry after it completes.') from exc
            yield
        finally:
            os.close(fd)

    def load(self, vm):
        directory = self.directory(vm)
        if directory.is_symlink():
            raise VMError('VM directory cannot be a symlink.', 9)
        path = directory / 'config.json'
        if not path.is_file():
            raise VMError(f'VM not found: {vm}', 6)
        data = read_json(path)
        if data.get('schema_version') != 1 or data.get('name') != vm or not re.fullmatch(r'[a-f0-9-]{36}', data.get('uuid', '')):
            raise VMError('Invalid or unsupported VM metadata.', 6)
        return data

    def state(self, vm):
        directory = self.directory(vm)
        runtime_path = directory / 'runtime.json'
        if not runtime_path.exists():
            return 'STOPPED', None
        runtime = read_json(runtime_path)
        record_path = directory / 'process.json'
        if not record_path.exists():
            return 'ORPHANED', runtime
        try:
            recorded = read_record(record_path)
        except (FileNotFoundError, ProcessLookupError):
            return 'STOPPED', runtime
        except (OSError, ValueError, KeyError, TypeError):
            # A zombie with the same boot/start identity has exited, even if a
            # container PID 1 has not reaped it yet. Never treat PID reuse as exit.
            try:
                saved = read_json(record_path)
                fields = Path(f'/proc/{saved["pid"]}/stat').read_text().rsplit(')', 1)[1].split()
                boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
                if saved.get('boot_id') != boot or (fields[0] == 'Z' and fields[19] == saved.get('start_ticks')):
                    return 'STOPPED', runtime
            except (OSError, ValueError, KeyError, TypeError, IndexError):
                pass
            return 'STALE_STATE', runtime
        config = self.load(vm)
        if runtime.get('pid') != recorded['pid'] or runtime.get('uuid') != config['uuid']:
            return 'STALE_STATE', runtime
        try:
            exe = str(Path(f'/proc/{recorded["pid"]}/exe').resolve(strict=True))
            cmdline = Path(f'/proc/{recorded["pid"]}/cmdline').read_bytes().split(b'\0')
            marker = config['uuid'].encode()
            index = cmdline.index(b'-uuid')
            if exe != runtime.get('executable') or cmdline[index + 1] != marker:
                return 'STALE_STATE', runtime
        except (OSError, ValueError, IndexError):
            return 'STALE_STATE', runtime
        return 'RUNNING', runtime

    def stopped(self, vm):
        state, _ = self.state(vm)
        if state != 'STOPPED':
            raise VMError(f'VM must be STOPPED for this operation (current state {state}).')

    def image_info(self, path):
        data = json.loads(run([tool('qemu-img'), 'info', '--output=json', path]))
        if data.get('format') not in ('qcow2', 'raw'):
            raise VMError('Only raw or qcow2 cloud images are accepted.', 6)
        if data.get('backing-filename') or data.get('full-backing-filename') or data.get('data-file'):
            raise VMError('Base image must be self-contained, without backing or external data files.', 9)
        specific = data.get('format-specific', {}).get('data', {})
        if specific.get('data-file'):
            raise VMError('External image data files are not accepted.', 9)
        if not isinstance(data.get('virtual-size'), int) or data['virtual-size'] <= 0:
            raise VMError('Invalid image virtual size.', 9)
        return data

    def seed(self, directory, vm, identifier, public_key_path=None, username='cyber'):
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', username) or username == 'root':
            raise VMError('Cloud-init login user must be a non-root Linux username.', 6)
        seed_tool = capabilities()['cloud_init_seed_builder']
        if not seed_tool:
            raise VMError('cloud-localds or genisoimage/mkisofs is required for secure cloud-init. Install one or explicitly use --no-cloud-init for an already configured image.', 3)
        if public_key_path:
            public = Path(public_key_path).read_text().strip()
            private = None
        else:
            private = directory / 'id_ed25519'
            run([tool('ssh-keygen'), '-q', '-t', 'ed25519', '-N', '', '-C', f'cybervm-{vm}', '-f', private])
            private.chmod(0o600)
            public = Path(str(private) + '.pub').read_text().strip()
        if '\n' in public or not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]+(?: [^\r\n]*)?', public):
            raise VMError('Expected one OpenSSH public key, not a private key or authorized-key options.', 6)
        cloud = directory / 'cloud-init'
        private_dir(cloud)
        payload = {'users': [{'name': username, 'shell': '/bin/sh', 'lock_passwd': True,
                              'sudo': ['ALL=(ALL) NOPASSWD:ALL'], 'ssh_authorized_keys': [public]}],
                   'disable_root': True, 'ssh_pwauth': False, 'ssh_deletekeys': True}
        (cloud / 'user-data').write_text('#cloud-config\n' + json.dumps(payload, indent=2) + '\n')
        (cloud / 'meta-data').write_text(json.dumps({'instance-id': identifier, 'local-hostname': vm}) + '\n')
        for item in cloud.iterdir():
            item.chmod(0o600)
        seed_path = directory / 'seed.iso'
        if Path(seed_tool).name == 'cloud-localds':
            run([seed_tool, seed_path, cloud / 'user-data', cloud / 'meta-data'])
        else:
            run([seed_tool, '-output', seed_path, '-volid', 'cidata', '-joliet', '-rock', cloud / 'user-data', cloud / 'meta-data'])
        seed_path.chmod(0o600)
        return {'username': username, 'private_key': 'id_ed25519' if private else None, 'cloud_init': True}

    def create(self, args):
        destination = self.directory(args.name)
        if destination.exists():
            raise VMError(f'VM already exists: {args.name}', 6)
        source = Path(args.image).expanduser().resolve(strict=True)
        if not source.is_file() or not re.fullmatch(r'[A-Fa-f0-9]{64}', args.sha256):
            raise VMError('A regular cloud image and trusted 64-character SHA256 are required.', 6)
        expected = args.sha256.lower()
        if sha256(source) != expected:
            raise VMError('Cloud image checksum mismatch; no VM was created.', 9)
        if not 128 <= args.memory <= 1048576 or not 1 <= args.cpus <= 256:
            raise VMError('Memory must be 128-1048576 MiB and CPUs 1-256.', 6)
        temporary = Path(tempfile.mkdtemp(prefix='.create-', dir=self.vms))
        try:
            # Copy before QEMU inspection; verify the copy to detect changed sources.
            cached = self.images / f'{expected}.image'
            if cached.exists():
                if cached.is_symlink() or sha256(cached) != expected:
                    raise VMError('Cached base image checksum mismatch; refusing reuse.', 9)
            else:
                staged = temporary / 'base.image'
                shutil.copyfile(source, staged)
                if sha256(staged) != expected:
                    raise VMError('Image changed while copying; refusing it.', 9)
                staged.chmod(0o400)
                os.replace(staged, cached)
            image = self.image_info(cached)
            disk = temporary / 'disk.qcow2'
            run([tool('qemu-img'), 'create', '-f', 'qcow2', '-F', image['format'], '-b', cached, disk])
            disk.chmod(0o600)
            if args.disk_gb:
                if args.disk_gb < 1 or args.disk_gb * 1024**3 < image['virtual-size']:
                    raise VMError('Requested disk size must be at least the base virtual size; shrinking is not supported.', 6)
                run([tool('qemu-img'), 'resize', disk, f'{args.disk_gb}G'])
            identifier = str(uuid.uuid4())
            login = {'cloud_init': False, 'username': args.user, 'private_key': None}
            if not args.no_cloud_init:
                login = self.seed(temporary, args.name, identifier, args.ssh_public_key, args.user)
            config = {'schema_version': 1, 'name': args.name, 'uuid': identifier, 'created_at': int(time.time()),
                      'architecture': 'x86_64', 'memory_mib': args.memory, 'cpus': args.cpus,
                      'base_sha256': expected, 'base_format': image['format'], 'login': login}
            write_json(temporary / 'config.json', config)
            os.rename(temporary, destination)
            return config
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)

    def qmp(self, vm, command):
        state, runtime = self.state(vm)
        if state != 'RUNNING':
            raise VMError(f'VM process identity is not verified ({state}).', 9)
        expected = self.socket_path(self.load(vm)['uuid'])
        if runtime.get('qmp') != str(expected):
            raise VMError('QMP endpoint does not match this VM.', 9)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(str(expected))
            stream = sock.makefile('rwb')
            hello = json.loads(stream.readline())
            if 'QMP' not in hello:
                raise VMError('Invalid QMP greeting.', 9)
            def execute(operation):
                stream.write((json.dumps({'execute': operation}) + '\n').encode())
                stream.flush()
                while True:
                    line = stream.readline()
                    if not line:
                        raise VMError('QMP disconnected unexpectedly.')
                    reply = json.loads(line)
                    if 'error' in reply:
                        raise VMError(f'QMP command failed: {reply["error"]}')
                    if 'return' in reply:
                        return reply['return']
            execute('qmp_capabilities')
            if execute('query-uuid').get('UUID') != self.load(vm)['uuid']:
                raise VMError('QMP UUID mismatch.', 9)
            return execute(command)

    @staticmethod
    def socket_path(identifier):
        # A short, owner-only directory avoids Unix socket path-length failures.
        directory = private_dir(Path(tempfile.gettempdir()) / f'cybervps-vm-{os.getuid()}')
        return directory / f'{identifier}.sock'

    def start(self, vm, acceleration='auto', port=0):
        config = self.load(vm)
        self.stopped(vm)
        caps = capabilities()
        executable = tool('qemu-system-x86_64')
        if acceleration == 'kvm' and not caps['kvm_device_accessible']:
            raise VMError('KVM is not accessible; use --accel tcg if provider policy permits software emulation.', 3)
        accel = 'kvm' if acceleration == 'kvm' or (acceleration == 'auto' and caps['kvm_device_accessible']) else 'tcg'
        if port and not 1024 <= port <= 65535:
            raise VMError('SSH forwarding port must be 1024-65535, or 0 for automatic selection.', 6)
        base = self.images / f'{config["base_sha256"]}.image'
        if base.is_symlink() or sha256(base) != config['base_sha256']:
            raise VMError('Base image checksum mismatch. VM start refused.', 9)
        directory = self.directory(vm)
        disk = directory / 'disk.qcow2'
        if disk.is_symlink():
            raise VMError('VM disk cannot be a symlink.', 9)
        endpoint = self.socket_path(config['uuid'])
        if endpoint.exists():
            endpoint.unlink()
        # QEMU does not adopt this socket; a competing bind can still race and
        # is handled as a QEMU startup failure, never by killing its owner.
        probe = socket.socket()
        try:
            probe.bind(('127.0.0.1', port))
            chosen_port = probe.getsockname()[1]
            argv = [executable, '-name', vm, '-uuid', config['uuid'], '-machine', f'q35,accel={accel}',
                    '-m', str(config['memory_mib']), '-smp', str(config['cpus']), '-nodefaults',
                    '-drive', f'file={disk},if=virtio,format=qcow2', '-netdev',
                    f'user,id=net0,hostfwd=tcp:127.0.0.1:{chosen_port}-:22', '-device', 'virtio-net-pci,netdev=net0',
                    '-display', 'none', '-serial', f'file:{directory / "console.log"}', '-monitor', 'none',
                    '-qmp', f'unix:{endpoint},server=on,wait=off', '-no-reboot']
            if config['login']['cloud_init']:
                argv.extend(['-drive', f'file={directory / "seed.iso"},format=raw,media=cdrom,readonly=on'])
            # QEMU comma-delimited options cannot safely represent arbitrary
            # paths containing commas. Reject before executing any QEMU process.
            if ',' in str(directory) or ',' in str(endpoint):
                raise VMError('CyberVM data paths cannot contain commas (QEMU option syntax).', 6)
            logpath = directory / 'qemu.log'
            with logpath.open('ab') as log:
                logpath.chmod(0o600)
                probe.close()
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            try:
                record = identity(child.pid)
                write_json(directory / 'process.json', record)
                runtime = {'pid': child.pid, 'uuid': config['uuid'], 'executable': executable, 'qmp': str(endpoint),
                           'ssh_port': chosen_port, 'acceleration': accel.upper(), 'started_at': int(time.time())}
                write_json(directory / 'runtime.json', runtime)
                for _ in range(50):
                    if child.poll() is not None:
                        raise VMError(f'QEMU exited during startup (exit {child.returncode}). Log: {logpath}')
                    if endpoint.exists():
                        self.qmp(vm, 'query-status')
                        return runtime
                    time.sleep(0.1)
                raise VMError(f'QEMU did not establish QMP within 5s. Log: {logpath}')
            except BaseException:
                # Child object belongs to this start attempt, not an arbitrary PID.
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                raise
        finally:
            probe.close()

    def stop(self, vm, force=False):
        state, runtime = self.state(vm)
        if state == 'STOPPED':
            return {'name': vm, 'state': 'STOPPED'}
        if state != 'RUNNING':
            raise VMError('Process state is stale/unverifiable. Refusing to signal an unrelated process.', 9)
        if force:
            if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
                raise VMError('Safe force-stop requires Linux pidfd support.', 3)
            record = read_record(self.directory(vm) / 'process.json')
            fd = os.pidfd_open(record['pid'])
            try:
                if read_record(self.directory(vm) / 'process.json') != record or self.state(vm)[0] != 'RUNNING':
                    raise VMError('VM identity changed; refusing force-stop.', 9)
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            finally:
                os.close(fd)
        else:
            self.qmp(vm, 'system_powerdown')
        for _ in range(100):
            if self.state(vm)[0] != 'RUNNING':
                return {'name': vm, 'state': 'STOPPED'}
            time.sleep(0.1)
        raise VMError('Guest did not shut down within 10s. Inspect logs; force-stop is a separate explicit action.')

    def inspect(self, vm):
        config = self.load(vm)
        state, runtime = self.state(vm)
        return {'config': config, 'state': state, 'runtime': runtime}

    def listing(self):
        if not self.vms.is_dir():
            return []
        result = []
        for entry in sorted(self.vms.iterdir()):
            if not entry.name.startswith('.') and entry.is_dir():
                try:
                    data = self.inspect(entry.name)
                    result.append({'name': entry.name, 'state': data['state'], 'uuid': data['config']['uuid']})
                except (VMError, OSError, ValueError) as error:
                    result.append({'name': entry.name, 'state': 'UNKNOWN', 'error': str(error)})
        return result

    def snapshot(self, vm, snapshot):
        self.load(vm)
        self.stopped(vm)
        name(snapshot)
        info = json.loads(run([tool('qemu-img'), 'info', '--output=json', self.directory(vm) / 'disk.qcow2']))
        if any(item.get('name') == snapshot for item in info.get('snapshots', [])):
            raise VMError('Snapshot name already exists; refusing replacement.', 6)
        run([tool('qemu-img'), 'snapshot', '-c', snapshot, self.directory(vm) / 'disk.qcow2'])
        return {'name': vm, 'snapshot': snapshot, 'type': 'qcow2-internal-offline'}

    def clone(self, source, destination):
        config = self.load(source)
        self.stopped(source)
        if self.directory(destination).exists():
            raise VMError('Clone destination already exists.', 6)
        with tempfile.TemporaryDirectory(prefix='.clone-', dir=self.root) as temporary:
            image = Path(temporary) / 'clone.qcow2'
            run([tool('qemu-img'), 'convert', '-O', 'qcow2', self.directory(source) / 'disk.qcow2', image], timeout=600)
            args = argparse.Namespace(name=destination, image=str(image), sha256=sha256(image), memory=config['memory_mib'],
                                      cpus=config['cpus'], disk_gb=None, no_cloud_init=not config['login']['cloud_init'],
                                      ssh_public_key=None, user=config['login']['username'])
            return self.create(args)

    def connection(self, vm):
        config = self.load(vm)
        state, runtime = self.state(vm)
        if state != 'RUNNING':
            raise VMError(f'VM is not running ({state}).', 3)
        result = {'host': '127.0.0.1', 'port': runtime['ssh_port'], 'user': config['login']['username'],
                  'authentication': 'public-key', 'ready': 'Guest SSH readiness has not been verified. Verify the host-key fingerprint.'}
        if config['login'].get('private_key'):
            result['identity_file'] = str(self.directory(vm) / config['login']['private_key'])
        return result


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    sub = cli.add_subparsers(dest='action', required=True)
    sub.add_parser('doctor')
    sub.add_parser('list')
    create = sub.add_parser('create')
    create.add_argument('name', type=name)
    create.add_argument('--image', required=True)
    create.add_argument('--sha256', required=True)
    create.add_argument('--memory', type=int, default=1024, help='MiB')
    create.add_argument('--cpus', type=int, default=1)
    create.add_argument('--disk-gb', type=int)
    create.add_argument('--ssh-public-key')
    create.add_argument('--user', default='cyber')
    create.add_argument('--no-cloud-init', action='store_true', help='Explicitly use an already configured image; no credentials are created')
    for action in ('inspect', 'logs', 'connection', 'ssh', 'shell', 'stop', 'force-stop', 'delete', 'start', 'snapshot', 'clone'):
        item = sub.add_parser(action)
        item.add_argument('name', type=name)
        if action == 'start':
            item.add_argument('--accel', choices=['auto', 'kvm', 'tcg'], default='auto')
            item.add_argument('--ssh-port', type=int, default=0)
        if action == 'snapshot':
            item.add_argument('snapshot', type=name)
        if action == 'clone':
            item.add_argument('destination', type=name)
        if action == 'delete':
            item.add_argument('--yes', action='store_true')
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    manager = Manager()
    try:
        if args.action == 'doctor':
            result = capabilities()
        elif args.action == 'list':
            result = manager.listing()
        elif args.action == 'inspect':
            result = manager.inspect(args.name)
        elif args.action == 'connection':
            result = manager.connection(args.name)
        elif args.action in ('ssh', 'shell'):
            info = manager.connection(args.name)
            command = [tool('ssh'), '-p', str(info['port'])]
            if info.get('identity_file'):
                command.extend(['-i', info['identity_file']])
            command.append(f'{info["user"]}@127.0.0.1')
            return subprocess.call(command)
        elif args.action == 'logs':
            manager.load(args.name)
            for filename in ('qemu.log', 'console.log'):
                path = manager.directory(args.name) / filename
                if path.is_file() and not path.is_symlink():
                    with path.open('rb') as file:
                        file.seek(max(0, path.stat().st_size - 65536))
                        print(f'--- {filename} (last 64 KiB) ---\n{file.read().decode(errors="replace")}')
            return 0
        else:
            with manager.locked():
                if args.action == 'create': result = manager.create(args)
                elif args.action == 'start': result = manager.start(args.name, args.accel, args.ssh_port)
                elif args.action in ('stop', 'force-stop'): result = manager.stop(args.name, args.action == 'force-stop')
                elif args.action == 'snapshot': result = manager.snapshot(args.name, args.snapshot)
                elif args.action == 'clone': result = manager.clone(args.name, args.destination)
                elif args.action == 'delete':
                    manager.load(args.name)
                    manager.stopped(args.name)
                    if not args.yes:
                        raise VMError('Deletion requires --yes and removes only this stopped VM directory, not shared base images.', 2)
                    target = manager.directory(args.name)
                    if target.resolve().parent != manager.vms.resolve():
                        raise VMError('Invalid deletion target.', 9)
                    shutil.rmtree(target)
                    result = {'name': args.name, 'deleted': True}
        print(json.dumps(result, indent=2))
        return 0
    except VMError as error:
        print(f'CyberVM: {error}', file=sys.stderr)
        return error.code
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f'CyberVM operation failed: {error}', file=sys.stderr)
        return 8


if __name__ == '__main__':
    sys.exit(main())
