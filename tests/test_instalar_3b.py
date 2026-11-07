"""Testes da Fase 3b do instalar.sh: perguntas, config, deploy, HTTPS, firewall, relatório.

Raiz falsa e comandos falsos (openssl, certbot, nginx, dig, ufw, systemctl, ip, who, ss, curl, stat...);
nada toca o sistema real. Exemplos: RFC 5737/3849 e example.com.
"""
import datetime
import os
import re
import subprocess
import unittest
from pathlib import Path

import test_instalar as t
from test_instalar import Base, fingerprint, setUpModule, tearDownModule  # noqa: F401  (setUp/tearDown do módulo)

RESP_PADRAO = """# respostas de teste
DOMINIO=netbackup.example.com
EMAIL_LETSENCRYPT=admin@example.com
REDES_PAINEL=203.0.113.50/32  Administração
REDES_PAINEL=198.51.100.0/24  Escritório
REDES_PUBLICAS=192.0.2.0/24  Provedor
REDES_PRIVADAS=10.20.0.0/16  LAN
FUSO=America/Manaus
"""


class Base3b(Base):
    def setUp(self):
        super().setUp()
        self.extra_env.pop("ETAPAS_LISTA")
        self.resp = self.root / "rootdir" / "entrada.conf"
        self.set_resp(RESP_PADRAO)
        self.set_state("dig_A", "203.0.113.10\n")
        self.conf = self.nb / "config"
        self.site = self.sites_av / "netbackup"
        self.link = self.sites_en / "netbackup"
        self.estado = self.estado_dir / "estado.conf"
        self.saved = self.log_dir / "netbackup-respostas.conf"
        self.report = self.log_dir / "netbackup-instalacao.txt"

    def set_resp(self, texto, modo=0o600):
        self.resp.write_text(texto)
        self.resp.chmod(modo)

    def run_full(self, *extra, stdin="", resp=True):
        args = (["--respostas", str(self.resp)] if resp else []) + list(extra)
        return self.run_inst(*args, stdin=stdin)

    def estado_val(self, chave):
        if not self.estado.exists():
            return ""
        m = re.search(r"^%s=(.*)$" % chave, self.estado.read_text(), re.M)
        return m.group(1) if m else ""

    def ufw_rules(self):
        f = self.state / "ufw_rules"
        return f.read_text() if f.exists() else ""

    def tree_fp(self, *paths):
        return [fingerprint(p) for p in paths if Path(p).exists()]



def fp(raiz):
    """Impressão digital de uma árvore (modo e conteúdo), sem mtime de pasta e sem o log da execução."""
    out = []
    for p in sorted(Path(raiz).rglob("*")):
        if "netbackup-instalacao-" in p.name:
            continue
        if p.is_symlink():
            out.append((str(p), "L", os.readlink(p)))
        elif p.is_dir():
            out.append((str(p), "D", p.lstat().st_mode))
        else:
            out.append((str(p), "F", p.lstat().st_mode, p.read_bytes()))
    return out


class TestFluxoCompleto(Base3b):
    def test_fluxo_dns_ok_definitivo(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "1")
        self.assertTrue(self.site.exists())
        self.assertIn("server_name netbackup.example.com;", self.site.read_text())
        self.assertNotIn("@SERVER_NAME@", self.site.read_text())
        self.assertNotIn("PROVISORIO", self.site.read_text())
        self.assertTrue(self.link.is_symlink())
        self.assertIn("44318/tcp", self.ufw_rules())
        self.assertIn("https://netbackup.example.com:44318", self.report.read_text())
        self.assertIn("Acesse https://netbackup.example.com:44318", out)

    def test_ordem_das_etapas(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        ordem = ["== 1. Pré", "== 2. Perguntas", "== 3. Disco", "== 4. Chave", "== 5. Código",
                 "== 6. Configuração", "== 7. Deploy", "== 8. HTTPS", "== 9. Firewall", "== 10. Relatório"]
        pos = [out.index(x) for x in ordem]
        self.assertEqual(pos, sorted(pos))

    def test_toda_pergunta_vem_antes_de_qualquer_alteracao(self):
        # entrada interativa: nada de disco/chave/clone antes da confirmação final
        stdin = "netbackup.example.com\nadmin@example.com\n203.0.113.50/32 Administração\n\n\n\n\n\nN\n"
        antes = fp(self.root)
        p, out = self.run_inst(stdin=stdin)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cancelada", out)
        self.assertEqual(fp(self.root), antes)
        for c in ("lsblk -nr", "ssh-keygen", "git clone", "pvcreate", "ufw allow", "certbot", "nginx"):
            self.assertEqual(self.ncalls(c), 0, c)
        self.assertFalse(self.saved.exists())

    def test_interativo_completo_grava_respostas_600(self):
        stdin = "netbackup.example.com\nadmin@example.com\n203.0.113.50/32 Administração\n\n\n\n\n\ns\n"
        p, out = self.run_inst(stdin=stdin)
        self.assertEqual(p.returncode, 0, out)
        txt = self.saved.read_text()
        self.assertIn("DOMINIO=netbackup.example.com", txt)
        self.assertIn("EMAIL_LETSENCRYPT=admin@example.com", txt)
        self.assertIn("REDES_PAINEL=203.0.113.50/32  Administração", txt)
        self.assertIn("FUSO=America/Sao_Paulo", txt)
        self.assertIn("PORTA_SSH=22", txt)
        self.assertEqual(oct(self.saved.stat().st_mode & 0o777), "0o600")
        self.assertIn("Resumo das respostas", out)
        self.assertIn("deploy.sh, digitada no terminal", out)   # senha do admin não é pergunta

    def test_senha_do_admin_nao_e_pergunta_nem_gravada(self):
        p, out = self.run_full()
        self.assertNotIn("senha", self.saved.read_text().lower().replace("sem segredos", "").replace("não fica aqui", "").replace("a senha do administrador", ""))
        self.assertNotRegex(out, r"(?i)digite a senha")


class TestValidacoesDasRespostas(Base3b):
    """Cada valor inválido para a instalação ANTES de qualquer alteração."""

    def assert_recusa(self, texto, esperado):
        self.set_resp(texto)
        self.calls.write_text("")
        antes = fp(self.root)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0, out)
        self.assertIn(esperado, out)
        self.assertIn("Nada foi alterado", out)
        self.assertEqual(fp(self.root), antes, "a máquina foi alterada")
        for c in ("lsblk -nr", "ssh-keygen", "git clone", "pvcreate", "ufw allow", "certbot", "deploy-run"):
            self.assertEqual(self.ncalls(c), 0, c)
        self.assertFalse(self.saved.exists())

    def com(self, linhas):
        base = [l for l in RESP_PADRAO.splitlines()]
        return "\n".join(base + linhas) + "\n"

    def sem(self, chave_prefixo):
        return "\n".join(l for l in RESP_PADRAO.splitlines() if not l.startswith(chave_prefixo)) + "\n"

    def troca(self, chave, valor):
        out = []
        for l in RESP_PADRAO.splitlines():
            out.append("%s=%s" % (chave, valor) if l.startswith(chave + "=") else l)
        return "\n".join(out) + "\n"

    def test_dominios_invalidos(self):
        for d in ("*.example.com", "http://netbackup.example.com", "netbackup.example.com:44318",
                  "192.0.2.10", "semponto", "-a.example.com", "a..example.com", "nome com espaco.example.com",
                  "netbackup.example.com/"):
            with self.subTest(dominio=d):
                self.assert_recusa(self.troca("DOMINIO", d), "DOMINIO inválido")

    def test_dominio_maiusculo_e_normalizado(self):
        self.set_resp(self.troca("DOMINIO", "NetBackup.Example.COM"))
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("DOMINIO=netbackup.example.com", self.saved.read_text())

    def test_emails_invalidos(self):
        for e in ("semarroba", "-x@example.com", "a@b", "a b@example.com", "a@example..com", "@example.com"):
            with self.subTest(email=e):
                self.assert_recusa(self.troca("EMAIL_LETSENCRYPT", e), "EMAIL_LETSENCRYPT inválido")

    def test_redes_do_painel_invalidas(self):
        casos = {
            "203.0.113.10/33": "prefixo",
            "203.0.113.5/24": "bits de host",
            "203.0.113.0/7": "fora do aceito",
            "999.1.1.1/32": "inválido",
            "2001:db8::/32": "rede inválida",
            "127.0.0.1/32": "endereço local",
            "010.0.0.1/32": "inválido",
            "203.0.113.10/032": "rede inválida",
            "abc": "rede inválida",
        }
        for rede, msg in casos.items():
            with self.subTest(rede=rede):
                self.assert_recusa(self.com(["REDES_PAINEL=" + rede]), msg)

    def test_rede_com_descricao_de_controle_ou_longa(self):
        self.assert_recusa(self.com(["REDES_PAINEL=203.0.113.9/32 " + "x" * 101]), "passa de 100")

    def test_redes_privadas_so_privadas(self):
        for rede in ("203.0.113.0/24", "100.64.0.0/10", "172.32.0.0/16", "11.0.0.0/8"):
            with self.subTest(rede=rede):
                self.assert_recusa(self.com(["REDES_PRIVADAS=" + rede]), "não é rede privada")

    def test_redes_privadas_validas_e_ip_simples(self):
        self.set_resp(self.com(["REDES_PRIVADAS=172.16.0.0/12 docker", "REDES_PRIVADAS=192.168.7.7",
                                "REDES_PRIVADAS=127.0.0.0/8", "REDES_PAINEL=10.0.0.0/8 tudo"]))
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        txt = self.saved.read_text()
        self.assertIn("REDES_PRIVADAS=172.16.0.0/12  docker", txt)
        self.assertIn("REDES_PRIVADAS=192.168.7.7/32", txt)
        self.assertIn("REDES_PAINEL=10.0.0.0/8  tudo", txt)

    def test_fusos_invalidos(self):
        for z in ("Mars/Olympus", "../etc/passwd", "posix/UTC", "America", "America/", "UTC;rm", "a b"):
            with self.subTest(fuso=z):
                self.assert_recusa(self.troca("FUSO", z), "FUSO")

    def test_fuso_ausente_usa_o_do_servidor(self):
        self.set_state("timezone", "America/Manaus\n")
        self.set_resp(self.sem("FUSO="))
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("FUSO=America/Manaus", self.saved.read_text())
        self.assertIn("TIMEZONE=America/Manaus", (self.conf / "app_settings.conf").read_text())

    def test_portas_invalidas(self):
        for v in ("0", "70000", "abc", "-1", "08", "2 2"):
            with self.subTest(porta=v):
                self.assert_recusa(self.com(["PORTA_SSH=" + v]), "PORTA_SSH inválida")

    def test_faltas_obrigatorias(self):
        self.assert_recusa(self.sem("DOMINIO="), "falta DOMINIO")
        self.assert_recusa(self.sem("EMAIL_LETSENCRYPT="), "falta EMAIL_LETSENCRYPT")
        self.assert_recusa(self.sem("REDES_PAINEL="), "falta ao menos uma REDES_PAINEL")

    def test_chave_desconhecida_linha_sem_igual_e_repeticao(self):
        self.assert_recusa(self.com(["SENHA_ADMIN=x"]), "chave desconhecida")
        self.assert_recusa(self.com(["isto nao e uma linha"]), "esperado CHAVE=valor")
        self.assert_recusa(self.com(["DOMINIO=outro.example.com"]), "DOMINIO repetido")

    def test_varios_erros_sao_todos_listados(self):
        self.assert_recusa(self.com(["PORTA_SSH=0", "FUSO=Mars/Olympus"]), "PORTA_SSH inválida")

    def test_arquivo_inexistente(self):
        antes = fp(self.root)
        p, out = self.run_inst("--respostas", str(self.root / "rootdir" / "nao-existe.conf"))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não encontrado", out)
        self.assertEqual(fp(self.root), antes)

    def test_arquivo_com_escrita_de_outros_nao_e_confiavel(self):
        self.set_resp(RESP_PADRAO, modo=0o666)
        antes = fp(self.root)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não confiável", out)
        self.assertEqual(fp(self.root), antes)
        self.assertEqual(self.ncalls("deploy-run"), 0)

    def test_arquivo_link_simbolico_recusado(self):
        alvo = self.root / "rootdir" / "alvo.conf"
        alvo.write_text(RESP_PADRAO)
        alvo.chmod(0o600)
        self.resp.unlink()
        self.resp.symlink_to(alvo)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_respostas_nao_se_combina_com_check(self):
        p, out = self.run_inst("--respostas", str(self.resp), "--check")
        self.assertEqual(p.returncode, 2)
        p, out = self.run_inst("--respostas")
        self.assertEqual(p.returncode, 2)

    def test_respostas_validas_nao_pedem_nada_e_gravam_o_arquivo_salvo(self):
        p, out = self.run_full(stdin="")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("Confirma estas respostas", out)
        self.assertEqual(oct(self.saved.stat().st_mode & 0o777), "0o600")


