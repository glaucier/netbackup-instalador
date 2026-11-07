"""Testes do instalar.sh (Fase 3a).

Rodam como usuário comum: raiz falsa (caminhos por variável de ambiente) e
comandos falsos no PATH. Nada toca disco, /etc, /root ou /opt reais.
Sem dependências externas (somente biblioteca padrão).
"""
import hashlib
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
SCRIPT_SRC = REPO_DIR / "instalar.sh"
GOOD_FP = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
UUID = "1111-2222-uuid"

# --------------------------------------------------------------------------
# Comandos falsos. Todos registram a chamada em $FAKE_CALLS; o comportamento
# vem de arquivos em $FAKE_STATE.
# --------------------------------------------------------------------------
FAKES = {
    "id": 'echo "${FAKE_UID:-0}"',
    "hostname": "echo vm-teste",
    "dpkg": 'echo "${FAKE_ARCH:-amd64}"',
    "ufw": '[ -e "$FAKE_STATE/ufw_inactive" ] && echo "Status: inactive" || echo "Status: active"',
    "timedatectl": '[ -e "$FAKE_STATE/ntp_no" ] && echo no || echo yes',
    "systemctl": "exit 0",
    "lsblk": r'''
case "$1" in
  -dnpo) cat "$FAKE_STATE/disks" 2>/dev/null ;;
  -nr) d="$4"; b="${d##*/}"
       if [ -e "$FAKE_STATE/lsblk_$b" ]; then cat "$FAKE_STATE/lsblk_$b"; else echo "$b disk"; fi ;;
  -dnbo) d="$3"; b="${d##*/}"
       if [ -e "$FAKE_STATE/size_$b" ]; then cat "$FAKE_STATE/size_$b"; else echo 107374182400; fi ;;
esac
exit 0''',
    "wipefs": 'b="${2##*/}"; [ -e "$FAKE_STATE/wipefs_$b" ] && cat "$FAKE_STATE/wipefs_$b"; exit 0',
    "pvs": '[ -e "$FAKE_STATE/pvs" ] && cat "$FAKE_STATE/pvs"; exit 0',
    "lvs": '[ -e "$FAKE_STATE/lv_exists" ]',
    "pvcreate": "exit 0",
    "vgcreate": "exit 0",
    "lvcreate": 'touch "$FAKE_STATE/lv_exists"',
    "mkfs.ext4": 'touch "$FAKE_STATE/fs_made"',
    "blkid": r'''
[ -e "$FAKE_STATE/fs_made" ] || exit 2
case "$2" in TYPE) echo ext4 ;; UUID) echo 1111-2222-uuid ;; esac''',
    "mount": r'''
if [ "$1" = "-a" ] && grep -q "UUID=1111-2222-uuid" "$FSTAB"; then
  echo /dev/mapper/dados--vg-opt--lv > "$FAKE_STATE/findmnt_opt"
fi
exit 0''',
    "findmnt": '[ -e "$FAKE_STATE/findmnt_opt" ] && cat "$FAKE_STATE/findmnt_opt"; exit 0',
    "ssh-keyscan": r'''
for h; do :; done
if [ -e "$FAKE_STATE/keyscan_bad" ]; then echo "$h ssh-ed25519 BADKEY"; else echo "$h ssh-ed25519 GOODKEY"; fi''',
    "ssh-keygen": r'''
case "$1" in
  -lf)
    if grep -q GOODKEY "$2"; then echo "256 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU github.com (ED25519)"
    else echo "256 SHA256:ZZZZ-fingerprint-errada github.com (ED25519)"; fi ;;
  -y) echo "ssh-ed25519 AAAAFAKEPUB recuperada" ;;
  *) while [ $# -gt 0 ]; do
       case "$1" in -f) f="$2"; shift ;; -C) c="$2"; shift ;; esac; shift
     done
     echo "FAKE-PRIVATE-KEY" > "$f"; chmod 600 "$f"
     echo "ssh-ed25519 AAAAFAKEPUB $c" > "$f.pub" ;;
esac''',
    "ssh": r'''
case "$*" in
  *git-receive-pack*)
    case "$(cat "$FAKE_STATE/write_mode" 2>/dev/null)" in
      write) echo "00abcdef refs/heads/main report-status delete-refs"; exit 0 ;;
      weird) echo "Permission denied (publickey)."; exit 255 ;;
      *) echo "ERROR: The key you are authenticating with has been marked as read only."; exit 1 ;;
    esac ;;
esac
exit 0''',
    "git": r'''
if [ "$1" = "-C" ]; then d="$2"; shift 2
  case "$1" in
    remote) cat "$d/.git/fake_remote" 2>/dev/null; exit 0 ;;
    log) echo "abc1234 2026-01-01 commit de teste"; exit 0 ;;
  esac
  exit 0
fi
case "$1" in
  ls-remote)
    n=$(cat "$FAKE_STATE/ls_fail_count" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n-1)) > "$FAKE_STATE/ls_fail_count"; echo "Permission denied" >&2; exit 128; fi
    echo "deadbeef	HEAD"; exit 0 ;;
  clone)
    shift; [ "$1" = "--branch" ] && shift 2
    repo="$1"; dest="$2"
    mkdir -p "$dest/.git" "$dest/deploy"
    echo "$repo" > "$dest/.git/fake_remote"
    printf '#!/bin/sh\necho deploy-check-ran >> "$FAKE_CALLS"\nexit 3\n' > "$dest/deploy/deploy.sh"
    chmod 644 "$dest/deploy/deploy.sh"
    exit 0 ;;
esac
exit 0''',
}

