#!/usr/bin/env bash

echo "Installing Python on appVM"
curl https://pyenv.run | bash

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

echo "installing latest python..."
pyenv install 3.11
