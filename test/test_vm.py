import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import shutil
import time
import urllib.request

import pexpect.fdpexpect

ramdisk_size_mb=1.5*1024
alpine_version = '3.22.1'
qemu_pidfile = 'qemu.pid'
qemu_socket = 'qemu.sock'
install_vm_password = 'installpass'
test_username = 'testuser'
test_password = 'testpass'
test_encryption_password = 'testencpass'
http_proxy = os.environ.get('http_proxy')

def get_qemu_pid():
    if os.path.exists(qemu_pidfile):
        with open(qemu_pidfile) as f:
            return int(f.read())
    else:
        return None

def kill_vm():
    pid = get_qemu_pid()
    try:
        os.kill(pid, 0)
    except:
        return
    if pid:
        os.kill(pid, signal.SIGINT)

def wait_for_qemu_shutdown():
    for i in range(0, 10):
        if not os.path.exists(qemu_pidfile):
            return
        else:
            time.sleep(1)
    print('Pidfile still present')
    exit(1)

def start_qemu_vm(command):
    vm_command = subprocess.run(
        command.split()
    )
    if vm_command.returncode != 0:
        print('Failed to launch VM')
        exit(1)
    for i in range(0, 10):
        if os.path.exists(qemu_socket):
            break
        else:
            time.sleep(1)
    if not os.path.exists(qemu_socket):
        print('Socket did not become available')
        exit(1)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(qemu_socket)
    return s, pexpect.fdpexpect.fdspawn(s.fileno(), logfile=sys.stdout, encoding='utf-8')

def check_last_command_exit_code(vm):
    vm.sendline('echo Exit code: $?')
    vm.readline() # eat the echoed command
    vm.expect('Exit code: ')
    status = int(vm.readline())
    if status != 0:
        print(f'Last command exit code was {status}')
        exit(1)

# Command line argument parsing and validation
modes = {
    'install': 'Create a VM and debootstrap it with the given command',
    'test': 'Run tests to validate the installation',
    'run': 'Run the VM for manual inspection',
    'cleanup': 'Delete anything created by this script',
}
arg_parser = argparse.ArgumentParser(
    description='Manage the test virtual machine',
    formatter_class=argparse.RawTextHelpFormatter,
)
arg_parser.add_argument(
    choices=modes.keys(),
    dest='mode',
    help='\n'.join(f'{k}: {v}' for k, v in modes.items()),
)
arg_parser.add_argument(
    '-a', '--append-arguments',
    metavar='<arguments>',
    nargs='?',
    dest='append_arguments',
    help='The debootscript arguments to use during installation'
)
arg_parser.add_argument(
    '-e', '--efi',
    dest='efi',
    action='store_true',
    help='The VM should be EFI instead of BIOS',
)
arguments = arg_parser.parse_args()

if arguments.mode == 'install' and not arguments.append_arguments:
    print('--debootscript-arguments is required for installation')
    exit(1)

# Compute qemu parameters for different platforms
match os.uname().sysname:
    case 'Linux':
        qemu_accel = 'kvm'

        # CPU cores
        for line in subprocess.run('lscpu', capture_output=True, encoding='UTF-8').stdout.split('\n'):
            if line.startswith('Core(s) per socket: '):
                physical_cores = line.split()[-1]
                break
        logical_cores = os.cpu_count()

        # Ramdisk
        if not os.path.exists('ramdisk'):
            os.mkdir('ramdisk')
        result = subprocess.run(f'mount -t tmpfs -o size={ramdisk_size_mb}M tmpfs ramdisk')
        if result.returncode != 0:
            print('Failed to mount ramdisk')
            exit(1)
        ramdisk='ramdisk/disk'

        # EFI firmware
        if arguments.efi:
            efi_firmware = '/usr/share/OVMF/OVMF_CODE.fd'
            shutil.copyfile(src='/usr/share/OVMF/OVMF_VARS.fd', dst='efi_vars.fd')

    case 'Darwin':
        qemu_accel = 'hvf'
        os.environ['OBJC_DISABLE_INITIALIZE_FORK_SAFETY'] = 'YES'

        # CPU cores
        physical_cores = int(
            subprocess.run('sysctl -n hw.physicalcpu'.split(), capture_output=True).stdout
        )
        logical_cores = int(
            subprocess.run('sysctl -n hw.logicalcpu'.split(), capture_output=True).stdout
        )

        # Ramdisk
        if not os.path.islink('ramdisk'):
            if os.path.exists('ramdisk'):
                print('Non-symlink "ramdisk" already exists')
                exit(1)
            result = subprocess.run(
                f'hdiutil attach -nomount ram://{ramdisk_size_mb*2048}'.split(),
                capture_output=True
            )
            if result.returncode != 0:
                print('Failed to create ramdisk')
                exit(1)
            os.symlink(src=result.stdout.split()[-1], dst='ramdisk')
        ramdisk='ramdisk'

        # EFI firmware
        if arguments.efi:
            efi_firmware = '/usr/local/share/qemu/edk2-x86_64-code.fd'
            with open('efi_vars.fd', 'wb') as f:
                f.write(b'\x00' * 1024 * 1024 * 2)

    case _:
        print('Unknown OS')
        exit(1)