_listener = {}


def setUpModule():
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    _listener["srv"] = srv
    _listener["port"] = srv.getsockname()[1]

    def loop():
        while True:
            try:
                c, _ = srv.accept()
                c.close()
            except OSError:
                return
    threading.Thread(target=loop, daemon=True).start()


def tearDownModule():
    _listener["srv"].close()


def fingerprint(root):
    """Impressão digital de uma árvore: caminho, modo, tamanho, mtime, hash."""
    out = []
    for p in sorted(Path(root).rglob("*")):
        st = p.lstat()
        h = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ""
        out.append((str(p), st.st_mode, st.st_size, st.st_mtime_ns, h))
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.sb = Path(tempfile.mkdtemp(prefix="nbtest-")).resolve()
        self.sb.chmod(0o755)
        self.root = self.sb / "root"          # raiz falsa
        self.inst = self.sb / "inst"          # pasta do instalador
        self.bin = self.sb / "bin"
        self.state = self.sb / "state"
        self.calls = self.sb / "calls.log"
        for d in (self.root / "etc", self.root / "proc", self.root / "opt",
                  self.root / "rootdir", self.inst, self.bin, self.state,
                  self.sb / "tmp", self.sb / "home"):
            d.mkdir(parents=True)
        for d in (self.root, self.root / "etc", self.root / "proc", self.root / "opt",
                  self.root / "rootdir", self.inst, self.bin, self.state,
                  self.sb / "tmp", self.sb / "home"):
            d.chmod(0o755)
        self.calls.write_text("")
        self.fstab = self.root / "etc" / "fstab"
        self.fstab_orig = "# fstab de teste\nUUID=aaaa-bbbb / ext4 defaults 0 1\n"
        self.fstab.write_text(self.fstab_orig)
        (self.root / "etc" / "os-release").write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
        (self.root / "proc" / "meminfo").write_text("MemTotal:       8000000 kB\n")
        self.script = self.inst / "instalar.sh"
        shutil.copy(SCRIPT_SRC, self.script)
        self.script.chmod(0o755)
        for name, body in FAKES.items():
            f = self.bin / name
            f.write_text('#!/bin/sh\necho "%s $*" >> "$FAKE_CALLS"\n%s\n' % (name, body))
            f.chmod(0o755)
        self.ssh_dir = self.root / "rootdir" / ".ssh"
        self.log_dir = self.root / "rootdir"
        self.opt = self.root / "opt"
        self.nb = self.opt / "netbackup"
        self.extra_env = {}
        self.addCleanup(shutil.rmtree, self.sb, True)

    # ---- helpers ----
    def env(self):
        e = {
            "PATH": "%s:%s" % (self.bin, os.environ["PATH"]),
            "HOME": str(self.sb / "home"),
            "TMPDIR": str(self.sb / "tmp"),
            "OWNER_UID": str(os.getuid()),
            "TRUST_TOP": str(self.sb),
            "OPT_DIR": str(self.opt),
            "FSTAB": str(self.fstab),
            "OS_RELEASE": str(self.root / "etc" / "os-release"),
            "MEMINFO": str(self.root / "proc" / "meminfo"),
            "SSH_DIR": str(self.ssh_dir),
            "LOG_DIR": str(self.log_dir),
            "DISK_MIN_MB": "1",
            "GH_HOST": "127.0.0.1",
            "GH_PORT": str(_listener["port"]),
            "FAKE_CALLS": str(self.calls),
            "FAKE_STATE": str(self.state),
            "FSTAB_": "",
        }
        e.update(self.extra_env)
        return e

    def run_inst(self, *args, stdin="", script=None):
        p = subprocess.run(
            ["bash", str(script or self.script), *args],
            input=stdin, capture_output=True, text=True, env=self.env(),
            cwd=str(self.sb), timeout=120)
        return p, p.stdout + p.stderr

    def calls_text(self):
        return self.calls.read_text()

    def ncalls(self, prefix):
        return sum(1 for l in self.calls_text().splitlines() if l.startswith(prefix))

    def set_state(self, name, content="1"):
        (self.state / name).write_text(content)

    def add_disk(self, dev="/dev/sdb", size=None):
        with open(self.state / "disks", "a") as f:
            f.write("%s disk\n" % dev)
        if size:
            self.set_state("size_" + dev.split("/")[-1], str(size))

    def logs(self):
        return sorted(self.log_dir.glob("netbackup-instalacao-*.log"))

    def prepare_nb(self, remote="git@github-netbackup:glaucier/netbackup-manager.git"):
        (self.nb / ".git").mkdir(parents=True)
        (self.nb / "deploy").mkdir()
        (self.nb / ".git" / "fake_remote").write_text(remote + "\n")
        d = self.nb / "deploy" / "deploy.sh"
        d.write_text('#!/bin/sh\necho deploy-check-ran >> "$FAKE_CALLS"\nexit 3\n')
        for p in (self.nb, self.nb / ".git", self.nb / "deploy"):
            p.chmod(0o755)
        d.chmod(0o644)