class TestPerguntasInterativas(Base3b):
    def dados(self, **kw):
        return dict(dom="netbackup.example.com\n", email="admin@example.com\n", **kw)

    def test_sugere_o_ip_de_quem_esta_no_ssh(self):
        self.set_state("who_m", "ubuntu  pts/0  2026-11-07 10:00 (203.0.113.77)\n")
        stdin = "netbackup.example.com\nadmin@example.com\n\n\n\n\n\n\ns\n"
        p, out = self.run_inst(stdin=stdin)
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("[Enter = 203.0.113.77/32", out)
        self.assertIn("REDES_PAINEL=203.0.113.77/32", self.saved.read_text())

    def test_sem_descobrir_nao_ha_sugestao_e_a_rede_e_obrigatoria(self):
        stdin = "netbackup.example.com\nadmin@example.com\n\n\n\n"
        p, out = self.run_inst(stdin=stdin)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("[Enter =", out)
        self.assertIn("ao menos uma rede é obrigatória", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_origem_que_nao_e_ipv4_nao_vira_sugestao(self):
        for linha in ("ubuntu pts/0 2026-11-07 10:00 (host.example.com)\n", "ubuntu :0 2026-11-07 10:00 (:0)\n",
                      "ubuntu pts/0 2026-11-07 10:00 (2001:db8::5)\n"):
            with self.subTest(linha=linha):
                self.set_state("who_m", linha)
                p, out = self.run_inst(stdin="netbackup.example.com\nadmin@example.com\n\n\n\n")
                self.assertNotIn("[Enter =", out)

    def test_ssh_client_so_vale_como_ultimo_recurso(self):
        self.extra_env["SSH_CLIENT"] = "203.0.113.88 50000 22"
        p, out = self.run_inst(stdin="netbackup.example.com\nadmin@example.com\n\n\n\n\n\n\ns\n")
        self.assertIn("[Enter = 203.0.113.88/32", out)

    def test_valor_invalido_pergunta_de_novo_e_desiste_na_terceira(self):
        p, out = self.run_inst(stdin="http://x\n*.example.com\nfoo\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("nome inválido", out)
        self.assertIn("Nada foi alterado", out)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_portas_nao_oficiais_pedem_cada_uma(self):
        stdin = ("netbackup.example.com\nadmin@example.com\n203.0.113.50/32\n\n\n\n\nn\n"
                 "2222\n\n8080\n\ns\n")
        p, out = self.run_inst(stdin=stdin)
        self.assertEqual(p.returncode, 0, out)
        txt = self.saved.read_text()
        self.assertIn("PORTA_SSH=2222", txt)
        self.assertIn("PORTA_HTTPS=443", txt)
        self.assertIn("PORTA_HTTP=8080", txt)
        self.assertIn("PORTA_WINBOX=8291", txt)
        cfg = (self.conf / "app_settings.conf").read_text()
        self.assertIn("\nDEFAULT_PORT_SSH=2222\n", cfg)
        self.assertIn("\nDEFAULT_PORT_HTTP=8080\n", cfg)
        self.assertIn("\n# DEFAULT_PORT_HTTPS=443\n", cfg)      # igual ao padrão: não é aplicado
        self.assertIn("\n# DEFAULT_PORT_WINBOX=8291\n", cfg)

    def test_reaproveita_respostas_gravadas(self):
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        p, out = self.run_inst(stdin="\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("Usar as respostas gravadas", out)
        self.assertNotIn("Nome do painel", out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_recusar_as_gravadas_pergunta_tudo_de_novo(self):
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        stdin = "n\nnovo.example.com\nadmin@example.com\n203.0.113.60/32\n\n\n\n\n\ns\n"
        self.set_state("dig_A", "203.0.113.10\n")
        p, out = self.run_inst(stdin=stdin)
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("DOMINIO=novo.example.com", self.saved.read_text())

    def test_gravadas_invalidas_sao_perguntadas_de_novo(self):
        self.saved.write_text("DOMINIO=*.example.com\n")
        self.saved.chmod(0o600)
        stdin = "netbackup.example.com\nadmin@example.com\n203.0.113.60/32\n\n\n\n\n\ns\n"
        p, out = self.run_inst(stdin=stdin)
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("inválidas", out)

    def test_entrada_encerrada_nao_altera_nada(self):
        antes = fp(self.root)
        p, out = self.run_inst(stdin="netbackup.example.com\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(fp(self.root), antes)


class TestConfig(Base3b):
    def test_cria_arquivos_a_partir_dos_modelos_com_as_respostas(self):
        self.set_resp(RESP_PADRAO + "PORTA_SSH=2222\n")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        app = (self.conf / "app_settings.conf").read_text()
        self.assertIn("\nTIMEZONE=America/Manaus\n", app)
        self.assertIn("\nPANEL_HOSTNAME=netbackup.example.com:44318\n", app)
        self.assertIn("\nDEFAULT_PORT_SSH=2222\n", app)
        self.assertIn("\n# DEFAULT_PORT_HTTPS=443\n", app)
        self.assertIn("APP_SECRET_KEY=" + t.SECRET_KEY, app)
        self.assertNotIn("ALTERE_AQUI", app)
        self.assertEqual(oct((self.conf / "app_settings.conf").stat().st_mode & 0o777), "0o600")
        panel = (self.conf / "trusted_panel_networks.conf").read_text()
        self.assertIn("\n203.0.113.50/32  Administração\n", panel)
        self.assertIn("\n198.51.100.0/24  Escritório\n", panel)
        self.assertTrue(panel.startswith("# Redes do painel - modelo."))     # o modelo é preservado
        self.assertIn("\n192.0.2.0/24  Provedor\n", (self.conf / "trusted_public_networks.conf").read_text())
        priv = (self.conf / "trusted_private_networks.conf").read_text()
        self.assertIn("\n127.0.0.1/32  túnel SSH local\n", priv)          # linha ativa do modelo continua
        self.assertIn("\n10.20.0.0/16  LAN\n", priv)
        for n in ("trusted_panel_networks.conf", "trusted_public_networks.conf", "trusted_private_networks.conf"):
            self.assertEqual(oct((self.conf / n).stat().st_mode & 0o777), "0o644", n)
        # só os arquivos que o instalador precisa; o resto o deploy.sh cria dos modelos
        self.assertEqual(sorted(x.name for x in self.conf.iterdir() if not x.name.endswith(".example")),
                         ["app_settings.conf", "trusted_panel_networks.conf",
                          "trusted_private_networks.conf", "trusted_public_networks.conf"])

    def test_chave_secreta_nao_vai_para_saida_log_nem_respostas(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn(t.SECRET_KEY, out)
        for lg in self.logs():
            self.assertNotIn(t.SECRET_KEY, lg.read_text())
        self.assertNotIn(t.SECRET_KEY, self.saved.read_text())
        self.assertNotIn(t.SECRET_KEY, self.report.read_text())
        self.assertNotIn(t.SECRET_KEY, self.estado.read_text())

    def test_copia_do_modelo_do_nginx_so_do_root_com_sha256(self):
        import hashlib
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        copia = self.share / "netbackup.conf.template"
        self.assertEqual(copia.read_text(), t.NGINX_TEMPLATE)
        self.assertEqual(oct(self.share.stat().st_mode & 0o777), "0o755")
        self.assertEqual(oct(copia.stat().st_mode & 0o777), "0o644")
        soma = hashlib.sha256(copia.read_bytes()).hexdigest()
        self.assertEqual((self.share / "netbackup.conf.template.sha256").read_text(),
                         "%s  netbackup.conf.template\n" % soma)
        self.assertEqual(self.estado_val("TEMPLATE_SHA256"), soma)

    def test_idempotente_antes_do_deploy(self):
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config"
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(out.count("já está como as respostas pedem"), 4)
        self.assertEqual(fp(self.nb), antes)

    def test_arquivo_de_redes_diferente_nao_e_sobrescrito_no_modo_respostas(self):
        self.prepare_nb()
        alvo = self.conf / "trusted_panel_networks.conf"
        alvo.write_text("# meu arquivo\n192.0.2.77/32  Outro\n")
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("difere das respostas", out)
        self.assertIn("modo --respostas não decide por você", out)
        self.assertIn("192.0.2.77/32  Outro", out)               # mostra o que existe
        self.assertEqual(alvo.read_text(), "# meu arquivo\n192.0.2.77/32  Outro\n")
        self.assertEqual(self.ncalls("deploy-run"), 0)
        self.assertEqual(self.ncalls("ufw allow"), 0)
        self.assertEqual([x for x in fp(self.nb) if "trusted_panel" in x[0]],
                         [x for x in antes if "trusted_panel" in x[0]])

    def test_decisao_manter_nao_altera_e_registra_pendencia(self):
        self.prepare_nb()
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        alvo = self.conf / "trusted_panel_networks.conf"
        alvo.write_text("# meu arquivo\n192.0.2.77/32  Outro\n")
        p, out = self.run_inst(stdin="\nmanter\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(alvo.read_text(), "# meu arquivo\n192.0.2.77/32  Outro\n")
        self.assertIn("mantido como está", out)
        self.assertIn("trusted_panel_networks.conf", self.report.read_text())
        self.assertEqual(self.estado_val("CONFIG_MANTIDOS"), "trusted_panel_networks.conf")

    def test_decisao_substituir_guarda_copia(self):
        self.prepare_nb()
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        alvo = self.conf / "trusted_panel_networks.conf"
        alvo.write_text("# meu arquivo\n192.0.2.77/32  Outro\n")
        p, out = self.run_inst(stdin="\nsubstituir\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("203.0.113.50/32  Administração", alvo.read_text())
        self.assertNotIn("192.0.2.77", alvo.read_text())
        baks = list(self.log_dir.glob("netbackup-config-anterior-*/trusted_panel_networks.conf"))
        self.assertEqual(len(baks), 1)
        self.assertEqual(baks[0].read_text(), "# meu arquivo\n192.0.2.77/32  Outro\n")
        self.assertEqual(oct(baks[0].parent.stat().st_mode & 0o777), "0o700")

    def test_qualquer_outra_resposta_para_a_instalacao(self):
        self.prepare_nb()
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        alvo = self.conf / "trusted_panel_networks.conf"
        alvo.write_text("192.0.2.77/32  Outro\n")
        p, out = self.run_inst(stdin="\nparar\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(alvo.read_text(), "192.0.2.77/32  Outro\n")
        self.assertEqual(self.ncalls("deploy-run"), 0)

    def test_app_settings_existente_so_mostra_as_chaves_das_respostas(self):
        self.prepare_nb()
        alvo = self.conf / "app_settings.conf"
        original = "APP_SECRET_KEY=SEGREDO-EXISTENTE-123\nTIMEZONE=UTC\nOUTRA=coisa\n"
        alvo.write_text(original)
        alvo.chmod(0o600)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("TIMEZONE: atual='UTC' desejado='America/Manaus'", out)
        self.assertIn("PANEL_HOSTNAME", out)
        self.assertNotIn("SEGREDO-EXISTENTE-123", out)             # o segredo nunca é mostrado
        for lg in self.logs():
            self.assertNotIn("SEGREDO-EXISTENTE-123", lg.read_text())
        self.assertEqual(alvo.read_text(), original)

    def test_app_settings_substituir_so_as_chaves_e_guarda_copia_600(self):
        self.prepare_nb()
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        alvo = self.conf / "app_settings.conf"
        alvo.write_text("APP_SECRET_KEY=SEGREDO-EXISTENTE-123\nTIMEZONE=UTC\nOUTRA=coisa\n")
        alvo.chmod(0o600)
        p, out = self.run_inst(stdin="\nsubstituir\n")
        self.assertEqual(p.returncode, 0, out)
        novo = alvo.read_text()
        self.assertIn("APP_SECRET_KEY=SEGREDO-EXISTENTE-123", novo)   # chave secreta intocada
        self.assertIn("OUTRA=coisa", novo)
        self.assertIn("TIMEZONE=America/Manaus", novo)
        self.assertNotIn("TIMEZONE=UTC", novo)
        self.assertIn("PANEL_HOSTNAME=netbackup.example.com:44318", novo)
        bak = list(self.log_dir.glob("netbackup-config-anterior-*/app_settings.conf"))
        self.assertEqual(len(bak), 1)
        self.assertEqual(oct(bak[0].stat().st_mode & 0o777), "0o600")
        self.assertNotIn("SEGREDO-EXISTENTE-123", out)

    def test_link_simbolico_no_lugar_do_arquivo_e_recusado(self):
        self.prepare_nb()
        alvo = self.conf / "trusted_private_networks.conf"
        alvo.symlink_to(self.sb / "fora.conf")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("link simbólico", out)
        self.assertFalse((self.sb / "fora.conf").exists())

    def test_modelo_gravavel_por_outros_e_recusado(self):
        self.prepare_nb()
        (self.conf / "app_settings.conf.example").chmod(0o666)
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertEqual(fp(self.nb), antes)

    def test_pasta_config_gravavel_por_outros_nao_recebe_escrita_do_root(self):
        self.prepare_nb()
        self.conf.chmod(0o777)
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertEqual(fp(self.nb), antes)
        self.assertEqual(self.ncalls("deploy-run"), 0)

    def test_openssl_com_chave_estranha_para(self):
        self.prepare_nb()
        (self.bin / "openssl").write_text('#!/bin/sh\necho "openssl $*" >> "$FAKE_CALLS"\necho curta\n')
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("openssl rand", out)
        self.assertFalse((self.conf / "app_settings.conf").exists())


class TestDeploy(Base3b):
    def test_executa_deploy_com_dominio_e_marca_feito(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("deploy-dominio netbackup.example.com", self.calls_text())
        self.assertEqual(self.ncalls("deploy-dominio"), 1)
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "1")
        self.assertEqual(self.estado_val("ADMIN"), "criado")
        self.assertEqual(oct(self.estado.stat().st_mode & 0o777), "0o600")
        self.assertIn("a partir daqui", out)

    def test_saida_do_deploy_vai_ao_log_sem_tee(self):
        p, out = self.run_full()
        log = self.logs()[-1].read_text()
        self.assertIn("primeiro usuário criado", log)
        self.assertIn("[aviso]  site novo", log)

    def test_rodar_de_novo_detecta_deploy_feito_e_nao_executa_nada_do_opt(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        antes = fp(self.nb)
        n_calls = len(self.calls_text().splitlines())
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        novos = self.calls_text().splitlines()[n_calls:]
        self.assertEqual(self.ncalls("deploy-dominio"), 1)
        self.assertEqual(self.ncalls("deploy-run"), 1)
        self.assertIn("deploy feito", out)
        self.assertEqual(fp(self.nb), antes, "o instalador escreveu em /opt/netbackup depois do deploy")
        # nem git nem nenhum outro comando foi apontado para a árvore do produto
        self.assertFalse([l for l in novos if str(self.nb) in l and not l.startswith("stat ")], novos)
        self.assertFalse([l for l in novos if l.startswith("git -C")], novos)

    def test_deploy_com_erro_termina_com_codigo_diferente_de_zero(self):
        self.set_state("deploy_fail")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ERRO: falha simulada do deploy", out)
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "")
        self.assertEqual(self.ncalls("certbot"), 0)          # nada de HTTPS depois de um deploy falho
        self.assertEqual(self.ncalls("ufw allow"), 0)

    def test_linha_erro_com_codigo_zero_tambem_falha(self):
        self.set_state("deploy_erro_rc0")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ERRO: erro com código 0", out)
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "")

    def test_deploy_falho_nao_roda_de_novo_recusa_e_explica(self):
        self.set_state("deploy_fail")
        self.run_full()
        n = self.ncalls("deploy-dominio")
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.ncalls("deploy-dominio"), n)
        self.assertIn("não escreve nem executa nada numa pasta que não é do root", out)
        self.assertIn("deploy.sh --dominio", out)
        self.assertEqual(fp(self.nb), antes)

    def test_deploy_feito_a_mao_e_detectado(self):
        self.prepare_nb()
        self.set_state("nb_owner_netbackup")                 # árvore do netbackup e serviço habilitado
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config deploy"
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("deploy detectado", out)
        self.assertEqual(self.ncalls("deploy-run"), 0)
        self.assertEqual(fp(self.nb), antes)
        self.assertEqual(self.estado_val("DEPLOY_ORIGEM"), "detectado")

    def test_deploy_feito_sem_o_instalador_nao_tem_copia_do_modelo_e_o_https_explica(self):
        self.prepare_nb()
        self.set_state("nb_owner_netbackup")
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cópia do modelo do Nginx", out)
        self.assertIn("ANTES do deploy.sh", out)
        self.assertEqual(self.ncalls("deploy-run"), 0)
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertFalse(self.site.exists())
        self.assertEqual(fp(self.nb), antes)

    def test_arvore_de_outro_dono_sem_sinal_de_deploy_e_recusada_sem_escrita(self):
        self.prepare_nb()
        self.set_state("nb_owner_netbackup")
        self.set_state("unit_off")
        antes = fp(self.nb)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não escreve nem executa nada numa pasta que não é do root", out)
        self.assertEqual(fp(self.nb), antes)
        self.assertEqual(self.ncalls("deploy-run"), 0)
        self.assertEqual(self.ncalls("git clone"), 0)

    def test_root_nao_escreve_na_arvore_do_netbackup_na_config(self):
        # árvore do netbackup + registro de deploy: a config é pulada, sem nenhuma escrita
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        (self.conf / "trusted_panel_networks.conf").chmod(0o644)
        antes = fp(self.nb)
        self.set_resp(RESP_PADRAO.replace("203.0.113.50/32", "203.0.113.99/32"))
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("não é mais tocada", out)
        self.assertEqual(fp(self.nb), antes)

    def test_deploy_com_escrita_de_outros_nao_roda(self):
        self.prepare_nb()
        (self.nb / "deploy" / "deploy.sh").chmod(0o666)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("RECUSADO", out)
        self.assertIn("escrita para grupo/outros", out)
        self.assertEqual(self.ncalls("deploy-run"), 0)
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "")

    def test_deploy_em_pasta_gravavel_nao_roda(self):
        self.prepare_nb()
        (self.nb / "deploy").chmod(0o777)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.ncalls("deploy-run"), 0)

    def test_deploy_link_para_fora_nao_roda(self):
        self.prepare_nb()
        fora = self.sb / "fora.sh"
        fora.write_text("#!/bin/sh\necho x\n")
        (self.nb / "deploy" / "deploy.sh").unlink()
        (self.nb / "deploy" / "deploy.sh").symlink_to(fora)
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("fora de", out)
        self.assertEqual(self.ncalls("deploy-run"), 0)

    def test_sem_terminal_avisa_e_registra_admin_pendente(self):
        self.set_state("deploy_sem_tty")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("sem terminal interativo", out)
        self.assertEqual(self.estado_val("ADMIN"), "pendente")
        self.assertIn("criar o administrador", self.report.read_text())

    def test_admin_ja_existente(self):
        self.set_state("deploy_admin_existente")
        p, out = self.run_full()
        self.assertEqual(self.estado_val("ADMIN"), "existente")
        self.assertNotIn("criar o administrador", self.report.read_text())

    def test_deploy_exige_a_copia_do_modelo(self):
        # sem a etapa de config (lista reduzida) o deploy não roda
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo deploy"
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("cópia do modelo do Nginx", out)
        self.assertEqual(self.ncalls("deploy-run"), 0)


class TestDeployScript(Base3b):
    def test_usa_script_ligado_ao_terminal_sem_log_in(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        linha = [l for l in self.calls_text().splitlines() if l.startswith("script ")]
        self.assertEqual(len(linha), 1)
        self.assertIn("-q -e -f -c", linha[0])
        self.assertIn("--dominio netbackup.example.com", linha[0])
        self.assertNotIn("--log-in", linha[0])
        self.assertNotIn("-I ", linha[0])
        self.assertEqual(self.ncalls("deploy-dominio"), 1)

    def test_aviso_destacado_e_separado_antes_do_deploy(self):
        p, out = self.run_full()
        i = out.index("==================================================================")
        self.assertTrue(out[:i].endswith("\n\n"), repr(out[i - 5:i]))
        self.assertIn("SENHA DO ADMINISTRADOR", out)
        self.assertIn("12 ou mais caracteres, 3 dos 4 tipos", out)
        self.assertIn("Ela não aparece na tela e não é gravada.", out)
        fim = out.index("Ela não aparece na tela e não é gravada.")
        resto = out[fim:]
        self.assertRegex(resto, r"\n=+\n\n")
        self.assertLess(out.index("executando: deploy.sh"), i)
        self.assertLess(fim, out.index("repositório em /opt/netbackup"))

    def test_classifica_a_partir_do_arquivo_e_o_log_fica_limpo(self):
        p, out = self.run_full()
        self.assertEqual(self.estado_val("ADMIN"), "criado")
        self.assertEqual(self.estado_val("DEPLOY_AVISOS"), "1")
        log = self.logs()[-1].read_text()
        self.assertIn("primeiro usuário criado", log)
        self.assertNotIn("\r", log)
        self.assertNotIn("\x1b", log)

    def test_admin_existente_via_arquivo(self):
        self.set_state("deploy_admin_existente")
        self.run_full()
        self.assertEqual(self.estado_val("ADMIN"), "existente")

    def test_erro_no_arquivo_e_codigo_de_saida_propagado(self):
        self.set_state("deploy_fail")
        self.set_state("deploy_fail_rc", "7")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("deploy.sh terminou com código 7", out)
        self.assertIn("ERRO: falha simulada do deploy", self.logs()[-1].read_text())
        self.assertEqual(self.estado_val("DEPLOY_FEITO"), "")

    def test_erro_com_codigo_zero_pelo_arquivo_tambem_falha(self):
        self.set_state("deploy_erro_rc0")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("reportou ERRO", out)

    def test_temporario_apagado_em_sucesso_e_em_falha(self):
        self.run_full()
        self.assertEqual(list(self.estado_dir.glob(".deploy.*")), [])
        self.set_state("deploy_fail")
        self.run_full()
        self.assertEqual(list(self.estado_dir.glob(".deploy.*")), [])

    def test_temporario_fica_em_pasta_700_do_root(self):
        (self.bin / "script").write_text(
            '#!/bin/sh\necho "script $*" >> "$FAKE_CALLS"\nfor f; do :; done\n'
            'stat -c "%a" "$(dirname "$f")" > "$FAKE_STATE/modo_tmp"\n'
            'dirname "$f" > "$FAKE_STATE/dir_tmp"\necho "[feito]  primeiro usuário criado" > "$f"\nexit 0\n')
        self.run_full()
        self.assertEqual((self.state / "modo_tmp").read_text().strip(), "700")
        self.assertTrue((self.state / "dir_tmp").read_text().startswith(str(self.estado_dir)))

    def test_senha_digitada_nunca_aparece_no_log_nem_na_saida_nem_no_relatorio(self):
        self.set_state("deploy_le_senha")
        p, out = self.run_full(stdin="SENHA-DIGITADA-XYZ-123\n")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("SENHA-DIGITADA-XYZ-123", out)
        for lg in self.logs():
            self.assertNotIn("SENHA-DIGITADA-XYZ-123", lg.read_text())
        self.assertNotIn("SENHA-DIGITADA-XYZ-123", self.report.read_text())
        self.assertNotIn("SENHA-DIGITADA-XYZ-123", self.estado.read_text())

    def test_sem_script_usa_o_laco_com_aviso_destacado(self):
        self.extra_env["CMD_SCRIPT"] = "script-que-nao-existe"
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("script(1) (util-linux) ausente", out)
        self.assertIn("SENHA DO ADMINISTRADOR", out)
        self.assertEqual(self.estado_val("ADMIN"), "criado")
        self.assertEqual(self.ncalls("script "), 0)

    def test_sem_script_erro_continua_falhando(self):
        self.extra_env["CMD_SCRIPT"] = "script-que-nao-existe"
        self.set_state("deploy_fail")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ERRO: falha simulada do deploy", out)


class TestDns(Base3b):
    def roda(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        return out

    def assert_provisorio(self, out):
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertEqual(self.ncalls("hook-pre"), 0)
        self.assertEqual(self.site.read_text().splitlines()[0], "# PROVISORIO - gerado por instalar.sh (não editar)")

    def test_a_ok_aaaa_ausente_emite(self):
        out = self.roda()
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")
        self.assertIn("A=203.0.113.10 AAAA=(vazio)", out)
        self.assertEqual(self.ncalls("certbot"), 1)

    def test_a_errado_nao_emite_e_mostra_encontrado_e_esperado(self):
        self.set_state("dig_A", "198.51.100.99\n")
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("Esperado (endereços globais da VM): A=203.0.113.10", out)
        self.assertIn("Encontrado em 1.1.1.1: A=198.51.100.99", out)
        self.assertIn("Encontrado em 8.8.8.8: A=198.51.100.99", out)
        self.assertIn("não é um endereço desta VM", out)

    def test_a_ausente_nao_emite(self):
        self.set_state("dig_A", "")
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("não devolveu registro A", out)

    def test_um_dos_resolvedores_discorda(self):
        self.set_state("dig_8.8.8.8_A", "198.51.100.99\n")
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("Encontrado em 8.8.8.8: A=198.51.100.99", out)

    def test_dois_registros_a_um_deles_errado(self):
        self.set_state("dig_A", "203.0.113.10\n198.51.100.99\n")
        out = self.roda()
        self.assert_provisorio(out)

    def test_aaaa_errado_nao_tenta_emitir(self):
        self.set_state("dig_AAAA", "2001:db8::99\n")
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("AAAA 2001:db8::99", out)
        self.assertIn("não tento emitir", out)
        self.assertIn("prefere IPv6", out)

    def test_aaaa_certo_em_outra_notacao_emite(self):
        self.set_state("dig_AAAA", "2001:0DB8:0:0:0:0:0:10\n")
        out = self.roda()
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_aaaa_compactado_contra_ipv6_da_vm_por_extenso(self):
        self.set_state("ip_addr", "2: eth0    inet 203.0.113.10/24 scope global eth0\n"
                                  "2: eth0    inet6 2001:0db8:0000:0000:0000:0000:0000:0010/64 scope global eth0\n")
        self.set_state("dig_AAAA", "2001:db8::10\n")
        out = self.roda()
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_aaaa_existe_mas_a_vm_nao_tem_ipv6(self):
        self.set_state("ip_addr", "2: eth0    inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0\n")
        self.set_state("dig_AAAA", "2001:db8::10\n")
        out = self.roda()
        self.assert_provisorio(out)

    def test_vm_sem_ipv4_global(self):
        self.set_state("ip_addr", "2: eth0    inet6 2001:db8::10/64 scope global eth0\n")
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("não tem endereço IPv4 global", out)

    def test_linhas_de_cname_na_resposta_sao_ignoradas(self):
        self.set_state("dig_A", "alvo.example.com.\n203.0.113.10\n")
        out = self.roda()
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_dig_ausente_dns_nao_conferido_provisorio(self):
        self.extra_env["CMD_DIG"] = "dig-que-nao-existe"
        out = self.roda()
        self.assert_provisorio(out)
        self.assertIn("DNS não conferido", out)

    def test_consulta_usa_dois_resolvedores_publicos_com_short_e_timeout(self):
        self.roda()
        calls = self.calls_text()
        for r in ("1.1.1.1", "8.8.8.8"):
            self.assertIn("dig @%s +short +time=3 +tries=2 A netbackup.example.com" % r, calls)
            self.assertIn("dig @%s +short +time=3 +tries=2 AAAA netbackup.example.com" % r, calls)


class TestCertificado(Base3b):
    def pre_certbot_pos(self):
        linhas = [l for l in self.calls_text().splitlines()]
        idx = lambda pref: [i for i, l in enumerate(linhas) if l.startswith(pref)]
        return idx("hook-pre"), idx("certbot "), idx("hook-post")

    def test_argumentos_do_certbot_e_ordem_dos_ganchos(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        pre, cb, post = self.pre_certbot_pos()
        self.assertEqual((len(pre), len(cb), len(post)), (1, 1, 1))
        self.assertLess(pre[0], cb[0])
        self.assertLess(cb[0], post[0])
        linha = self.calls_text().splitlines()[cb[0]]
        self.assertEqual(linha, "certbot certonly --standalone -d netbackup.example.com -m admin@example.com "
                                "--agree-tos --no-eff-email --non-interactive")
        self.assertNotIn("--staging", linha)
        self.assertEqual(self.estado_val("CERT_TIPO"), "producao")

    def test_staging_passa_staging(self):
        self.extra_env["LE_STAGING"] = "1"
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("--staging", [l for l in self.calls_text().splitlines() if l.startswith("certbot ")][0])
        self.assertEqual(self.estado_val("CERT_TIPO"), "staging")
        self.assertIn("certificado de TESTE", out.lower().replace("de teste", "de TESTE") + "certificado de TESTE")
        self.assertIn("staging", self.report.read_text())

    def test_certbot_falha_gancho_post_roda_sempre_e_cai_no_provisorio(self):
        self.set_state("certbot_fail")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        pre, cb, post = self.pre_certbot_pos()
        self.assertEqual((len(pre), len(cb), len(post)), (1, 1, 1))
        self.assertLess(cb[0], post[0])
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")
        self.assertIn("não foi possível emitir o certificado", out)

    def test_gancho_pre_falha_nao_roda_certbot_mas_roda_o_post(self):
        self.set_state("hook_pre_fail")
        p, out = self.run_full()
        pre, cb, post = self.pre_certbot_pos()
        self.assertEqual((len(pre), len(cb), len(post)), (1, 0, 1))
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")

    def test_gancho_post_roda_mesmo_se_o_instalador_for_interrompido(self):
        # o fake do certbot mata o instalador (avô dele: certbot -> subshell do executa -> instalar.sh) com SIGTERM:
        # o trap ainda fecha a porta 80
        (self.bin / "certbot").write_text(
            '#!/bin/sh\necho "certbot $*" >> "$FAKE_CALLS"\n'
            'kill -TERM "$(awk \'{print $4}\' /proc/$PPID/stat)"\nsleep 2\nexit 1\n')
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        pre, cb, post = self.pre_certbot_pos()
        self.assertEqual(len(post), 1, self.calls_text())

    def test_gancho_ausente_ou_nao_confiavel_nao_emite(self):
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config deploy"
        self.run_full()
        import shutil
        shutil.rmtree(self.hooks)
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas https"
        p, out = self.run_full()
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")
        self.assertIn("gancho do certbot ausente ou não confiável", out)

    def test_gancho_gravavel_por_outros_nao_e_executado(self):
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config deploy"
        self.run_full()
        (self.hooks / "pre" / "00-open-port-80.sh").chmod(0o666)
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas https"
        p, out = self.run_full()
        self.assertEqual(self.ncalls("hook-pre"), 0)
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertIn("não confiável", out)

    def test_porta_80_ocupada_nao_emite(self):
        self.set_state("ss_listen", "LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\n")
        p, out = self.run_full()
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertIn("a porta 80 está ocupada", out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")

    def test_porta_80_de_outro_processo_na_44318_nao_confunde(self):
        self.set_state("ss_listen", "LISTEN 0 511 0.0.0.0:8080 0.0.0.0:*\nLISTEN 0 511 [::]:44318 [::]:*\n")
        p, out = self.run_full()
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_link_do_site_padrao_e_removido_se_nginx_parado(self):
        default = self.sites_en / "default"
        default.symlink_to("../sites-available/default")
        self.set_state("inactive_nginx")
        p, out = self.run_full()
        self.assertFalse(default.is_symlink())
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_link_do_site_padrao_fica_se_nginx_ativo_e_a_80_ocupada(self):
        default = self.sites_en / "default"
        default.symlink_to("../sites-available/default")
        self.set_state("ss_listen", "LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\n")
        p, out = self.run_full()
        self.assertTrue(default.is_symlink())
        self.assertEqual(self.ncalls("certbot"), 0)

    def test_certificado_existente_nao_emite_de_novo(self):
        (self.le_live / "netbackup.example.com").mkdir()
        (self.le_live / "netbackup.example.com" / "fullchain.pem").write_text("x")
        (self.le_live / "netbackup.example.com" / "privkey.pem").write_text("x")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_nginx_ativo_recarrega_e_parado_liga(self):
        p, out = self.run_full()
        self.assertIn("systemctl reload nginx.service", self.calls_text())
        self.assertEqual(self.ncalls("systemctl enable --now nginx.service"), 0)

    def test_nginx_parado_e_habilitado_e_ligado(self):
        self.set_state("inactive_nginx")
        p, out = self.run_full()
        self.assertIn("systemctl enable --now nginx.service", self.calls_text())

    def test_https_exige_o_deploy(self):
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas https"
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("depois do deploy", out)
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertFalse(self.site.exists())

    def test_prova_https_302_ou_403_no_ar_e_outro_codigo_falha(self):
        self.set_state("curl_code", "403")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("respondeu 403 (no ar)", out)
        self.set_state("curl_code", "502")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não respondeu 302/403", out)

    def test_nginx_t_falha_no_site_definitivo_nao_deixa_site_nem_link(self):
        self.set_state("nginx_t_fail")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.site.exists())
        self.assertFalse(self.link.exists() or self.link.is_symlink())
        self.assertIn("nginx -t falhou", out)
        self.assertEqual(list(self.sites_av.glob(".instalador*")), [])


class TestSiteProvisorio(Base3b):
    def setUp(self):
        super().setUp()
        self.set_state("dig_A", "198.51.100.99\n")

    def test_gerado_com_cabecalho_da_copia_do_root_e_aponta_para_o_provisorio(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        linhas = self.site.read_text().splitlines()
        self.assertEqual(linhas[0], "# PROVISORIO - gerado por instalar.sh (não editar)")
        txt = self.site.read_text()
        prov = self.estado_dir / "provisorio"
        self.assertIn("ssl_certificate     %s/provisorio.crt;" % prov, txt)
        self.assertIn("ssl_certificate_key %s/provisorio.key;" % prov, txt)
        self.assertNotIn("/etc/letsencrypt/live", txt)
        self.assertIn("server_name netbackup.example.com;", txt)
        self.assertIn("listen 44318 ssl default_server;", txt)
        self.assertTrue(self.link.is_symlink())
        self.assertEqual(self.ncalls("certbot"), 0)

    def test_certificado_autoassinado_365_dias_san_com_ip_e_nome_pasta_700_chave_600(self):
        p, out = self.run_full()
        prov = self.estado_dir / "provisorio"
        self.assertEqual(oct(prov.stat().st_mode & 0o777), "0o700")
        self.assertEqual(oct((prov / "provisorio.key").stat().st_mode & 0o777), "0o600")
        calls = self.calls_text()
        req = [l for l in calls.splitlines() if l.startswith("openssl req")][0]
        self.assertIn("-x509", req)
        self.assertIn("-days 365", req)
        self.assertIn("SAN subjectAltName=DNS:netbackup.example.com,IP:203.0.113.10", calls)

    def test_relatorio_diz_para_acessar_pelo_ip_e_rodar_certificado(self):
        p, out = self.run_full()
        rel = self.report.read_text()
        self.assertIn("Acesse https://203.0.113.10:44318", rel)
        self.assertIn("instalar.sh --certificado", rel)
        self.assertIn("PROVISÓRIO", rel)
        self.assertIn("aviso do navegador esperado", out)
        self.assertIn("bash instalar.sh --certificado", out)
        self.assertEqual(self.estado_val("CERT_TIPO"), "autoassinado")

    def test_prova_do_provisorio_aceita_certificado_sem_confianca(self):
        p, out = self.run_full()
        self.assertIn("curl -s -o /dev/null -m 10 -w %{http_code} -k https://127.0.0.1:44318/", self.calls_text())

    def test_rodar_de_novo_nao_regera_o_provisorio(self):
        p, out = self.run_full()
        antes = (self.site.read_text(), (self.estado_dir / "provisorio" / "provisorio.crt").read_text())
        n = self.ncalls("openssl req")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.ncalls("openssl req"), n)
        self.assertEqual((self.site.read_text(), (self.estado_dir / "provisorio" / "provisorio.crt").read_text()), antes)

    def test_provisorio_vira_definitivo_na_proxima_execucao_se_o_dns_apontar(self):
        self.run_full()
        self.set_state("dig_A", "203.0.113.10\n")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn("PROVISORIO", self.site.read_text())
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_nginx_t_falha_no_provisorio_para_sem_ligar_o_nginx(self):
        self.set_state("nginx_t_fail")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.site.exists())
        self.assertEqual(self.ncalls("systemctl enable"), 0)
        self.assertEqual(self.ncalls("systemctl reload"), 0)

    def test_nunca_sobrescreve_site_que_nao_e_o_provisorio(self):
        self.sites_av.joinpath("netbackup").write_text("# meu site antigo\nserver { listen 44318; }\n")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.site.read_text(), "# meu site antigo\nserver { listen 44318; }\n")
        self.assertIn("NÃO será alterado", out)
        self.assertEqual(self.ncalls("certbot"), 0)
        self.assertEqual(self.ncalls("openssl req"), 0)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "existente")

    def test_nunca_sobrescreve_site_mesmo_com_dns_ok(self):
        self.set_state("dig_A", "203.0.113.10\n")
        self.sites_av.joinpath("netbackup").write_text("# meu site antigo\n")
        p, out = self.run_full()
        self.assertEqual(self.site.read_text(), "# meu site antigo\n")
        self.assertEqual(self.ncalls("certbot"), 0)

    def test_modelo_com_sha256_alterado_nao_gera_site(self):
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas disco chave codigo config deploy"
        self.run_full()
        (self.share / "netbackup.conf.template").write_text("server { adulterado }\n")
        self.extra_env["ETAPAS_LISTA"] = "precheck perguntas https"
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse(self.site.exists())
        self.assertIn("alterada (sha256)", out)


class TestModoCertificado(Base3b):
    def instala_provisorio(self):
        self.set_state("dig_A", "198.51.100.99\n")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")
        self.set_state("dig_A", "203.0.113.10\n")

    def test_troca_so_o_provisorio_pelo_definitivo(self):
        self.instala_provisorio()
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        txt = self.site.read_text()
        self.assertNotIn("PROVISORIO", txt)
        self.assertIn("/etc/letsencrypt/live/netbackup.example.com/fullchain.pem", txt)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")
        self.assertEqual(self.estado_val("CERT_TIPO"), "producao")
        self.assertIn("agora acesse https://netbackup.example.com:44318", out)
        pre, cb, post = TestCertificado.pre_certbot_pos(self)
        self.assertEqual((len(pre), len(cb), len(post)), (1, 1, 1))
        self.assertIn("systemctl reload nginx.service", self.calls_text())

    def test_nao_usa_nada_de_opt_netbackup(self):
        self.instala_provisorio()
        import shutil
        shutil.rmtree(self.nb)                       # o produto some: a cópia do root basta
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        self.assertNotIn(str(self.nb), "\n".join(l for l in self.calls_text().splitlines()[-60:] if not l.startswith("stat ")))

    def test_dns_nao_bate_para_sem_alterar(self):
        self.instala_provisorio()
        self.set_state("dig_A", "198.51.100.99\n")
        antes = fp(self.sites_av)
        n = self.ncalls("certbot")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("o DNS ainda não aponta para esta VM", out)
        self.assertEqual(fp(self.sites_av), antes)
        self.assertEqual(self.ncalls("certbot"), n)

    def test_nginx_t_falha_volta_o_provisorio(self):
        self.instala_provisorio()
        antes = self.site.read_text()
        self.set_state("nginx_t_fail_definitivo")
        reloads = self.ncalls("systemctl reload")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.site.read_text(), antes)
        self.assertTrue(self.link.is_symlink())
        self.assertIn("nginx -t falhou", out)
        self.assertIn("o site anterior foi restaurado", out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "provisorio")
        self.assertEqual(self.ncalls("systemctl reload"), reloads)      # nada foi recarregado
        self.assertEqual(list(self.sites_av.glob(".instalador*")), [])

    def test_site_que_nao_e_provisorio_nao_e_tocado_e_explica(self):
        self.instala_provisorio()
        self.site.write_text("# editado a mão\nserver { }\n")
        n = self.ncalls("certbot")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.site.read_text(), "# editado a mão\nserver { }\n")
        self.assertIn("NÃO será tocado", out)
        self.assertEqual(self.ncalls("certbot"), n)      # nem gasta o limite do Let's Encrypt

    def test_ja_definitivo_nada_a_fazer(self):
        self.run_full()
        n = self.ncalls("certbot")
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("nada a fazer", out)
        self.assertEqual(self.ncalls("certbot"), n)

    def test_sem_site_ou_sem_deploy_ou_sem_respostas(self):
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("respostas", out)
        self.saved.write_text(RESP_PADRAO)
        self.saved.chmod(0o600)
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("deploy ainda não foi feito", out)

    def test_certbot_falha_mantem_o_provisorio(self):
        self.instala_provisorio()
        antes = self.site.read_text()
        self.set_state("certbot_fail")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.site.read_text(), antes)
        pre, cb, post = TestCertificado.pre_certbot_pos(self)
        self.assertEqual(len(post), len(pre))               # todo pre tem seu post

    def test_modelo_adulterado_na_copia_do_root_nao_troca(self):
        self.instala_provisorio()
        antes = self.site.read_text()
        (self.share / "netbackup.conf.template").write_text("server { adulterado }\n")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.site.read_text(), antes)

    def test_staging_para_bancada(self):
        self.instala_provisorio()
        self.extra_env["LE_STAGING"] = "1"
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        self.assertIn("--staging", [l for l in self.calls_text().splitlines() if l.startswith("certbot ")][-1])
        self.assertEqual(self.estado_val("CERT_TIPO"), "staging")

    def test_de_staging_para_producao_forca_a_renovacao(self):
        self.extra_env["LE_STAGING"] = "1"
        self.run_full()
        self.assertEqual(self.estado_val("CERT_TIPO"), "staging")
        site = self.site.read_text()
        self.extra_env["LE_STAGING"] = "0"
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        ultimo = [l for l in self.calls_text().splitlines() if l.startswith("certbot ")][-1]
        self.assertIn("--force-renewal", ultimo)
        self.assertNotIn("--staging", ultimo)
        self.assertEqual(self.estado_val("CERT_TIPO"), "producao")
        self.assertEqual(self.site.read_text(), site)          # o site não é reescrito

    def test_rodar_o_instalador_de_novo_tambem_troca_staging_por_producao(self):
        self.extra_env["LE_STAGING"] = "1"
        self.run_full()
        self.extra_env["LE_STAGING"] = "0"
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("CERT_TIPO"), "producao")
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")

    def test_rodar_de_novo_com_site_definitivo_preserva_o_modo_e_nao_reescreve(self):
        self.run_full()
        site = self.site.read_text()
        n = self.ncalls("certbot")
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(self.estado_val("HTTPS_MODO"), "definitivo")
        self.assertEqual(self.site.read_text(), site)
        self.assertEqual(self.ncalls("certbot"), n)