cpu_cores = physical_cores-2
cpu_threads = int(logical_cores/physical_cores)
qemu_command = f"""
    qemu-system-x86_64
        -daemonize
        -pidfile {qemu_pidfile}
        -accel {qemu_accel}
        -machine q35
        -cpu host
        -smp cores={cpu_cores},threads={cpu_threads}
        -m 1G
        -serial unix:{qemu_socket},server,nowait
        -drive file={ramdisk},format=raw
        -net nic -net user,hostfwd=tcp::65522-:22
        -device virtio-gpu-pci
"""

if arguments.efi:
    qemu_command += f"""
        -drive if=pflash,format=raw,readonly=on,file={efi_firmware}
        -drive if=pflash,format=raw,file=efi_vars.fd
    """

match arguments.mode:
    case 'install':
        kill_vm()
        if not os.path.exists('alpine.iso'):
            urllib.request.urlretrieve(
                url=f'https://dl-cdn.alpinelinux.org/alpine/v{re.sub(r'\.\d+$', '', alpine_version)}/' +
                    f'releases/x86_64/alpine-virt-{alpine_version}-x86_64.iso',
                filename='alpine.iso'
            )
        with open(ramdisk, 'wb') as f:
            f.write(b'\x00' * int(ramdisk_size_mb * 1024 * 1024)) # 1GB
        s, vm = start_qemu_vm(qemu_command + '-display none -cdrom alpine.iso -boot d')
        vm.expect('login: ')
        vm.sendline('root')
        vm.expect('localhost:~# ')
        with open('../debootscript.sh') as f:
            debootscript = f.read()
        vm.send(f"""\
            sh -c '
                set -e
                setup-interfaces -a -r
                export HTTP_PROXY={http_proxy}
                echo "http://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories
                apk update
                apk add bash curl e2fsprogs debootstrap cryptsetup dosfstools sfdisk blkid lvm2 util-linux tar zstd
                modprobe -a ext4 vfat
                '
        """)
        vm.expect('localhost:~# ')

        # Upload debootscript
        vm.logfile = None
        vm.send(f"""\
            cat > debootscript.sh <<'DEBOOTSCRIPT'
            {debootscript}
        """)
        vm.send('\n')
        vm.sendline('DEBOOTSCRIPT')
        vm.logfile = sys.stdout

        vm.expect('localhost:~# ')
        vm.sendline(
            f"""\
            http_proxy={http_proxy} bash debootscript.sh \
                -b /dev/sda \
                -u '{test_username}' \
                -p '{test_password}' \
                {arguments.append_arguments}
            """
        )
        vm.expect('localhost:~# ', timeout=300)
        check_last_command_exit_code(vm)
        vm.sendline('poweroff')

    case 'test':
        wait_for_qemu_shutdown()
        s, vm = start_qemu_vm(qemu_command)
        vm.timeout = 180
        prompt = vm.expect(['(press TAB for no echo)', 'login: '])
        if prompt == 0:
            vm.sendline(test_encryption_password)
            vm.expect('login: ')
        vm.sendline(test_username)
        vm.expect('Password: ')
        vm.sendline(test_password)
        vm.expect(re.escape('localhost:~$ '))
        vm.sendline('sudo poweroff')
        vm.expect(r'password for \w+: ')
        vm.sendline(test_password)

    case 'run':
        if not os.path.exists(qemu_pidfile):
            subprocess.run(qemu_command.split())
        else:
            print('VM already running')

    case 'cleanup':
        # Kill the VM
        kill_vm()

        # Remove any files created
        for f in ['efi_vars.fd', 'alpine.iso', qemu_pidfile, qemu_socket]:
            if os.path.exists(f):
                os.remove(f)

        match os.uname().sysname:
            case 'Linux':
                result = subprocess.run('umount ramdisk')
            case 'Darwin':
                ramdisk = os.readlink('ramdisk')
                result = subprocess.run(f'hdiutil detach {ramdisk}')
            case _:
                exit(1)
        if result.returncode != 0:
            print('Failed to unmount ramdisk')
            exit(1)