# --------------------------------------------------------------------------
class TestSegurancaDoInstalador(Base):
    def test_recusa_sem_root(self):
        self.extra_env["FAKE_UID"] = "1000"
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("root", out)
        self.assertEqual(self.logs(), [])
        self.assertEqual(self.ncalls("lsblk"), 0)

    def test_versao_impressa_sempre(self):
        p, out = self.run_inst("--help")
        self.assertEqual(p.returncode, 0)
        self.assertIn("versão 0.1.0-dev", out)
        self.extra_env["FAKE_UID"] = "1000"
        p, out = self.run_inst()
        self.assertIn("versão 0.1.0-dev", out)

    def test_opcao_desconhecida(self):
        p, out = self.run_inst("--xyz")
        self.assertEqual(p.returncode, 2)

    def test_recusa_script_com_escrita_de_outros(self):
        self.script.chmod(0o757)
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não confiável", out)
        self.assertEqual(self.ncalls("ufw"), 0)

    def test_recusa_script_com_escrita_de_grupo(self):
        self.script.chmod(0o775)
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não confiável", out)

    def test_recusa_pasta_acima_com_escrita_de_outros(self):
        self.inst.chmod(0o777)
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não confiável", out)
        self.assertEqual(self.ncalls("ufw"), 0)

    def test_recusa_dono_diferente(self):
        self.extra_env["OWNER_UID"] = str(os.getuid() + 12345)
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não pertence ao root", out)

    def test_recusa_rodar_de_dentro_de_opt_netbackup(self):
        d = self.nb / "instalador"
        d.mkdir(parents=True)
        for p_ in (self.nb, d):
            p_.chmod(0o755)
        s = d / "instalar.sh"
        shutil.copy(SCRIPT_SRC, s)
        s.chmod(0o755)
        p, out = self.run_inst(script=s)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("de dentro de", out)

    def test_recusa_script_via_stdin(self):
        p = subprocess.run(["bash"], input=SCRIPT_SRC.read_text(), capture_output=True,
                           text=True, env=self.env(), cwd=str(self.sb), timeout=60)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("arquivo", p.stdout + p.stderr)