class TestRelatorioDoCertificado(Base3b):
    def prov(self):
        self.set_state("dig_A", "198.51.100.99\n")
        self.run_full()
        self.set_state("dig_A", "203.0.113.10\n")

    def test_provisorio_diz_vencimento_365_dias_certificado_e_hsts(self):
        self.prov()
        rel = self.report.read_text()
        vence = (datetime.date.today() + datetime.timedelta(days=365)).isoformat()
        self.assertEqual(self.estado_val("PROV_VENCE"), vence)
        self.assertIn("O certificado provisório vence em %s (365 dias" % vence, rel)
        self.assertIn("instalar.sh --certificado", rel)
        self.assertIn("includeSubDomains", rel)
        self.assertIn("BLOQUEIA o acesso", rel)
        self.assertIn("pelo NOME com certificado provisório ou de TESTE", rel)
        self.assertIn("use o acesso pelo IP (https://203.0.113.10:44318)", rel)

    def test_a_tela_tambem_avisa_do_vencimento_e_do_hsts(self):
        self.set_state("dig_A", "198.51.100.99\n")
        p, out = self.run_full()
        self.assertIn("vence em", out)
        self.assertIn("includeSubDomains", out)

    def test_certificado_regrava_o_relatorio_producao(self):
        self.prov()
        antes = self.report.read_text()
        self.assertIn("PROVISÓRIO", antes)
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        rel = self.report.read_text()
        self.assertNotEqual(rel, antes)
        self.assertIn("Acesse https://netbackup.example.com:44318", rel)
        self.assertNotIn("PROVISÓRIO", rel)
        self.assertNotIn("provisório vence", rel)
        self.assertNotIn("includeSubDomains", rel)
        self.assertNotIn("--certificado", rel)
        self.assertIn("HTTPS com certificado Let's Encrypt", rel)
        self.assertIn("(nada)", rel)
        self.assertEqual(oct(self.report.stat().st_mode & 0o777), "0o600")
        self.assertIn("Relatório gravado em", out)

    def test_certificado_staging_regrava_com_aviso_de_teste(self):
        self.prov()
        self.extra_env["LE_STAGING"] = "1"
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        rel = self.report.read_text()
        self.assertIn("Acesse https://netbackup.example.com:44318", rel)
        self.assertNotIn("PROVISÓRIO", rel)
        self.assertIn("certificado de TESTE (staging)", rel)
        self.assertIn("NÃO é confiável nos navegadores", rel)
        self.assertIn("includeSubDomains", rel)
        self.assertIn("https://203.0.113.10:44318", rel)

    def test_staging_para_producao_regrava_sem_pendencia(self):
        self.prov()
        self.extra_env["LE_STAGING"] = "1"
        self.run_inst("--certificado")
        self.extra_env["LE_STAGING"] = "0"
        p, out = self.run_inst("--certificado")
        self.assertEqual(p.returncode, 0, out)
        rel = self.report.read_text()
        self.assertNotIn("TESTE", rel)
        self.assertNotIn("includeSubDomains", rel)
        self.assertIn("(nada)", rel)

    def test_certificado_que_falha_nao_regrava_o_relatorio(self):
        self.prov()
        antes = self.report.read_text()
        self.set_state("certbot_fail")
        p, out = self.run_inst("--certificado")
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.report.read_text(), antes)

    def test_definitivo_direto_nao_tem_aviso_de_hsts(self):
        self.run_full()
        rel = self.report.read_text()
        self.assertNotIn("includeSubDomains", rel)
        self.assertNotIn("vence em", rel)


