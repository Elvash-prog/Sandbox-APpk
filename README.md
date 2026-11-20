# Espelhar Celular

Programa portátil para Windows que mostra e controla a tela do seu Android no PC, com **baixa latência** (cerca de 35 a 70 ms), por **cabo USB (adb)** ou por **Wi-Fi**.

- **Não precisa de administrador** e não tem instalação: tudo fica dentro da própria pasta.
- Por baixo ele usa o [scrcpy](https://github.com/Genymobile/scrcpy) (open source), que é baixado sozinho na primeira vez para a pasta `scrcpy\`.
- No celular **não é instalado nenhum app**.

## Como usar

1. **No celular:** Configurações → Sobre o telefone → toque 7 vezes em *Número da versão*. Depois vá em Opções do desenvolvedor e ligue a **Depuração USB**.
   - Xiaomi/POCO: ligue também *Depuração USB (Configurações de segurança)*, senão o mouse não funciona.
2. **No PC:** copie esta pasta para onde quiser (Documentos, pendrive...) e dê dois cliques em **`EspelharCelular.bat`**.
3. Conecte o cabo e aceite a mensagem **"Permitir depuração USB?"** no celular. Clique em **Atualizar**.
4. Clique em **ESPELHAR TELA**.

### Pelo Wi-Fi

O celular e o PC precisam estar na mesma rede.

- **Jeito fácil (qualquer Android):** com o cabo conectado, clique em *Ativar Wi-Fi usando o cabo USB*, tire o cabo e espelhe. O IP fica salvo e o programa tenta reconectar sozinho da próxima vez. Se o celular reiniciar, repita esse passo.
- **Sem cabo nenhum (Android 11+):** Opções do desenvolvedor → *Depuração por Wi-Fi* → *Parear o dispositivo com um código*. Coloque o IP:porta e o código no campo **Parear**. Depois coloque em **IP:porta** o endereço da tela principal da Depuração por Wi-Fi (a porta é outra) e clique em **Conectar**.

## Dicas para ter o menor delay

- Use o perfil **Latência mínima** (1280 px, 8 Mbps, 60 fps, H.264). O cabo USB é sempre o mais rápido.
- No Wi-Fi, prefira a rede de **5 GHz**. Se travar, use o perfil **Wi-Fi fraco**.
- Deixe o áudio desligado se não precisar dele.

## Atalhos na janela do espelho

| Atalho | Ação |
|---|---|
| `Alt+F` | Tela cheia |
| `Alt+H` / `Alt+B` | Home / Voltar |
| `Alt+O` | Apagar a tela do celular (o espelho continua) |
| `Alt+R` | Girar |
| `Alt+↑` / `Alt+↓` | Volume |
| Arrastar um APK para a janela | Instala o app |
| Arrastar outro arquivo | Copia para `/sdcard/Download` |

## Problemas comuns

- **Nenhum celular encontrado:** troque o cabo (alguns só carregam) e confirme que a Depuração USB está ligada. Alguns aparelhos mais antigos precisam do driver USB do fabricante, e esse driver pode pedir administrador.
- **"unauthorized":** desbloqueie o celular e aceite a autorização.
- **O PowerShell está bloqueado pela empresa/escola:** se uma política de grupo bloquear scripts, rode `scrcpy\scrcpy-win64-*\scrcpy.exe` direto, que também funciona sem administrador.
- O log do último espelhamento fica em `logs\scrcpy.log`.