class TestSomenteLeitura(Base):
    def snapshot_ok(self, args):
        before = fingerprint(self.root)
        nlogs = len(self.logs())
        cmds = ("pvcreate", "vgcreate", "lvcreate", "mkfs.ext4", "mount", "ssh-keygen -q",
                "ssh-keyscan", "git clone")
        antes = {c: self.ncalls(c) for c in cmds}
        p, out = self.run_inst(*args)
        after = fingerprint(self.root)
        self.assertEqual(before, after, "a raiz falsa foi alterada por " + " ".join(args))
        self.assertEqual(len(self.logs()), nlogs)
        for cmd in cmds:
            self.assertEqual(self.ncalls(cmd), antes[cmd], cmd)
        return p, out

    def test_check_nao_altera_maquina_limpa(self):
        self.add_disk()
        p, out = self.snapshot_ok(["--check"])
        self.assertEqual(p.returncode, 1)  # há itens "falta"
        self.assertIn("[falta]", out)
        self.assertIn("[ok]", out)

    def test_status_nao_altera(self):
        p, out = self.snapshot_ok(["--status"])
        self.assertEqual(p.returncode, 0)
        self.assertIn("Estado das etapas", out)

    def test_check_apos_instalacao_completa_nao_altera(self):
        self.add_disk()
        p, _ = self.run_inst(stdin="1\n/dev/sdb\n")
        self.assertEqual(p.returncode, 0, _)
        p, out = self.snapshot_ok(["--check"])
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("deploy-check-ran", self.calls_text())

    def test_status_nao_usa_rede(self):
        self.extra_env["GH_PORT"] = "1"  # fechada: --status não deve nem tentar
        p, out = self.run_inst("--status")
        self.assertEqual(p.returncode, 0)
        self.assertNotIn("sem saída", out)