class TestFirewall(Base3b):
    COMENT = "NetBackup HTTPS (Nginx) - painel"

    def allows(self):
        return [l for l in self.calls_text().splitlines() if l.startswith("ufw allow")]

    def test_regra_para_cada_rede_com_o_mesmo_comentario_da_tela_do_produto(self):
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        a = self.allows()
        self.assertEqual(a, [
            "ufw allow from 203.0.113.50/32 to any port 44318 proto tcp comment %s" % self.COMENT,
            "ufw allow from 198.51.100.0/24 to any port 44318 proto tcp comment %s" % self.COMENT,
        ])

    def test_idempotente(self):
        self.run_full()
        n = len(self.allows())
        self.assertEqual(n, 2)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertEqual(len(self.allows()), n)
        self.assertIn("já existe", out)

    def test_so_acrescenta_nao_remove_nem_toca_no_baseline(self):
        baseline = ("44320/tcp                  ALLOW       198.51.100.0/24            # baseline: SSH gestao\n"
                    "161/udp                    ALLOW       192.0.2.5                  # baseline: SNMP\n")
        self.set_state("ufw_rules", baseline)
        p, out = self.run_full()
        self.assertEqual(p.returncode, 0, out)
        self.assertTrue(self.ufw_rules().startswith(baseline))
        self.assertEqual(self.ncalls("ufw delete"), 0)
        self.assertEqual(self.ncalls("ufw reset"), 0)
        self.assertEqual(self.ncalls("ufw disable"), 0)
        self.assertEqual(self.ncalls("ufw default"), 0)
        self.assertFalse([a for a in self.allows() if "44320" in a])

    def test_regra_ja_criada_pela_tela_do_produto_nao_duplica(self):
        self.set_state("ufw_rules", "44318/tcp                  ALLOW       203.0.113.50              # %s\n" % self.COMENT)
        self.run_full()
        self.assertEqual(len(self.allows()), 1)
        self.assertIn("198.51.100.0/24", self.allows()[0])

    def test_falha_do_ufw_termina_com_erro(self):
        self.set_state("ufw_allow_fail")
        p, out = self.run_full()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("não foi possível criar a regra do UFW", out)

    def test_rede_do_painel_sem_regra_aparece_no_check(self):
        self.run_full()
        (self.state / "ufw_rules").write_text("")
        p, out = self.run_inst("--check")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("falta 44318/tcp para 203.0.113.50/32", out)


