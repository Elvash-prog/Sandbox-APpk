#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VTuber Layers - separa um PNG em camadas nomeadas e exporta PSD/ORA,
pronto para abrir num editor de rig (Live2D Cubism, Inochi2D, etc.).

Fluxo: carregar PNG -> pintar cada parte com o pincel (com a arte original
de guia por baixo) -> o app reconstroi uma margem atras das bordas e
exporta as camadas separadas.

Dependencias obrigatorias: PySide6, numpy, Pillow, opencv-python
Opcionais (o app detecta sozinho):
    - pytoshop  -> exporta .psd nativo (se faltar, cai no .ora)
    - rembg     -> botao "remover fundo" automatico
"""

import os
import sys
import zipfile
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image

try:
    import cv2
    HAS_CV2 = True
except Exception:
    HAS_CV2 = False

try:
    import rembg
    HAS_REMBG = True
except Exception:
    HAS_REMBG = False

try:
    import pytoshop
    from pytoshop.user import nested_layers
    from pytoshop import enums as ps_enums
    HAS_PSD = True
except Exception:
    HAS_PSD = False

from PySide6 import QtCore, QtGui, QtWidgets
from PySide6.QtCore import Qt

# ----------------------------------------------------------------- modelo

# Partes padrao no padrao VTuber, da camada de tras para a da frente.
DEFAULT_PARTS = [
    "fundo",
    "cabelo_tras",
    "corpo",
    "rosto",
    "orelha_esq",
    "orelha_dir",
    "sobrancelha_esq",
    "sobrancelha_dir",
    "olho_esq",
    "olho_dir",
    "iris_esq",
    "iris_dir",
    "nariz",
    "boca",
    "cabelo_frente",
    "acessorio",
]

PALETTE = [
    (255, 80, 80), (80, 200, 120), (80, 150, 255), (240, 200, 60),
    (200, 100, 240), (60, 220, 220), (255, 140, 60), (150, 150, 255),
    (255, 90, 170), (120, 220, 90), (90, 170, 230), (230, 160, 90),
    (180, 120, 220), (90, 220, 190), (230, 120, 120), (160, 180, 110),
]


def part_color(index):
    return PALETTE[index % len(PALETTE)]


def np_rgba_to_qimage(arr):
    """arr: HxWx4 uint8 -> QImage (copia os dados)."""
    h, w = arr.shape[:2]
    arr = np.ascontiguousarray(arr)
    img = QtGui.QImage(arr.data, w, h, 4 * w, QtGui.QImage.Format_RGBA8888)
    return img.copy()


# ----------------------------------------------------------------- canvas

class Canvas(QtWidgets.QWidget):
    """Mostra a imagem base e deixa pintar a mascara da parte atual."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(400, 400)
        self.setMouseTracking(True)
        self.base = None          # HxWx4 uint8 (imagem original)
        self.base_pix = None      # QPixmap da base
        self.masks = {}           # nome -> HxW uint8 (0/255)
        self.current = None       # nome da parte atual
        self.current_color = (255, 80, 80)
        self.brush = 28
        self.erasing = False
        self.show_all = False
        self._scale = 1.0
        self._ox = 0.0
        self._oy = 0.0
        self._painting = False
        self._last = None
        self.all_colors = {}      # nome -> cor, para o modo "mostrar todas"

    def set_image(self, arr):
        self.base = arr
        self.base_pix = QtGui.QPixmap.fromImage(np_rgba_to_qimage(arr))
        self.masks = {}
        self.update()

    def ensure_mask(self, name):
        if self.base is None:
            return None
        if name not in self.masks:
            h, w = self.base.shape[:2]
            self.masks[name] = np.zeros((h, w), np.uint8)
        return self.masks[name]

    def set_current(self, name, color):
        self.current = name
        self.current_color = color
        self.ensure_mask(name)
        self.update()

    # --- geometria tela <-> imagem ---
    def _recalc(self):
        if self.base is None:
            return
        h, w = self.base.shape[:2]
        sw, sh = self.width(), self.height()
        self._scale = min(sw / w, sh / h)
        dw, dh = w * self._scale, h * self._scale
        self._ox = (sw - dw) / 2.0
        self._oy = (sh - dh) / 2.0

    def _to_image(self, pt):
        if self.base is None or self._scale == 0:
            return None
        x = (pt.x() - self._ox) / self._scale
        y = (pt.y() - self._oy) / self._scale
        return int(round(x)), int(round(y))

    # --- pintura ---
    def _stamp(self, ix, iy):
        if self.current is None:
            return
        m = self.ensure_mask(self.current)
        if m is None:
            return
        val = 0 if self.erasing else 255
        r = max(1, int(self.brush / 2))
        if HAS_CV2:
            cv2.circle(m, (ix, iy), r, val, -1)
        else:
            h, w = m.shape
            y0, y1 = max(0, iy - r), min(h, iy + r + 1)
            x0, x1 = max(0, ix - r), min(w, ix + r + 1)
            yy, xx = np.ogrid[y0:y1, x0:x1]
            circle = (xx - ix) ** 2 + (yy - iy) ** 2 <= r * r
            m[y0:y1, x0:x1][circle] = val

    def _line(self, a, b):
        (x0, y0), (x1, y1) = a, b
        dist = max(abs(x1 - x0), abs(y1 - y0))
        steps = max(1, dist)
        for i in range(steps + 1):
            t = i / steps
            self._stamp(int(round(x0 + (x1 - x0) * t)),
                        int(round(y0 + (y1 - y0) * t)))

    def mousePressEvent(self, e):
        if self.base is None or self.current is None:
            return
        if e.button() in (Qt.LeftButton, Qt.RightButton):
            self.erasing = (e.button() == Qt.RightButton) or self.erasing
            self._painting = True
            p = self._to_image(e.position())
            if p:
                self._stamp(*p)
                self._last = p
            self.update()

    def mouseMoveEvent(self, e):
        if self._painting:
            p = self._to_image(e.position())
            if p and self._last:
                self._line(self._last, p)
                self._last = p
                self.update()

    def mouseReleaseEvent(self, e):
        self._painting = False
        self._last = None
        if e.button() == Qt.RightButton and not self.erasing:
            pass

    def wheelEvent(self, e):
        d = 2 if e.angleDelta().y() > 0 else -2
        self.brush = max(2, min(200, self.brush + d))
        w = self.window()
        if hasattr(w, "sync_brush"):
            w.sync_brush(self.brush)
        self.update()

    def _mask_overlay(self, mask, color, alpha):
        h, w = mask.shape
        ov = np.zeros((h, w, 4), np.uint8)
        sel = mask > 0
        ov[sel, 0] = color[0]
        ov[sel, 1] = color[1]
        ov[sel, 2] = color[2]
        ov[sel, 3] = alpha
        return np_rgba_to_qimage(ov)

    def paintEvent(self, _):
        p = QtGui.QPainter(self)
        p.fillRect(self.rect(), QtGui.QColor(40, 40, 46))
        if self.base is None:
            p.setPen(QtGui.QColor(200, 200, 200))
            p.drawText(self.rect(), Qt.AlignCenter,
                       "Abra um PNG para comecar\n(Arquivo > Abrir)")
            return
        self._recalc()
        target = QtCore.QRectF(self._ox, self._oy,
                               self.base.shape[1] * self._scale,
                               self.base.shape[0] * self._scale)
        p.setRenderHint(QtGui.QPainter.SmoothPixmapTransform, True)
        p.drawPixmap(target, self.base_pix, QtCore.QRectF(self.base_pix.rect()))

        if self.show_all:
            for name, mask in self.masks.items():
                if mask.max() == 0:
                    continue
                col = self.all_colors.get(name, (255, 80, 80))
                img = self._mask_overlay(mask, col, 90)
                p.drawImage(target, img, QtCore.QRectF(img.rect()))
        elif self.current and self.current in self.masks:
            img = self._mask_overlay(self.masks[self.current],
                                     self.current_color, 130)
            p.drawImage(target, img, QtCore.QRectF(img.rect()))


