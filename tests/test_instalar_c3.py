"""Testes do PR C3 do instalar.sh: --importar (pacote do sistema do produto).

Tudo isolado: raiz falsa, systemctl/sudo falsos e uma "ferramenta do produto" falsa
(venv/bin/python -> $FAKE_PRODUTO) que lê a senha do descritor 3, como a real. Sem binários no repositório.
"""
import getpass
import hashlib
import os
import re
import stat
import unittest
from pathlib import Path

from test_instalar import FAKES, fingerprint, setUpModule, tearDownModule  # noqa: F401  (listener do módulo)
from test_instalar_3b import Base3b, fp

SENHA = "SenhaCorreta#123"
PKG = "netbackup-20260105_101500-sistema.tar.gz.gpg"

SUDO = r'''#!/bin/sh
echo "sudo $*" >> "$FAKE_CALLS"
[ "$1" = "-u" ] || exit 99
shift 2
[ "$1" = "--" ] && shift
case "$1" in
  install) [ -e "$FAKE_STATE/sudo_install_fail" ] && exit 1 ;;
esac
"$@"; rc=$?
if [ -e "$FAKE_STATE/tee_corrupt" ] && [ "$1" = "sh" ]; then
  for last; do :; done
  echo junk >> "$last"
fi
exit $rc
'''

SYSTEMCTL = r'''#!/bin/sh
echo "systemctl $*" >> "$FAKE_CALLS"
case "$1" in
  is-active)
    for a; do u="$a"; done; u="${u%.service}"
    [ -e "$FAKE_STATE/inactive_$u" ] && exit 3
    exit 0 ;;
  is-enabled) [ -e "$FAKE_STATE/unit_off" ] && exit 1; exit 0 ;;
  stop)
    shift
    for u; do [ -e "$FAKE_STATE/stop_fail" ] || touch "$FAKE_STATE/inactive_${u%.service}"; done
    exit 0 ;;
  start)
    shift
    [ -e "$FAKE_STATE/start_fail" ] && exit 1
    for u; do rm -f "$FAKE_STATE/inactive_${u%.service}"; done
    exit 0 ;;
esac
exit 0
'''

PRODUTO = r'''#!/bin/sh
# ferramenta do produto (falsa): python -m tools.pacote|tools.manutencao ...
[ "$1" = "-m" ] || exit 99
mod="$2"; shift 2
S="$FAKE_STATE"
case "$mod" in
  tools.manutencao)
    echo "produto manutencao $*" >> "$FAKE_CALLS"
    case "$1" in
      ligar) [ -e "$S/manut_ligar_fail" ] && exit 1; touch "$S/manut_on"; exit 0 ;;
      desligar) rm -f "$S/manut_on"; exit 0 ;;
      estado) [ -e "$S/manut_on" ] && exit 10; exit 0 ;;
    esac ;;
  tools.pacote)
    echo "produto pacote $*" >> "$FAKE_CALLS"
    [ "$1" = "importar" ] || exit 2
    shift
    arq="$1"; shift
    check=0; host=""; fd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --check) check=1 ;;
        --homologacao) ;;
        --painel-hostname) host="$2"; shift ;;
        --senha-fd) fd="$2"; shift ;;
      esac
      shift
    done
    [ "$fd" = 3 ] || { echo "ERRO: faltou --senha-fd 3"; exit 2; }
    read -r senha <&3 || { echo "ERRO: descritor 3 sem senha"; exit 2; }
    printf '%s' "$senha" | sha256sum | cut -d' ' -f1 >> "$S/senhas_vistas"
    [ -f "$arq" ] || { echo "ERRO: pacote não encontrado"; exit 1; }
    if [ ${#senha} -lt 8 ]; then echo "ERRO: senha curta (mínimo 8)"; exit 2; fi
    if [ "$senha" != "$(cat "$S/senha_ok" 2>/dev/null || echo 'SenhaCorreta#123')" ]; then echo "ERRO: senha do pacote incorreta"; exit 4; fi
    if [ "$check" = 1 ]; then
      [ -e "$S/pacote_check_rc" ] && { echo "ERRO: falha simulada no --check"; exit "$(cat "$S/pacote_check_rc")"; }
      pkg="$(cat "$S/pkg_host" 2>/dev/null || echo origem.example.org)"
      if [ -n "$host" ]; then
        echo "PANEL_HOSTNAME: origem $pkg → destino $host"
      else
        echo "PANEL_HOSTNAME: origem $pkg → destino $pkg (o pacote o traz; para trocar use --painel-hostname NOME[:PORTA])"
      fi
      [ -e "$S/dest_dados" ] && cat "$S/dest_dados"
      echo "pré-condições para importar: PENDENTE: manutenção desligada; serviços ativos"
      exit 0
    fi
    if [ ! -e "$S/manut_on" ] || [ ! -e "$S/inactive_netbackup" ] || [ ! -e "$S/inactive_netbackup-scheduler" ]; then
      echo "ERRO: manutenção desligada ou serviço ativo"; exit 2
    fi
    [ -e "$S/pacote_real_rc" ] && { echo "ERRO: falha simulada na importação"; exit "$(cat "$S/pacote_real_rc")"; }
    echo "importado: 3 equipamentos"
    echo "CHECKLIST DO DESTINO"
    echo " [ ] conferir o rclone.conf (não vem no pacote)"
    echo " [ ] revisar os agendamentos"
    exit 0 ;;
esac
exit 2
'''


LOCAL_H = "a" * 40
REMOTO_H = "b" * 40

# git falso com estado do clone existente (git_local, git_remote, git_rel, git_sujo ...); o resto vem do fake padrão.
GIT_CODIGO = r'''
S="$FAKE_STATE"
if [ "$1" = "-C" ]; then d="$2"; shift 2
  case "$1" in
    remote) cat "$d/.git/fake_remote" 2>/dev/null; exit 0 ;;
    log) echo "abc1234 2026-01-01 commit de teste"; exit 0 ;;
    rev-parse) case "$2" in HEAD) cat "$S/git_local" ;; FETCH_HEAD*) cat "$S/git_remote" ;; esac; exit 0 ;;
    fetch) [ -e "$S/git_fetch_fail" ] && exit 1; exit 0 ;;
    ls-remote) printf '%s\trefs/heads/main\n' "$(cat "$S/git_remote")"; exit 0 ;;
    cat-file) [ -e "$S/git_remote_unknown" ] && exit 1; exit 0 ;;
    merge-base)
      rel="$(cat "$S/git_rel")"; loc="$(cat "$S/git_local")"; rem="$(cat "$S/git_remote")"
      [ "$3" = "$loc" ] && [ "$4" = "$rem" ] && [ "$rel" = atras ] && exit 0
      [ "$3" = "$rem" ] && [ "$4" = "$loc" ] && [ "$rel" = adiantado ] && exit 0
      exit 1 ;;
    status) [ -e "$S/git_sujo" ] && echo " M config/app_settings.conf.example"; exit 0 ;;
    merge) cp "$S/git_remote" "$S/git_local"; touch "$S/git_merged"; exit 0 ;;
  esac
  exit 0
fi
'''