class TestRelatorio(Base3b):
    def test_relatorio_600_com_versao_commit_acesso_login_feito_e_proximos_passos(self):
        p, out = self.run_full()
        rel = self.report.read_text()
        self.assertEqual(oct(self.report.stat().st_mode & 0o777), "0o600")
        self.assertIn("versão 0.2.0-dev", rel)
        self.assertIn("abc1234", rel)
        self.assertIn("Acesse https://netbackup.example.com:44318", rel)
        self.assertIn("Login ...............: admin", rel)
        self.assertIn("O QUE FOI FEITO", rel)
        self.assertIn("O QUE FICOU PENDENTE", rel)
        self.assertIn("(nada)", rel)
        self.assertIn("backup externo", rel)
        self.assertIn("Telegram", rel)

    def test_relatorio_sem_segredos(self):
        self.set_resp(RESP_PADRAO)
        p, out = self.run_full()
        rel = self.report.read_text()
        for segredo in (t.SECRET_KEY, "APP_SECRET_KEY", "BEGIN", "PRIVATE KEY", "admin@example.com", "FAKE-PROV-KEY", "KEY"):
            self.assertNotIn(segredo, rel, segredo)
        self.assertIn("não é gravada em lugar nenhum", rel)

    def test_relatorio_do_provisorio_lista_o_certificado_definitivo_como_pendente(self):
        self.set_state("dig_A", "198.51.100.99\n")
        self.run_full()
        rel = self.report.read_text()
        self.assertIn("certificado definitivo", rel)
        self.assertIn("bash instalar.sh --certificado", rel)

    def test_relatorio_depois_do_certificado_nao_tem_pendencia(self):
        self.set_state("dig_A", "198.51.100.99\n")
        self.run_full()
        self.set_state("dig_A", "203.0.113.10\n")
        self.run_inst("--certificado")
        self.run_full()
        self.assertIn("(nada)", self.report.read_text())

    def test_log_nao_tem_segredos(self):
        p, out = self.run_full()
        for lg in self.logs():
            txt = lg.read_text()
            self.assertNotIn(t.SECRET_KEY, txt)
            self.assertEqual(oct(lg.stat().st_mode & 0o777), "0o600")

    def test_apos_deploy_o_relatorio_nao_roda_deploy_check(self):
        p, out = self.run_full()
        self.assertEqual(self.ncalls("deploy-check-ran"), 0)
        p, out = self.run_full()
        self.assertEqual(self.ncalls("deploy-check-ran"), 0)


