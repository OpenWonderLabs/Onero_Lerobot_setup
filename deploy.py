#!/usr/bin/env python3
"""Shared PC/Orin deployment. Run the matching deploy-*.sh with sudo."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time


ASSETS = Path(__file__).resolve().parent
ETC = Path('/etc')
SBIN = Path('/usr/local/sbin')
BACKUPS = Path('/var/backups/robot-x1-zenoh')
ROS_SETUP = Path('/opt/ros/jazzy/setup.bash')
PACKAGES = ('ros-jazzy-rmw-zenoh-cpp', 'ros-jazzy-zenoh-cpp-vendor')
RUNTIME_PACKAGES = ('ros-jazzy-fastcdr', 'ros-jazzy-fastrtps',
                    'ros-jazzy-rosidl-typesupport-fastrtps-cpp', 'ros-jazzy-rosidl-typesupport-fastrtps-c')
SESSION = '/opt/ros/jazzy/share/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5'
BEGIN = '# >>> Robot X1 Zenoh environment >>>'
END = '# <<< Robot X1 Zenoh environment <<<'


class DeploymentError(Exception):
    pass


def run(argv, *, capture=False, check=True, timeout=600, env=None):
    result = subprocess.run(argv, check=check, text=True, timeout=timeout,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None,
                            env=dict(os.environ, NEEDRESTART_MODE='l', **(env or {})))
    return result.stdout or ''


class Backup:
    def __init__(self):
        BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory = Path(tempfile.mkdtemp(prefix=time.strftime('deploy-%Y%m%d-%H%M%S-'), dir=BACKUPS))
        self.saved = {}
        print(f'配置备份目录：{self.directory}', flush=True)

    def save(self, path):
        if path in self.saved:
            return
        destination = self.directory / str(path).lstrip('/')
        self.saved[path] = destination if path.exists() or path.is_symlink() else None
        if self.saved[path] is not None:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if path.is_dir() and not path.is_symlink():
                shutil.copytree(path, destination, symlinks=True)
            else:
                shutil.copy2(path, destination, follow_symlinks=False)
        (self.directory / 'files.json').write_text(json.dumps(
            {str(p): str(saved) if saved else None for p, saved in self.saved.items()}, indent=2) + '\n')


def validate_target(value):
    try:
        address = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as error:
        raise DeploymentError('请指定 H1 end1 可达的单播 IPv4 地址。') from error
    if (address.is_unspecified or address.is_loopback or address.is_multicast
            or address.is_reserved or address in ipaddress.IPv4Network('0.0.0.0/8')):
        raise DeploymentError('H1 目标不能是回环、组播或保留地址。')
    return str(address)


def check_package_plan(plan, installed, role):
    """Preview updates, rejecting removals outside the Orin time-service swap."""
    refused = []
    changed = False
    for line in plan.splitlines():
        action = line.split(maxsplit=1)[0] if line.strip() else ''
        if action not in ('Inst', 'Conf', 'Remv', 'Purg'):
            continue
        match = re.fullmatch(r'(Inst|Conf|Remv|Purg) (\S+)(?: \[([^\]]+)\])?(?: \((\S+).*\))?(?: \[.*\])?', line)
        if not match:
            raise DeploymentError(f'无法识别 APT 预检动作，停止安装：{line}')
        action, name, old, new = match.groups()
        changed = True
        previous = old or installed.get(name) or installed.get(name.split(':')[0])
        if action in ('Remv', 'Purg'):
            if role != 'orin' or action != 'Remv' or name != 'systemd-timesyncd':
                refused.append(f'{name}: {previous or "?"} -> 删除')
        elif not new:
            raise DeploymentError(f'APT 预检缺少目标版本，停止安装：{line}')
    if refused:
        raise DeploymentError('安装需要删除其它已有软件包，已停止；请先处理依赖冲突：\n  '
                              + '\n  '.join(dict.fromkeys(refused)))
    return changed


def install_packages(role, backup):
    audit = run(['dpkg', '--audit'], capture=True)
    if audit.strip():
        raise DeploymentError('dpkg 已有未完成或异常状态，请先处理：\n' + audit)
    query = ['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Status}\n']
    before = run(query, capture=True)
    (backup.directory / 'packages-before.tsv').write_text(before)
    installed = {}
    for line in before.splitlines():
        name, version, status = line.split('\t')
        if status == 'installed':
            installed[name] = version
    required = [*PACKAGES, *RUNTIME_PACKAGES, 'openssh-client', 'ros-jazzy-std-msgs',
                'ros-jazzy-example-interfaces', 'ros-jazzy-demo-nodes-cpp']
    if role == 'orin':
        required += ['chrony', 'openssh-server']
    options = ['--no-install-recommends']
    try:
        run(['apt-get', '-o', 'APT::Update::Error-Mode=any', 'update'], timeout=None)
    except subprocess.CalledProcessError:
        print('警告：部分软件源更新失败，已忽略并继续。'
              '如果后续安装软件包失败，请检查 /etc/apt/sources.list.d/ 中失效的源。')
    # Explicitly request the serialization/runtime packages in the same update
    # as the message libraries; their metadata may omit minimum ABI versions.
    # Preserve existing pin/hold policies and never run a whole-system upgrade.
    try:
        plan = run(['apt-get', '-s', *options, 'install', *required],
                   capture=True, timeout=None, env={'LC_ALL': 'C'})
    except subprocess.CalledProcessError as error:
        detail = (error.stdout or '') + (error.stderr or '')
        (backup.directory / 'apt-plan.txt').write_text(detail)
        raise DeploymentError('APT 无法在当前依赖和 pin/hold 策略下生成安装计划：\n'
                              + (detail or str(error))) from error
    (backup.directory / 'apt-plan.txt').write_text(plan)
    print(plan, end='')
    if not check_package_plan(plan, installed, role):
        print('所需软件包已满足当前 APT 策略，无安装或更新动作。')
        (backup.directory / 'packages-after.tsv').write_text(before)
        return
    # A fresh APT transaction can differ from the simulation. Check its actual
    # VERSION 2 actions before dpkg runs; do not install persistent APT policy.
    with tempfile.TemporaryDirectory(prefix='robot-x1-apt-', dir='/tmp') as temp:
        guard = Path(temp) / 'guard'
        shutil.copyfile(ASSETS / 'apt-package-guard.py', guard)
        guard.chmod(0o700)
        hook = str(guard) + ' --allow-upgrades' + (' --allow-timesyncd-removal' if role == 'orin' else '')
        command = ['apt-get', '-o', f'DPkg::Pre-Install-Pkgs::={hook}',
                   '-o', f'DPkg::Tools::Options::{guard}::Version=2',
                   '-o', f'DPkg::Tools::Options::{guard}::InfoFD=0',
                   *options, *(['--no-remove'] if role == 'pc' else []),
                   'install', '-y', *required]
        try:
            run(command, timeout=None, env={'LC_ALL': 'C'})
        finally:
            # This is a diagnostic snapshot, not a rollback of package files.
            (backup.directory / 'packages-after.tsv').write_text(run(query, capture=True, check=False))


def validate_ros_libraries(*, require_all):
    """Resolve real shared-library symbols before changing ROS configuration."""
    code = '''import ctypes, os, pathlib, sys
directory = pathlib.Path(sys.argv[1])
required = sys.argv[2] == 'required'
names = ['librmw_zenoh_cpp.so']
for package in ('std_msgs', 'example_interfaces'):
    for language in ('c', 'cpp'):
        names.append(f'lib{package}__rosidl_typesupport_fastrtps_{language}.so')
for name in names:
    library = directory / name
    if not required and not library.exists():
        continue
    try:
        ctypes.CDLL(str(library), mode=os.RTLD_NOW | os.RTLD_LOCAL)
    except OSError as error:
        print(f'{library}: {error}')
        sys.exit(1)
print('ROS shared-library symbol checks passed.')
'''
    command = ['/bin/bash', '--noprofile', '--norc', '-ec',
               'source "$1"; exec /usr/bin/python3 -c "$2" "$3" "$4"',
               'robot-abi-check', str(ROS_SETUP), code, str(ROS_SETUP.parent / 'lib'),
               'required' if require_all else 'existing']
    try:
        print(run(command, capture=True, timeout=30), end='')
    except subprocess.CalledProcessError as error:
        raise DeploymentError('ROS 动态库加载失败，已停止配置。请统一维护 ROS 依赖后重试：\n'
                              + ((error.stdout or '') + (error.stderr or '') or str(error))) from error


def prepare_bashrc(user):
    path = Path(user.pw_dir) / '.bashrc'
    if path.is_symlink():
        raise DeploymentError(f'{path} 是符号链接，请先人工合并 ROS 环境。')
    content = path.read_text() if path.exists() else ''
    if content.count(BEGIN) != content.count(END) or content.count(BEGIN) > 1:
        raise DeploymentError(f'{path} 中的 Robot X1 配置标记不完整。')
    if BEGIN in content:
        if content.index(END) < content.index(BEGIN):
            raise DeploymentError(f'{path} 中的 Robot X1 配置标记顺序错误。')
        content = re.sub(re.escape(BEGIN) + r'.*?' + re.escape(END), '', content, flags=re.S)
    block = (f'{BEGIN}\nsource /opt/ros/jazzy/setup.bash\n'
             f'source {ETC}/zenoh/ros.env\n'
             'export RMW_IMPLEMENTATION ROS_DOMAIN_ID ZENOH_SESSION_CONFIG_URI\n'
             'unset CYCLONEDDS_URI ZENOH_CONFIG_OVERRIDE\n' + END)
    return content.rstrip() + '\n\n' + block + '\n'


def write_file(path, content, backup, mode=0o644, owner=None):
    if path.is_symlink():
        raise DeploymentError(f'不覆盖符号链接：{path}')
    backup.save(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            if owner is not None:
                os.fchown(stream.fileno(), *owner)
            stream.write(content.encode() if isinstance(content, str) else content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def configure_files(role, target, user, backup):
    bashrc = prepare_bashrc(user)
    override = ('listen/endpoints=["tcp/127.0.0.1:7447"];'
                f'connect/endpoints=["tcp/{target}:7447"];'
                'routing/router/peers_failover_brokering=true')
    write_file(ETC / 'zenoh/router.env', "# Router only.\nZENOH_CONFIG_OVERRIDE='" + override + "'\n", backup)
    write_file(ETC / 'zenoh/ros.env',
               'RMW_IMPLEMENTATION=rmw_zenoh_cpp\nROS_DOMAIN_ID=0\n'
               f'ZENOH_SESSION_CONFIG_URI={SESSION}\n', backup)
    write_file(ETC / 'systemd/system/zenoh-router.service', (ASSETS / 'zenoh-router.service').read_bytes(), backup)
    bashrc_path = Path(user.pw_dir) / '.bashrc'
    bashrc_mode = stat.S_IMODE(bashrc_path.stat().st_mode) if bashrc_path.exists() else 0o644
    write_file(bashrc_path, bashrc, backup, mode=bashrc_mode, owner=(user.pw_uid, user.pw_gid))
    if role == 'pc':
        write_file(SBIN / 'robot-zenoh-connect', (ASSETS / 'robot-zenoh-connect').read_bytes(), backup, mode=0o755)
    else:
        write_file(ETC / 'chrony/chrony.conf', (ASSETS / 'orin-chrony.conf').read_bytes(), backup)
    return override


def configure_network(interface):
    uuid = run(['nmcli', '-g', 'GENERAL.CON-UUID', 'device', 'show', interface], capture=True).strip()
    if not uuid or uuid == '--':
        uuid = run(['nmcli', '-g', 'connection.uuid', 'connection', 'show', 'robot-h1-orin'],
                   capture=True, check=False).strip()
        if uuid:
            kind = run(['nmcli', '-g', 'connection.type', 'connection', 'show', 'uuid', uuid], capture=True).strip()
            bound = run(['nmcli', '-g', 'connection.interface-name', 'connection', 'show', 'uuid', uuid], capture=True).strip()
            devices = run(['nmcli', '-g', 'GENERAL.DEVICES', 'connection', 'show', 'uuid', uuid], capture=True).strip()
            if kind != '802-3-ethernet' or bound not in ('', interface) or devices not in ('', '--', interface):
                raise DeploymentError('已有 robot-h1-orin 连接不属于指定以太网口；请先核对其配置。')
        else:
            run(['nmcli', 'connection', 'add', 'type', 'ethernet', 'ifname', interface, 'con-name', 'robot-h1-orin'])
            uuid = run(['nmcli', '-g', 'connection.uuid', 'connection', 'show', 'robot-h1-orin'], capture=True).strip()
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', uuid):
        raise DeploymentError(f'无法确定 {interface} 的 NetworkManager 连接 UUID。')
    run(['nmcli', 'connection', 'modify', 'uuid', uuid,
         'connection.interface-name', interface, 'connection.autoconnect', 'yes',
         'ipv4.method', 'auto', 'ipv4.addresses', '', 'ipv4.gateway', '', 'ipv4.dns', '',
         'ipv4.never-default', 'yes', 'ipv4.ignore-auto-dns', 'yes', 'ipv6.method', 'disabled'])
    run(['nmcli', '--wait', '30', 'connection', 'up', 'uuid', uuid, 'ifname', interface], timeout=40)


def wait_for_router(override):
    for _ in range(20):
        pid = run(['systemctl', 'show', 'zenoh-router.service', '-p', 'MainPID', '--value'], capture=True).strip()
        if pid.isdecimal() and int(pid) > 0:
            try:
                environment = Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
                if f'ZENOH_CONFIG_OVERRIDE={override}'.encode() in environment:
                    listeners = run(['ss', '-H', '-ltnp', 'sport = :7447'], capture=True)
                    owned = any(len(parts := line.split()) >= 5 and parts[3] == '127.0.0.1:7447'
                                and re.search(r'\bpid=' + pid + r'\b', line)
                                for line in listeners.splitlines())
                    active = run(['systemctl', 'is-active', 'zenoh-router.service'], capture=True, check=False).strip()
                    if owned and active == 'active':
                        return
            except OSError:
                pass
        time.sleep(0.25)
    raise DeploymentError('Router 未正常监听或未加载指定环境，请查看 journalctl -u zenoh-router。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('role', choices=('pc', 'orin'))
    parser.add_argument('--h1-ip', help='PC: reachable H1 end1 IPv4; no default')
    parser.add_argument('--interface', help='Orin: Ethernet interface connected to H1')
    parser.add_argument('--user', default=os.environ.get('SUDO_USER'), help='ROS login user (defaults to sudo caller)')
    args = parser.parse_args()
    backup = None
    try:
        if os.geteuid() != 0:
            raise DeploymentError('请通过 sudo 运行部署脚本。')
        if not args.user or args.user == 'root':
            raise DeploymentError('请用 --user 指定运行 ROS 的普通登录用户。')
        user = pwd.getpwnam(args.user)
        if not Path(user.pw_dir).is_dir() or not ROS_SETUP.is_file():
            raise DeploymentError('登录用户目录或 /opt/ros/jazzy/setup.bash 不存在。')
        prepare_bashrc(user)
        dropins = run(['systemctl', 'show', 'zenoh-router.service', '-p', 'DropInPaths', '--value'],
                      capture=True, check=False).strip()
        if dropins:
            raise DeploymentError(f'已有 Router drop-in 可能覆盖部署配置，请先合并：{dropins}')
        if args.role == 'pc':
            if args.interface:
                raise DeploymentError('PC 脚本不修改网卡，请勿传入 --interface。')
            target = validate_target(args.h1_ip or '')
        else:
            if args.h1_ip or not args.interface:
                raise DeploymentError('Orin 请指定 --interface；H1 内网地址固定为 192.168.251.1。')
            if run(['nmcli', '-g', 'GENERAL.TYPE', 'device', 'show', args.interface], capture=True).strip() != 'ethernet':
                raise DeploymentError('--interface 必须是连接 H1 的以太网接口。')
            target = '192.168.251.1'
            print('Orin 有线连接将重新激活；请在本机终端或临时 Wi-Fi SSH 中执行。', flush=True)
        required_assets = ('zenoh-router.service', 'apt-package-guard.py',
                           'robot-zenoh-connect' if args.role == 'pc' else 'orin-chrony.conf')
        for name in required_assets:
            if not (ASSETS / name).is_file():
                raise DeploymentError(f'缺少 {name}，请完整解压对应角色的部署包。')
        backup = Backup()
        for path in (ETC / 'zenoh', ETC / 'systemd/system/zenoh-router.service', Path(user.pw_dir) / '.bashrc'):
            backup.save(path)
        if args.role == 'orin':
            backup.save(ETC / 'chrony/chrony.conf')
            backup.save(ETC / 'NetworkManager/system-connections')
        print('安装或更新 Zenoh、消息包及 Fast-CDR/FastRTPS 类型支持依赖。', flush=True)
        install_packages(args.role, backup)
        validate_ros_libraries(require_all=True)
        override = configure_files(args.role, target, user, backup)
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', 'zenoh-router.service'])
        run(['systemctl', 'restart', 'zenoh-router.service'], timeout=30)
        wait_for_router(override)
        if args.role == 'orin':
            run(['chronyd', '-p', '-f', str(ETC / 'chrony/chrony.conf')], capture=True)
            run(['systemctl', 'disable', '--now', 'systemd-timesyncd.service'], capture=True, check=False)
            run(['systemctl', 'mask', 'systemd-timesyncd.service'])
            run(['systemctl', 'enable', '--now', 'ssh.service', 'chrony.service'])
            run(['systemctl', 'restart', 'chrony.service'], timeout=30)
            configure_network(args.interface)
        # Existing application processes are intentionally not restarted here.
        run(['runuser', '-u', user.pw_name, '--', 'bash', '-c',
             'source /opt/ros/jazzy/setup.bash; export RMW_IMPLEMENTATION=rmw_zenoh_cpp ROS_DOMAIN_ID=0; ros2 daemon stop'],
            check=False, timeout=20)
        run(['dpkg-query', '-W', '-f=${Package} ${Version}\n', *PACKAGES, *RUNTIME_PACKAGES])
        print(f'{args.role.upper()} 配置完成，Router 上联 {target}:7447。重新打开 {user.pw_name} 的终端加载 ROS 环境。')
        try:
            with socket.create_connection((target, 7447), timeout=3):
                print('H1 TCP 7447 可达；请按文档验证双向 topic。')
        except OSError:
            print('H1 TCP 7447 暂不可达，Router 会重连；当前尚未验证跨机 ROS 通信。')
        if args.role == 'orin':
            run(['chronyc', '-n', 'sources', '-v'], check=False)
            print('校时验收：chronyc sources 中应选中 192.168.251.1；^? 表示尚未同步。')
        print(f'旧配置备份：{backup.directory}。已有 ROS 业务请按自身服务方式重新启动以加载新环境/库。')
    except (DeploymentError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f'部署未完成：{error}', file=sys.stderr)
        if backup:
            print(f'原文件备份：{backup.directory}；配置/包操作可能已部分完成，请处理错误后重新执行。', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