class TestPrecheck(Base):
    def test_ok_basico(self):
        p, out = self.run_inst("--check")
        for txt in ("Ubuntu 24.04", "amd64", "UFW ativo", "relógio sincronizado", "memória:"):
            self.assertIn(txt, out)

    def test_ubuntu_2204_pede_confirmacao(self):
        (self.root / "etc" / "os-release").write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        p, out = self.run_inst(stdin="nao\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("22.04", out)
        self.assertEqual(self.ncalls("ssh-keyscan"), 0)
        p, out = self.run_inst(stdin="sim\n")
        self.assertEqual(p.returncode, 0, out)

    def test_outro_so_para(self):
        (self.root / "etc" / "os-release").write_text('ID=debian\nVERSION_ID="12"\n')
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não suportado", out)

    def test_arquitetura(self):
        self.extra_env["FAKE_ARCH"] = "arm64"
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("amd64", out)

    def test_ufw_inativo_para(self):
        self.set_state("ufw_inactive")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("UFW", out)
        self.assertEqual(self.ncalls("ssh-keyscan"), 0)

    def test_relogio_nao_sincronizado_para(self):
        self.set_state("ntp_no")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("relógio", out)

    def test_memoria_pouca_para(self):
        (self.root / "proc" / "meminfo").write_text("MemTotal:       1500000 kB\n")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("memória", out)

    def test_memoria_media_so_avisa(self):
        (self.root / "proc" / "meminfo").write_text("MemTotal:       3000000 kB\n")
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("[aviso] memória", out)

    def test_espaco_insuficiente_para(self):
        self.extra_env["DISK_MIN_MB"] = "999999999"
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("espaço livre", out)

    def test_sem_saida_para_github_para(self):
        self.extra_env["GH_PORT"] = "1"
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("sem saída", out)
        self.assertEqual(self.ncalls("ssh-keyscan"), 0)


class TestDisco(Base):
    def test_disco_com_assinatura_nao_e_candidato(self):
        self.add_disk("/dev/sdb")
        self.set_state("wipefs_sdb", "offset type\n0x438 ext4\n")
        p, out = self.run_inst()
        self.assertIn("nenhum disco candidato", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)

    def test_disco_particionado_montado_ou_lvm_nao_listados(self):
        for d in ("/dev/sdb", "/dev/sdc", "/dev/sdd"):
            self.add_disk(d)
        self.set_state("lsblk_sdb", "sdb disk\nsdb1 part /boot\n")
        self.set_state("lsblk_sdc", "sdc disk /mnt/x\n")
        self.set_state("pvs", "  /dev/sdd\n")
        p, out = self.run_inst()
        self.assertIn("nenhum disco candidato", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)

    def test_escolha_de_assinatura_digitada_nao_listada_e_recusada(self):
        self.add_disk("/dev/sdb")
        self.add_disk("/dev/sdc")
        self.set_state("wipefs_sdb", "x\n")
        p, out = self.run_inst(stdin="1\n/dev/sdc\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("1) /dev/sdb", out)  # sdb não foi listado
        self.assertIn("1) /dev/sdc", out)

    def test_confirmacao_errada_recusada(self):
        self.add_disk("/dev/sdb")
        p, out = self.run_inst(stdin="1\n/dev/sdc\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("confirmação não confere", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)
        self.assertEqual(self.fstab.read_text(), self.fstab_orig)

    def test_escolha_invalida_recusada(self):
        self.add_disk("/dev/sdb")
        for ans in ("abc", "7", "0"):
            p, out = self.run_inst(stdin=ans + "\n")
            self.assertNotEqual(p.returncode, 0, ans)
        self.assertEqual(self.ncalls("pvcreate"), 0)

    def test_nenhum_segue_no_disco_do_sistema(self):
        self.add_disk("/dev/sdb")
        p, out = self.run_inst(stdin="nenhum\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("disco do sistema", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)
        self.assertEqual(self.fstab.read_text(), self.fstab_orig)
        self.assertTrue((self.nb / ".git").is_dir())  # seguiu até o código

    def test_opt_nao_vazio_recusado(self):
        self.add_disk("/dev/sdb")
        (self.opt / "algum-software").mkdir()
        p, out = self.run_inst(stdin="1\n/dev/sdb\n")
        self.assertIn("RECUSADO", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)
        self.assertEqual(self.fstab.read_text(), self.fstab_orig)

    def test_opt_com_lost_found_e_tolerado(self):
        self.add_disk("/dev/sdb")
        (self.opt / "lost+found").mkdir()
        p, out = self.run_inst(stdin="1\n/dev/sdb\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.ncalls("pvcreate"), 1)

    def test_fluxo_completo_fstab_e_comandos(self):
        self.add_disk("/dev/sdb", size=107374182400)
        p, out = self.run_inst(stdin="1\n/dev/sdb\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("100 GiB", out)
        calls = self.calls_text()
        for esperado in ("pvcreate /dev/sdb", "vgcreate dados-vg /dev/sdb",
                         "lvcreate -n opt-lv -l 100%FREE dados-vg",
                         "mkfs.ext4 -L nb-dados /dev/dados-vg/opt-lv", "mount -a"):
            self.assertIn(esperado, calls)
        # ordem
        ordem = [calls.index(x) for x in ("pvcreate", "vgcreate", "lvcreate", "mkfs.ext4", "mount -a")]
        self.assertEqual(ordem, sorted(ordem))
        # fstab: cópia com data + linha por UUID
        baks = list(self.root.glob("etc/fstab.bak-*"))
        self.assertEqual(len(baks), 1)
        self.assertRegex(baks[0].name, r"fstab\.bak-\d{8}_\d{6}$")
        self.assertEqual(baks[0].read_text(), self.fstab_orig)
        linha = "UUID=%s %s ext4 defaults,nodev,nosuid,nofail 0 2" % (UUID, self.opt)
        self.assertEqual(self.fstab.read_text(), self.fstab_orig + linha + "\n")

    def test_idempotencia_segunda_execucao_nao_refaz(self):
        self.add_disk("/dev/sdb")
        p, out = self.run_inst(stdin="1\n/dev/sdb\n")
        self.assertEqual(p.returncode, 0, out)
        antes = {c: self.ncalls(c) for c in ("pvcreate", "vgcreate", "lvcreate", "mkfs.ext4",
                                              "ssh-keygen -q", "ssh-keyscan", "git clone", "mount -a")}
        fstab = self.fstab.read_text()
        config = (self.ssh_dir / "config").read_text()
        p, out = self.run_inst(stdin="")
        self.assertEqual(p.returncode, 0, out)
        depois = {c: self.ncalls(c) for c in antes}
        self.assertEqual(antes, depois)
        self.assertEqual(self.fstab.read_text(), fstab)
        self.assertEqual((self.ssh_dir / "config").read_text(), config)
        self.assertEqual(len(list(self.root.glob("etc/fstab.bak-*"))), 1)
        self.assertIn("já montado", out)
        self.assertEqual(len(self.logs()), 2)

    def test_retomada_com_lv_existente_nao_recria(self):
        self.set_state("lv_exists")
        self.set_state("fs_made")
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.ncalls("pvcreate"), 0)
        self.assertEqual(self.ncalls("lvcreate"), 0)
        self.assertEqual(self.ncalls("mkfs.ext4"), 0)
        self.assertIn("UUID=%s" % UUID, self.fstab.read_text())

    def test_opt_ja_e_outro_ponto_de_montagem(self):
        self.add_disk("/dev/sdb")
        self.set_state("findmnt_opt", "/dev/sdz1")
        p, out = self.run_inst(stdin="")
        self.assertIn("outro volume", out)
        self.assertEqual(self.ncalls("pvcreate"), 0)


class TestChave(Base):
    def test_impressao_digital_diferente_para(self):
        self.set_state("keyscan_bad")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("DIFERE", out)
        self.assertFalse((self.ssh_dir / "known_hosts_github_netbackup").exists())
        self.assertFalse((self.ssh_dir / "id_ed25519_github_netbackup_ro").exists())
        self.assertFalse((self.ssh_dir / "config").exists())
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_known_hosts_existente_adulterado_para(self):
        self.ssh_dir.mkdir()
        self.ssh_dir.chmod(0o700)
        (self.ssh_dir / "known_hosts_github_netbackup").write_text("127.0.0.1 ssh-ed25519 BADKEY\n")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("difere da oficial", out)
        self.assertEqual(self.ncalls("ssh-keyscan"), 0)

    def test_arquivos_e_permissoes(self):
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        kh = self.ssh_dir / "known_hosts_github_netbackup"
        key = self.ssh_dir / "id_ed25519_github_netbackup_ro"
        self.assertEqual(kh.read_text(), "127.0.0.1 ssh-ed25519 GOODKEY\n")
        self.assertEqual(stat.S_IMODE(kh.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.ssh_dir.stat().st_mode), 0o700)
        self.assertIn("vm-teste somente leitura", (self.ssh_dir / (key.name + ".pub")).read_text())
        self.assertIn("-t ed25519 -N  -f %s" % key, self.calls_text())
        cfg = (self.ssh_dir / "config").read_text()
        for linha in ("Host github-netbackup", "HostName 127.0.0.1", "User git",
                      "IdentityFile %s" % key, "IdentitiesOnly yes",
                      "StrictHostKeyChecking yes", "UserKnownHostsFile %s" % kh,
                      "HostKeyAlgorithms ssh-ed25519"):
            self.assertIn(linha, cfg)
        self.assertEqual(stat.S_IMODE((self.ssh_dir / "config").stat().st_mode), 0o600)

    def test_config_existente_tem_copia_e_bloco_nao_duplica(self):
        self.ssh_dir.mkdir()
        self.ssh_dir.chmod(0o700)
        orig = "Host outro\n    HostName example.com\n"
        (self.ssh_dir / "config").write_text(orig)
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        baks = list(self.ssh_dir.glob("config.bak-*"))
        self.assertEqual(len(baks), 1)
        self.assertEqual(baks[0].read_text(), orig)
        cfg = (self.ssh_dir / "config").read_text()
        self.assertTrue(cfg.startswith(orig))
        p, out = self.run_inst()
        self.assertEqual((self.ssh_dir / "config").read_text(), cfg)
        self.assertEqual(cfg.count("Host github-netbackup"), 1)
        self.assertEqual(len(list(self.ssh_dir.glob("config.bak-*"))), 1)

    def test_mostra_chave_publica_e_espera_enter(self):
        self.set_state("ls_fail_count", "1")
        p, out = self.run_inst(stdin="\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("ssh-ed25519 AAAAFAKEPUB vm-teste somente leitura", out)
        self.assertIn("Deploy keys", out)
        self.assertIn("Allow write access", out)
        self.assertIn("tentativa 1/3", out)

    def test_leitura_ate_tres_tentativas(self):
        self.set_state("ls_fail_count", "3")  # 1 sondagem silenciosa + 2 tentativas
        p, out = self.run_inst(stdin="\n\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("tentativa 3/3", out)

    def test_leitura_falha_apos_tres_tentativas(self):
        self.set_state("ls_fail_count", "10")
        p, out = self.run_inst(stdin="\n\n\n\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("3 tentativas", out)
        self.assertNotIn("tentativa 4/3", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_chave_com_escrita_aceita_para(self):
        self.set_state("write_mode", "write")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ACEITA ESCRITA", out)
        self.assertIn("SEM 'Allow write access'", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_escrita_inconclusiva_para(self):
        self.set_state("write_mode", "weird")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não foi possível confirmar", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_teste_de_escrita_usa_receive_pack_e_nunca_push(self):
        self.run_inst()
        calls = self.calls_text()
        self.assertIn("git-receive-pack 'glaucier/netbackup-manager.git'", calls)
        self.assertNotIn(" push", calls)


class TestCodigo(Base):
    def test_clone_novo_mostra_commit(self):
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("clone --branch main git@github-netbackup:glaucier/netbackup-manager.git %s" % self.nb,
                      self.calls_text())
        self.assertIn("commit: abc1234 2026-01-01 commit de teste", out)

    def test_repo_e_branch_sobrescrevíveis(self):
        self.extra_env.update(REPO="git@github-netbackup:example/outro.git", BRANCH="dev")
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("clone --branch dev git@github-netbackup:example/outro.git", self.calls_text())
        self.assertIn("git-receive-pack 'example/outro.git'", self.calls_text())

    def test_repositorio_existente_igual_segue_sem_clonar(self):
        self.prepare_nb()
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.ncalls("git clone"), 0)
        self.assertIn("já é o repositório do produto", out)

    def test_repositorio_existente_equivalente_https_segue(self):
        self.prepare_nb("https://github.com/glaucier/netbackup-manager.git")
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)

    def test_opt_netbackup_de_outro_repositorio_para(self):
        self.prepare_nb("git@github.com:example/outra-coisa.git")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("outro repositório", out)
        self.assertEqual(self.ncalls("git clone"), 0)
        self.assertNotIn("deploy-check-ran", self.calls_text())

    def test_opt_netbackup_sem_git_para(self):
        self.nb.mkdir()
        self.nb.chmod(0o755)
        (self.nb / "arquivo").write_text("x")
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não é um repositório git", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_git_sempre_com_pager_cat(self):
        # o instalador exporta GIT_PAGER=cat; conferimos no texto do script
        txt = SCRIPT_SRC.read_text()
        self.assertIn("GIT_PAGER=cat", txt)
        self.assertNotIn("| tee", txt)


class TestDeployShTrava(Base):
    def test_deploy_com_escrita_de_outros_nao_executa(self):
        self.prepare_nb()
        (self.nb / "deploy" / "deploy.sh").chmod(0o666)
        p, out = self.run_inst()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertIn("escrita para grupo/outros", out)
        self.assertNotIn("deploy-check-ran", self.calls_text())

    def test_deploy_com_pasta_gravavel_nao_executa(self):
        self.prepare_nb()
        (self.nb / "deploy").chmod(0o777)
        p, out = self.run_inst()
        self.assertIn("RECUSADO", out)
        self.assertNotIn("deploy-check-ran", self.calls_text())

    def test_deploy_com_opt_gravavel_nao_executa(self):
        self.prepare_nb()
        self.opt.chmod(0o777)
        p, out = self.run_inst()
        self.assertIn("RECUSADO", out)
        self.assertNotIn("deploy-check-ran", self.calls_text())

    def test_deploy_de_outro_dono_nao_executa(self):
        self.prepare_nb()
        self.extra_env["OWNER_UID"] = str(os.getuid())
        # o instalador passa na checagem inicial; só o deploy.sh muda de "dono"
        # simulado: troca o dono esperado só depois do início é impossível,
        # então usamos um symlink que aponta para fora de NB_DIR
        outside = self.sb / "fora.sh"
        outside.write_text('#!/bin/sh\necho deploy-check-ran >> "$FAKE_CALLS"\n')
        outside.chmod(0o644)
        (self.nb / "deploy" / "deploy.sh").unlink()
        (self.nb / "deploy" / "deploy.sh").symlink_to(outside)
        p, out = self.run_inst()
        self.assertIn("aponta para fora", out)
        self.assertNotIn("deploy-check-ran", self.calls_text())

    def test_deploy_confiavel_executa_check_e_mostra_relatorio(self):
        self.prepare_nb()
        p, out = self.run_inst()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("deploy-check-ran", self.calls_text())
        self.assertIn("deploy.sh --check terminou com código 3", out)
        self.assertIn("Fase 3b", out)
        self.assertIn("Log desta execução:", out)


class TestLog(Base):
    def test_log_600_versao_e_sem_segredos(self):
        self.set_state("ls_fail_count", "1")
        p, out = self.run_inst(stdin="\n")
        self.assertEqual(p.returncode, 0, out)
        logs = self.logs()
        self.assertEqual(len(logs), 1)
        self.assertRegex(logs[0].name, r"^netbackup-instalacao-\d{8}_\d{6}\.log$")
        self.assertEqual(stat.S_IMODE(logs[0].stat().st_mode), 0o600)
        txt = logs[0].read_text()
        self.assertIn("versão 0.1.0-dev", txt)
        self.assertIn("PERGUNTA:", txt)
        self.assertIn("== 1. Pré-checagem ==", txt)
        self.assertNotIn("FAKE-PRIVATE-KEY", txt)
        self.assertIn(str(logs[0]), out)

    def test_texto_antes_das_perguntas_aparece_na_saida(self):
        self.add_disk("/dev/sdb")
        p, out = self.run_inst(stdin="nenhum\n")
        self.assertLess(out.index("Pré-checagem"), out.index("Escolha o número"))


class TestArtefatos(unittest.TestCase):
    def test_bash_n(self):
        r = subprocess.run(["bash", "-n", str(SCRIPT_SRC)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_shellcheck_se_disponivel(self):
        if not shutil.which("shellcheck"):
            self.skipTest("shellcheck não instalado")
        r = subprocess.run(["shellcheck", "-x", str(SCRIPT_SRC), str(REPO_DIR / "tools" / "gerar-sha256sums.sh")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_sha256sums_confere(self):
        sums = (REPO_DIR / "SHA256SUMS").read_text().split()
        self.assertEqual(sums[1].lstrip("*"), "instalar.sh")
        real = hashlib.sha256(SCRIPT_SRC.read_bytes()).hexdigest()
        self.assertEqual(sums[0], real,
                         "SHA256SUMS desatualizado: rode tools/gerar-sha256sums.sh")

    def test_sha256sum_c(self):
        r = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=str(REPO_DIR),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_gerador_reproduz_arquivo(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        out = Path(d) / "SHA256SUMS"
        r = subprocess.run(["bash", str(REPO_DIR / "tools" / "gerar-sha256sums.sh"), str(out)],
                           capture_output=True, text=True, cwd=d)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(out.read_text(), (REPO_DIR / "SHA256SUMS").read_text())

    def test_sem_binarios_nem_licenca_e_sem_dados_reais(self):
        tracked = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=str(REPO_DIR),
                                 capture_output=True, text=True).stdout.split()
        for f in tracked:
            data = (REPO_DIR / f).read_bytes()
            self.assertNotIn(b"\0", data, f + " parece binário")
            self.assertFalse(f.upper().startswith("LICENSE"), "não deve haver arquivo de licença")


if __name__ == "__main__":
    unittest.main()