class BaseImp(Base3b):
    def setUp(self):
        super().setUp()
        self.pkgdir = self.sb / "pacotes"
        self.pkgdir.mkdir()
        self.pkgdir.chmod(0o755)
        self.me = getpass.getuser()
        self.import_dir = self.root / "home-netbackup" / "importar"
        self.extra_env.update({
            "APP_USER": self.me,
            "IMPORT_DIR": str(self.import_dir),
            "FAKE_PRODUTO": str(self.bin / "fake-produto"),
        })
        for nome, corpo in (("sudo", SUDO), ("systemctl", SYSTEMCTL), ("fake-produto", PRODUTO)):
            f = self.bin / nome
            f.write_text(corpo)
            f.chmod(0o755)
        py = self.fixture / "venv" / "bin" / "python"
        py.parent.mkdir(parents=True)
        py.write_text('#!/bin/sh\nexec "$FAKE_PRODUTO" "$@"\n')
        for d in (self.fixture / "venv", self.fixture / "venv" / "bin"):
            d.chmod(0o755)
        py.chmod(0o755)
        self.pkg = self.make_pkg()

    def make_pkg(self, nome=PKG, sha=True, conteudo=b"PACOTE-CIFRADO-DE-TESTE\n" * 50):
        arq = self.pkgdir / nome
        arq.write_bytes(conteudo)
        if sha:
            h = hashlib.sha256(conteudo).hexdigest()
            (self.pkgdir / (nome + ".sha256")).write_text("%s  %s\n" % (h, nome))
        return arq

    def imp(self, *extra, stdin=None, resp=True):
        if stdin is None:
            stdin = SENHA + "\n\n"
        return self.run_full("--importar", str(self.pkg), *extra, stdin=stdin, resp=resp)

    def lines(self, prefix):
        return [l for l in self.calls_text().splitlines() if l.startswith(prefix)]

    def idx(self, prefix, nth=0):
        ls = [i for i, l in enumerate(self.calls_text().splitlines()) if l.startswith(prefix)]
        return ls[nth] if len(ls) > nth else None

    def tool_calls(self):
        return self.lines("produto pacote")

    def tudo_texto(self, out):
        partes = [out, self.calls_text()]
        for p in self.root.rglob("*"):
            if p.is_file() and not p.is_symlink():
                try:
                    partes.append(p.read_text(errors="ignore"))
                except OSError:
                    pass
        return "\n".join(partes)