class TestCheckEStatus(Base3b):
    def test_check_numa_maquina_limpa_nao_altera_nada(self):
        antes = fp(self.root)
        p, out = self.run_inst("--check")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(fp(self.root), antes)
        for c in ("ufw allow", "certbot", "openssl req", "nginx", "systemctl reload", "systemctl enable",
                  "deploy-dominio", "git clone", "ssh-keygen"):
            self.assertEqual(self.ncalls(c), 0, c)
        self.assertIn("Respostas da instalação", out)
        self.assertIn("Configuração do produto", out)
        self.assertIn("Deploy do produto", out)
        self.assertIn("HTTPS (Nginx)", out)
        self.assertIn("Firewall", out)

    def test_check_depois_de_tudo_nao_altera_e_passa(self):
        self.run_full()
        antes = fp(self.root)
        n_dep = self.ncalls("deploy-run")
        p, out = self.run_inst("--check")
        self.assertEqual(fp(self.root), antes)
        self.assertEqual(self.ncalls("deploy-run"), n_dep)
        self.assertIn("deploy feito", out)
        self.assertIn("UFW: 44318/tcp liberada para 203.0.113.50/32", out)
        self.assertIn("DNS de netbackup.example.com confere com a VM", out)
        self.assertIn("site habilitado", out)
        self.assertEqual(self.ncalls("ufw allow"), 2)
        self.assertEqual(self.ncalls("certbot"), 1)

    def test_check_mostra_https_provisorio_como_aviso(self):
        self.set_state("dig_A", "198.51.100.99\n")
        self.run_full()
        antes = fp(self.root)
        p, out = self.run_inst("--check")
        self.assertIn("HTTPS PROVISÓRIO", out)
        self.assertIn("não confere com a VM", out)
        self.assertEqual(fp(self.root), antes)

    def test_check_antes_do_deploy_com_codigo_pronto_roda_deploy_check_somente_leitura(self):
        self.prepare_nb()
        p, out = self.run_inst("--check")
        self.assertEqual(self.ncalls("deploy-check-ran"), 1)
        self.assertEqual(self.ncalls("deploy-dominio"), 0)

    def test_status_nao_usa_rede_nem_altera(self):
        self.run_full()
        antes = fp(self.root)
        n_dig, n_curl = self.ncalls("dig"), self.ncalls("curl")
        p, out = self.run_inst("--status")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.ncalls("dig"), n_dig)
        self.assertEqual(self.ncalls("curl"), n_curl)
        self.assertEqual(fp(self.root), antes)
        for titulo in ("Respostas da instalação", "Configuração do produto", "Deploy do produto",
                       "HTTPS (Nginx)", "Firewall"):
            self.assertIn("[ok]    " + titulo, out)

    def test_status_antes_de_tudo_mostra_falta(self):
        p, out = self.run_inst("--status")
        self.assertIn("[falta] Respostas da instalação", out)
        self.assertIn("[falta] Deploy do produto", out)
        self.assertIn("[falta] HTTPS (Nginx)", out)

    def test_check_apos_deploy_com_servico_parado_reporta(self):
        self.run_full()
        self.set_state("inactive_netbackup")
        p, out = self.run_inst("--check")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("netbackup.service não está ativo", out)