# ----------------------------------------------------------------- exportacao

def build_layers(base, masks, order, margin=14, inpaint_bg=True):
    """
    Monta a lista de camadas (nome, rgba HxWx4).
    - Cada parte recebe uma margem reconstruida atras das bordas (dilatacao),
      pegando pixels da propria regiao para nao deixar vao no rig.
    - A camada 'fundo', se existir, tem a area do personagem preenchida.
    """
    h, w = base.shape[:2]
    rgb = base[:, :, :3]
    base_alpha = base[:, :, 3]
    layers = []

    def dilate(mask, px):
        if px <= 0:
            return mask
        if HAS_CV2:
            k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (px * 2 + 1, px * 2 + 1))
            return cv2.dilate(mask, k)
        out = mask.copy()
        for _ in range(px):
            out[:-1, :] |= out[1:, :]
            out[1:, :] |= out[:-1, :]
            out[:, :-1] |= out[:, 1:]
            out[:, 1:] |= out[:, :-1]
        return out

    # uniao de todas as partes que nao sao o fundo (= silhueta do personagem)
    char = np.zeros((h, w), np.uint8)
    for name in order:
        if name == "fundo":
            continue
        m = masks.get(name)
        if m is not None:
            char = np.maximum(char, (m > 0).astype(np.uint8) * 255)

    for name in order:
        m = masks.get(name)
        if m is None or m.max() == 0:
            continue
        if name == "fundo":
            out = base.copy()
            if inpaint_bg and HAS_CV2 and char.max() > 0:
                hole = dilate(char, 3)
                filled = cv2.inpaint(rgb, hole, 6, cv2.INPAINT_TELEA)
                out = np.dstack([filled, np.full((h, w), 255, np.uint8)])
            else:
                keep = (m > 0)
                a = np.where(keep, base_alpha, 0).astype(np.uint8)
                out = np.dstack([rgb, a])
            layers.append((name, out))
            continue

        core = (m > 0).astype(np.uint8) * 255
        grown = dilate(core, margin)
        rgba = np.zeros((h, w, 4), np.uint8)
        rgba[:, :, :3] = rgb
        # alpha: cheio no nucleo, com uma borda de reconstrucao suavizada
        alpha = (core > 0).astype(np.uint8) * 255
        band = (grown > 0) & (core == 0)
        if HAS_CV2:
            # preenche a cor da banda com os pixels vizinhos da propria parte
            missing = band.astype(np.uint8) * 255
            src = rgb.copy()
            filled = cv2.inpaint(src, missing, 4, cv2.INPAINT_TELEA)
            rgba[:, :, :3] = filled
            alpha_f = alpha.astype(np.float32)
            alpha_f[band] = 160.0  # margem semitransparente
            rgba[:, :, 3] = alpha_f.astype(np.uint8)
        else:
            rgba[:, :, 3] = alpha
        layers.append((name, rgba))

    return layers


