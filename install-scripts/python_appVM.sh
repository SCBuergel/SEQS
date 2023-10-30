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
pyenv install 3.11.6

echo "setting symlink..."
sudo ln -s /usr/bin/python3 /usr/local/bin/python

echo "setting global python version..."
pyenv global 3.11.6

echo "installing virtualenv..."
pip install virtualenv

echo "updating pip..."
pip install --upgrade pip

echo "adding deleting of Qubes and Downloads folder to .bashrc"
echo "
rm -rf QubesIncoming
rm -rf Downloads/*" >> .bashrc
