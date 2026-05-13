#!/bin/bash
# setup_deps.sh — one-time install of the tools the lint suite needs.
#
# Run once after cloning:
#   bash tests/setup_deps.sh
set -uo pipefail

OS="$(uname -s)"
FAILED=0

echo "Setting up lint dependencies..."
echo

# --- shellcheck ---
if command -v shellcheck >/dev/null 2>&1; then
    echo "✓ shellcheck already installed ($(shellcheck --version | grep ^version: | awk '{print $2}'))"
else
    echo "→ Installing shellcheck..."
    if [ "$OS" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            brew install shellcheck || FAILED=1
        else
            echo "  ✗ Homebrew not found. Install from https://brew.sh first." >&2
            FAILED=1
        fi
    elif [ "$OS" = "Linux" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y shellcheck || FAILED=1
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y ShellCheck || FAILED=1
        else
            echo "  ✗ Unknown package manager. Install shellcheck manually." >&2
            FAILED=1
        fi
    else
        echo "  ✗ Unsupported OS: $OS. Install shellcheck manually." >&2
        FAILED=1
    fi
fi

# --- PyYAML ---
PYTHON=$(command -v python3 || command -v python)
if [ -z "$PYTHON" ]; then
    echo "✗ python3 not found. Install Python 3 first." >&2
    FAILED=1
elif "$PYTHON" -c "import yaml" 2>/dev/null; then
    echo "✓ PyYAML already installed"
else
    echo "→ Installing PyYAML..."
    # On macOS / Linux with externally-managed Python, --user works without --break-system-packages
    "$PYTHON" -m pip install --user pyyaml 2>/dev/null \
        || "$PYTHON" -m pip install --user --break-system-packages pyyaml 2>/dev/null \
        || { echo "  ✗ pip install failed. Try: $PYTHON -m pip install --user pyyaml"; FAILED=1; }
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "✗ Some dependencies failed to install. Address the errors above." >&2
    exit 1
fi

# Enable git hooks if not already.
if [ "$(git config --get core.hooksPath)" != ".githooks" ]; then
    echo "→ Enabling .githooks/ for pre-commit (was: $(git config --get core.hooksPath || echo "<default>"))"
    git config core.hooksPath .githooks
fi

echo "✓ Setup complete. Run 'bash tests/lint/run_all.sh' to verify."
