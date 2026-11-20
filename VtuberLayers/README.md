# VTuber Layers

App de desktop (Windows) que separa um **PNG** nas camadas de um personagem
(cabelo frente/trás, rosto, olhos, íris, sobrancelhas, boca, corpo...) e exporta
um **PSD** (ou `.ora`) com tudo nomeado, **pronto para abrir num editor de rig**
(Live2D Cubism, Inochi2D, etc.).

Não precisa de administrador: ao abrir, ele cria um ambiente Python local dentro
da própria pasta (`.venv`) e instala o que precisa ali.

> ⚠️ **Ainda não foi testado no Windows** (foi desenvolvido no Linux). A lógica de
> montar as camadas e exportar foi testada; a interface não. Se der erro, me manda
> o texto que aparece.

## O que ele faz (e o que não faz)

Um PNG "achatado" **não tem** a informação do que está atrás do cabelo, das
pálpebras, etc. Então a separação **não é 100% automática nem perfeita** — isso
vale para qualquer ferramenta. O que este app faz:

- Você pinta cada parte com o **pincel**, vendo a arte original por baixo de guia.
- Botões de ajuda: **remover fundo** automático e **preencher o fundo** com o que sobrou.
- Na exportação, o app **reconstrói uma margem atrás das bordas** de cada peça, para
  o rig poder deformar sem deixar vão.
- Exporta **PSD** com as camadas nomeadas, além de um `.ora` e os **PNGs soltos**.

## Como usar

1. Instale o **Python 3** (https://www.python.org/downloads/). Na instalação marque
   *Add Python to PATH* e, se quiser, *Install for me only* (não pede administrador).
2. Copie esta pasta para onde quiser e dê dois cliques em **`IniciarVtuberLayers.bat`**.
   Na primeira vez ele baixa as dependências (demora um pouco).
3. **Arquivo → Abrir PNG**.
4. (Opcional) Clique em **Remover fundo (auto)**.
5. Selecione uma parte na lista à direita e **pinte** a região dela na imagem:
   - **Botão esquerdo** pinta, **botão direito** apaga, **roda do mouse** muda o tamanho do pincel.
   - Pinte só a parte **visível** de cada peça. A margem escondida o app reconstrói sozinho.
6. Use **Preencher 'fundo' com o resto** para a camada de fundo.
7. Clique em **EXPORTAR CAMADAS** e escolha onde salvar.

## Saída

- `nome_camadas.psd` (ou `.ora` se o PSD nativo não estiver disponível).
- `nome_camadas_png/` com cada camada em PNG separado e numerado na ordem.

O `.ora` abre no **Krita** ou **GIMP** (grátis); de lá dá para *Salvar como* `.psd`.
Depois é só abrir no seu editor de rig e começar a animar.

## Dependências

Obrigatórias (instaladas sozinhas): `PySide6`, `numpy`, `Pillow`, `opencv-python`.

Opcionais (o app detecta; se faltarem, ele avisa e segue):
- `pytoshop` → exporta PSD nativo. Sem ele, exporta `.ora`.
- `rembg` + `onnxruntime` → botão de remover fundo automático.

## Dicas para um bom resultado

- Trabalhe com a arte em **resolução alta** e personagem **de frente**.
- Separe o que vai se mexer sozinho: cada **olho**, cada **íris**, **boca** e
  **sobrancelhas** em camadas próprias — é o que o rig mais usa.
- Aumente a margem de reconstrução se notar vão nas junções (hoje fixa em ~14 px;
  me avisa se quiser isso como ajuste na tela).