class TestArtefatos3b(unittest.TestCase):
    def test_script_sem_source_nem_eval_de_arquivos_externos(self):
        src = (t.REPO_DIR / "instalar.sh").read_text()
        codigo = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
        self.assertIsNone(re.search(r"(^|[;&|]\s*)(source|\.)\s+[\"$/]", codigo, re.M))
        self.assertNotIn("eval ", codigo)
        self.assertNotIn("| tee", codigo)
        self.assertNotIn("tee -a", codigo)

    def test_comentario_do_ufw_e_o_do_produto(self):
        src = (t.REPO_DIR / "instalar.sh").read_text()
        self.assertIn('readonly UFW_COMMENT="NetBackup HTTPS (Nginx) - painel"', src)

    def test_exemplos_publicos_so_rfc_5737_3849_e_example_com(self):
        for f in ("README.md", "tests/test_instalar_3b.py", "tests/test_instalar.py"):
            txt = (t.REPO_DIR / f).read_text()
            for ip in re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", txt):
                ok = ip.startswith(("192.0.2.", "198.51.100.", "203.0.113.", "10.", "172.16.", "192.168.", "127.",
                                    "0.0.0.", "1.1.1.1", "8.8.8.8", "255.", "100.64.", "999.1.1.1", "010.0.0.1", "172.32.", "11.0.0.0"))
                self.assertTrue(ok, "%s: %s" % (f, ip))
