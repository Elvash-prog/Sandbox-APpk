@echo off
rem Inicia o VTuber Layers sem precisar de administrador.
rem Cria um ambiente Python local na propria pasta (.venv).
cd /d "%~dp0"

where py >nul 2>&1 && (set "PY=py") || (set "PY=python")
%PY% --version >nul 2>&1 || (echo.& echo [ERRO] Python nao encontrado. Instale em https://www.python.org/downloads/ ^(marque "Add to PATH"^).& echo Nao precisa de administrador: na instalacao escolha "Install for me only".& pause& exit /b 1)

if not exist ".venv\Scripts\python.exe" (
  echo Criando ambiente local pela primeira vez...
  %PY% -m venv .venv || (echo [ERRO] Falha ao criar o ambiente.& pause& exit /b 1)
)

call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip >nul 2>&1

python -c "import PySide6, numpy, PIL, cv2" 2>nul || (
  echo Instalando dependencias ^(so na primeira vez^)...
  pip install -r requirements.txt || (echo [ERRO] Falha ao instalar.& pause& exit /b 1)
)

rem Opcionais ^(PSD nativo e remover fundo^); se falhar, segue com .ora
python -c "import pytoshop" 2>nul || pip install -r requirements-extra.txt 2>nul

python vtuber_layers.py
if errorlevel 1 pause
