#!/usr/bin/env bash

# Error trapping: exit on errors and pipe failures. 'nounset' is left off
# because `eval "$(pyenv init -)"` and pyenv's profile sourcing are not
# nounset-clean (the same constraint that applies to nvm in node/app-vm.sh,
# but pyenv touches profile in more places so the selective wrap would be
# noisy here).
set -Eeo pipefail

echo "Installing Python on appVM"
# pyenv is kept, in preference to the apt python3 package, for the flexibility
# of installing and switching Python versions -- see TRUST.md. The installer is
# an unverified curl|bash; -fsSL at least makes it fail on an HTTP error.
curl -fsSL https://pyenv.run | bash

echo "setting .profile..."
echo -e "\
export PYENV_ROOT=\"\$HOME/.pyenv\"\n\
command -v pyenv >/dev/null || export PATH=\"\$PYENV_ROOT/bin:\$PATH\"\n\
eval \"\$(pyenv init -)\"" >> ~/.profile

echo "reloading .profile twice..."
source ~/.profile
source ~/.profile

echo "setting .bashrc..."
echo "eval \"\$(pyenv virtualenv-init -)\"" >> ~/.bashrc

echo "installing Python 3.13.13..."
pyenv install 3.13.13

echo "setting symlink..."
sudo ln -s /usr/bin/python3 /usr/local/bin/python

echo "setting global python version..."
pyenv global 3.13.13

echo "installing virtualenv..."
pip install virtualenv

echo "updating pip..."
pip install --upgrade pip