def export_psd(path, base, layers):
    h, w = base.shape[:2]
    ps_layers = []
    for name, rgba in layers:
        r = rgba[:, :, 0].astype(np.uint8)
        g = rgba[:, :, 1].astype(np.uint8)
        b = rgba[:, :, 2].astype(np.uint8)
        a = rgba[:, :, 3].astype(np.uint8)
        layer = nested_layers.Image(
            name=name, visible=True, opacity=255,
            top=0, left=0, bottom=h, right=w,
            channels={-1: a, 0: r, 1: g, 2: b},
            color_mode=ps_enums.ColorMode.rgb,
        )
        ps_layers.append(layer)
    # na ordem do PSD, o topo da lista fica por cima
    ps_layers = list(reversed(ps_layers))
    psd = nested_layers.nested_layers_to_psd(
        ps_layers, color_mode=ps_enums.ColorMode.rgb)
    with open(path, "wb") as f:
        psd.write(f)


def export_ora(path, base, layers):
    """OpenRaster: ZIP com PNG por camada + stack.xml. Abre no Krita/GIMP."""
    h, w = base.shape[:2]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("mimetype", "image/openraster", zipfile.ZIP_STORED)
        image = ET.Element("image", {"w": str(w), "h": str(h)})
        stack = ET.SubElement(image, "stack")
        tmp_dir = os.path.join(os.path.dirname(path), "_ora_tmp")
        os.makedirs(tmp_dir, exist_ok=True)
        # topo da lista = frente; no ORA o primeiro <layer> fica por cima
        for i, (name, rgba) in enumerate(reversed(layers)):
            fn = "data/layer%02d.png" % i
            buf = os.path.join(tmp_dir, "l%02d.png" % i)
            Image.fromarray(rgba, "RGBA").save(buf)
            z.write(buf, fn)
            ET.SubElement(stack, "layer",
                          {"name": name, "src": fn, "opacity": "1.0"})
        merged = os.path.join(tmp_dir, "merged.png")
        Image.fromarray(base, "RGBA").save(merged)
        z.write(merged, "mergedimage.png")
        thumb = Image.fromarray(base, "RGBA").convert("RGBA")
        thumb.thumbnail((256, 256))
        tp = os.path.join(tmp_dir, "thumb.png")
        thumb.save(tp)
        z.write(tp, "Thumbnails/thumbnail.png")
        z.writestr("stack.xml",
                   '<?xml version="1.0" encoding="UTF-8"?>\n'
                   + ET.tostring(image, encoding="unicode"))
        for f in os.listdir(tmp_dir):
            os.remove(os.path.join(tmp_dir, f))
        os.rmdir(tmp_dir)