class TestFluxoFeliz(BaseImp):
    def test_ordem_check_stop_manutencao_importar_start(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        i_check = self.idx("produto pacote importar %s --check" % (self.import_dir / PKG))
        i_stop = self.idx("systemctl stop")
        i_lig = self.idx("produto manutencao ligar")
        i_real = [i for i, l in enumerate(self.calls_text().splitlines())
                  if l.startswith("produto pacote") and "--check" not in l]
        i_start = self.idx("systemctl start")
        self.assertIsNotNone(i_check, self.calls_text())
        self.assertEqual(len(i_real), 1)
        self.assertLess(i_check, i_stop)
        self.assertLess(i_stop, i_lig)
        self.assertLess(i_lig, i_real[0])
        self.assertLess(i_real[0], i_start)
        self.assertIn("systemctl stop netbackup.service netbackup-scheduler.service", self.calls_text())
        # a importação vem depois do deploy e antes do HTTPS
        self.assertLess(out.index("== 7. Deploy"), out.index("== 8. Importação"))
        self.assertLess(out.index("== 8. Importação"), out.index("== 9. HTTPS"))

    def test_manutencao_continua_ligada_e_servicos_sobem(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertTrue((self.state / "manut_on").exists())
        self.assertFalse(list(self.state.glob("inactive_netbackup*")))
        self.assertNotIn("manutencao desligar", self.calls_text())
        self.assertIn("MANUTENÇÃO CONTINUA LIGADA", out)

    def test_ferramenta_sempre_como_netbackup_pelo_sudo(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        prod = [l for l in self.calls_text().splitlines() if l.startswith("produto")]
        sudo = [l for l in self.lines("sudo") if "tools." in l]
        self.assertEqual(len(prod), len(sudo))
        for l in self.lines("sudo"):
            self.assertTrue(l.startswith("sudo -u %s -- " % self.me), l)

    def test_estado_e_relatorio(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "1")
        self.assertEqual(self.estado_val("IMPORT_STATUS"), "feita")
        self.assertEqual(self.estado_val("IMPORT_ARQUIVO"), PKG)
        self.assertEqual(self.estado_val("IMPORT_ORIGEM"), "origem.example.org")
        self.assertEqual(self.estado_val("IMPORT_HOMOLOGACAO"), "nao")
        self.assertEqual(self.estado_val("IMPORT_COPIA"), "apagada")
        rel = self.report.read_text()
        for txt in ("Importação ..........: sim", PKG, "origem.example.org", "Homologação .........: nao",
                    'botão "Liberar agendador"', "tools.manutencao desligar", "tools.manutencao estado",
                    "CHECKLIST DO DESTINO", "[ ] conferir o rclone.conf", "[ ] revisar os agendamentos",
                    "servidor de ORIGEM",
                    "vieram do PACOTE", "UFW desta VM recebeu as redes das RESPOSTAS", "Aplicar regras faltantes"):
            self.assertIn(txt, rel)
        self.assertNotIn("HOMOLOGAÇÃO: os AGENDAMENTOS", rel)

    def test_sem_importar_o_relatorio_diz_nao(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("importação não solicitada", out)
        self.assertIn("Importação ..........: não", self.report.read_text())
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "")

    def test_senha_so_pelo_descritor_nunca_em_argv_disco_log_ou_tela(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--senha-fd 3", l)
        visto = (self.state / "senhas_vistas").read_text().split()
        self.assertEqual(visto, [hashlib.sha256(SENHA.encode()).hexdigest()] * 2)  # a MESMA senha, nas 2 chamadas
        self.assertNotIn(SENHA, self.tudo_texto(out))
        self.assertNotIn("SenhaCorreta", self.tudo_texto(out))

    def test_transporte_pelo_netbackup_pasta_700_arquivo_600(self):
        p, out = self.imp(stdin=SENHA + "\nn\n")
        self.assertEqual(p.returncode, 0, out)
        d = self.import_dir
        self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)
        c = d / PKG
        self.assertEqual(stat.S_IMODE(c.stat().st_mode), 0o600)
        self.assertEqual(c.read_bytes(), self.pkg.read_bytes())
        sudo = "\n".join(self.lines("sudo"))
        self.assertIn("install -d -m 700 -- %s" % d, sudo)
        self.assertIn("tee", sudo)
        self.assertEqual(self.estado_val("IMPORT_COPIA"), "mantida")
        self.assertIn("MANTIDA", out)
        self.assertIn(str(c), out)

    def test_limpeza_padrao_apaga_e_fim_da_entrada_tambem(self):
        p, out = self.imp(stdin=SENHA + "\n")   # sem resposta à pergunta de limpeza
        self.assertEqual(p.returncode, 0, out)
        self.assertFalse((self.import_dir / PKG).exists())
        self.assertIn("apagada", out)

    def test_rodar_de_novo_nao_importa_outra_vez(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        n = len(self.tool_calls())
        p, out = self.imp(stdin="")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("a importação já foi feita", out)
        self.assertEqual(len(self.tool_calls()), n)


class TestNomeDoPainel(BaseImp):
    def test_nome_do_pacote_diferente_avisa_e_o_https_usa_o_dele(self):
        self.set_state("pkg_host", "novo.example.com")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("DIFERENTE", out)
        self.assertIn("novo.example.com", out)
        self.assertTrue(any("novo.example.com" in l for l in self.lines("certbot")), self.calls_text())
        self.assertFalse(any("netbackup.example.com" in l for l in self.lines("certbot")))
        self.assertEqual(self.estado_val("ACESSO"), "https://novo.example.com:44318")
        self.assertEqual(self.estado_val("IMPORT_DOMINIO_RESPOSTAS"), "netbackup.example.com")
        self.assertIn("DOMINIO=novo.example.com", self.saved.read_text())
        self.assertIn("diferente do nome das respostas", self.report.read_text())

    def test_painel_hostname_vai_para_a_ferramenta_e_a_porta_nao_vai_para_o_https(self):
        p, out = self.imp("--painel-hostname", "Outro.Example.com:8443")
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--painel-hostname outro.example.com:8443", l)
        self.assertTrue(any("outro.example.com" in l for l in self.lines("certbot")))
        self.assertFalse(any("8443" in l for l in self.lines("certbot")))

    def test_mesmo_nome_nao_avisa(self):
        self.set_state("pkg_host", "netbackup.example.com")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("DIFERENTE", out)
        self.assertEqual(self.estado_val("IMPORT_DOMINIO_RESPOSTAS"), "")

    def test_origem_nao_definida_mantem_o_nome_das_respostas(self):
        self.set_state("pkg_host", "(não definido)")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertTrue(any("netbackup.example.com" in l for l in self.lines("certbot")))
        self.assertIn("não foi possível ler o nome do painel", out)
        self.assertNotIn("DIFERENTE", out)
        self.assertEqual(self.estado_val("IMPORT_ORIGEM"), "n/d")

    def test_formato_sem_opcao_com_nome_sem_porta_e_o_sufixo_do_texto(self):
        # "destino X (o pacote o traz; ... NOME[:PORTA])": só o 1º token vale (antes o corte em ':' pegava lixo)
        self.set_state("pkg_host", "novo.example.com")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("DIFERENTE", out)
        self.assertEqual(self.estado_val("ACESSO"), "https://novo.example.com:44318")
        self.assertEqual(self.estado_val("IMPORT_PAINEL"), "novo.example.com")

    def test_formato_sem_opcao_com_nome_com_porta(self):
        self.set_state("pkg_host", "novo.example.com:8443")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("IMPORT_PAINEL"), "novo.example.com")
        self.assertTrue(any("novo.example.com" in l for l in self.lines("certbot")))
        self.assertFalse(any("8443" in l for l in self.lines("certbot")))
        self.assertEqual(self.estado_val("IMPORT_ORIGEM"), "novo.example.com:8443")

    def test_formato_com_opcao_com_e_sem_porta(self):
        for v, esperado in (("outro.example.com", "outro.example.com"), ("outro.example.com:8443", "outro.example.com")):
            self.setUp()
            p, out = self.imp("--painel-hostname", v)
            self.assertEqual(p.returncode, 0, out)
            self.assertEqual(self.estado_val("IMPORT_PAINEL"), esperado)
            self.assertIn("--painel-hostname %s" % v, "\n".join(self.tool_calls()))

    def test_origem_nao_definida_com_opcao_usa_o_nome_pedido(self):
        self.set_state("pkg_host", "(não definido)")
        p, out = self.imp("--painel-hostname", "outro.example.com")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("IMPORT_PAINEL"), "outro.example.com")
        self.assertNotIn("não foi possível ler", out)

    def test_falha_nao_troca_as_respostas(self):
        self.set_state("pkg_host", "novo.example.com")
        self.set_state("pacote_real_rc", "7")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("DOMINIO=netbackup.example.com", self.saved.read_text())


class TestHomologacaoNomeDoPainel(BaseImp):
    def test_homologacao_sem_nome_passa_dominio_das_respostas_e_porta_https(self):
        self.set_state("pkg_host", "producao.example.org")
        p, out = self.imp("--homologacao")
        self.assertEqual(p.returncode, 0, out)
        tools = self.tool_calls()
        self.assertEqual(len(tools), 2)
        for l in tools:   # no --check e no real
            self.assertIn("--painel-hostname netbackup.example.com:44318", l)
        self.assertIn("NÃO assume o nome da origem", out)
        self.assertNotIn("producao.example.org:", "\n".join(tools))
        self.assertTrue(any("netbackup.example.com" in l for l in self.lines("certbot")))
        self.assertFalse(any("producao.example.org" in l for l in self.lines("certbot")))
        self.assertEqual(self.estado_val("IMPORT_PAINEL"), "netbackup.example.com")
        self.assertEqual(self.estado_val("IMPORT_PAINEL_AUTO"), "sim")
        self.assertEqual(self.estado_val("IMPORT_DOMINIO_RESPOSTAS"), "")
        self.assertIn("DOMINIO=netbackup.example.com", self.saved.read_text())
        self.assertIn("NÃO é o da origem", self.report.read_text())

    def test_homologacao_com_nome_pedido_nao_e_sobrescrito(self):
        p, out = self.imp("--homologacao", "--painel-hostname", "lab.example.com:8443")
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--painel-hostname lab.example.com:8443", l)
            self.assertNotIn("44318", l)
        self.assertNotIn("NÃO assume o nome da origem", out)
        self.assertEqual(self.estado_val("IMPORT_PAINEL_AUTO"), "nao")

    def test_homologacao_nome_pelo_arquivo_de_respostas(self):
        self.set_resp(RESPOSTAS_BASE + "IMPORTAR_ARQUIVO=%s\nIMPORTAR_HOMOLOGACAO=sim\nIMPORTAR_PAINEL_HOSTNAME=lab.example.com\n" % self.pkg)
        p, out = self.run_full(stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--painel-hostname lab.example.com", l)
            self.assertNotIn("44318", l)

    def test_fora_da_homologacao_vale_o_nome_do_pacote_e_nada_e_passado(self):
        self.set_state("pkg_host", "producao.example.org")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertNotIn("--painel-hostname", l)
        self.assertIn("DIFERENTE", out)
        self.assertEqual(self.estado_val("IMPORT_PAINEL"), "producao.example.org")
        self.assertEqual(self.estado_val("IMPORT_PAINEL_AUTO"), "nao")

    def test_check_do_instalador_avisa_o_que_sera_passado(self):
        p, out = self.run_inst("--check", "--importar", str(self.pkg), "--homologacao")
        self.assertIn("nunca o nome da origem", out)


class TestAvisosNaTela(BaseImp):
    def test_senha_do_admin_e_descartavel_so_com_importacao(self):
        p, out = self.imp()
        self.assertIn("TEMPORÁRIA", out)
        bloco = out[out.index("Em instantes o deploy.sh"):out.index("== 8. Importação")]
        self.assertIn("esta senha é TEMPORÁRIA", bloco)   # aviso no bloco do deploy, antes do pedido da senha
        self.assertLess(bloco.index("TEMPORÁRIA"), bloco.index("=====", bloco.index("TEMPORÁRIA")) + 1)
        self.setUp()
        p, out = self.run_full()
        self.assertNotIn("TEMPORÁRIA", out)


class TestHomologacao(BaseImp):
    def test_flag_vai_as_duas_chamadas_e_o_relatorio_destaca(self):
        p, out = self.imp("--homologacao")
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--homologacao", l)
        self.assertEqual(self.estado_val("IMPORT_HOMOLOGACAO"), "sim")
        rel = self.report.read_text()
        self.assertIn("Homologação .........: sim", rel)
        self.assertIn("HOMOLOGAÇÃO: os AGENDAMENTOS ficaram DESLIGADOS", rel)
        self.assertIn("cd %s && sudo -u %s venv/bin/python -m tools.pacote homologacao --encerrar" % (self.nb, self.me), rel)
        self.assertIn("não religa nada sozinho", rel)
        self.assertIn('"homologacao" sem', rel)
        self.assertNotIn("Siga o CHECKLIST, libere", rel)

    def test_sem_flag_nao_passa_homologacao(self):
        p, out = self.imp()
        for l in self.tool_calls():
            self.assertNotIn("--homologacao", l)


class TestDestinoComDados(BaseImp):
    def com_backups(self):
        f = self.fixture / "backups" / "rt1" / "antigo.cfg"
        f.parent.mkdir(parents=True)
        f.write_text("backup antigo\n")
        for d in (self.fixture / "backups", f.parent):
            d.chmod(0o755)
        f.chmod(0o644)

    def test_com_backups_recusa_sem_forcar(self):
        self.com_backups()
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertIn("--forcar-importacao", out)
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertEqual(self.lines("sudo"), [])

    def test_forcar_deixa_claro_que_sobrepoe_e_pede_confirmacao(self):
        self.com_backups()
        p, out = self.imp("--forcar-importacao", stdin="sim\n" + SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("SOBREPOR", out)
        self.assertIn("pre-importacao", out)
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "1")

    def test_forcar_sem_confirmar_nao_altera(self):
        self.com_backups()
        p, out = self.imp("--forcar-importacao", stdin="nao\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(self.lines("systemctl stop"), [])

    def test_banco_com_usuarios_antes_do_deploy_nao_e_instalacao_nova(self):
        self.set_state("deploy_admin_existente")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertIn("usuários", out)
        self.assertEqual(self.tool_calls(), [])

    def test_instalacao_nova_so_com_admin_inicial_nao_recusa(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("RECUSADO", out)

    def test_forcar_sem_necessidade_nao_pergunta(self):
        p, out = self.imp("--forcar-importacao", stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("SOBREPOR", out)


class TestPrecheckDoArquivo(BaseImp):
    def assertNadaAlterado(self, out):
        for c in ("ssh-keyscan", "git clone", "ufw allow", "mkfs", "sudo", "systemctl stop"):
            self.assertEqual(self.ncalls(c), 0, c)
        self.assertEqual(self.tool_calls(), [])
        self.assertFalse(self.estado.exists())
        self.assertFalse(self.saved.exists())

    def test_arquivo_inexistente(self):
        self.pkg.unlink()
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não existe", out)
        self.assertNadaAlterado(out)

    def test_link_simbolico_recusado(self):
        real = self.pkgdir / "real.bin"
        real.write_bytes(b"x" * 10)
        link = self.pkgdir / "netbackup-20260106_000000-completo.tar.gz"
        link.symlink_to(real)
        self.pkg = link
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("link simbólico", out)
        self.assertNadaAlterado(out)

    def test_diretorio_nao_e_arquivo_comum(self):
        d = self.pkgdir / "netbackup-20260106_000000-completo.tar.gz"
        d.mkdir()
        self.pkg = d
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não é um arquivo comum", out)
        self.assertNadaAlterado(out)

    def test_arquivo_vazio(self):
        self.pkg.write_bytes(b"")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("vazio", out)
        self.assertNadaAlterado(out)

    def test_nomes_fora_do_padrao(self):
        for nome in ("backup.tar.gz", "netbackup-20260105-sistema.tar.gz", "netbackup-20261305_101500-sistema.tar.gz",
                     "netbackup-20260105_101500-parcial.tar.gz", "netbackup-20260105_101500-sistema.zip",
                     "netbackup-20260105_101500-sistema.tar.gz.gpg.bak", "xnetbackup-20260105_101500-sistema.tar.gz"):
            self.pkg = self.make_pkg(nome)
            p, out = self.imp()
            self.assertNotEqual(p.returncode, 0, nome)
            self.assertIn("fora do padrão", out, nome)
            self.assertNadaAlterado(out)

    def test_nomes_validos(self):
        for nome in ("netbackup-20260105_101500-sistema.tar.gz", "netbackup-20260105_101500-completo.tar.gz.gpg",
                     "netbackup-manager-lab-20260105_101500-sistema-2.tar.gz.gpg", "netbackup_x.y-20260105_101500-completo-13.tar.gz"):
            self.pkg = self.make_pkg(nome)
            p, out = self.run_inst("--check", "--importar", str(self.pkg))
            self.assertIn("[ok] pacote: %s" % self.pkg, out, nome)

    def test_sha256_confere(self):
        p, out = self.imp()
        self.assertIn("sha256 confere", out)

    def test_sha256_que_nao_confere_para_antes_de_tudo(self):
        (self.pkgdir / (PKG + ".sha256")).write_text("%s  %s\n" % ("0" * 64, PKG))
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("NÃO confere", out)
        self.assertNadaAlterado(out)

    def test_sha256_de_outro_nome_ou_formato_ruim(self):
        h = hashlib.sha256(self.pkg.read_bytes()).hexdigest()
        for txt in ("%s  outro-arquivo.tar.gz\n" % h, "lixo\n", "%s  %s\n%s  x\n" % (h, PKG, h)):
            (self.pkgdir / (PKG + ".sha256")).write_text(txt)
            p, out = self.imp()
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("inválido", out)
            self.assertNadaAlterado(out)

    def test_sha256_modo_binario_com_asterisco(self):
        h = hashlib.sha256(self.pkg.read_bytes()).hexdigest()
        (self.pkgdir / (PKG + ".sha256")).write_text("%s *%s\n" % (h, PKG))
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)

    def test_sha256_link_simbolico_recusado(self):
        s = self.pkgdir / (PKG + ".sha256")
        alvo = self.pkgdir / "sha-real"
        alvo.write_text(s.read_text())
        s.unlink()
        s.symlink_to(alvo)
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("link simbólico", out)
        self.assertNadaAlterado(out)

    def test_sem_sha256_pede_confirmacao_e_recusa_sem_sim(self):
        (self.pkgdir / (PKG + ".sha256")).unlink()
        p, out = self.imp(stdin="nao\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("sem conferir o sha256", out)
        self.assertNadaAlterado(out)

    def test_sem_sha256_entrada_encerrada_nao_altera(self):
        (self.pkgdir / (PKG + ".sha256")).unlink()
        p, out = self.imp(stdin="")
        self.assertNotEqual(p.returncode, 0)
        self.assertNadaAlterado(out)

    def test_sem_sha256_com_sim_segue_e_pergunta_uma_vez_so(self):
        (self.pkgdir / (PKG + ".sha256")).unlink()
        p, out = self.imp(stdin="sim\n" + SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(out.count("sem conferir o sha256"), 1)

    def test_sem_sha256_com_a_opcao_nao_pergunta(self):
        (self.pkgdir / (PKG + ".sha256")).unlink()
        p, out = self.imp("--sem-sha256")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("sem conferir o sha256", out)

    def test_gpg_ausente_so_importa_se_o_pacote_e_cifrado(self):
        self.extra_env["CMD_GPG"] = "gpg-que-nao-existe"
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("gnupg", out)
        self.assertNadaAlterado(out)
        self.pkg = self.make_pkg("netbackup-20260105_101500-sistema.tar.gz")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)

    def test_sudo_ausente(self):
        self.extra_env["CMD_SUDO"] = "sudo-que-nao-existe"
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("sudo-que-nao-existe", out)
        self.assertNadaAlterado(out)

    def test_caminho_relativo_e_aceito(self):
        p, out = self.run_full("--importar", os.path.relpath(self.pkg, self.sb), stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)


class TestCodigosDaFerramenta(BaseImp):
    def check_falha(self, rc, trecho):
        self.set_state("pacote_check_rc", str(rc))
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0, out)
        self.assertIn(trecho, out)
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertEqual(self.lines("produto manutencao"), [])
        self.assertTrue((self.import_dir / PKG).exists())            # em falha a cópia fica
        self.assertIn(str(self.import_dir / PKG), out)               # e diz onde
        self.assertEqual(len([l for l in self.tool_calls() if "--check" not in l]), 0)
        return out

    def test_check_1_erro_de_es(self):
        self.check_falha(1, "entrada/saída")

    def test_check_2_recusado(self):
        self.check_falha(2, "RECUSADA")

    def test_check_3_pacote_adulterado(self):
        self.check_falha(3, "INVÁLIDO ou ADULTERADO")

    def test_check_5_pacote_mais_novo(self):
        self.check_falha(5, "MAIS NOVO")

    def test_check_6_gpg_ausente(self):
        self.check_falha(6, "gpg ausente")

    def test_check_4_senha_errada_ate_3_tentativas(self):
        p, out = self.imp(stdin="SenhaErrada#999\nOutraErrada#888\nTerceiraErrada#7\n" + SENHA + "\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len(self.tool_calls()), 3)                  # a quarta senha nem é lida
        self.assertIn("tentativa 3 de 3", out)
        self.assertIn("não aceita após 3 tentativas", out)
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertTrue((self.import_dir / PKG).exists())

    def test_check_4_acerta_na_segunda(self):
        p, out = self.imp(stdin="SenhaErrada#999\n" + SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(len([l for l in self.tool_calls() if "--check" in l]), 2)
        self.assertIn("tentativa 1 de 3", out)
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "1")

    def test_senha_curta_tambem_pede_de_novo(self):
        p, out = self.imp(stdin="abc\n" + SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("senha curta", out)

    def test_senha_vazia_pede_de_novo_e_fim_da_entrada_para(self):
        p, out = self.imp(stdin="\n" + SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        p, out = self.imp(stdin="")
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "1")  # a 1ª execução já importou
        self.setUp()
        p, out = self.imp(stdin="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("entrada encerrada antes da senha", out)
        self.assertEqual(self.lines("systemctl stop"), [])

    def test_codigo_desconhecido(self):
        self.check_falha(9, "inesperado (9)")

    def test_nunca_importa_sem_check_com_saida_zero(self):
        self.set_state("pacote_check_rc", "3")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertFalse([l for l in self.tool_calls() if "--check" not in l])

    def test_real_7_parou_no_meio_nao_sobe_servicos(self):
        self.set_state("pacote_real_rc", "7")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("PAROU NO MEIO", out)
        self.assertIn("pre-importacao", out)
        self.assertIn(str(self.nb / "system_backups" / "pre-importacao"), out)
        self.assertEqual(self.lines("systemctl start"), [])
        self.assertTrue((self.state / "inactive_netbackup").exists())
        self.assertTrue((self.state / "manut_on").exists())
        self.assertNotIn("manutencao desligar", self.calls_text())
        self.assertEqual(self.estado_val("IMPORT_STATUS"), "parou")
        self.assertTrue((self.import_dir / PKG).exists())
        self.assertIn(str(self.import_dir / PKG), out)
        self.assertIn("NÃO foram religados", out)
        # rodar de novo com --importar recusa; sem --importar segue e avisa
        p, out = self.imp(stdin="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("começou e não terminou", out)
        n = len(self.tool_calls())
        p, out = self.run_full(stdin="")
        self.assertEqual(len(self.tool_calls()), n)
        self.assertIn("NÃO terminou", out)
        self.assertIn("INTERROMPIDA", self.report.read_text())

    def test_real_2_a_6_restaura_manutencao_e_religa(self):
        for rc in (2, 3, 4, 5, 6):
            self.setUp()
            self.set_state("pacote_real_rc", str(rc))
            p, out = self.imp()
            self.assertNotEqual(p.returncode, 0, rc)
            self.assertIn("NÃO foi feita", out)
            self.assertIn("systemctl start", self.calls_text())
            self.assertFalse((self.state / "manut_on").exists(), rc)
            self.assertFalse(list(self.state.glob("inactive_netbackup*")), rc)
            self.assertEqual(self.estado_val("IMPORT_STATUS"), "recusada")
            self.assertTrue((self.import_dir / PKG).exists())

    def test_real_1_estado_incerto_nao_sobe_servicos(self):
        self.set_state("pacote_real_rc", "1")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("incerto", out)
        self.assertEqual(self.lines("systemctl start"), [])
        self.assertEqual(self.estado_val("IMPORT_STATUS"), "parou")

    def test_nao_para_os_servicos(self):
        self.set_state("stop_fail")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não foi possível parar os serviços", out)
        self.assertEqual(self.lines("produto manutencao ligar"), [])
        self.assertFalse([l for l in self.tool_calls() if "--check" not in l])

    def test_manutencao_nao_liga_religa_os_servicos(self):
        self.set_state("manut_ligar_fail")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não foi possível ligar a manutenção", out)
        self.assertIn("systemctl start", self.calls_text())
        self.assertFalse([l for l in self.tool_calls() if "--check" not in l])

    def test_servicos_que_nao_sobem_apos_sucesso_dao_erro_mas_mantem_estado(self):
        self.set_state("start_fail")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.estado_val("IMPORT_FEITO"), "1")
        self.assertIn("os serviços não subiram", out)

    def test_manutencao_ja_ligada_nao_e_religada_nem_desligada_na_recusa(self):
        self.set_state("manut_on")
        self.set_state("pacote_real_rc", "2")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.lines("produto manutencao ligar"), [])
        self.assertNotIn("manutencao desligar", self.calls_text())


class TestTransporte(BaseImp):
    def test_falha_ao_criar_a_pasta_nao_para_nada(self):
        self.set_state("sudo_install_fail")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não foi possível criar", out)
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertEqual(self.tool_calls(), [])

    def test_copia_corrompida_e_removida(self):
        self.set_state("tee_corrupt")
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não confere com o original", out)
        self.assertFalse((self.import_dir / PKG).exists())
        self.assertEqual(self.tool_calls(), [])

    def test_pasta_com_modo_errado_e_recusada(self):
        self.import_dir.mkdir(parents=True)
        self.import_dir.chmod(0o755)
        p, out = self.imp(stdin=SENHA + "\nn\n")
        # "install -d -m 700" corrige o modo de uma pasta existente do próprio usuário
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(stat.S_IMODE(self.import_dir.stat().st_mode), 0o700)

    def test_pasta_link_simbolico_e_recusada(self):
        alvo = self.sb / "alvo"
        alvo.mkdir()
        self.import_dir.parent.mkdir(parents=True)
        self.import_dir.symlink_to(alvo)
        p, out = self.imp()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(list(alvo.iterdir()), [])


class TestRespostas(BaseImp):
    def resp_com(self, extra):
        self.set_resp(RESPOSTAS_BASE + extra)

    def test_chaves_importar_no_arquivo_de_respostas(self):
        self.resp_com("IMPORTAR_ARQUIVO=%s\nIMPORTAR_HOMOLOGACAO=sim\nIMPORTAR_PAINEL_HOSTNAME=Lab.Example.com:8443\n" % self.pkg)
        p, out = self.run_full(stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        for l in self.tool_calls():
            self.assertIn("--homologacao", l)
            self.assertIn("--painel-hostname lab.example.com:8443", l)
        self.assertEqual(self.estado_val("IMPORT_HOMOLOGACAO"), "sim")

    def test_linha_de_comando_vale_mais_que_o_arquivo(self):
        outro = self.make_pkg("netbackup-20260101_000000-completo.tar.gz")
        self.resp_com("IMPORTAR_ARQUIVO=%s\n" % outro)
        p, out = self.run_full("--importar", str(self.pkg), stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("IMPORT_ARQUIVO"), PKG)
        self.assertIn("diferem", out)

    def test_senha_no_arquivo_de_respostas_e_recusada(self):
        for chave in ("IMPORTAR_SENHA", "IMPORTAR_SENHA_PACOTE", "SENHA_PACOTE"):
            self.resp_com("IMPORTAR_ARQUIVO=%s\n%s=segredo123\n" % (self.pkg, chave))
            p, out = self.run_full(stdin=SENHA + "\n")
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("NUNCA vai no arquivo de respostas", out)
            self.assertNotIn("segredo123", out + self.calls_text())
            self.assertEqual(self.tool_calls(), [])

    def test_valores_invalidos(self):
        for extra, frag in (("IMPORTAR_HOMOLOGACAO=talvez\n", "deve ser sim ou nao"),
                            ("IMPORTAR_PAINEL_HOSTNAME=http://x.com\n", "IMPORTAR_PAINEL_HOSTNAME inválido"),
                            ("IMPORTAR_PAINEL_HOSTNAME=x.example.com:99999\n", "IMPORTAR_PAINEL_HOSTNAME inválido"),
                            ("IMPORTAR_ARQUIVO=\n", "IMPORTAR_ARQUIVO vazio"),
                            ("IMPORTAR_ARQUIVO=/a/b\nIMPORTAR_ARQUIVO=/a/c\n", "repetido")):
            self.resp_com(extra)
            p, out = self.run_full(stdin="")
            self.assertNotEqual(p.returncode, 0, extra)
            self.assertIn(frag, out)
            self.assertFalse(self.estado.exists())

    def test_homologacao_sem_arquivo_e_erro_de_uso(self):
        self.resp_com("IMPORTAR_HOMOLOGACAO=sim\n")
        p, out = self.run_full(stdin="")
        self.assertEqual(p.returncode, 2)
        self.assertIn("só valem com --importar", out)

    def test_homologacao_nao_no_arquivo_e_aceita(self):
        self.resp_com("IMPORTAR_ARQUIVO=%s\nIMPORTAR_HOMOLOGACAO=nao\n" % self.pkg)
        p, out = self.run_full(stdin=SENHA + "\n\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("IMPORT_HOMOLOGACAO"), "nao")

    def test_respostas_salvas_nao_guardam_chaves_de_importacao_nem_senha(self):
        p, out = self.imp("--homologacao")
        self.assertEqual(p.returncode, 0, out)
        txt = self.saved.read_text()
        self.assertNotIn("IMPORTAR", txt)
        self.assertNotIn(SENHA, txt)


class TestOpcoes(BaseImp):
    def test_opcoes_de_importacao_sem_importar(self):
        for args in (["--homologacao"], ["--painel-hostname", "x.example.com"], ["--forcar-importacao"], ["--sem-sha256"]):
            p, out = self.run_inst(*args)
            self.assertEqual(p.returncode, 2, args)
            self.assertIn("só valem com --importar", out)

    def test_importar_com_outros_modos(self):
        for modo in ("--status", "--certificado"):
            p, out = self.run_inst("--importar", str(self.pkg), modo)
            self.assertEqual(p.returncode, 2, modo)
            self.assertIn("só valem", out)

    def test_importar_sem_valor_e_repetido(self):
        p, out = self.run_inst("--importar")
        self.assertEqual(p.returncode, 2)
        p, out = self.run_inst("--importar", str(self.pkg), "--importar", str(self.pkg))
        self.assertEqual(p.returncode, 2)
        self.assertIn("só pode aparecer uma vez", out)

    def test_painel_hostname_invalido(self):
        for v in ("http://x.example.com", "x.example.com:0", "x", "x.example.com:abc", "*.example.com"):
            p, out = self.run_inst("--importar", str(self.pkg), "--painel-hostname", v)
            self.assertEqual(p.returncode, 2, v)
            self.assertIn("--painel-hostname inválido", out)

    def test_ajuda_documenta_as_opcoes(self):
        p, out = self.run_inst("--help")
        for txt in ("--importar ARQUIVO", "--homologacao", "--painel-hostname", "--forcar-importacao",
                    "--sem-sha256", "IMPORTAR_ARQUIVO"):
            self.assertIn(txt, out)


class TestCheckDoInstalador(BaseImp):
    def test_check_valida_arquivo_e_sha_sem_alterar_nada(self):
        antes = fingerprint(self.root)
        nlogs = len(self.logs())
        p, out = self.run_inst("--check", "--importar", str(self.pkg))
        self.assertEqual(fingerprint(self.root), antes)
        self.assertEqual(len(self.logs()), nlogs)
        self.assertIn("[ok] pacote: %s" % self.pkg, out)
        self.assertIn("sha256 confere", out)
        self.assertIn("senha do pacote será pedida", out)
        self.assertEqual(self.tool_calls(), [])
        self.assertEqual(self.lines("sudo"), [])
        self.assertEqual(self.lines("systemctl stop"), [])
        self.assertFalse(self.import_dir.exists())
        self.assertIn("importação de %s solicitada e ainda não executada" % PKG, out)

    def test_check_acusa_arquivo_ruim(self):
        (self.pkgdir / (PKG + ".sha256")).write_text("%s  %s\n" % ("1" * 64, PKG))
        antes = fingerprint(self.root)
        p, out = self.run_inst("--check", "--importar", str(self.pkg))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("[falta] pacote: o sha256 NÃO confere", out)
        self.assertEqual(fingerprint(self.root), antes)

    def test_check_sem_sha256_so_avisa(self):
        (self.pkgdir / (PKG + ".sha256")).unlink()
        p, out = self.run_inst("--check", "--importar", str(self.pkg))
        self.assertIn("[aviso] pacote: sem", out)
        self.assertIn("--sem-sha256", out)

    def test_check_com_homologacao_avisa(self):
        p, out = self.run_inst("--check", "--importar", str(self.pkg), "--homologacao")
        self.assertIn("modo HOMOLOGAÇÃO", out)

    def test_check_aceita_homologacao_painel_e_forcar(self):
        p, out = self.run_inst("--check", "--importar", str(self.pkg), "--painel-hostname", "x.example.com",
                               "--forcar-importacao", "--sem-sha256")
        self.assertIn("nome do painel pedido para o destino: x.example.com", out)

    def test_check_depois_da_importacao_mostra_manutencao_ligada_sem_alterar(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        antes = fingerprint(self.root)
        p, out = self.run_inst("--check")
        self.assertEqual(fingerprint(self.root), antes)
        self.assertIn("importação feita: %s" % PKG, out)
        self.assertIn("manutenção do produto LIGADA", out)
        self.set_state("manut_on", "")
        (self.state / "manut_on").unlink()
        p, out = self.run_inst("--check")
        self.assertIn("manutenção do produto desligada", out)

    def test_check_avisa_destino_com_dados(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        (self.nb / "backups").mkdir()
        (self.nb / "backups" / "a.cfg").write_text("x")
        p, out = self.run_inst("--check", "--importar", str(self.pkg))
        self.assertIn("[falta] destino com dados", out)
        p, out = self.run_inst("--check", "--importar", str(self.pkg), "--forcar-importacao")
        self.assertIn("[aviso] destino com dados", out)

    def test_status_lista_a_etapa(self):
        p, out = self.run_inst("--status")
        self.assertEqual(p.returncode, 0)
        self.assertIn("Importação do pacote do sistema", out)


class TestResumoERelatorio(BaseImp):
    def test_resumo_mostra_importacao_homologacao_nome_e_senha_temporaria(self):
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        resumo = out[out.index("Resumo das respostas"):out.index("respostas lidas") if "respostas lidas" in out else None]
        for txt in ("Importação ............: %s" % PKG, "Homologação ...........: não",
                    "Nome do painel no produto: o do pacote",
                    "TEMPORÁRIA (o banco será trocado pelo do pacote)"):
            self.assertIn(txt, out)
        self.assertNotIn("será pedida pelo deploy.sh, digitada no terminal", out)

    def test_resumo_com_homologacao_e_nome(self):
        p, out = self.imp("--homologacao")
        self.assertIn("Homologação ...........: sim", out)
        self.assertIn("Nome do painel no produto: netbackup.example.com:44318 (homologação: automático", out)
        self.setUp()
        p, out = self.imp("--painel-hostname", "x.example.com:8443")
        self.assertIn("Nome do painel no produto: x.example.com:8443 (--painel-hostname)", out)

    def test_resumo_sem_importacao_nao_muda(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("Importação ............:", out)
        self.assertIn("Senha do administrador : será pedida pelo deploy.sh, digitada no terminal (nunca gravada).", out)
        self.assertNotIn("TEMPORÁRIA", out)

    def test_proximos_passos_com_importacao(self):
        p, out = self.imp()
        rel = self.report.read_text()
        prox = rel[rel.index("PRÓXIMOS PASSOS"):]
        for txt in ("1. Abra o endereço de acesso acima e entre com um usuário do servidor de origem",
                    "2. Siga o CHECKLIST DO DESTINO", "3. Libere a manutenção do produto",
                    "4. Em homologação, encerre quando for o caso", "5. Confira a tela Firewall", "Aplicar regras faltantes"):
            self.assertIn(txt, prox)
        self.assertNotIn("Cadastre os equipamentos", prox)
        self.assertNotIn("nenhum vem ligado", prox)

    def test_proximos_passos_sem_importacao_nao_mudam(self):
        p, out = self.run_full()
        rel = self.report.read_text()
        self.assertIn("2. No painel, ligue os módulos opcionais", rel)
        self.assertIn("nenhum vem ligado", rel)
        self.assertIn("3. Cadastre os equipamentos", rel)
        self.assertIn("4. Confira a tela Firewall do painel (as regras criadas aqui aparecem lá)", rel)


class TestAdminTemporarioEsperado(BaseImp):
    def test_um_usuario_e_o_admin_do_deploy_e_esperado(self):
        self.set_state("dest_dados", "AVISO: o destino JÁ tem dados (1 usuário(s), 0 equipamento(s))")
        p, out = self.imp()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(out.count("(esperado: é o admin temporário criado pelo deploy agora há pouco)"), 1)
        self.assertLess(out.index("JÁ tem dados"), out.index("(esperado:"))
        self.assertLess(out.index("(esperado:"), out.index("importar --check terminou"))

    def test_mais_de_um_usuario_nao_e_esperado(self):
        self.set_state("dest_dados", "AVISO: o destino JÁ tem dados (3 usuário(s), 0 equipamento(s))")
        p, out = self.imp()
        self.assertNotIn("(esperado:", out)

    def test_sem_aviso_da_ferramenta_nao_imprime(self):
        p, out = self.imp()
        self.assertNotIn("(esperado:", out)

    def test_admin_nao_criado_pelo_instalador_nao_e_esperado(self):
        self.set_state("dest_dados", "AVISO: o destino JÁ tem dados (1 usuário(s), 0 equipamento(s))")
        self.set_state("deploy_sem_tty")   # ADMIN=pendente: o deploy não criou admin
        p, out = self.imp()
        self.assertNotIn("(esperado:", out)


class TestCodigoDesatualizado(Base3b):
    def setUp(self):
        super().setUp()
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config"
        f = self.bin / "git"
        f.write_text('#!/bin/sh\necho "git $*" >> "$FAKE_CALLS"\n' + GIT_CODIGO + FAKES["git"] + "\n")
        f.chmod(0o755)
        self.prepare_nb()
        self.set_state("git_local", LOCAL_H)
        self.set_state("git_remote", REMOTO_H)
        self.set_state("git_rel", "atras")

    def merges(self):
        return [l for l in self.calls_text().splitlines() if l.startswith("git") and " merge " in l]

    def test_em_dia(self):
        self.set_state("git_remote", LOCAL_H)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("código em dia (local aaaaaaa = remoto aaaaaaa)", out)
        self.assertNotIn("Atualizar para", out)
        self.assertEqual(self.merges(), [])

    def test_atras_com_fast_forward_pergunta_e_atualiza(self):
        p, out = self.run_full(stdin="\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("local aaaaaaa, remoto bbbbbbb", out)
        self.assertIn("Atualizar para bbbbbbb? [S/n]", out)
        self.assertEqual(len(self.merges()), 1)
        self.assertIn("merge --ff-only FETCH_HEAD", self.merges()[0])
        self.assertIn("código atualizado", out)
        self.assertIn("== 6. Configuração", out)
        self.assertEqual((self.state / "git_local").read_text(), REMOTO_H)

    def test_atras_resposta_sim_explicita(self):
        p, out = self.run_full(stdin="s\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(len(self.merges()), 1)

    def test_atras_recusando_para_antes_da_config(self):
        p, out = self.run_full(stdin="n\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("atualização foi recusada", out)
        self.assertEqual(self.merges(), [])
        self.assertNotIn("== 6. Configuração", out)
        self.assertFalse(self.conf.exists() and (self.conf / "app_settings.conf").exists())

    def test_atras_sem_resposta_para(self):
        p, out = self.run_full(stdin="")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.merges(), [])
        self.assertNotIn("== 6. Configuração", out)

    def test_divergente_recusa_com_instrucao_antes_da_config(self):
        self.set_state("git_rel", "divergente")
        p, out = self.run_full(stdin="\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("DIVERGIRAM", out)
        self.assertIn("git -C %s" % self.nb, out)
        self.assertNotIn("Atualizar para", out)
        self.assertEqual(self.merges(), [])
        self.assertNotIn("== 6. Configuração", out)

    def test_alteracao_local_recusa_antes_da_config(self):
        self.set_state("git_sujo")
        p, out = self.run_full(stdin="\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("alterações locais", out)
        self.assertIn("app_settings.conf.example", out)
        self.assertIn("stash", out)
        self.assertNotIn("Atualizar para", out)
        self.assertEqual(self.merges(), [])
        self.assertNotIn("== 6. Configuração", out)

    def test_alteracao_local_com_clone_em_dia_nao_atrapalha(self):
        self.set_state("git_sujo")
        self.set_state("git_remote", LOCAL_H)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)

    def test_local_a_frente_so_avisa(self):
        self.set_state("git_rel", "adiantado")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("À FRENTE", out)
        self.assertEqual(self.merges(), [])

    def test_fetch_que_falha_so_avisa(self):
        self.set_state("git_fetch_fail")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("não foi possível comparar", out)

    def test_check_apenas_informa_sem_escrever(self):
        antes = fp(self.nb)
        p, out = self.run_inst("--check")
        self.assertIn("[falta] código DESATUALIZADO: local aaaaaaa, remoto bbbbbbb", out)
        self.assertEqual(fp(self.nb), antes)
        calls = self.calls_text()
        self.assertNotIn(" fetch ", calls)
        self.assertEqual(self.merges(), [])
        self.assertIn("ls-remote origin refs/heads/main", calls)

    def test_check_em_dia(self):
        self.set_state("git_remote", LOCAL_H)
        p, out = self.run_inst("--check")
        self.assertIn("[ok] código em dia com origin/main (aaaaaaa)", out)

    def test_check_objeto_remoto_desconhecido_e_desatualizado(self):
        self.set_state("git_remote_unknown")
        p, out = self.run_inst("--check")
        self.assertIn("[falta] código DESATUALIZADO", out)

    def test_check_divergente_e_a_frente(self):
        self.set_state("git_rel", "divergente")
        p, out = self.run_inst("--check")
        self.assertIn("[falta] código local (aaaaaaa) DIVERGE", out)
        self.set_state("git_rel", "adiantado")
        p, out = self.run_inst("--check")
        self.assertIn("[aviso] código local (aaaaaaa) à frente", out)

    def test_status_nao_consulta_a_rede(self):
        p, out = self.run_inst("--status")
        self.assertNotIn("ls-remote origin", self.calls_text())


class TestInterrompida(BaseImp):
    def test_check_marca_importacao_interrompida(self):
        self.set_state("pacote_real_rc", "7")
        self.imp()
        p, out = self.run_inst("--check")
        self.assertIn("[falta] importação de %s INTERROMPIDA" % PKG, out)


RESPOSTAS_BASE = """DOMINIO=netbackup.example.com
EMAIL_LETSENCRYPT=admin@example.com
REDES_PAINEL=203.0.113.50/32  Administração
FUSO=America/Manaus
"""

if __name__ == "__main__":
    unittest.main()