# ----------------------------------------------------------------- janela

class MainWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("VTuber Layers")
        self.resize(1180, 820)
        self.parts = list(DEFAULT_PARTS)
        self.image_path = None

        self.canvas = Canvas()
        self.setCentralWidget(self.canvas)

        self._build_menu()
        self._build_dock()
        self._refresh_parts()
        self.statusBar().showMessage(self._deps_line())

    def _deps_line(self):
        bits = []
        bits.append("PSD nativo: " + ("ok" if HAS_PSD else "indisponivel (usa .ora)"))
        bits.append("remover fundo: " + ("ok" if HAS_REMBG else "off"))
        bits.append("OpenCV: " + ("ok" if HAS_CV2 else "off"))
        return "   |   ".join(bits)

    def _build_menu(self):
        m = self.menuBar().addMenu("Arquivo")
        a_open = m.addAction("Abrir PNG...")
        a_open.triggered.connect(self.open_image)
        a_exp = m.addAction("Exportar camadas...")
        a_exp.triggered.connect(self.export)
        m.addSeparator()
        m.addAction("Sair", self.close)

    def _build_dock(self):
        dock = QtWidgets.QDockWidget("Partes e ferramentas", self)
        dock.setFeatures(QtWidgets.QDockWidget.DockWidgetMovable)
        w = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(w)

        lay.addWidget(QtWidgets.QLabel("Camadas (de tras para frente):"))
        self.list = QtWidgets.QListWidget()
        self.list.currentRowChanged.connect(self._pick_part)
        lay.addWidget(self.list, 1)

        row = QtWidgets.QHBoxLayout()
        b_add = QtWidgets.QPushButton("+ parte")
        b_add.clicked.connect(self._add_part)
        b_del = QtWidgets.QPushButton("- parte")
        b_del.clicked.connect(self._del_part)
        b_up = QtWidgets.QPushButton("sobe")
        b_up.clicked.connect(lambda: self._move(-1))
        b_dn = QtWidgets.QPushButton("desce")
        b_dn.clicked.connect(lambda: self._move(1))
        for b in (b_add, b_del, b_up, b_dn):
            row.addWidget(b)
        lay.addLayout(row)

        lay.addWidget(self._hline())
        lay.addWidget(QtWidgets.QLabel("Pincel"))
        self.sld = QtWidgets.QSlider(Qt.Horizontal)
        self.sld.setRange(2, 200)
        self.sld.setValue(self.canvas.brush)
        self.sld.valueChanged.connect(self._set_brush)
        lay.addWidget(self.sld)

        self.chk_erase = QtWidgets.QCheckBox("Borracha (ou use o botao direito)")
        self.chk_erase.toggled.connect(lambda v: setattr(self.canvas, "erasing", v))
        lay.addWidget(self.chk_erase)

        self.chk_all = QtWidgets.QCheckBox("Mostrar todas as camadas")
        self.chk_all.toggled.connect(self._toggle_all)
        lay.addWidget(self.chk_all)

        lay.addWidget(self._hline())
        b_bg = QtWidgets.QPushButton("Remover fundo (auto)")
        b_bg.clicked.connect(self.auto_bg)
        lay.addWidget(b_bg)
        b_fill = QtWidgets.QPushButton("Preencher 'fundo' com o resto")
        b_fill.clicked.connect(self.fill_bg_part)
        lay.addWidget(b_fill)
        b_clear = QtWidgets.QPushButton("Limpar parte atual")
        b_clear.clicked.connect(self.clear_part)
        lay.addWidget(b_clear)

        lay.addWidget(self._hline())
        b_export = QtWidgets.QPushButton("EXPORTAR CAMADAS")
        b_export.setMinimumHeight(40)
        f = b_export.font(); f.setBold(True); f.setPointSize(11)
        b_export.setFont(f)
        b_export.clicked.connect(self.export)
        lay.addWidget(b_export)

        tip = QtWidgets.QLabel(
            "Dica: esquerdo pinta, direito apaga, roda do mouse muda o "
            "tamanho do pincel. Pinte so a parte visivel de cada peca; o "
            "app reconstroi a margem atras das bordas na exportacao.")
        tip.setWordWrap(True)
        tip.setStyleSheet("color:#888;")
        lay.addWidget(tip)

        dock.setWidget(w)
        dock.setMinimumWidth(300)
        self.addDockWidget(Qt.RightDockWidgetArea, dock)

    def _hline(self):
        line = QtWidgets.QFrame()
        line.setFrameShape(QtWidgets.QFrame.HLine)
        return line

    def sync_brush(self, v):
        self.sld.blockSignals(True)
        self.sld.setValue(v)
        self.sld.blockSignals(False)

    def _set_brush(self, v):
        self.canvas.brush = v

    def _refresh_parts(self):
        self.list.blockSignals(True)
        self.list.clear()
        self.canvas.all_colors = {}
        for i, name in enumerate(self.parts):
            it = QtWidgets.QListWidgetItem(name)
            c = part_color(i)
            self.canvas.all_colors[name] = c
            it.setIcon(self._swatch(c))
            self.list.addItem(it)
        self.list.blockSignals(False)
        if self.parts:
            self.list.setCurrentRow(0)

    def _swatch(self, color):
        pm = QtGui.QPixmap(16, 16)
        pm.fill(QtGui.QColor(*color))
        return QtGui.QIcon(pm)

    def _pick_part(self, row):
        if 0 <= row < len(self.parts):
            self.canvas.set_current(self.parts[row], part_color(row))

    def _add_part(self):
        name, ok = QtWidgets.QInputDialog.getText(self, "Nova parte", "Nome:")
        if ok and name.strip():
            self.parts.append(name.strip())
            self._refresh_parts()
            self.list.setCurrentRow(len(self.parts) - 1)

    def _del_part(self):
        row = self.list.currentRow()
        if 0 <= row < len(self.parts):
            name = self.parts.pop(row)
            self.canvas.masks.pop(name, None)
            self._refresh_parts()

    def _move(self, d):
        row = self.list.currentRow()
        n = row + d
        if 0 <= row < len(self.parts) and 0 <= n < len(self.parts):
            self.parts[row], self.parts[n] = self.parts[n], self.parts[row]
            self._refresh_parts()
            self.list.setCurrentRow(n)

    def _toggle_all(self, v):
        self.canvas.show_all = v
        self.canvas.update()

    # --- acoes ---
    def open_image(self):
        path, _ = QtWidgets.QFileDialog.getOpenFileName(
            self, "Abrir PNG", "", "Imagens (*.png *.webp *.jpg *.jpeg)")
        if not path:
            return
        try:
            img = Image.open(path).convert("RGBA")
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro", str(e))
            return
        self.image_path = path
        self.canvas.set_image(np.array(img, np.uint8))
        self._refresh_parts()
        self.statusBar().showMessage("Carregado: %s   (%dx%d)"
                                     % (os.path.basename(path), img.width, img.height))

    def auto_bg(self):
        if self.canvas.base is None:
            return
        if not HAS_REMBG:
            QtWidgets.QMessageBox.information(
                self, "Remover fundo",
                "O modulo 'rembg' nao esta instalado.\n\n"
                "Instale com:  pip install rembg onnxruntime\n"
                "ou apague o fundo na mao com a camada 'fundo'.")
            return
        QtWidgets.QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            out = rembg.remove(Image.fromarray(self.canvas.base, "RGBA"))
            arr = np.array(out.convert("RGBA"), np.uint8)
            self.canvas.set_image(arr)
            self._refresh_parts()
            self.statusBar().showMessage("Fundo removido. Agora pinte as partes.")
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro", str(e))
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()

    def fill_bg_part(self):
        """Marca em 'fundo' tudo que ainda nao foi atribuido a nenhuma parte."""
        if self.canvas.base is None or "fundo" not in self.parts:
            return
        h, w = self.canvas.base.shape[:2]
        used = np.zeros((h, w), np.uint8)
        for name, m in self.canvas.masks.items():
            if name != "fundo":
                used = np.maximum(used, (m > 0).astype(np.uint8))
        bg = ((used == 0).astype(np.uint8)) * 255
        self.canvas.masks["fundo"] = bg
        self.canvas.update()
        self.statusBar().showMessage("Camada 'fundo' preenchida com o restante.")

    def clear_part(self):
        if self.canvas.current and self.canvas.current in self.canvas.masks:
            self.canvas.masks[self.canvas.current][:] = 0
            self.canvas.update()

    def export(self):
        if self.canvas.base is None:
            return
        painted = [n for n in self.parts
                   if n in self.canvas.masks and self.canvas.masks[n].max() > 0]
        if not painted:
            QtWidgets.QMessageBox.information(
                self, "Exportar", "Pinte pelo menos uma parte antes de exportar.")
            return
        default = os.path.splitext(self.image_path or "modelo")[0] + "_camadas"
        flt = "PSD (*.psd);;OpenRaster (*.ora)" if HAS_PSD else "OpenRaster (*.ora)"
        path, sel = QtWidgets.QFileDialog.getSaveFileName(
            self, "Exportar camadas", default, flt)
        if not path:
            return
        QtWidgets.QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            layers = build_layers(self.canvas.base, self.canvas.masks, self.parts)
            wrote = []
            if path.lower().endswith(".psd") and HAS_PSD:
                try:
                    export_psd(path, self.canvas.base, layers)
                    wrote.append(path)
                except Exception as e:
                    ora = os.path.splitext(path)[0] + ".ora"
                    export_ora(ora, self.canvas.base, layers)
                    wrote.append(ora)
                    QtWidgets.QMessageBox.warning(
                        self, "PSD falhou",
                        "Nao deu pra gravar o PSD (%s).\nSalvei em .ora: %s"
                        % (e, ora))
            else:
                if not path.lower().endswith(".ora"):
                    path = os.path.splitext(path)[0] + ".ora"
                export_ora(path, self.canvas.base, layers)
                wrote.append(path)
            # sempre tambem salva os PNGs soltos, uteis de qualquer jeito
            png_dir = os.path.splitext(wrote[0])[0] + "_png"
            os.makedirs(png_dir, exist_ok=True)
            for i, (name, rgba) in enumerate(layers):
                Image.fromarray(rgba, "RGBA").save(
                    os.path.join(png_dir, "%02d_%s.png" % (i, name)))
            QtWidgets.QMessageBox.information(
                self, "Pronto",
                "Camadas exportadas:\n%s\n\nPNGs soltos em:\n%s"
                % ("\n".join(wrote), png_dir))
            self.statusBar().showMessage("Exportado: " + wrote[0])
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "Erro ao exportar", str(e))
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()


def main():
    app = QtWidgets.QApplication(sys.argv)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
